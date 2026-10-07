require "test_helper"
require "tmpdir"
require "socket"
require "stringio"
require "muxr"
require "minitest/mock"

class TestApplicationSwitch < Minitest::Test
  class FakeProcess
    def io; nil; end
    def writer_io; nil; end
    def pending_write?; false; end
    def write(_); end
    def resize(_, _); end
    def alive?; true; end
    def cwd; "/tmp/local"; end
    def pid; nil; end
    def close; end
  end

  class RecordingRenderer
    def reset_frame!; end
  end

  def setup
    @dir = Dir.mktmpdir("muxr-switch")
    @original = Muxr::Application::SOCKETS_DIR
    Muxr::Application.send(:remove_const, :SOCKETS_DIR)
    Muxr::Application.const_set(:SOCKETS_DIR, @dir)
    @app = Muxr::Application.new(["-s", "here"])
    @app.instance_variable_set(:@session, Muxr::Session.new(name: "here", width: 80, height: 24))
    @app.instance_variable_set(:@renderer, RecordingRenderer.new)
    @app.instance_variable_set(:@input, Muxr::InputHandler.new(@app))
    @panes = 3.times.map { |i| Muxr::Pane.new(id: "pane0#{i}", process: FakeProcess.new) }
    @panes.each { |pane| @app.session.window.add_pane(pane) }
    @app.session.window.focused_index = 0
    @servers = []
    @sockets = []
  end

  def teardown
    (@servers + @sockets).each { |io| io.close rescue nil }
    Muxr::Application.send(:remove_const, :SOCKETS_DIR)
    Muxr::Application.const_set(:SOCKETS_DIR, @original)
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def listen(name)
    server = UNIXServer.new(Muxr::Application.socket_path_for(name))
    @servers << server
    server
  end

  def attach_client
    ours, theirs = UNIXSocket.pair
    @sockets.push(ours, theirs)
    @attached = ours
    @app.instance_variable_set(:@current_client, ours)
    theirs
  end

  def bye_reason(io)
    type, payload = Muxr::Protocol.read(io)
    assert_equal Muxr::Protocol::BYE, type
    payload
  end

  def test_switching_within_the_session_focuses_the_pane_by_id_name_or_slot
    @panes[2].name = "agent"
    @app.switch_client("here", "pane01")
    assert_equal 1, @app.session.window.focused_index
    @app.switch_client("here", "agent")
    assert_equal 2, @app.session.window.focused_index
    @app.switch_client("here", "1")
    assert_equal 0, @app.session.window.focused_index
  end

  def test_an_unknown_local_pane_is_flashed
    @app.switch_client("here", "nope")
    assert_match(/no pane nope/, @app.instance_variable_get(:@message))
  end

  def test_switching_to_a_session_that_is_not_running_keeps_the_client
    client = attach_client
    @app.switch_client("elsewhere", "abc123")
    assert @app.client_attached?
    assert_match(/no running session elsewhere/, @app.instance_variable_get(:@message))
    refute IO.select([client], nil, nil, 0)
  end

  def test_switching_to_another_session_hands_the_client_a_switch_bye
    listen("elsewhere")
    client = attach_client
    @app.switch_client("elsewhere", "abc123")
    refute @app.client_attached?
    assert_equal "switch elsewhere abc123", bye_reason(client)
  end

  def test_a_departing_client_is_sent_to_a_detached_session_other_than_this_one
    attach_client
    pick = ->(exclude:) { exclude == "here" ? ["elsewhere"] : [] }
    Muxr::SessionDirectory.stub(:detached_sessions, pick) do
      assert_equal "switch elsewhere", @app.send(:departure_reason)
    end
  end

  def test_a_departing_session_without_a_client_looks_nothing_up
    Muxr::SessionDirectory.stub(:detached_sessions, ->(**) { flunk "queried other sessions" }) do
      assert_nil @app.send(:departure_reason)
    end
  end

  def test_quitting_moves_the_client_to_a_detached_session
    client = attach_client
    Muxr::SessionDirectory.stub(:detached_sessions, ["elsewhere"]) { @app.confirm_quit }
    assert_equal "switch elsewhere", bye_reason(client)
  end

  def test_quitting_the_only_session_still_says_shutdown
    client = attach_client
    Muxr::SessionDirectory.stub(:detached_sessions, []) { @app.confirm_quit }
    assert_equal "shutdown", bye_reason(client)
  end

  def test_a_takeover_hello_replaces_the_attached_client
    @app.instance_variable_set(:@listening_socket, listen("here"))
    old = attach_client
    newcomer = UNIXSocket.new(Muxr::Application.socket_path_for("here"))
    @sockets << newcomer
    Muxr::Protocol.write(newcomer, Muxr::Protocol::HELLO, Muxr::Protocol.encode_size(30, 100, { takeover: 1 }))

    @app.send(:accept_client)

    assert_match(/taken over/, bye_reason(old))
    assert @app.client_attached?
    assert_equal [100, 30], [@app.session.width, @app.session.height]
  end

  def test_a_plain_hello_is_still_turned_away_while_attached
    @app.instance_variable_set(:@listening_socket, listen("here"))
    old = attach_client
    newcomer = UNIXSocket.new(Muxr::Application.socket_path_for("here"))
    @sockets << newcomer
    Muxr::Protocol.write(newcomer, Muxr::Protocol::HELLO, Muxr::Protocol.encode_size(30, 100))

    @app.send(:accept_client)

    assert_equal "busy", bye_reason(newcomer)
    assert_same @attached, @app.instance_variable_get(:@current_client)
    refute IO.select([old], nil, nil, 0)
  end

  def test_confirming_the_switcher_on_a_local_pane_focuses_it
    entries = @panes.each_with_index.map do |pane, i|
      Muxr::SessionDirectory::Entry.new(session: "here", pane_id: pane.id, slot: i + 1, state: "idle", here: true)
    end
    @app.instance_variable_set(:@switcher, Muxr::PaneSwitcher.new(entries, query: "pane02"))
    @app.confirm_switcher
    assert_nil @app.switcher
    assert_equal 2, @app.session.window.focused_index
  end

  def test_the_switcher_lists_local_panes_without_querying_its_own_socket
    server = Muxr::ControlServer.new(@app, File.join(@dir, "here.ctrl.sock"))
    @app.instance_variable_set(:@control_server, server)
    @panes[1].foreground_command = "claude"
    @app.open_switcher("cmd:claude")
    assert_equal :switcher, @app.input.state
    assert_equal ["pane01"], @app.switcher.rows.map(&:pane_id)
    assert @app.switcher.rows.first.here
  end
