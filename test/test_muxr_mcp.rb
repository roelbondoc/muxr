require "test_helper"
require "muxr"
require "json"
require "open3"
require "socket"
require "tmpdir"
require "timeout"

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

  def build_app
    app = FakeApp.new
    app.session = Muxr::Session.new(name: "mcp-spec", width: 80, height: 24)
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

  def with_bridge(socket_path)
    env = { "MUXR_CONTROL_SOCKET" => socket_path }
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
end
