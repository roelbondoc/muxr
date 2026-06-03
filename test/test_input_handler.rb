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

  def test_normal_mode_x_requests_close
    # Close uses lowercase x (with a y/n confirmation) so shift-HJKL can move
    # tiles without colliding with destructive actions.
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("x")
    assert_equal [:request_close], app.calls
  end

  def test_normal_mode_lower_k_navigates_up
    # k is vim-up; uppercase K moves the pane up (see HJKL test below).
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

  def test_normal_mode_shift_hjkl_moves_pane
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("HJKL")
    assert_equal [[:move_direction, :left],
                  [:move_direction, :down],
                  [:move_direction, :up],
                  [:move_direction, :right]], app.calls
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
    # (x/H/J/K/L are bound now; pick keys that aren't.)
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.feed("yz!")
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

  def test_passthrough_prefix_x_requests_close
    h = build_passthrough
    h.feed("\x01x")
    assert_equal [:request_close], h.instance_variable_get(:@app).calls
  end

  def test_passthrough_prefix_lower_k_is_not_bound
    # `k` in prefix is intentionally unbound — close is `x`, and there's no
    # spatial navigation under the Ctrl-a prefix. A bare lowercase k from
    # prefix should be silently dropped and return to passthrough.
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

  # ---------- scrollback / selection (exits restore the previous base mode) ----------

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

  def test_scrollback_mode_exits_on_q_restores_base_mode
    h = build_passthrough
    h.enter_scrollback_mode
    h.feed("q")
    assert_equal [:exit_scrollback], h.instance_variable_get(:@app).calls
    assert_equal :passthrough, h.state
    assert_equal :passthrough, h.base_mode
  end

  def test_scrollback_mode_exits_on_escape_restores_base_mode
    h = build_passthrough
    h.enter_scrollback_mode
    h.feed("\e")
    assert_equal [:exit_scrollback], h.instance_variable_get(:@app).calls
    assert_equal :passthrough, h.state
  end

  def test_scrollback_mode_exit_from_normal_returns_to_normal
    h = Muxr::InputHandler.new(FakeApp.new)
    h.enter_scrollback_mode
    h.feed("q")
    assert_equal :normal, h.state
    assert_equal :normal, h.base_mode
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

  def test_scrollback_ctrl_a_switches_pane_and_stays_in_scrollback
    h = build_passthrough
    h.enter_scrollback_mode
    h.feed("\x01n") # Ctrl-a n → next pane
    calls = h.instance_variable_get(:@app).calls
    assert_equal [:focus_next], calls
    # No exit_scrollback: the source pane keeps its scroll position, and the
    # mode is pane-bound so we stay in scrollback on the new pane.
    refute_includes calls, :exit_scrollback
    assert_equal :scrollback, h.state
  end

  def test_scrollback_ctrl_a_digit_switches_pane_and_stays_in_scrollback
    h = Muxr::InputHandler.new(FakeApp.new) # normal base mode
    h.enter_scrollback_mode
    h.feed("\x012") # Ctrl-a 2 → focus pane #2
    calls = h.instance_variable_get(:@app).calls
    assert_equal [[:focus_pane_number, 2]], calls
    refute_includes calls, :exit_scrollback
    assert_equal :scrollback, h.state
  end

  def test_scrollback_ctrl_a_then_escape_leaves_scrollback_to_normal
    h = build_passthrough
    h.enter_scrollback_mode
    h.feed("\x01\e") # Ctrl-a Esc → leave passthrough entirely
    assert_equal :normal, h.state
    assert_equal :normal, h.base_mode
  end

  def test_scrollback_i_enters_passthrough_insert
    h = Muxr::InputHandler.new(FakeApp.new) # normal base mode
    h.enter_scrollback_mode
    h.feed("i")
    calls = h.instance_variable_get(:@app).calls
    assert_equal [:enter_passthrough_mode], calls
    # No exit_scrollback / scroll-to-bottom: the pane keeps its position.
    refute_includes calls, :exit_scrollback
    assert_equal :passthrough, h.state
    assert_equal :passthrough, h.base_mode
  end

  def test_selection_ctrl_a_switches_pane_and_returns_to_scrollback
    h = build_passthrough
    h.enter_selection_mode
    h.feed("\x01p") # Ctrl-a p → prev pane
    calls = h.instance_variable_get(:@app).calls
    assert_equal [:focus_prev], calls
    refute_includes calls, :exit_selection
    # Switching out of selection lands you in scrollback on the new pane.
    assert_equal :scrollback, h.state
  end

  def test_prefix_return_does_not_leak_into_next_prefix
    # A scrollback-originated prefix sets @prefix_return = :scrollback. After
    # it resolves, a fresh prefix from passthrough must fall back to base.
    h = build_passthrough
    h.enter_scrollback_mode
    h.feed("\x01n")        # scrollback → switch pane → stays scrollback
    assert_equal :scrollback, h.state
    h.feed("i")            # scrollback → insert → passthrough
    assert_equal :passthrough, h.state
    h.feed("\x01z")        # unknown prefix key from passthrough → base mode
    assert_equal :passthrough, h.state
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

  # ---------- confirm_close (close pane y/n) ----------

  def test_confirm_close_on_y_calls_confirm_close
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_confirm_close
    assert_equal :confirm_close, h.state
    h.feed("y")
    assert_equal [:confirm_close], app.calls
    assert_equal :normal, h.state
  end

  def test_confirm_close_on_other_key_calls_cancel_close
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_confirm_close
    h.feed("n")
    assert_equal [:cancel_close], app.calls
    assert_equal :normal, h.state
  end

  def test_confirm_close_returns_to_passthrough_when_entered_from_passthrough
    h = build_passthrough
    h.enter_confirm_close
    h.feed("n")
    assert_equal :passthrough, h.state
  end

  # enter_idle_mode is used by the selection-yank exit path in Application;
  # verify it restores the base mode the user was in before scrollback.
  def test_enter_idle_mode_restores_base_mode
    h = build_passthrough
    h.enter_idle_mode
    assert_equal :passthrough, h.state
    assert_equal :passthrough, h.base_mode
  end

  def test_enter_idle_mode_from_normal_stays_in_normal
    h = Muxr::InputHandler.new(FakeApp.new)
    h.enter_idle_mode
    assert_equal :normal, h.state
    assert_equal :normal, h.base_mode
  end

  # ---------- scrollback arrow keys + search ----------

  def test_scrollback_up_arrow_scrolls_back
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("\e[A")
    assert_equal [[:scroll_focused, :line_back]], app.calls
    assert_equal :scrollback, h.state
  end

  def test_scrollback_down_arrow_scrolls_forward
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("\e[B")
    assert_equal [[:scroll_focused, :line_forward]], app.calls
  end

  def test_scrollback_pageup_pagedown_map_to_half_scrolls
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("\e[5~\e[6~")
    assert_equal [[:scroll_focused, :half_back],
                  [:scroll_focused, :half_forward]], app.calls
  end

  def test_scrollback_arrow_then_more_keys_in_same_chunk
    # A single client read might deliver "\e[A" followed by other keys; the
    # CSI peek must consume exactly the escape sequence and let the rest
    # dispatch normally.
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("\e[Aj")
    assert_equal [[:scroll_focused, :line_back],
                  [:scroll_focused, :line_forward]], app.calls
  end

  def test_scrollback_bare_escape_still_exits
    # Regression: the CSI lookahead must not change the meaning of a lone
    # ESC byte. ESC alone exits scrollback the way it always has.
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("\e")
    assert_equal [:exit_scrollback], app.calls
    assert_equal :normal, h.state
  end

  def test_scrollback_slash_enters_search_mode
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("/")
    assert_equal :search, h.state
    assert_equal :forward, h.search_direction
    assert_equal [[:enter_search, { direction: :forward }]], app.calls
  end

  def test_scrollback_question_mark_enters_backward_search
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("?")
    assert_equal :search, h.state
    assert_equal :backward, h.search_direction
    assert_equal [[:enter_search, { direction: :backward }]], app.calls
  end

  def test_scrollback_n_and_N_navigate_matches
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.feed("nN")
    assert_equal [:find_next, :find_prev], app.calls
  end

  def test_search_typing_builds_buffer
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_scrollback_mode
    h.enter_search_mode(direction: :forward)
    h.feed("foo")
    assert_equal "foo", h.search_buffer
    assert_equal :search, h.state
  end

  def test_search_backspace_chops_buffer
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_search_mode(direction: :forward)
    h.feed("ab\x7f")
    assert_equal "a", h.search_buffer
  end

  def test_search_enter_commits_and_returns_to_scrollback
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_search_mode(direction: :forward)
    h.feed("foo\r")
    assert_equal :scrollback, h.state
    assert_equal "", h.search_buffer
    commit = app.calls.find { |c| c.is_a?(Array) && c[0] == :commit_search }
    refute_nil commit
    assert_equal "foo", commit[1]
  end

  def test_search_escape_cancels_and_returns_to_scrollback
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_search_mode(direction: :forward)
    h.feed("foo\e")
    assert_equal :scrollback, h.state
    assert_equal "", h.search_buffer
    assert_includes app.calls, :cancel_search
  end

  def test_search_mode_swallows_arrow_keys_without_exiting
    # A stray arrow key while typing a query must not be parsed as
    # `\e` + `[A` (which would cancel the prompt and inject text).
    app = FakeApp.new
    h = Muxr::InputHandler.new(app)
    h.enter_search_mode(direction: :forward)
    h.feed("f\e[Aoo")
    assert_equal :search, h.state
    assert_equal "foo", h.search_buffer
  end
end