end

class TestInputHandlerSwitcher < Minitest::Test
  class FakeApp
    attr_reader :calls

    def initialize
      @calls = []
    end

    def method_missing(name, *args)
      @calls << (args.empty? ? name : [name, *args])
      nil
    end

    def respond_to_missing?(*) = true
  end

  def setup
    @app = FakeApp.new
    @input = Muxr::InputHandler.new(@app)
  end

  def test_o_and_prefix_space_open_the_switcher
    @input.feed("o")
    assert_includes @app.calls, :open_switcher
    @input.enter_passthrough_mode
    @input.feed("\x01 ")
    assert_equal 2, @app.calls.count(:open_switcher)
  end

  def test_printable_keys_type_into_the_filter_including_q_and_j
    @input.enter_switcher_mode
    @input.feed("qj:")
    assert_equal [[:type_switcher, "q"], [:type_switcher, "j"], [:type_switcher, ":"]], @app.calls
    assert_equal :switcher, @input.state
  end

  def test_navigation_editing_and_exit_keys
    @input.enter_switcher_mode
    @input.feed("\e[B\e[A\x0e\x10\t\x7f\x15\x12")
    assert_equal [
      [:move_switcher, 1], [:move_switcher, -1], [:move_switcher, 1], [:move_switcher, -1],
      [:move_switcher, 1], :backspace_switcher, :clear_switcher_query, :refresh_switcher
    ], @app.calls
    @input.feed("\r")
    assert_equal :confirm_switcher, @app.calls.last
    assert_equal :normal, @input.state
    @input.enter_switcher_mode
    @input.feed("\e")
    assert_equal :cancel_switcher, @app.calls.last
  end

  def test_the_switch_command_opens_it_with_a_query
    Muxr::CommandDispatcher.new(@app).dispatch("switch cmd:claude is:idle")
    assert_includes @app.calls, [:open_switcher, "cmd:claude is:idle"]
  end
end

class TestClientSwitch < Minitest::Test
  def test_a_switch_bye_names_the_target
    client = Muxr::Client.new("here")
    client.instance_variable_set(:@bye_reason, "switch other-session abc123")
    assert_equal ["other-session", "abc123"], client.send(:switch_target)
    client.instance_variable_set(:@bye_reason, "switch other-session")
    assert_equal ["other-session", nil], client.send(:switch_target)
    client.instance_variable_set(:@bye_reason, "detached")
    assert_nil client.send(:switch_target)
  end
end

class TestRendererSwitcher < Minitest::Test
  def test_the_switcher_overlay_shows_the_query_and_rows
    session = Muxr::Session.new(name: "spec", width: 140, height: 20)
    terminal = Muxr::Terminal.new(rows: 5, cols: 20)
    pane = Struct.new(:rect, :terminal) { def resize(*); end }.new(nil, terminal)
    session.window.add_pane(pane)
    entries = [
      Muxr::SessionDirectory::Entry.new(session: "Users-me-src-project", pane_id: "abc123", slot: 2,
                                        command: "claude", state: "busy", idle: 75.0, bell: true,
                                        title: "◐ Fixing the build")
    ]
    out = StringIO.new
    Muxr::Renderer.new(out: out).render(session, input_state: :switcher, switcher: Muxr::PaneSwitcher.new(entries, query: "cmd:cl"))
    painted = out.string
    %w[cmd:cl busy claude 1m PANES UPDATED].each { |text| assert_includes painted, text }
    assert_includes painted, "Fixing"
    assert_includes painted, "#2"
  end

  def switcher_frame(entries, state: :switcher)
    session = Muxr::Session.new(name: "spec", width: 140, height: 20)
    terminal = Muxr::Terminal.new(rows: 5, cols: 20)
    pane = Struct.new(:rect, :terminal) { def resize(*); end }.new(nil, terminal)
    session.window.add_pane(pane)
    out = StringIO.new
    Muxr::Renderer.new(out: out).render(session, input_state: state, switcher: Muxr::PaneSwitcher.new(entries))
    out.string
  end

  def entry(**fields)
    Muxr::SessionDirectory::Entry.new(session: "spec", pane_id: "abc123", slot: 1, state: "idle", **fields)
  end

  def test_the_pane_you_are_on_is_labelled
    painted = switcher_frame([entry(here: true, focused: true, title: "vim"), entry(pane_id: "def456", slot: 2, here: true)])
    assert_includes painted, "this pane"
    assert_equal 1, painted.scan("this pane").length
  end

  def test_the_focused_pane_of_another_session_is_not_labelled
    refute_includes switcher_frame([entry(session: "other", focused: true)]), "this pane"
  end

  def test_the_real_cursor_stays_hidden_under_the_overlays
    %i[switcher pane_picker directory_prompt help].each do |state|
      painted = switcher_frame([entry], state: state)
      refute_includes painted, "\e[?25h", "cursor shown under #{state}"
    end
  end
end
