require "test_helper"
require "muxr/input_handler"

class TestInputHandlerPicker < Minitest::Test
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

  def open_picker
    @input.feed("A")
    @input.enter_pane_picker_mode
  end

  def test_A_opens_the_picker_from_normal_mode
    @input.feed("A")
    assert_includes @app.calls, :open_pane_picker
  end

  def test_prefix_A_opens_the_picker_from_passthrough
    @input.enter_passthrough_mode
    @input.feed("\x01A")
    assert_includes @app.calls, :open_pane_picker
  end

  def test_jk_move_the_selection
    open_picker
    @input.feed("jjk")
    assert_equal [[:move_pane_picker, 1], [:move_pane_picker, 1], [:move_pane_picker, -1]],
                 @app.calls.select { |c| c.is_a?(Array) && c[0] == :move_pane_picker }
  end

  def test_arrow_keys_move_the_selection
    open_picker
    @input.feed("\e[B\e[A")
    assert_equal [[:move_pane_picker, 1], [:move_pane_picker, -1]],
                 @app.calls.select { |c| c.is_a?(Array) && c[0] == :move_pane_picker }
  end

  def test_enter_confirms_and_leaves_the_overlay
    open_picker
    @input.feed("\r")
    assert_includes @app.calls, :confirm_pane_picker
    assert_equal :normal, @input.state
  end

  def test_m_moves_the_pane_rather_than_sharing_it
    open_picker
    @input.feed("m")
    assert_includes @app.calls, [:confirm_pane_picker, { move: true }]
    assert_equal :normal, @input.state
  end

  def test_escape_cancels_and_leaves_the_overlay
    open_picker
    @input.feed("\e")
    assert_includes @app.calls, :cancel_pane_picker
    assert_equal :normal, @input.state
  end

  def test_q_cancels_without_killing_the_session
    open_picker
    @input.feed("q")
    assert_includes @app.calls, :cancel_pane_picker
    refute_includes @app.calls, :quit_immediate
  end

  def test_stray_keys_are_ignored_rather_than_reaching_the_pane
    open_picker
    @input.feed("zx9")
    assert_equal :pane_picker, @input.state
    refute @app.calls.any? { |c| c.is_a?(Array) && c[0] == :send_to_focused }
  end

  def test_cancelling_returns_to_passthrough_when_that_is_where_you_came_from
    @input.enter_passthrough_mode
    @input.feed("\x01A")
    @input.enter_pane_picker_mode
    @input.feed("\e")
    assert_equal :passthrough, @input.state
  end
end
