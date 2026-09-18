require_relative "test_helper"
require "muxr/application"
require "muxr/input_handler"
require "muxr/mouse_report"
require "muxr/terminal"
require "muxr/window"

class TestMouseReport < Minitest::Test
  def test_sgr_wheel_up_and_down
    assert_equal "\e[<64;40;13M", Muxr::MouseReport.wheel(:up, row: 13, col: 40)
    assert_equal "\e[<65;40;13M", Muxr::MouseReport.wheel(:down, row: 13, col: 40)
  end

  def test_x10_offsets_coordinates_by_32
    report = Muxr::MouseReport.wheel(:up, row: 13, col: 40, encoding: :x10)
    assert_equal "\e[M#{(32 + 64).chr}#{(32 + 40).chr}#{(32 + 13).chr}", report
  end

  def test_x10_clamps_coordinates_past_its_encodable_range
    report = Muxr::MouseReport.wheel(:down, row: 900, col: 900, encoding: :x10)
    assert_equal "\e[M#{(32 + 65).chr}#{255.chr}#{255.chr}", report
  end
end

class TestTerminalMouseModes < Minitest::Test
  def terminal
    Muxr::Terminal.new(rows: 10, cols: 40)
  end

  def test_starts_with_no_mouse_tracking
    term = terminal
    refute term.mouse_tracking?
    assert_equal :x10, term.mouse_encoding
  end

  def test_tracks_the_sequence_claude_code_emits
    term = terminal
    term.feed("\e[?1000h\e[?1006h")
    assert term.mouse_tracking?
    assert_equal :sgr, term.mouse_encoding
  end

  def test_each_tracking_mode_counts
    [1000, 1002, 1003].each do |mode|
      term = terminal
      term.feed("\e[?#{mode}h")
      assert term.mouse_tracking?, "mode #{mode} should enable tracking"
      term.feed("\e[?#{mode}l")
      refute term.mouse_tracking?, "mode #{mode} should disable tracking"
    end
  end

  def test_disabling_one_mode_leaves_another_on
    term = terminal
    term.feed("\e[?1000h\e[?1002h\e[?1000l")
    assert term.mouse_tracking?
  end

  def test_enabling_twice_still_clears_on_one_reset
    term = terminal
    term.feed("\e[?1000h\e[?1000h\e[?1000l")
    refute term.mouse_tracking?
  end

  def test_application_cursor_keys_tracked
    term = terminal
    refute term.app_cursor_keys?
    term.feed("\e[?1h")
    assert term.app_cursor_keys?
    term.feed("\e[?1l")
    refute term.app_cursor_keys?
  end

  def test_dump_ansi_carries_mouse_modes_to_a_mirror
    term = terminal
    term.feed("\e[?1002h\e[?1006h\e[?1h")
    copy = Muxr::Terminal.new(rows: 10, cols: 40)
    copy.feed(term.dump_ansi)
    assert copy.mouse_tracking?
    assert_equal :sgr, copy.mouse_encoding
    assert copy.app_cursor_keys?
  end
end

