require_relative "test_helper"
require "muxr/application"
require "muxr/input_handler"
require "muxr/terminal"
require "muxr/window"

# Scrollback is pane-bound: focusing a pane that was left scrolled re-enters
# scrollback, and a select-mode yank returns to scrollback at the current
# position instead of snapping to the live bottom.
class TestApplicationScrollbackFollowsFocus < Minitest::Test
  FakeSession = Struct.new(:window, :focus_drawer, :drawer)

  class FakeRenderer
    def reset_frame!; end
  end

  class FakePane
    attr_reader :terminal
    def initialize(terminal)
      @terminal = terminal
    end
  end

  # A real Terminal carrying `n` lines of scrollback, scrolled back by
  # `back` rows (0 = sitting at the live bottom).
  def terminal_scrolled(back:)
    term = Muxr::Terminal.new(rows: 5, cols: 20)
    12.times { |i| term.feed("line#{i}\r\n") }
    term.scroll_back(back) if back.positive?
    term
  end

  def build_app(panes:)
    app = Muxr::Application.new([])
    win = Muxr::Window.new
    panes.each { |p| win.add_pane(p) }
    app.instance_variable_set(:@session, FakeSession.new(win, false, nil))
    app.instance_variable_set(:@renderer, FakeRenderer.new)
    input = Muxr::InputHandler.new(app)
    app.instance_variable_set(:@input, input)
    [app, input]
  end

  def test_focusing_scrolled_pane_auto_enters_scrollback
    live = FakePane.new(terminal_scrolled(back: 0))
    scrolled = FakePane.new(terminal_scrolled(back: 3))
    app, input = build_app(panes: [live, scrolled])
    input.enter_passthrough_mode
    app.focus_next # land on the scrolled pane
    assert_equal :scrollback, input.state
  end

  def test_focusing_live_pane_leaves_mode_untouched
    a = FakePane.new(terminal_scrolled(back: 0))
    b = FakePane.new(terminal_scrolled(back: 0))
    app, input = build_app(panes: [a, b])
    input.enter_passthrough_mode
    app.focus_next # both panes are live
    assert_equal :passthrough, input.state
  end

  def test_focus_pane_number_auto_enters_scrollback
    live = FakePane.new(terminal_scrolled(back: 0))
    scrolled = FakePane.new(terminal_scrolled(back: 2))
    app, input = build_app(panes: [live, scrolled])
    input.enter_passthrough_mode
    app.focus_pane_number(2) # 1-based → the scrolled pane
    assert_equal :scrollback, input.state
  end

  def test_selection_yank_exit_returns_to_scrollback_without_snapping
    term = terminal_scrolled(back: 3)
    offset_before = term.view_offset
    assert offset_before.positive?, "fixture should start scrolled back"
    app, input = build_app(panes: [FakePane.new(term)])
    input.enter_selection_mode
    app.exit_selection(yank: false)
    assert_equal :scrollback, input.state
    assert_equal offset_before, term.view_offset, "yank exit must not snap to bottom"
  end
end

class TestApplicationListActive < Minitest::Test
  def with_isolated_sockets_dir
    Dir.mktmpdir("muxr-sockets") do |dir|
      original = Muxr::Application::SOCKETS_DIR
      Muxr::Application.send(:remove_const, :SOCKETS_DIR)
      Muxr::Application.const_set(:SOCKETS_DIR, dir)
      begin
        yield dir
      ensure
        Muxr::Application.send(:remove_const, :SOCKETS_DIR)
        Muxr::Application.const_set(:SOCKETS_DIR, original)
      end
    end
  end

  def test_list_active_returns_empty_when_dir_missing
    Dir.mktmpdir("muxr-sockets") do |tmp|
      missing = File.join(tmp, "does-not-exist")
      original = Muxr::Application::SOCKETS_DIR
      Muxr::Application.send(:remove_const, :SOCKETS_DIR)
      Muxr::Application.const_set(:SOCKETS_DIR, missing)
      begin
        assert_equal [], Muxr::Application.list_active
      ensure
        Muxr::Application.send(:remove_const, :SOCKETS_DIR)
        Muxr::Application.const_set(:SOCKETS_DIR, original)
      end
    end
  end

  def test_list_active_returns_empty_when_no_sockets
    with_isolated_sockets_dir do
      assert_equal [], Muxr::Application.list_active
    end
  end

  def test_list_active_returns_names_of_alive_sockets
    with_isolated_sockets_dir do |dir|
      alive_a = UNIXServer.new(File.join(dir, "work.sock"))
      alive_b = UNIXServer.new(File.join(dir, "play.sock"))
      begin
        assert_equal %w[play work], Muxr::Application.list_active
      ensure
        alive_a.close
        alive_b.close
      end
    end
  end

  def test_list_active_skips_stale_sockets_and_non_sock_files
    with_isolated_sockets_dir do |dir|
      alive = UNIXServer.new(File.join(dir, "alive.sock"))
      # A regular file with .sock extension — connect() will fail with ECONNREFUSED.
      File.write(File.join(dir, "stale.sock"), "")
      # Something unrelated in the same directory.
      File.write(File.join(dir, "notes.txt"), "ignore me")
      begin
        assert_equal %w[alive], Muxr::Application.list_active
      ensure
        alive.close
      end
    end
  end
end
