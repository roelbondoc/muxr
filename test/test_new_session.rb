require "test_helper"
require "tmpdir"
require "socket"
require "stringio"
require "muxr"

class TestDirectoryPrompt < Minitest::Test
  def setup
    @root = File.realpath(Dir.mktmpdir("muxr-dirs"))
    %w[phoenix phoenix-frontend platform .hidden].each { |d| Dir.mkdir(File.join(@root, d)) }
    File.write(File.join(@root, "phoenix-notes.txt"), "")
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def prompt(buffer = "")
    Muxr::DirectoryPrompt.new(base: @root, buffer: buffer)
  end

  def test_tab_extends_to_the_common_prefix_and_lists_the_candidates
    p = prompt("pho")
    p.complete
    assert_equal "phoenix", p.buffer
    assert_equal %w[phoenix phoenix-frontend], p.candidates
  end

  def test_a_unique_match_completes_with_a_trailing_slash
    p = prompt("pla")
    p.complete
    assert_equal "platform/", p.buffer
    assert_empty p.candidates
  end

  def test_completion_ignores_files_and_hidden_directories_unless_asked
    p = prompt("")
    p.complete
    assert_equal %w[phoenix phoenix-frontend platform], p.candidates
    dotted = prompt(".h")
    dotted.complete
    assert_equal ".hidden/", dotted.buffer
  end

  def test_completion_works_below_an_absolute_path
    p = prompt("#{@root}/plat")
    p.complete
    assert_equal "#{@root}/platform/", p.buffer
  end

  def test_editing_drops_stale_candidates
    p = prompt("pho")
    p.complete
    p.type("-")
    assert_empty p.candidates
  end

  def test_ctrl_w_removes_one_path_component
    p = prompt("src/phoenix/platform")
    p.delete_component
    assert_equal "src/phoenix/", p.buffer
    p.delete_component
    assert_equal "src/", p.buffer
  end

  def test_paths_resolve_relative_to_the_base_and_must_be_directories
    assert_equal File.join(@root, "platform"), prompt("platform").resolved_dir
    assert_equal File.join(@root, "platform"), prompt(" #{@root}/platform/ ").resolved_dir
    assert_nil prompt("phoenix-notes.txt").resolved_dir
    assert_nil prompt("missing").resolved_dir
    assert_nil prompt("  ").resolved_dir
  end

  def test_the_preview_names_the_session_muxr_would_use_for_that_directory
    preview = prompt("platform").preview
    assert_equal Muxr::Application.default_session_name(File.join(@root, "platform")), preview.session
    refute preview.running
  end
end

class TestApplicationNewSession < Minitest::Test
  class FakeProcess
    def io; nil; end
    def writer_io; nil; end
    def pending_write?; false; end
    def write(_); end
    def resize(_, _); end
    def alive?; true; end
    def cwd; "/tmp"; end
    def pid; nil; end
    def close; end
  end

  def setup
    @sockets_dir = Dir.mktmpdir("mx", "/tmp")
    @original = Muxr::Application::SOCKETS_DIR
    Muxr::Application.send(:remove_const, :SOCKETS_DIR)
    Muxr::Application.const_set(:SOCKETS_DIR, @sockets_dir)
    @root = File.realpath(Dir.mktmpdir("n", "/tmp"))
    Dir.mkdir(File.join(@root, "proj"))
    @app = Muxr::Application.new(["-s", "here"])
    @app.instance_variable_set(:@origin_cwd, @root)
    @app.instance_variable_set(:@session, Muxr::Session.new(name: "here", width: 80, height: 24))
    @app.instance_variable_set(:@renderer, Object.new.tap { |r| def r.reset_frame!; end })
    @app.instance_variable_set(:@input, Muxr::InputHandler.new(@app))
    @app.session.window.add_pane(Muxr::Pane.new(process: FakeProcess.new))
    ours, @client = UNIXSocket.pair
    @app.instance_variable_set(:@current_client, ours)
    @spawned = []
    spawned = @spawned
    Muxr::Application.singleton_class.alias_method(:real_spawn_server, :spawn_server)
    Muxr::Application.define_singleton_method(:spawn_server) { |name, cwd:| spawned << [name, cwd] }
  end

  def teardown
    Muxr::Application.singleton_class.alias_method(:spawn_server, :real_spawn_server)
    Muxr::Application.singleton_class.send(:remove_method, :real_spawn_server)
    @client.close rescue nil
    Muxr::Application.send(:remove_const, :SOCKETS_DIR)
    Muxr::Application.const_set(:SOCKETS_DIR, @original)
    FileUtils.remove_entry(@sockets_dir)
    FileUtils.remove_entry(@root)
  end

  def flashed
    @app.instance_variable_get(:@message)
  end

  def expected_name
    Muxr::Application.default_session_name(File.join(@root, "proj"))
  end

  def test_a_new_directory_starts_a_server_there_and_switches_the_client
    @app.new_session("proj")
    assert_equal [[expected_name, File.join(@root, "proj")]], @spawned
    type, payload = Muxr::Protocol.read(@client)
    assert_equal Muxr::Protocol::BYE, type
    assert_equal "switch #{expected_name}", payload
  end

  def test_a_directory_with_a_running_session_switches_without_spawning
    server = UNIXServer.new(Muxr::Application.socket_path_for(expected_name))
    @app.new_session(File.join(@root, "proj"))
    assert_empty @spawned
    assert_equal "switch #{expected_name}", Muxr::Protocol.read(@client)[1]
  ensure
    server&.close
  end

  def test_a_bad_path_is_flashed_and_keeps_the_client
    @app.new_session("nope")
    assert_match(/not a directory: nope/, flashed)
    assert @app.client_attached?
    assert_empty @spawned
  end

  def test_the_current_sessions_own_directory_is_refused
    @app.instance_variable_set(:@session_name, expected_name)
    @app.new_session("proj")
    assert_match(/already in session/, flashed)
    assert @app.client_attached?
  end

  def test_the_prompt_flows_from_open_to_confirm
    @app.open_new_session_prompt
    assert_equal :directory_prompt, @app.input.state
    "pro".each_char { |ch| @app.edit_directory_prompt(:type, ch) }
    @app.edit_directory_prompt(:complete)
    assert_equal "proj/", @app.directory_prompt.buffer
    @app.confirm_directory_prompt
    assert_nil @app.directory_prompt
    assert_equal [[expected_name, File.join(@root, "proj")]], @spawned
  end
