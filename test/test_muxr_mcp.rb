require "test_helper"
require "muxr"
require "json"
require "open3"
require "socket"
require "tmpdir"
require "timeout"

load File.expand_path("../bin/muxr-mcp", __dir__)

# End-to-end test for bin/muxr-mcp. Boots a ControlServer in-process,
# spawns the bridge as a subprocess pointed at our socket via env, and
# drives the bridge via MCP JSON-RPC on stdio.
class TestMuxrMcp < Minitest::Test
  BRIDGE_PATH = File.expand_path("../bin/muxr-mcp", __dir__)

  class FakeProcess
    attr_reader :writes
    def initialize; @writes = +"".b; end
    def io; nil; end
    def writer_io; nil; end
    def pending_write?; false; end
    def drain; end
    def write(data); @writes << data.b; end
    def read_nonblock(_ = 8192); nil; end
    def resize(_, _); end
    def alive?; true; end
    def cwd; "/tmp/fake"; end
    def close; end
  end

  class FakeApp
    attr_accessor :session
    def invalidate; end
    def new_pane(cwd: nil); pane = Muxr::Pane.new(process: FakeProcess.new); @session.window.add_pane(pane); pane; end
    def toggle_drawer; end
    def show_drawer; end
    def hide_drawer; end
    def reset_drawer; end
  end

  def build_app(name = "mcp-spec")
    app = FakeApp.new
    app.session = Muxr::Session.new(name: name, width: 80, height: 24)
    2.times do |i|
      pane = Muxr::Pane.new(process: FakeProcess.new)
      pane.terminal.feed("pane#{i}-content")
      app.session.window.add_pane(pane)
    end
    app
  end

  # Run a tiny IO.select loop for the ControlServer in a background thread
  # so the bridge's blocking reads on the socket actually complete.
  def with_control_server(app)
    Dir.mktmpdir("muxr-mcp-test") do |dir|
      path = File.join(dir, "spec.ctrl.sock")
      server = Muxr::ControlServer.new(app, path)
      server.start
      stop = false
      thread = Thread.new do
        until stop
          read_ios = server.read_ios
          write_ios = server.write_ios
          ready_r, ready_w, = IO.select(read_ios, write_ios, nil, 0.05)
          (ready_r || []).each { |io| server.handle_read(io) }
          (ready_w || []).each { |io| server.handle_write(io) }
          server.tick
        end
      end
      begin
        yield path
      ensure
        stop = true
        thread.join(2)
        server.stop
      end
    end
  end

  def with_bridge(socket_path, extra_env = {})
    env = { "MUXR_CONTROL_SOCKET" => socket_path, "MUXR_SESSION" => nil, "MUXR_PANE" => nil }.merge(extra_env)
    Open3.popen3(env, RbConfig.ruby, BRIDGE_PATH) do |stdin, stdout, stderr, wait|
      io = BridgeIO.new(stdin, stdout, stderr, wait)
      begin
        yield io
      ensure
        io.close
      end
    end
  end

  class BridgeIO
    def initialize(stdin, stdout, stderr, wait)
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @wait = wait
      @next_id = 0
    end

    def request(method, params = {})
      @next_id += 1
      rid = @next_id
      @stdin.write(JSON.generate({ "jsonrpc" => "2.0", "id" => rid, "method" => method, "params" => params }) + "\n")
      @stdin.flush
      Timeout.timeout(5) do
        loop do
          line = @stdout.gets
          raise "bridge closed stdout (stderr: #{drain_stderr})" if line.nil?
          msg = JSON.parse(line.strip)
          next unless msg["id"] == rid
          return msg
        end
      end
    end

    def notify(method, params = {})
      @stdin.write(JSON.generate({ "jsonrpc" => "2.0", "method" => method, "params" => params }) + "\n")
      @stdin.flush
    end

    def drain_stderr
      @stderr.read_nonblock(4096) rescue ""
    end

    def close
      @stdin.close rescue nil
      @stdout.close rescue nil
      @stderr.close rescue nil
      Process.kill("TERM", @wait.pid) rescue nil
      @wait.join
    end
  end

  def test_initialize_and_tools_list
    app = build_app
    with_control_server(app) do |path|
      with_bridge(path) do |bridge|
        init = bridge.request("initialize", { "protocolVersion" => "2024-11-05" })
        assert_equal "muxr-mcp", init["result"]["serverInfo"]["name"]
        assert init["result"]["capabilities"]["tools"]

        bridge.notify("notifications/initialized")

        tools = bridge.request("tools/list")
        names = tools["result"]["tools"].map { |t| t["name"] }
        assert_includes names, "muxr_panes_list"
        assert_includes names, "muxr_pane_run"
        assert_includes names, "muxr_drawer_toggle"
      end
    end
  end

  def test_panes_list_tool_call
    app = build_app
    with_control_server(app) do |path|
      with_bridge(path) do |bridge|
        bridge.request("initialize", { "protocolVersion" => "2024-11-05" })
        bridge.notify("notifications/initialized")
        resp = bridge.request("tools/call", { "name" => "muxr_panes_list", "arguments" => {} })
        text = resp["result"]["content"][0]["text"]
        parsed = JSON.parse(text)
        assert_equal 2, parsed["panes"].length
        assert parsed["panes"].all? { |p| p["id"].match?(/\A[0-9a-f]{6}\z/) }
      end
    end
  end

  def test_pane_send_input_round_trip
    app = build_app
    target = app.session.window.panes[1]
    with_control_server(app) do |path|
      with_bridge(path) do |bridge|
        bridge.request("initialize", { "protocolVersion" => "2024-11-05" })
        bridge.notify("notifications/initialized")
        bridge.request("tools/call", {
          "name" => "muxr_pane_send_input",
          "arguments" => { "pane" => target.id, "data" => "hi" }
        })
      end
    end
    # The control thread already shut down; the write should have landed.
    assert_equal "hi".b, target.process.writes
  end

  def test_unknown_tool_returns_error_content
    app = build_app
    with_control_server(app) do |path|
      with_bridge(path) do |bridge|
        bridge.request("initialize", { "protocolVersion" => "2024-11-05" })
        bridge.notify("notifications/initialized")
        resp = bridge.request("tools/call", { "name" => "muxr_bogus", "arguments" => {} })
        assert resp["result"]["isError"]
        assert_match(/Unknown tool/, resp["result"]["content"][0]["text"])
      end
    end
  end

  def test_drawer_methods_refused_when_inside_drawer
    app = build_app
    Dir.mktmpdir("muxr-mcp-test") do |dir|
      path = File.join(dir, "spec.ctrl.sock")
      server = Muxr::ControlServer.new(app, path)
      server.start
      stop = false
      thread = Thread.new do
        until stop
          ready_r, ready_w, = IO.select(server.read_ios, server.write_ios, nil, 0.05)
          (ready_r || []).each { |io| server.handle_read(io) }
          (ready_w || []).each { |io| server.handle_write(io) }
          server.tick
        end
      end
      env = { "MUXR_CONTROL_SOCKET" => path, "MUXR_DRAWER_SELF" => "1" }
      Open3.popen3(env, RbConfig.ruby, BRIDGE_PATH) do |stdin, stdout, stderr, wait|
        io = BridgeIO.new(stdin, stdout, stderr, wait)
        begin
          io.request("initialize", { "protocolVersion" => "2024-11-05" })
          io.notify("notifications/initialized")
          resp = io.request("tools/call", { "name" => "muxr_drawer_toggle", "arguments" => {} })
          assert resp["result"]["isError"]
          assert_match(/inside the drawer/, resp["result"]["content"][0]["text"])
        ensure
          io.close
        end
      end
    ensure
      stop = true
      thread&.join(2)
      server&.stop
    end
  end

  def test_pane_methods_refused_on_own_pane
    app = build_app
    own = app.session.window.panes[0]
    other = app.session.window.panes[1]
    with_control_server(app) do |path|
      with_bridge(path, "MUXR_PANE" => own.id) do |bridge|
        bridge.request("initialize", { "protocolVersion" => "2024-11-05" })
        bridge.notify("notifications/initialized")

        %w[muxr_pane_read muxr_pane_send_input muxr_pane_run muxr_pane_kill].each do |tool|
          resp = bridge.request("tools/call", { "name" => tool, "arguments" => { "pane" => own.id, "data" => "x", "command" => "x" } })
          assert resp["result"]["isError"], "#{tool} should refuse its own pane"
          assert_match(/this claude\s+session is running in/, resp["result"]["content"][0]["text"])
        end

        resp = bridge.request("tools/call", { "name" => "muxr_pane_read", "arguments" => { "pane" => other.id } })
        refute resp["result"]["isError"], "a different pane should still be readable"

        resp = bridge.request("tools/call", { "name" => "muxr_pane_focus", "arguments" => { "pane" => own.id } })
        refute resp["result"]["isError"], "focusing your own pane is harmless and stays allowed"
      end
    end
  end

  def test_handshake_succeeds_outside_muxr
    with_bridge(nil) do |bridge|
      init = bridge.request("initialize", { "protocolVersion" => "2024-11-05" })
      assert_equal "muxr-mcp", init["result"]["serverInfo"]["name"]
      bridge.notify("notifications/initialized")

      tools = bridge.request("tools/list")
      assert_empty tools["result"]["tools"]

      resp = bridge.request("tools/call", { "name" => "muxr_panes_list", "arguments" => {} })
      assert resp["result"]["isError"]
      assert_match(/not running inside muxr/, resp["result"]["content"][0]["text"])
    end
  end

  def test_tool_call_reconnects_after_server_restart
    app = build_app
    Dir.mktmpdir("muxr-mcp-test") do |dir|
      path = File.join(dir, "spec.ctrl.sock")
      with_bridge(path) do |bridge|
        run_control_server(app, path) do
          bridge.request("initialize", { "protocolVersion" => "2024-11-05" })
          bridge.notify("notifications/initialized")
          resp = bridge.request("tools/call", { "name" => "muxr_ping", "arguments" => {} })
          refute resp["result"]["isError"]
        end

        run_control_server(app, path) do
          resp = bridge.request("tools/call", { "name" => "muxr_ping", "arguments" => {} })
          refute resp["result"]["isError"], "bridge should have reconnected to the restarted server"
          assert_equal true, JSON.parse(resp["result"]["content"][0]["text"])["pong"]
        end
      end
    end
  end

  def test_bridge_follows_a_pane_moved_to_another_session
    source = build_app("alpha")
    dest = build_app("beta")
    moved = dest.session.window.panes[0]
    Dir.mktmpdir("muxr-mcp-test") do |dir|
      alpha = File.join(dir, "alpha.ctrl.sock")
      beta = File.join(dir, "beta.ctrl.sock")
      run_control_server(source, alpha) do
        run_control_server(dest, beta) do
          with_bridge(alpha, "MUXR_PANE" => moved.id) do |bridge|
            bridge.request("initialize", { "protocolVersion" => "2024-11-05" })
            bridge.notify("notifications/initialized")
            resp = bridge.request("tools/call", { "name" => "muxr_session_get", "arguments" => {} })
            name = JSON.parse(resp["result"]["content"][0]["text"])["name"]
            assert_equal "beta", name, "should follow the pane to the session that now owns it"
          end
        end
      end
    end
  end

  def test_bridge_finds_its_pane_when_the_env_session_is_gone
    dest = build_app("beta")
    moved = dest.session.window.panes[0]
    Dir.mktmpdir("muxr-mcp-test") do |dir|
      dead = File.join(dir, "alpha.ctrl.sock")
      beta = File.join(dir, "beta.ctrl.sock")
      run_control_server(dest, beta) do
        with_bridge(dead, "MUXR_PANE" => moved.id) do |bridge|
          bridge.request("initialize", { "protocolVersion" => "2024-11-05" })
          bridge.notify("notifications/initialized")

          tools = bridge.request("tools/list")
          refute_empty tools["result"]["tools"], "a reachable owner means the tools are usable"

          resp = bridge.request("tools/call", { "name" => "muxr_session_get", "arguments" => {} })
          name = JSON.parse(resp["result"]["content"][0]["text"])["name"]
          assert_equal "beta", name
        end
      end
    end
  end

  def test_bridge_re_resolves_when_its_pane_moves_mid_session
    source = build_app("alpha")
    dest = build_app("beta")
    moving = source.session.window.panes[0]
    Dir.mktmpdir("muxr-mcp-test") do |dir|
      alpha = File.join(dir, "alpha.ctrl.sock")
      beta = File.join(dir, "beta.ctrl.sock")
      run_control_server(source, alpha) do
        run_control_server(dest, beta) do
          with_env("MUXR_CONTROL_SOCKET" => alpha, "MUXR_SESSION" => nil, "MUXR_PANE" => moving.id) do
            bridge = MuxrMcpBridge.new
            assert bridge.send(:ensure_owning_connection)
            assert_equal "alpha", bridge_session_name(bridge)

            source.session.window.remove_pane(moving)
            dest.session.window.add_pane(moving)
            bridge.instance_variable_set(:@verified_at, nil)

            assert bridge.send(:ensure_owning_connection)
            assert_equal "beta", bridge_session_name(bridge), "a move under a live session should re-resolve"
          end
        end
      end
    end
  end

  # The borrowing session sorts first in the discovery scan, so a bridge that
  # ignored `origin` would settle on the mirror rather than the real owner.
  def test_a_mirror_is_not_evidence_of_ownership
    owner = build_app("zeta")
    borrower = build_app("alpha")
    shared = owner.session.window.panes[0]
    mirror = Muxr::Pane.new(id: shared.id, process: FakeProcess.new)
    mirror.origin = "zeta:#{shared.id}"
    borrower.session.window.add_pane(mirror)

    Dir.mktmpdir("muxr-mcp-test") do |dir|
      zeta = File.join(dir, "zeta.ctrl.sock")
      alpha = File.join(dir, "alpha.ctrl.sock")
      run_control_server(owner, zeta) do
        run_control_server(borrower, alpha) do
          with_env("MUXR_CONTROL_SOCKET" => File.join(dir, "gone.ctrl.sock"), "MUXR_SESSION" => nil, "MUXR_PANE" => shared.id) do
            bridge = MuxrMcpBridge.new
            assert bridge.send(:ensure_owning_connection)
            assert_equal "zeta", bridge_session_name(bridge), "discovery should skip the mirroring session"
          end
        end
      end
    end
  end

  def bridge_session_name(bridge)
    bridge.send(:send_muxr_request, "session.get", {})["result"]["name"]
  end

  def with_env(vars)
    previous = vars.keys.to_h { |key| [key, ENV[key]] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def run_control_server(app, path)
    server = Muxr::ControlServer.new(app, path)
    server.start
    stop = false
    thread = Thread.new do
      until stop
        ready_r, ready_w, = IO.select(server.read_ios, server.write_ios, nil, 0.05)
        (ready_r || []).each { |io| server.handle_read(io) }
        (ready_w || []).each { |io| server.handle_write(io) }
        server.tick
      end
    end
    yield
  ensure
    stop = true
    thread&.join(2)
    server&.stop
  end
end
