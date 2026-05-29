require "test_helper"
require "json"
require "socket"
require "tmpdir"
require "muxr/pane"
require "muxr/control_server"

# Lightweight stand-ins for Application/Pane that satisfy what the dispatcher
# and ControlServer reach for, without spawning real PTYs.
class TestControlServer < Minitest::Test
  class FakeProcess
    attr_reader :rows, :cols, :writes
    def initialize(rows: 24, cols: 80); @rows = rows; @cols = cols; @writes = +"".b; end
    def io; nil; end
    def writer_io; nil; end
    def pending_write?; false; end
    def drain; end
    def write(data); @writes << data.b; end
    def read_nonblock(_ = 8192); nil; end
    def resize(_, _); end
    def alive?; true; end
    def cwd; @cwd ||= "/tmp/fake"; end
    def close; end
  end

  # Minimal stand-in for Application. Tests reach for session, new_pane, and
  # the drawer toggles; everything else is unused on the read paths.
  class FakeApp
    attr_accessor :session

    def initialize
      @invalidated = 0
    end

    def invalidate; @invalidated += 1; end

    def new_pane(cwd: nil)
      pane = Muxr::Pane.new(process: FakeProcess.new)
      @session.window.add_pane(pane)
      @session.focus_drawer = false if @session.respond_to?(:focus_drawer=)
      @session.window.focused_index = @session.window.panes.length - 1
      invalidate
      pane
    end

    def toggle_drawer
      # tests that need a drawer instantiate one directly on the session
    end
    def show_drawer; end
    def hide_drawer; end
    def reset_drawer; end
  end

  def build_app
    app = FakeApp.new
    app.session = Muxr::Session.new(name: "spec", width: 100, height: 30)
    %w[home work scratch].each do |label|
      pane = Muxr::Pane.new(process: FakeProcess.new)
      pane.terminal.feed("pane:#{label}")
      app.session.window.add_pane(pane)
    end
    app.session.window.set_layout(:tall)
    app.session.window.focused_index = 1
    app.session.window.master_index = 0
    app
  end

  # Fake stand-in for ControlServer; the Dispatcher only calls a small subset
  # of methods on it (the pane.run / subscribe paths), so we mock just those.
  class FakeServer
    attr_reader :pending_runs, :subscriptions, :events

    def initialize
      @pending_runs = []
      @subscriptions = []
      @events = []
    end

    def register_pending_run(**kw)
      @pending_runs << kw
    end

    def add_subscription(io, pane_id)
      @subscriptions << [io, pane_id.to_s]
    end

    def remove_subscription(io, pane_id)
      @subscriptions.reject! { |s| s == [io, pane_id.to_s] }
    end
  end

  def dispatch(app, method, params = {}, server: FakeServer.new, client_io: nil, request_id: 1)
    Muxr::Dispatcher.new(app, server).call(
      method: method, params: params, client_io: client_io, request_id: request_id
    )
  end

  def dispatch_with(app, method, params = {}, server: FakeServer.new, client_io: nil, request_id: 1)
    result = Muxr::Dispatcher.new(app, server).call(
      method: method, params: params, client_io: client_io, request_id: request_id
    )
    [result, server]
  end

  def test_terminal_dump_text_trims_trailing_blanks_and_joins_rows
    t = Muxr::Terminal.new(rows: 3, cols: 10)
    t.feed("hello\r\nworld\r\n!!!")
    lines = t.dump_text.split("\n")
    assert_equal "hello", lines[0]
    assert_equal "world", lines[1]
    assert_equal "!!!",   lines[2]
  end

  def test_session_get
    app = build_app
    res = dispatch(app, "session.get")
    assert_equal "spec", res["name"]
    assert_equal "tall", res["layout"]
    assert_equal 3, res["pane_count"]
    assert_equal 2, res["focused_slot"]
    assert_equal 1, res["master_slot"]
    assert_includes res["available_layouts"], "grid"
    assert_equal({ "present" => false, "visible" => false }, res["drawer"])
  end

  def test_panes_list_returns_ids_and_slots
    app = build_app
    res = dispatch(app, "panes.list")
    panes = res["panes"]
    assert_equal 3, panes.length
    assert_equal [1, 2, 3], panes.map { |p| p["slot"] }
    panes.each { |p| assert_match(/\A[0-9a-f]{6}\z/, p["id"]) }
    assert panes[1]["focused"]
    refute panes[0]["focused"]
    assert panes[0]["master"]
  end

  def test_pane_read_by_id
    app = build_app
    target = app.session.window.panes[2]
    res = dispatch(app, "pane.read", { "pane" => target.id })
    assert_equal target.id, res["id"]
    assert_match(/pane:scratch/, res["text"])
  end

  def test_pane_read_by_slot
    app = build_app
    res = dispatch(app, "pane.read", { "slot" => 1 })
    assert_match(/pane:home/, res["text"])
  end

  def test_pane_read_unknown_raises
    app = build_app
    err = assert_raises(Muxr::Dispatcher::Error) do
      dispatch(app, "pane.read", { "pane" => "deadbe" })
    end
    assert_match(/no pane/, err.message)
  end

  def test_unknown_method_raises
    app = build_app
    err = assert_raises(Muxr::Dispatcher::Error) do
      dispatch(app, "bogus.method")
    end
    assert_equal Muxr::ControlServer::METHOD_NOT_FOUND, err.code
  end

  def test_drawer_read_when_absent
    app = build_app
    res = dispatch(app, "drawer.read")
    refute res["present"]
    refute res["visible"]
    assert_equal "", res["text"]
  end

  # ---- write methods ----

  def test_pane_send_input_writes_to_pane_process
    app = build_app
    target = app.session.window.panes[1]
    dispatch(app, "pane.send_input", { "pane" => target.id, "data" => "hello" })
    assert_equal "hello".b, target.process.writes
  end

  def test_pane_send_input_bracketed_wraps_paste_markers
    app = build_app
    target = app.session.window.panes[0]
    dispatch(app, "pane.send_input", { "pane" => target.id, "data" => "x", "bracketed" => true })
    assert_equal "\e[200~x\e[201~".b, target.process.writes
  end

  # ---- keys parameter ----

  def test_pane_send_input_keys_translates_named_keys
    app = build_app
    target = app.session.window.panes[0]
    # vim "open, paste, save" pattern — the original footgun from the
    # task description, now expressible as a single keys sequence.
    dispatch(app, "pane.send_input", {
      "pane" => target.id,
      "keys" => ["G", "o", "hello world", "<esc>", ":w", "<enter>"]
    })
    assert_equal "Gohello world\e:w\r".b, target.process.writes
  end

  def test_pane_send_input_keys_ctrl_c_and_ctrl_d
    app = build_app
    target = app.session.window.panes[0]
    dispatch(app, "pane.send_input", { "pane" => target.id, "keys" => ["<c-c>"] })
    assert_equal "\x03".b, target.process.writes
    target.process.writes.clear
    dispatch(app, "pane.send_input", { "pane" => target.id, "keys" => ["<c-d>"] })
    assert_equal "\x04".b, target.process.writes
  end

  def test_pane_send_input_keys_arrow_sequence
    app = build_app
    target = app.session.window.panes[0]
    dispatch(app, "pane.send_input", {
      "pane" => target.id,
      "keys" => ["<down>", "<down>", "<enter>"]
    })
    assert_equal "\e[B\e[B\r".b, target.process.writes
  end

  def test_pane_send_input_keys_bracketed_wraps_only_literal_segments
    # bracketed: true wraps each literal segment in \e[200~..\e[201~ but
    # leaves named keys bare — they aren't paste content.
    app = build_app
    target = app.session.window.panes[0]
    dispatch(app, "pane.send_input", {
      "pane" => target.id,
      "keys" => ["hello", "<esc>", "world"],
      "bracketed" => true
    })
    assert_equal "\e[200~hello\e[201~\e\e[200~world\e[201~".b, target.process.writes
  end

  def test_pane_send_input_keys_and_data_together_raises
    app = build_app
    target = app.session.window.panes[0]
    err = assert_raises(Muxr::Dispatcher::Error) do
      dispatch(app, "pane.send_input", { "pane" => target.id, "data" => "x", "keys" => ["y"] })
    end
    assert_match(/either `data` or `keys`/, err.message)
  end

  def test_pane_send_input_keys_unknown_named_key_raises
    app = build_app
    target = app.session.window.panes[0]
    assert_raises(Muxr::Dispatcher::Error) do
      dispatch(app, "pane.send_input", { "pane" => target.id, "keys" => ["<bogus>"] })
    end
    assert_equal "".b, target.process.writes
  end

  def test_pane_send_input_missing_both_raises
    app = build_app
    target = app.session.window.panes[0]
    assert_raises(Muxr::Dispatcher::Error) do
      dispatch(app, "pane.send_input", { "pane" => target.id })
    end
  end

  def test_pane_run_keys_translates_named_keys
    app = build_app
    target = app.session.window.panes[0]
    dispatch(app, "pane.run", {
      "pane" => target.id,
      "keys" => ["i", "hi", "<esc>"],
      "append_enter" => false
    })
    assert_equal "ihi\e".b, target.process.writes
  end

  def test_pane_run_keys_appends_enter_by_default
    app = build_app
    target = app.session.window.panes[0]
    dispatch(app, "pane.run", { "pane" => target.id, "keys" => [":q"] })
    assert_equal ":q\r".b, target.process.writes
  end

  def test_drawer_send_input_keys_translates
    app = build_app
    # Stand up a drawer with a fake pane so drawer_send_input has somewhere
    # to write. The FakeApp doesn't auto-create one.
    drawer_pane = Muxr::Pane.new(process: FakeProcess.new)
    app.session.drawer = Muxr::Drawer.new(pane: drawer_pane)
    dispatch(app, "drawer.send_input", { "keys" => ["<c-c>"] })
    assert_equal "\x03".b, drawer_pane.process.writes
  end

  def test_pane_focus_changes_focused_index
    app = build_app
    target = app.session.window.panes[2]
    res = dispatch(app, "pane.focus", { "pane" => target.id })
    assert_equal 3, res["slot"]
    assert_equal 2, app.session.window.focused_index
  end

  def test_pane_kill_removes_pane
    app = build_app
    target = app.session.window.panes[1]
    dispatch(app, "pane.kill", { "pane" => target.id })
    refute app.session.window.panes.any? { |p| p.id == target.id }
  end

  def test_pane_promote_moves_pane_to_front
    app = build_app
    target = app.session.window.panes[2]
    dispatch(app, "pane.promote", { "pane" => target.id })
    assert_equal target.id, app.session.window.panes[0].id
    assert_equal 0, app.session.window.master_index
  end

  def test_pane_new_appends_new_pane
    app = build_app
    res = dispatch(app, "pane.new")
    assert_equal 4, res["slot"]
    assert_equal 4, app.session.window.panes.length
    assert_equal res["pane"], app.session.window.panes.last.id
  end

  def test_layout_set_changes_layout
    app = build_app
    res = dispatch(app, "layout.set", { "layout" => "grid" })
    assert_equal "grid", res["layout"]
    assert_equal :grid, app.session.window.layout
  end

  def test_layout_set_unknown_raises
    app = build_app
    assert_raises(Muxr::Dispatcher::Error) do
      dispatch(app, "layout.set", { "layout" => "floating" })
    end
  end

  def test_layout_cycle_advances_layout
    app = build_app
    app.session.window.set_layout(:tall)
    res = dispatch(app, "layout.cycle")
    assert_equal "wide", res["layout"]
  end

  # ---- pane.run ----

  def test_pane_run_registers_pending_run_and_writes_input
    app = build_app
    target = app.session.window.panes[0]
    result, server = dispatch_with(app, "pane.run",
      { "pane" => target.id, "input" => "ls", "idle_ms" => 100, "timeout_ms" => 2_000 },
      request_id: 7)
    assert_equal :deferred, result
    assert_equal 1, server.pending_runs.length
    run = server.pending_runs.first
    assert_equal target.id, run[:pane_id]
    assert_equal 7, run[:request_id]
    assert_in_delta 0.1, run[:idle_seconds], 0.001
    # input + carriage return appended (append_enter default true)
    assert_equal "ls\r".b, target.process.writes
  end

  def test_pane_run_without_append_enter
    app = build_app
    target = app.session.window.panes[0]
    dispatch(app, "pane.run", { "pane" => target.id, "input" => "x", "append_enter" => false })
    assert_equal "x".b, target.process.writes
  end

  def test_pane_run_requires_request_id
    app = build_app
    target = app.session.window.panes[0]
    assert_raises(Muxr::Dispatcher::Error) do
      dispatch(app, "pane.run", { "pane" => target.id }, request_id: nil)
    end
  end

  def test_pane_subscribe_and_unsubscribe
    app = build_app
    target = app.session.window.panes[0]
    server = FakeServer.new
    io = Object.new
    dispatch(app, "pane.subscribe", { "pane" => target.id }, server: server, client_io: io)
    assert_includes server.subscriptions, [io, target.id]
    dispatch(app, "pane.unsubscribe", { "pane" => target.id }, server: server, client_io: io)
    refute_includes server.subscriptions, [io, target.id]
  end

  # ---- pane.run end-to-end with real ControlServer ----

  # Stand-in for a connected UNIXSocket. ControlServer reaches for
  # write_nonblock; everything else is unused on the resolution path.
  class FakeIO
    attr_reader :written
    def initialize; @written = +"".b; end
    def write_nonblock(data); @written << data.b; data.bytesize; end
    def close; end
  end

  def make_unsocketed_server(app)
    # The socket path is never bound (start is not called) — we drive the
    # server through its public hooks directly. This keeps the test from
    # touching the filesystem.
    Muxr::ControlServer.new(app, "/tmp/muxr-test-#{Process.pid}.ctrl.sock")
  end

  def register_fake_client(server)
    io = FakeIO.new
    server.instance_variable_get(:@clients)[io] = { read_buffer: +"", write_buffer: +"".b }
    io
  end

  def test_pane_run_completes_after_idle_window
    app = build_app
    target = app.session.window.panes[0]
    server = make_unsocketed_server(app)
    io = register_fake_client(server)

    Muxr::Dispatcher.new(app, server).call(
      method: "pane.run",
      params: { "pane" => target.id, "input" => "", "append_enter" => false, "idle_ms" => 60, "timeout_ms" => 5_000 },
      client_io: io,
      request_id: 99
    )
    assert_equal 1, server.instance_variable_get(:@pending_runs).length

    server.on_pane_output(target.id, "x")
    sleep 0.08
    server.tick
    parsed = JSON.parse(io.written.lines.first.strip)
    assert_equal 99, parsed["id"]
    refute parsed["result"]["timed_out"]
    assert parsed["result"]["had_output"]
    assert_equal target.id, parsed["result"]["pane"]
  end

  def test_pane_run_times_out_when_no_output
    app = build_app
    target = app.session.window.panes[0]
    server = make_unsocketed_server(app)
    io = register_fake_client(server)

    Muxr::Dispatcher.new(app, server).call(
      method: "pane.run",
      params: { "pane" => target.id, "input" => "", "append_enter" => false, "idle_ms" => 500, "timeout_ms" => 100 },
      client_io: io,
      request_id: 100
    )
    sleep 0.12
    server.tick
    parsed = JSON.parse(io.written.lines.first.strip)
    assert parsed["result"]["timed_out"]
    refute parsed["result"]["had_output"]
  end

  def test_pane_subscribe_emits_event_on_output
    app = build_app
    target = app.session.window.panes[0]
    server = make_unsocketed_server(app)
    io = register_fake_client(server)

    Muxr::Dispatcher.new(app, server).call(
      method: "pane.subscribe",
      params: { "pane" => target.id },
      client_io: io,
      request_id: 1
    )
    server.on_pane_output(target.id, "ignored-payload")
    lines = io.written.lines.map { |l| JSON.parse(l.strip) }
    events = lines.select { |l| l["method"] == "event.pane.output" }
    assert_equal 1, events.length
    assert_equal target.id, events[0]["params"]["pane"]
  end

  # ---- end-to-end: real socket, real ControlServer, NDJSON round-trip ----

  def test_socket_round_trip
    Dir.mktmpdir("muxr-ctrl") do |dir|
      app = build_app
      path = File.join(dir, "spec.ctrl.sock")
      server = Muxr::ControlServer.new(app, path)
      server.start

      # Connect, write a request, drain reads via the server's handle_read
      # until the response lands. We drive the loop manually because there's
      # no Application running.
      client = UNIXSocket.new(path)
      pump = lambda do
        # Accept any new connection.
        ready_r, _, = IO.select(server.read_ios, [], [], 0.1)
        (ready_r || []).each { |io| server.handle_read(io) }
        ready_w = server.write_ios
        unless ready_w.empty?
          (IO.select(nil, ready_w, [], 0)&.dig(1) || []).each { |io| server.handle_write(io) }
        end
      end

      client.write(JSON.generate({ id: 1, method: "panes.list" }) + "\n")

      # Pump until the response is readable on client side, or we give up.
      response = nil
      buf = +""
      8.times do
        pump.call
        begin
          buf << client.read_nonblock(4096)
        rescue IO::WaitReadable
          # keep pumping
        end
        if buf.include?("\n")
          line, _, _rest = buf.partition("\n")
          response = JSON.parse(line)
          break
        end
        sleep 0.01
      end
      refute_nil response, "did not receive response (buffer was: #{buf.inspect})"
      assert_equal 1, response["id"]
      assert_equal 3, response["result"]["panes"].length
    ensure
      client&.close
      server&.stop
    end
  end

  # ---- private panes ----

  def test_panes_list_marks_private_and_strips_cwd
    app = build_app
    secret = app.session.window.panes[1]
    secret.mark_private!
    res = dispatch(app, "panes.list")
    entry = res["panes"].find { |p| p["id"] == secret.id }
    assert entry["private"]
    refute entry.key?("cwd"), "cwd should be redacted on private panes"
    refute entry.key?("rows")
    refute entry.key?("cols")
    public_entry = res["panes"].find { |p| p["id"] == app.session.window.panes[0].id }
    refute public_entry["private"]
    assert public_entry.key?("cwd")
  end

  def test_pane_read_refused_on_private_pane
    app = build_app
    secret = app.session.window.panes[0]
    secret.mark_private!
    err = assert_raises(Muxr::Dispatcher::Error) do
      dispatch(app, "pane.read", { "pane" => secret.id })
    end
    assert_match(/private/, err.message)
  end

  def test_pane_send_input_refused_on_private_pane
    app = build_app
    secret = app.session.window.panes[0]
    secret.mark_private!
    assert_raises(Muxr::Dispatcher::Error) do
      dispatch(app, "pane.send_input", { "pane" => secret.id, "data" => "x" })
    end
    assert_equal "".b, secret.process.writes
  end

  def test_pane_kill_refused_on_private_pane
    app = build_app
    secret = app.session.window.panes[0]
    secret.mark_private!
    assert_raises(Muxr::Dispatcher::Error) do
      dispatch(app, "pane.kill", { "pane" => secret.id })
    end
    assert_includes app.session.window.panes, secret
  end

  def test_pane_run_refused_on_private_pane
    app = build_app
    secret = app.session.window.panes[0]
    secret.mark_private!
    assert_raises(Muxr::Dispatcher::Error) do
      dispatch(app, "pane.run", { "pane" => secret.id, "input" => "ls" })
    end
    assert_equal "".b, secret.process.writes
  end

  def test_pane_subscribe_refused_on_private_pane
    app = build_app
    secret = app.session.window.panes[0]
    secret.mark_private!
    assert_raises(Muxr::Dispatcher::Error) do
      dispatch(app, "pane.subscribe", { "pane" => secret.id })
    end
  end

  def test_pane_focus_still_allowed_on_private_pane
    # Focus is a layout op and doesn't expose contents. Allowed so the
    # human can ask Claude to "switch to my private pane".
    app = build_app
    secret = app.session.window.panes[1]
    secret.mark_private!
    res = dispatch(app, "pane.focus", { "pane" => secret.id })
    assert_equal secret.id, res["pane"]
  end
end