end

class TestInputHandlerNewSession < Minitest::Test
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

  def test_N_and_prefix_N_open_the_prompt
    @input.feed("N")
    @input.enter_passthrough_mode
    @input.feed("\x01N")
    assert_equal 2, @app.calls.count(:open_new_session_prompt)
  end

  def test_keys_edit_the_path
    @input.enter_directory_prompt_mode
    @input.feed("q~/\t\x7f\x15\x17\e[A")
    assert_equal [
      [:edit_directory_prompt, :type, "q"], [:edit_directory_prompt, :type, "~"], [:edit_directory_prompt, :type, "/"],
      [:edit_directory_prompt, :complete], [:edit_directory_prompt, :backspace],
      [:edit_directory_prompt, :clear], [:edit_directory_prompt, :delete_component]
    ], @app.calls
    assert_equal :directory_prompt, @input.state
  end

  def test_enter_confirms_and_esc_cancels
    @input.enter_directory_prompt_mode
    @input.feed("\r")
    assert_equal :confirm_directory_prompt, @app.calls.last
    assert_equal :normal, @input.state
    @input.enter_directory_prompt_mode
    @input.feed("\e")
    assert_equal :cancel_directory_prompt, @app.calls.last
  end

  def test_new_with_a_directory_starts_a_session_and_bare_new_opens_the_prompt
    dispatcher = Muxr::CommandDispatcher.new(@app)
    dispatcher.dispatch("new ~/src/my project")
    dispatcher.dispatch("new")
    dispatcher.dispatch("new_pane")
    dispatcher.dispatch("c")
    assert_equal [[:new_session, "~/src/my project"], :open_new_session_prompt, :new_pane, :new_pane], @app.calls
  end
end

class TestClientWaitsForANewServer < Minitest::Test
  def test_connecting_retries_until_the_socket_appears
    dir = Dir.mktmpdir("mx")
    path = File.join(dir, "late.sock")
    server = nil
    Thread.new { sleep 0.2; server = UNIXServer.new(path) }
    sock = Muxr::Client.new("x").send(:open_when_ready, path)
    assert sock
  ensure
    sock&.close
    server&.close
    FileUtils.remove_entry(dir)
  end
end

class TestRendererDirectoryPrompt < Minitest::Test
  def test_the_modal_shows_the_path_the_verdict_and_candidates
    root = File.realpath(Dir.mktmpdir("muxr-render"))
    %w[alpha alpine].each { |d| Dir.mkdir(File.join(root, d)) }
    prompt = Muxr::DirectoryPrompt.new(base: root, buffer: "al")
    prompt.complete
    session = Muxr::Session.new(name: "spec", width: 120, height: 24)
    pane = Struct.new(:rect, :terminal) { def resize(*); end }.new(nil, Muxr::Terminal.new(rows: 5, cols: 20))
    session.window.add_pane(pane)
    out = StringIO.new
    Muxr::Renderer.new(out: out).render(session, input_state: :directory_prompt, directory_prompt: prompt)
    term = Muxr::Terminal.new(rows: 24, cols: 120)
    term.feed(out.string.b)
    screen = term.dump_text
    assert_includes screen, "New session"
    assert_includes screen, "> al"
    assert_includes screen, "alpha/"
    assert_includes screen, "alpine/"
    assert_includes screen, "not a directory"
  ensure
    FileUtils.remove_entry(root) if root
  end
end
