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

  # Most existing tests exercise the Ctrl-a prefix path, which now lives in
  # passthrough mode. Helper that builds a handler already in passthrough so
  # those tests don't have to type `i` first.
  def build_passthrough
    h = Muxr::InputHandler.new(FakeApp.new)
    h.enter_passthrough_mode
    h
  end

  # ---------- mode initialization ----------

  def test_starts_in_normal_mode
    h = Muxr::InputHandler.new(FakeApp.new)
    assert_equal :normal, h.state
    assert_equal :normal, h.base_mode
  end

  def test_i_in_normal_mode_enters_passthrough
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("i")
    assert_equal :passthrough, h.state
    assert_equal :passthrough, h.base_mode
    # Application#enter_passthrough_mode is what flips the input state, so
    # that's what we expect to see dispatched.
    assert_equal [:enter_passthrough_mode], app.calls
  end

  def test_ctrl_a_esc_returns_to_normal_from_passthrough
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_passthrough_mode
    h.feed("\x01\e")
    assert_equal :normal, h.state
    assert_equal :normal, h.base_mode
    assert_equal [:enter_normal_mode], app.calls
  end

  # ---------- normal-mode bindings ----------

  def test_normal_mode_c_creates_pane
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("c")
    assert_equal [:new_pane], app.calls
    assert_equal :normal, h.state
  end

  def test_normal_mode_capital_k_kills_pane
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("K")
    assert_equal [:close_focused], app.calls
  end

  def test_normal_mode_lower_k_navigates_up
    # k is vim-up, NOT kill — that's the whole reason we use uppercase K for kill.
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("k")
    assert_equal [[:focus_direction, :up]], app.calls
  end

  def test_normal_mode_hjkl_navigation
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("hjkl")
    assert_equal [[:focus_direction, :left],
                  [:focus_direction, :down],
                  [:focus_direction, :up],
                  [:focus_direction, :right]], app.calls
  end

  def test_normal_mode_tgm_sets_layout
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("tgm")
    assert_equal [[:set_layout, :tall],
                  [:set_layout, :grid],
                  [:set_layout, :monocle]], app.calls
  end

  def test_normal_mode_s_enters_scrollback
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("s")
    assert_equal [:enter_scrollback], app.calls
  end

  def test_normal_mode_digit_focuses_pane_number
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("3")
    assert_equal [[:focus_pane_number, 3]], app.calls
  end

  def test_normal_mode_colon_enters_command
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed(":foo\r")
    # Each typed char calls @app.invalidate to repaint the prompt; Enter
    # then dispatches run_command. Filter the redraws and assert on the
    # interesting tail.
    assert_equal [[:run_command, "foo"]], app.calls.reject { |c| c == :invalidate }
    assert_equal :normal, h.state
  end

  def test_normal_mode_ignores_unknown_keys
    # Avoid sending stray keys to the focused pane and avoid mode flapping.
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("xyz!")
    assert_equal [], app.calls
    assert_equal :normal, h.state
  end

  def test_normal_mode_does_not_pass_through_to_pane
    # If the user means to type into a shell they must press `i` first.
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("hello")
    assert(app.calls.none? { |c| c.is_a?(Array) && c[0] == :send_to_focused })
  end

  # ---------- passthrough-mode (was :idle) bindings ----------

  def test_passthrough_prefix_then_c_creates_pane
    h = build_passthrough
    h.feed("\x01c")
    assert_equal [:new_pane], h.instance_variable_get(:@app).calls
    assert_equal :passthrough, h.state
  end

  def test_passthrough_prefix_then_bracket_enters_scrollback
    h = build_passthrough
    h.feed("\x01[")
    assert_equal [:enter_scrollback], h.instance_variable_get(:@app).calls
  end

  def test_passthrough_passes_input_through_as_one_chunk
    # Batching the whole pass-through in one send_to_focused call is what
    # keeps large pastes from turning into one syscall per byte (the cause
    # of the 0.1.3 hang).
    h = build_passthrough
    h.feed("hello")
    assert_equal [[:send_to_focused, "hello"]], h.instance_variable_get(:@app).calls
  end

  def test_passthrough_splits_around_embedded_prefix
    h = build_passthrough
    h.feed("hi\x01cmore")
    assert_equal [[:send_to_focused, "hi"], :new_pane, [:send_to_focused, "more"]],
                 h.instance_variable_get(:@app).calls
    assert_equal :passthrough, h.state
  end

  def test_passthrough_ctrl_a_ctrl_a_sends_literal_prefix
    h = build_passthrough
    h.feed("\x01\x01")
    assert_equal [[:send_to_focused, "\x01"]], h.instance_variable_get(:@app).calls
    assert_equal :passthrough, h.state
  end

  def test_passthrough_prefix_capital_k_kills_pane
    h = build_passthrough
    h.feed("\x01K")
    assert_equal [:close_focused], h.instance_variable_get(:@app).calls
  end

  def test_passthrough_prefix_lower_k_is_not_bound
    # `k` in prefix is intentionally unbound now; only uppercase K kills.
    # A bare lowercase k from prefix should be silently dropped and return
    # to passthrough.
    h = build_passthrough
    h.feed("\x01k")
    assert_equal [], h.instance_variable_get(:@app).calls
    assert_equal :passthrough, h.state
  end

  def test_passthrough_prefix_close_bracket_pastes
    h = build_passthrough
    h.feed("\x01]")
    assert_equal [:paste_from_buffer], h.instance_variable_get(:@app).calls
  end

  # ---------- scrollback / selection (unchanged behavior, exits land in :normal) ----------

  def test_scrollback_mode_dispatches_j_and_k
    h = build_passthrough
    h.enter_scrollback_mode
    h.feed("jjk")
    assert_equal [[:scroll_focused, :line_forward],
                  [:scroll_focused, :line_forward],
                  [:scroll_focused, :line_back]], h.instance_variable_get(:@app).calls
    assert_equal :scrollback, h.state
  end

  def test_scrollback_mode_supports_paging_and_jumps
    h = build_passthrough
    h.enter_scrollback_mode
    h.feed("dufbgG")
    assert_equal [[:scroll_focused, :half_forward],
                  [:scroll_focused, :half_back],
                  [:scroll_focused, :full_forward],
                  [:scroll_focused, :full_back],
                  [:scroll_focused, :top],
                  [:scroll_focused, :bottom]], h.instance_variable_get(:@app).calls
  end

  def test_scrollback_mode_exits_on_q_to_normal
    h = build_passthrough
    h.enter_scrollback_mode
    h.feed("q")
    assert_equal [:exit_scrollback], h.instance_variable_get(:@app).calls
    assert_equal :normal, h.state
    assert_equal :normal, h.base_mode
  end

  def test_scrollback_mode_exits_on_escape_to_normal
    h = build_passthrough
    h.enter_scrollback_mode
    h.feed("\e")
    assert_equal [:exit_scrollback], h.instance_variable_get(:@app).calls
    assert_equal :normal, h.state
  end

  def test_scrollback_mode_ignores_unknown_keys
    h = build_passthrough
    h.enter_scrollback_mode
    h.feed("xyz")
    assert_equal [], h.instance_variable_get(:@app).calls
    assert_equal :scrollback, h.state
  end

  def test_scrollback_v_enters_selection
    h = build_passthrough
    h.enter_scrollback_mode
    h.feed("v")
    assert_equal [:enter_selection], h.instance_variable_get(:@app).calls
  end

  def test_selection_mode_dispatches_directional_moves
    h = build_passthrough
    h.enter_selection_mode
    h.feed("hjkl")
    assert_equal [[:move_selection, :left],
                  [:move_selection, :down],
                  [:move_selection, :up],
                  [:move_selection, :right]], h.instance_variable_get(:@app).calls
    assert_equal :selection, h.state
  end

  def test_selection_mode_supports_paging_and_jumps
    h = build_passthrough
    h.enter_selection_mode
    h.feed("duf\x02gG0$")
    actions = h.instance_variable_get(:@app).calls.map { |c| c.is_a?(Array) ? c[1] : c }
    assert_equal %i[half_down half_up full_down full_up top bottom line_start line_end], actions
  end

  def test_selection_yank_on_enter_dispatches_yank_true
    h = build_passthrough
    h.enter_selection_mode
    h.feed("\r")
    assert_equal [[:exit_selection, { yank: true }]], h.instance_variable_get(:@app).calls
  end

  def test_selection_yank_on_y_dispatches_yank_true
    h = build_passthrough
    h.enter_selection_mode
    h.feed("y")
    assert_equal [[:exit_selection, { yank: true }]], h.instance_variable_get(:@app).calls
  end

  def test_selection_cancel_on_escape_dispatches_yank_false
    h = build_passthrough
    h.enter_selection_mode
    h.feed("\e")
    assert_equal [[:exit_selection, { yank: false }]], h.instance_variable_get(:@app).calls
  end

  def test_selection_mode_ignores_unknown_keys
    h = build_passthrough
    h.enter_selection_mode
    h.feed("xz!")
    assert_equal [], h.instance_variable_get(:@app).calls
    assert_equal :selection, h.state
  end

  def test_selection_mode_v_toggles_linear
    h = build_passthrough
    h.enter_selection_mode
    h.feed("v")
    assert_equal [[:toggle_selection, :linear]], h.instance_variable_get(:@app).calls
    assert_equal :selection, h.state
  end

  def test_selection_mode_ctrl_v_toggles_block
    h = build_passthrough
    h.enter_selection_mode
    h.feed("\x16")
    assert_equal [[:toggle_selection, :block]], h.instance_variable_get(:@app).calls
    assert_equal :selection, h.state
  end

  def test_selection_mode_space_toggles_linear
    # Mirror of `v` so the right thumb can anchor/release without the index
    # finger jumping off h/j/k/l.
    h = build_passthrough
    h.enter_selection_mode
    h.feed(" ")
    assert_equal [[:toggle_selection, :linear]], h.instance_variable_get(:@app).calls
    assert_equal :selection, h.state
  end

  # enter_idle_mode is kept as a legacy alias for the selection-yank
  # exit path in Application; verify it lands the handler back in :normal.
  def test_enter_idle_mode_is_alias_for_normal
    h = build_passthrough
    h.enter_idle_mode
    assert_equal :normal, h.state
    assert_equal :normal, h.base_mode
  end
end