class TestApplicationAppScroll < Minitest::Test
  FakeSession = Struct.new(:window, :focus_drawer, :drawer)

  class FakeRenderer
    def reset_frame!; end
  end

  class FakePane
    attr_reader :terminal, :written
    def initialize(terminal)
      @terminal = terminal
      @written = +"".b
    end

    def write(data)
      @written << data
    end
  end

  def plain_terminal
    term = Muxr::Terminal.new(rows: 10, cols: 40)
    20.times { |i| term.feed("line#{i}\r\n") }
    term
  end

  def mouse_terminal
    term = plain_terminal
    term.feed("\e[?1000h\e[?1006h")
    term
  end

  def alt_screen_terminal
    term = plain_terminal
    term.feed("\e[?1049h")
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

  def flashed(app)
    app.instance_variable_get(:@message)
  end

  def selection_row(term)
    term.instance_variable_get(:@selection_cursor)[0]
  end

  def test_mouse_tracking_pane_starts_on_the_apps_own_scroll
    app, input = build_app(panes: [FakePane.new(mouse_terminal)])
    app.enter_scrollback
    assert_equal :scrollback, input.state
    assert_equal :app, input.scroll_source
  end

  def test_plain_pane_starts_on_muxr_history
    app, input = build_app(panes: [FakePane.new(plain_terminal)])
    app.enter_scrollback
    assert_equal :ring, input.scroll_source
  end

  def test_alt_screen_pane_no_longer_refuses
    app, input = build_app(panes: [FakePane.new(alt_screen_terminal)])
    app.enter_scrollback
    assert_equal :scrollback, input.state
    assert_equal :app, input.scroll_source
  end

  def test_line_scroll_sends_one_wheel_report
    pane = FakePane.new(mouse_terminal)
    app, = build_app(panes: [pane])
    app.enter_scrollback
    app.scroll_focused(:line_back)
    assert_equal "\e[<64;21;6M", pane.written
  end

  def test_half_page_sends_one_report_per_row
    pane = FakePane.new(mouse_terminal)
    app, = build_app(panes: [pane])
    app.enter_scrollback
    app.scroll_focused(:half_forward)
    assert_equal "\e[<65;21;6M" * 5, pane.written
  end

  def test_wheel_reports_are_not_sent_to_a_pane_on_muxr_history
    pane = FakePane.new(plain_terminal)
    app, = build_app(panes: [pane])
    app.enter_scrollback
    app.scroll_focused(:line_back)
    assert_empty pane.written
    assert pane.terminal.scrolled_back?
  end

  def test_x10_encoding_when_the_program_never_asked_for_sgr
    term = plain_terminal
    term.feed("\e[?1000h")
    pane = FakePane.new(term)
    app, = build_app(panes: [pane])
    app.enter_scrollback
    app.scroll_focused(:line_back)
    assert_equal "\e[M#{(32 + 64).chr}#{(32 + 21).chr}#{(32 + 6).chr}", pane.written
  end

  def test_alt_screen_without_mouse_falls_back_to_arrow_keys
    pane = FakePane.new(alt_screen_terminal)
    app, = build_app(panes: [pane])
    app.enter_scrollback
    app.scroll_focused(:line_forward)
    assert_equal "\e[B", pane.written
  end

  def test_arrow_fallback_honors_application_cursor_keys
    term = alt_screen_terminal
    term.feed("\e[?1h")
    pane = FakePane.new(term)
    app, = build_app(panes: [pane])
    app.enter_scrollback
    app.scroll_focused(:line_back)
    assert_equal "\eOA", pane.written
  end

  def test_jump_to_edges_is_refused_on_the_apps_scroll
    pane = FakePane.new(mouse_terminal)
    app, = build_app(panes: [pane])
    app.enter_scrollback
    app.scroll_focused(:top)
    assert_empty pane.written
    assert_match(/only the app knows/, flashed(app))
  end

  def test_tab_switches_from_the_app_to_muxr_history
    pane = FakePane.new(mouse_terminal)
    app, input = build_app(panes: [pane])
    app.enter_scrollback
    input.feed("\t")
    assert_equal :ring, input.scroll_source
    app.scroll_focused(:line_back)
    assert_empty pane.written
    assert pane.terminal.scrolled_back?
  end

  def test_tab_switches_back_to_the_app_and_snaps_to_the_live_bottom
    pane = FakePane.new(mouse_terminal)
    app, input = build_app(panes: [pane])
    app.enter_scrollback
    input.feed("\t")
    app.scroll_focused(:line_back)
    assert pane.terminal.scrolled_back?
    input.feed("\t")
    assert_equal :app, input.scroll_source
    refute pane.terminal.scrolled_back?
  end

  def test_tab_refuses_muxr_history_on_an_alt_screen_pane
    app, input = build_app(panes: [FakePane.new(alt_screen_terminal)])
    app.enter_scrollback
    input.feed("\t")
    assert_equal :app, input.scroll_source
    assert_match(/full-screen app/, flashed(app))
  end

  def test_tab_refuses_the_app_scroll_on_a_plain_pane
    app, input = build_app(panes: [FakePane.new(plain_terminal)])
    app.enter_scrollback
    input.feed("\t")
    assert_equal :ring, input.scroll_source
    assert_match(/no scroll of its own/, flashed(app))
  end

  def test_selection_on_the_apps_scroll_cannot_reach_into_muxr_history
    term = mouse_terminal
    app, = build_app(panes: [FakePane.new(term)])
    app.enter_scrollback
    app.enter_selection
    assert term.selection_confined_to_screen?
    100.times { app.move_selection(:up) }
    refute term.scrolled_back?
    assert_equal term.scrollback_size, selection_row(term)
  end

  def test_selection_on_muxr_history_still_reaches_the_whole_timeline
    term = plain_terminal
    app, = build_app(panes: [FakePane.new(term)])
    app.enter_scrollback
    app.enter_selection
    refute term.selection_confined_to_screen?
    100.times { app.move_selection(:up) }
    assert_equal 0, selection_row(term)
  end

  def test_leaving_scrollback_releases_the_confinement
    term = mouse_terminal
    app, = build_app(panes: [FakePane.new(term)])
    app.enter_scrollback
    app.enter_selection
    app.exit_selection(yank: false)
    app.exit_scrollback
    refute term.selection_confined_to_screen?
  end

  def test_scrollback_falls_back_to_muxr_history_when_the_app_exits
    term = mouse_terminal
    pane = FakePane.new(term)
    app, input = build_app(panes: [pane])
    app.enter_scrollback
    assert_equal :app, input.scroll_source
    term.feed("\e[?1000l\e[?1006l")
    app.send(:leave_stale_scrollback)
    assert_equal :scrollback, input.state
    assert_equal :ring, input.scroll_source
    app.scroll_focused(:line_back)
    assert_empty pane.written
  end

  def test_search_is_refused_while_scrolling_the_app
    app, input = build_app(panes: [FakePane.new(mouse_terminal)])
    app.enter_scrollback
    app.enter_search(direction: :forward)
    assert_equal :scrollback, input.state
    assert_match(/search reads muxr history/, flashed(app))
  end
end
