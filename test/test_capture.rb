require "test_helper"
require "muxr"
require_relative "support/pane_fakes"

class TestCapture < Minitest::Test
  include PaneFakes

  def test_history_and_screen_come_out_as_plain_text
    term = Muxr::Terminal.new(rows: 3, cols: 20)
    term.feed("\e[31mone\e[0m\r\ntwo   \r\nthree\r\nfour\r\nfive")
    assert_equal "one\ntwo\nthree\nfour\nfive\n", term.dump_history_text
  end

  def test_trailing_blank_rows_are_dropped_and_an_empty_pane_is_empty
    term = Muxr::Terminal.new(rows: 5, cols: 10)
    assert_equal "", term.dump_history_text
    term.feed("hi")
    assert_equal "hi\n", term.dump_history_text
  end

  def test_wide_glyphs_are_not_split_or_padded
    term = Muxr::Terminal.new(rows: 2, cols: 10)
    term.feed("中文 ok")
    assert_equal "中文 ok\n", term.dump_history_text
  end

  def test_a_full_screen_program_does_not_hide_the_shell_underneath
    term = Muxr::Terminal.new(rows: 3, cols: 20)
    term.feed("$ less file\r\n")
    term.feed("\e[?1049h\e[Hpager frame")
    assert_equal "$ less file\n", term.dump_history_text
  end

  def app_with(pane)
    app = Muxr::Application.new([])
    win = Muxr::Window.new
    win.add_pane(pane)
    app.instance_variable_set(:@session, FakeSession.new(win, false, nil))
    app
  end

  def test_the_command_writes_the_file_it_was_given
    Dir.mktmpdir("muxr-capture") do |dir|
      pane = Muxr::Pane.new(id: "aaaaaa", process: ScriptedProcess.new)
      pane.terminal.feed("hello\r\nworld")
      app = app_with(pane)
      app.instance_variable_set(:@origin_cwd, dir)
      Muxr::CommandDispatcher.new(app).dispatch("capture out/log.txt")
      assert_equal "hello\nworld\n", File.read(File.join(dir, "out", "log.txt"))
      assert_match(/captured 2 lines/, app.instance_variable_get(:@message))
    end
  end

  def test_the_default_path_names_the_session_and_the_pane
    pane = Muxr::Pane.new(id: "aaaaaa", process: ScriptedProcess.new)
    pane.name = "api server"
    path = app_with(pane).capture_path(pane, nil)
    assert path.start_with?(Muxr::Application::CAPTURES_DIR)
    assert_match(%r{-api-server-\d{8}-\d{6}\.txt\z}, path)
  end

  def test_a_failed_write_is_flashed
    pane = Muxr::Pane.new(id: "aaaaaa", process: ScriptedProcess.new)
    app = app_with(pane)
    assert_nil app.capture_focused("/dev/null/nope.txt")
    assert_match(/capture failed/, app.instance_variable_get(:@message))
  end
end
