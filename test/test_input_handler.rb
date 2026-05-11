require "test_helper"
require "muxr/input_handler"

class TestInputHandler < Minitest::Test
  # Records every action the InputHandler dispatches so each test can assert
  # against the sequence. The handler also touches a few helper methods on the
  # app — those return values the handler doesn't otherwise depend on.
  class FakeApp
    attr_reader :calls

    def initialize
      @calls = []
    end

    def method_missing(name, *args, &)
      @calls << (args.empty? ? name : [name, *args])
      nil
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end

  def test_prefix_then_c_creates_pane
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("\x01c")
    assert_equal [:new_pane], app.calls
    assert_equal :idle, h.state
  end

  def test_prefix_then_bracket_enters_scrollback
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("\x01[")
    assert_equal [:enter_scrollback], app.calls
  end

  def test_scrollback_mode_dispatches_j_and_k
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("jjk")
    assert_equal [[:scroll_focused, :line_forward],
                  [:scroll_focused, :line_forward],
                  [:scroll_focused, :line_back]], app.calls
    assert_equal :scrollback, h.state
  end

  def test_scrollback_mode_supports_paging_and_jumps
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("dufbgG")
    assert_equal [[:scroll_focused, :half_forward],
                  [:scroll_focused, :half_back],
                  [:scroll_focused, :full_forward],
                  [:scroll_focused, :full_back],
                  [:scroll_focused, :top],
                  [:scroll_focused, :bottom]], app.calls
  end

  def test_scrollback_mode_exits_on_q
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("q")
    assert_equal [:exit_scrollback], app.calls
    assert_equal :idle, h.state
  end

  def test_scrollback_mode_exits_on_escape
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("\e")
    assert_equal [:exit_scrollback], app.calls
    assert_equal :idle, h.state
  end

  def test_scrollback_mode_ignores_unknown_keys
    # Unknown keystrokes must NOT be forwarded to the focused pane and must
    # NOT exit the mode — that would let a typo eat the user's scroll
    # progress.
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("xyz")
    assert_equal [], app.calls
    assert_equal :scrollback, h.state
  end

  def test_idle_passes_input_through_to_focused_pane
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("hi")
    assert_equal [[:send_to_focused, "h"], [:send_to_focused, "i"]], app.calls
  end

  def test_scrollback_v_enters_selection
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("v")
    assert_equal [:enter_selection], app.calls
  end

  def test_selection_mode_dispatches_directional_moves
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_selection_mode
    h.feed("hjkl")
    assert_equal [[:move_selection, :left],
                  [:move_selection, :down],
                  [:move_selection, :up],
                  [:move_selection, :right]], app.calls
    assert_equal :selection, h.state
  end

  def test_selection_mode_supports_paging_and_jumps
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_selection_mode
    # `b` is now vim word-back; page-back is Ctrl-b (\x02).
    h.feed("duf\x02gG0$")
    actions = app.calls.map { |c| c.is_a?(Array) ? c[1] : c }
    assert_equal %i[half_down half_up full_down full_up top bottom line_start line_end], actions
  end

  def test_selection_yank_on_enter_dispatches_yank_true
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_selection_mode
    h.feed("\r")
    assert_equal [[:exit_selection, { yank: true }]], app.calls
  end

  def test_selection_yank_on_y_dispatches_yank_true
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_selection_mode
    h.feed("y")
    assert_equal [[:exit_selection, { yank: true }]], app.calls
  end

  def test_selection_cancel_on_escape_dispatches_yank_false
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_selection_mode
    h.feed("\e")
    assert_equal [[:exit_selection, { yank: false }]], app.calls
  end

  def test_prefix_close_bracket_pastes
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("\x01]")
    assert_equal [:paste_from_buffer], app.calls
  end

  def test_selection_mode_ignores_unknown_keys
    # "x" and "z" are not bound. "y" would yank, so don't include it.
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_selection_mode
    h.feed("xz!")
    assert_equal [], app.calls
    assert_equal :selection, h.state
  end

  def test_selection_mode_v_toggles_linear
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_selection_mode
    h.feed("v")
    assert_equal [[:toggle_selection, :linear]], app.calls
    assert_equal :selection, h.state # stays in selection mode
  end

  def test_selection_mode_ctrl_v_toggles_block
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_selection_mode
    h.feed("\x16")
    assert_equal [[:toggle_selection, :block]], app.calls
    assert_equal :selection, h.state
  end
end
