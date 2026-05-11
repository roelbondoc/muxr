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
end
