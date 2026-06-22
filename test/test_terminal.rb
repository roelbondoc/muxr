require "test_helper"

class TestTerminal < Minitest::Test
  def test_writes_plain_text_into_buffer
    t = Muxr::Terminal.new(rows: 5, cols: 10)
    t.feed("hi")
    assert_equal "h", t.cell(0, 0).char
    assert_equal "i", t.cell(0, 1).char
    assert_equal 0, t.cursor_row
    assert_equal 2, t.cursor_col
  end

  def test_line_feed_advances_row
    # VT100 LF advances the row but preserves the column (line-discipline
    # ONLCR is the layer responsible for the implicit CR).
    t = Muxr::Terminal.new(rows: 3, cols: 5)
    t.feed("a\r\nb")
    assert_equal "a", t.cell(0, 0).char
    assert_equal "b", t.cell(1, 0).char
  end

  def test_carriage_return_resets_column
    t = Muxr::Terminal.new(rows: 3, cols: 5)
    t.feed("ab\rX")
    assert_equal "X", t.cell(0, 0).char
    assert_equal "b", t.cell(0, 1).char
  end

  def test_csi_cursor_position
    t = Muxr::Terminal.new(rows: 5, cols: 10)
    t.feed("\e[3;5HX")
    assert_equal "X", t.cell(2, 4).char
  end

  def test_dsr_cursor_position_report
    # `\e[6n` (CPR) is how programs like the AWS CLI probe terminal
    # geometry. Without a reply they print "your terminal doesn't support
    # cursor position requests (CPR)" and fall back.
    t = Muxr::Terminal.new(rows: 5, cols: 10)
    t.feed("\e[3;5H\e[6n")
    assert_equal "\e[3;5R", t.take_pending_replies!
    assert_nil t.take_pending_replies!
  end

  def test_dsr_device_status_ok
    t = Muxr::Terminal.new(rows: 5, cols: 10)
    t.feed("\e[5n")
    assert_equal "\e[0n", t.take_pending_replies!
  end

  def test_erase_display_to_end
    t = Muxr::Terminal.new(rows: 4, cols: 5)
    t.feed("abcd\r\nfghi\r\nklmn")
    t.feed("\e[1;3H\e[0J") # cursor home -> (0,0), then (0;2), then erase to end
    assert_equal "a", t.cell(0, 0).char
    assert_equal "b", t.cell(0, 1).char
    assert_equal " ", t.cell(0, 2).char
    assert_equal " ", t.cell(1, 0).char
  end

  def test_sgr_color_persists
    t = Muxr::Terminal.new(rows: 1, cols: 4)
    t.feed("\e[31mAB")
    assert_equal 1, t.cell(0, 0).fg
    assert_equal "A", t.cell(0, 0).char
    assert_equal 1, t.cell(0, 1).fg
  end

  def test_sgr_reset
    t = Muxr::Terminal.new(rows: 1, cols: 4)
    t.feed("\e[31mA\e[0mB")
    assert_equal 1, t.cell(0, 0).fg
    assert_nil t.cell(0, 1).fg
  end

  def test_sgr_dim
    # Claude Code emits SGR 2 for placeholder/suggestion text. Without the
    # DIM attribute, it'd be silently dropped and the placeholder would
    # render at normal intensity.
    t = Muxr::Terminal.new(rows: 1, cols: 4)
    t.feed("\e[2mA\e[22mB")
    assert_equal Muxr::Terminal::DIM, t.cell(0, 0).attrs & Muxr::Terminal::DIM
    assert_equal 0, t.cell(0, 1).attrs & Muxr::Terminal::DIM
  end

  def test_resize_preserves_content_within_bounds
    t = Muxr::Terminal.new(rows: 4, cols: 5)
    t.feed("abc\r\ndef")
    t.resize(4, 5)
    assert_equal "a", t.cell(0, 0).char
    assert_equal "d", t.cell(1, 0).char
    t.resize(5, 6)
    assert_equal "a", t.cell(0, 0).char
    assert_equal "d", t.cell(1, 0).char
  end

  def test_sgr_colon_form_disables_underline
    # `\e[4:0m` is the colon-subparameter form for "no underline". Without
    # explicit colon handling, csi_params collapses "4:0" to 4 and we'd
    # erroneously turn underline ON.
    t = Muxr::Terminal.new(rows: 1, cols: 4)
    t.feed("\e[4mA\e[4:0mB")
    assert_equal Muxr::Terminal::UNDERLINE, t.cell(0, 0).attrs & Muxr::Terminal::UNDERLINE
    assert_equal 0, t.cell(0, 1).attrs & Muxr::Terminal::UNDERLINE
  end

  def test_sgr_colon_form_curly_underline_renders_as_underline
    t = Muxr::Terminal.new(rows: 1, cols: 2)
    t.feed("\e[4:3mA")
    assert_equal Muxr::Terminal::UNDERLINE, t.cell(0, 0).attrs & Muxr::Terminal::UNDERLINE
  end

  def test_sgr_underline_color_semicolon_does_not_leak_into_attrs
    # `\e[58;5;4m` sets the underline color (index 4). The trailing `4` must
    # NOT be re-interpreted as SGR 4 (underline on).
    t = Muxr::Terminal.new(rows: 1, cols: 2)
    t.feed("\e[58;5;4mA")
    assert_equal 0, t.cell(0, 0).attrs & Muxr::Terminal::UNDERLINE
    assert_nil t.cell(0, 0).fg
  end

  def test_sgr_underline_color_rgb_does_not_leak_into_attrs
    # `\e[58;2;1;4;7m` sets RGB underline color. Without consuming the color
    # parameters, the `1`, `4`, and `7` would each toggle BOLD, UNDERLINE,
    # and REVERSE respectively.
    t = Muxr::Terminal.new(rows: 1, cols: 2)
    t.feed("\e[58;2;1;4;7mA")
    assert_equal 0, t.cell(0, 0).attrs
  end

  def test_modify_other_keys_does_not_leak_into_sgr
    # `\e[>4;2m` is xterm's modifyOtherKeys mode set. The `>` prefix marks
    # it as a private/extended CSI, NOT standard SGR. If we strip the `>`
    # and route to apply_sgr, the `4` latches UNDERLINE on globally — which
    # is exactly what was making every character in the Claude Code UI
    # underlined.
    t = Muxr::Terminal.new(rows: 1, cols: 4)
    t.feed("\e[>4;2mABCD")
    4.times do |c|
      assert_equal 0, t.cell(0, c).attrs, "cell #{c} should have no attrs"
    end
  end

  def test_private_mode_r_does_not_set_scroll_region
    # `\e[?2026r` is XTRESTORE for DEC private mode 2026 (synchronized
    # output). The `?` prefix must keep it out of DECSTBM's lap.
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    t.feed("\e[?2026r")
    t.feed("X")
    # Cursor should still be at (0, 0) writing X, not relocated by a
    # spurious scroll-region reset.
    assert_equal "X", t.cell(0, 0).char
  end

  def test_bracketed_paste_mode_tracks_decset_2004
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    refute t.bracketed_paste?, "starts disabled"
    t.feed("\e[?2004h")
    assert t.bracketed_paste?, "enabled by \\e[?2004h"
    t.feed("\e[?2004l")
    refute t.bracketed_paste?, "disabled by \\e[?2004l"
  end

  def test_bracketed_paste_and_sync_modes_are_independent
    # A combined DECSET shouldn't bleed one mode into the other.
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    t.feed("\e[?2026h")
    assert t.sync_pending?
    refute t.bracketed_paste?
    t.feed("\e[?2004h")
    assert t.bracketed_paste?
    assert t.sync_pending?
  end

  def test_sgr_colon_extended_foreground_color
    t = Muxr::Terminal.new(rows: 1, cols: 2)
    t.feed("\e[38:5:9mA")
    assert_equal [:c256, 9], t.cell(0, 0).fg
  end

  def test_autowrap_at_right_edge
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("abcd")
    assert_equal "a", t.cell(0, 0).char
    assert_equal "b", t.cell(0, 1).char
    assert_equal "c", t.cell(0, 2).char
    assert_equal "d", t.cell(1, 0).char
  end

  def test_scrollback_captures_lines_scrolled_off_top
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    # Three lines into a 2-row grid: the first line gets pushed into
    # scrollback, the last two stay on the visible grid.
    t.feed("aaa\r\nbbb\r\nccc")
    assert_equal 1, t.scrollback_size
    # Visible grid (offset 0) shows the latest two rows.
    assert_equal "b", t.visible_cell(0, 0).char
    assert_equal "c", t.visible_cell(1, 0).char
  end

  def test_scroll_back_reveals_history
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("aaa\r\nbbb\r\nccc")
    t.scroll_back(1)
    assert_equal 1, t.view_offset
    # Top visible row now sources from scrollback, bottom row from the grid.
    assert_equal "a", t.visible_cell(0, 0).char
    assert_equal "b", t.visible_cell(1, 0).char
  end

  def test_scroll_back_clamps_to_scrollback_size
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("aaa\r\nbbb\r\nccc")
    t.scroll_back(99)
    assert_equal 1, t.view_offset
  end

  def test_view_offset_bumps_when_scrolled_back_and_new_row_arrives
    # When the user is scrolled back, fresh output must not shift the visible
    # content out from under them — view_offset compensates by tracking the
    # newly-pushed scrollback rows.
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("aaa\r\nbbb\r\nccc") # scrollback: [aaa], grid: [bbb, ccc]
    t.scroll_back(1)            # top visible = aaa
    assert_equal "a", t.visible_cell(0, 0).char
    t.feed("\r\nddd")           # scrollback: [aaa, bbb], grid: [ccc, ddd]
    assert_equal 2, t.scrollback_size
    assert_equal 2, t.view_offset
    # Top of view should STILL be aaa — frozen on the same content.
    assert_equal "a", t.visible_cell(0, 0).char
  end

  def test_scroll_to_top_and_bottom
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("aaa\r\nbbb\r\nccc\r\nddd")
    t.scroll_to_top
    assert_equal 2, t.view_offset
    assert_equal "a", t.visible_cell(0, 0).char
    t.scroll_to_bottom
    assert_equal 0, t.view_offset
    assert_equal "c", t.visible_cell(0, 0).char
    assert_equal "d", t.visible_cell(1, 0).char
  end

  def test_scrollback_evicts_oldest_at_cap
    cap = Muxr::Terminal::SCROLLBACK_MAX
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    # cap+5 lines worth of scrollback pushes — oldest fall off, newest stays.
    lines = Array.new(cap + 5) { |i| format("%03d", i % 1000) }
    t.feed(lines.join("\r\n"))
    assert_equal cap, t.scrollback_size
  end

  def test_partial_scroll_region_does_not_pollute_scrollback
    t = Muxr::Terminal.new(rows: 4, cols: 3)
    # \e[1;3r sets DECSTBM scroll region to rows 1..3 (1-based); CSI r also
    # homes the cursor. Then four LFs would scroll within rows 0..2 — nothing
    # should reach scrollback.
    t.feed("\e[1;3r")
    4.times { t.feed("a\r\n") }
    assert_equal 0, t.scrollback_size
  end

  def test_visible_cell_falls_back_to_blank_for_narrow_scrollback_row
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("aa\r\nbb\r\ncc")
    t.scroll_back(1)
    # The scrollback row is 3 cols wide; reading past it should still work.
    cell = t.visible_cell(0, 2)
    assert_equal " ", cell.char
  end

  def test_selection_extract_single_row
    t = Muxr::Terminal.new(rows: 2, cols: 6)
    t.feed("hello\r\nworld")
    t.start_selection_at_visible(0, 0)
    t.move_selection_cursor_by(0, 4) # extend to col 4 (inclusive)
    assert t.selection_active?
    assert_equal "hello", t.extract_selection_text
  end

  def test_selection_extract_multi_row_strips_trailing_whitespace
    t = Muxr::Terminal.new(rows: 3, cols: 8)
    t.feed("one\r\ntwo\r\nthree")
    t.start_selection_at_visible(0, 0)
    t.move_selection_cursor_by(2, 7) # row 2 col 7 (end of row)
    assert_equal "one\ntwo\nthree", t.extract_selection_text
  end

  def test_selection_extract_handles_reverse_anchor_cursor_order
    # Anchor below cursor: extract should still be in reading order.
    t = Muxr::Terminal.new(rows: 2, cols: 5)
    t.feed("aaaaa\r\nbbbbb")
    t.start_selection_at_visible(1, 4)
    t.move_selection_cursor_by(-1, -4) # back to (0,0)
    assert_equal "aaaaa\nbbbbb", t.extract_selection_text
  end

  def test_selection_spans_scrollback_and_live_buffer
    t = Muxr::Terminal.new(rows: 2, cols: 5)
    t.feed("aaaaa\r\nbbbbb\r\nccccc")
    # scrollback: [aaaaa], grid: [bbbbb, ccccc]. Anchor on scrollback row.
    t.scroll_back(1)                       # view: [aaaaa, bbbbb]
    t.start_selection_at_visible(0, 0)     # timeline row 0 (aaaaa), col 0
    t.scroll_to_bottom                     # back to view: [bbbbb, ccccc]
    t.move_selection_cursor_by(2, 4)       # to bottom row col 4 (ccccc end)
    assert_equal "aaaaa\nbbbbb\nccccc", t.extract_selection_text
  end

  def test_selection_cursor_movement_auto_scrolls_view
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("aaa\r\nbbb\r\nccc")
    t.scroll_back(1)                       # view: [aaa, bbb]
    t.start_selection_at_visible(0, 0)     # on aaa
    assert_equal 1, t.view_offset
    t.move_selection_cursor_by(2, 0)       # cursor jumps to ccc — must scroll forward
    assert_equal 0, t.view_offset
  end

  def test_clear_selection_removes_state
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("aa\r\nbb")
    t.start_selection_at_visible(0, 0)
    t.move_selection_cursor_by(1, 1)
    t.clear_selection
    refute t.selection_active?
    assert_equal "", t.extract_selection_text
  end

  def test_selected_at_visible_marks_cells_inside_range
    t = Muxr::Terminal.new(rows: 2, cols: 4)
    t.feed("abcd\r\nefgh")
    t.start_selection_at_visible(0, 1)
    t.move_selection_cursor_by(1, 1) # (1,2)
    assert t.selected_at_visible?(0, 1)
    assert t.selected_at_visible?(0, 3)
    assert t.selected_at_visible?(1, 2)
    refute t.selected_at_visible?(0, 0)
    refute t.selected_at_visible?(1, 3)
  end

  def test_selection_cursor_visible_returns_nil_when_off_screen
    # Anchor cursor on a scrollback row, then page forward past it so the
    # cursor is no longer inside the viewport. Auto-follow keeps the cursor
    # visible when the user moves IT — but plain scrolling should not.
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("aaa\r\nbbb\r\nccc\r\nddd")
    t.scroll_back(2)                       # view: [aaa, bbb]
    t.start_selection_at_visible(0, 0)     # cursor on aaa (timeline row 0)
    refute_nil t.selection_cursor_visible
    t.scroll_to_bottom                     # view: [ccc, ddd], cursor at aaa is off-screen
    assert_nil t.selection_cursor_visible
  end

  def test_resize_clears_selection
    t = Muxr::Terminal.new(rows: 3, cols: 5)
    t.feed("abc\r\ndef")
    t.start_selection_at_visible(0, 0)
    t.move_selection_cursor_by(1, 2)
    assert t.selection_active?
    t.resize(4, 6)
    refute t.selection_active?
  end

  def test_place_selection_cursor_does_not_activate_selection
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("aa\r\nbb")
    t.place_selection_cursor(0, 0)
    refute t.selection_active?
    # Cursor is movable even without an anchor.
    t.move_selection_cursor_by(1, 1)
    refute t.selection_active?
    refute_nil t.selection_cursor_visible
  end

  def test_anchor_selection_after_navigation
    t = Muxr::Terminal.new(rows: 2, cols: 4)
    t.feed("abcd\r\nefgh")
    t.place_selection_cursor(0, 1)
    t.anchor_selection!
    assert t.selection_active?
    assert_equal :linear, t.selection_mode
    t.move_selection_cursor_by(1, 1) # extend to (1, 2)
    assert_equal "bcd\nefg", t.extract_selection_text
  end

  def test_clear_anchor_keeps_cursor
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("aa\r\nbb")
    t.start_selection_at_visible(0, 0)
    t.move_selection_cursor_by(1, 1)
    t.clear_anchor!
    refute t.selection_active?
    refute_nil t.selection_cursor_visible
  end

  def test_block_selection_extracts_rectangle
    t = Muxr::Terminal.new(rows: 3, cols: 6)
    t.feed("abcdef\r\nghijkl\r\nmnopqr")
    t.place_selection_cursor(0, 1)
    t.anchor_selection!(mode: :block)
    t.move_selection_cursor_by(2, 2) # rect: rows 0..2, cols 1..3
    assert_equal :block, t.selection_mode
    assert_equal "bcd\nhij\nnop", t.extract_selection_text
  end

  def test_block_selection_handles_reverse_corners
    # Anchor in the bottom-right, cursor moves to top-left → still extracts
    # the natural rectangle in reading order.
    t = Muxr::Terminal.new(rows: 3, cols: 6)
    t.feed("abcdef\r\nghijkl\r\nmnopqr")
    t.place_selection_cursor(2, 3) # anchor at bottom-right corner
    t.anchor_selection!(mode: :block)
    t.move_selection_cursor_by(-2, -2) # cursor to (0, 1)
    assert_equal "bcd\nhij\nnop", t.extract_selection_text
  end

  def test_block_selection_selected_at_visible_marks_rectangle_only
    t = Muxr::Terminal.new(rows: 3, cols: 4)
    t.feed("abcd\r\nefgh\r\nijkl")
    t.place_selection_cursor(0, 1)
    t.anchor_selection!(mode: :block)
    t.move_selection_cursor_by(2, 1) # rows 0..2, cols 1..2
    assert t.selected_at_visible?(0, 1)
    assert t.selected_at_visible?(1, 2)
    assert t.selected_at_visible?(2, 1)
    # Outside the rectangle, including cells inside the linear-mode reading
    # path: (0, 3) is between top-left and bottom-right when read linearly,
    # but is NOT in the block rectangle.
    refute t.selected_at_visible?(0, 3)
    refute t.selected_at_visible?(1, 0)
    refute t.selected_at_visible?(2, 3)
  end

  def test_anchor_selection_is_a_noop_without_a_placed_cursor
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("aa\r\nbb")
    t.anchor_selection!
    refute t.selection_active?
  end

  def test_word_forward_skips_to_next_word_start
    t = Muxr::Terminal.new(rows: 1, cols: 20)
    t.feed("hello world foo")
    t.place_selection_cursor(0, 0)
    t.selection_cursor_word_forward
    assert_equal [0, 6], t.selection_cursor_visible # 'w' of "world"
    t.selection_cursor_word_forward
    assert_equal [0, 12], t.selection_cursor_visible # 'f' of "foo"
  end

  def test_word_forward_stops_at_punctuation_boundary
    t = Muxr::Terminal.new(rows: 1, cols: 20)
    t.feed("foo,bar baz")
    t.place_selection_cursor(0, 0)
    t.selection_cursor_word_forward
    assert_equal [0, 3], t.selection_cursor_visible # comma is its own word
    t.selection_cursor_word_forward
    assert_equal [0, 4], t.selection_cursor_visible # 'b' of "bar"
  end

  def test_word_forward_big_treats_punct_and_alnum_as_one_word
    t = Muxr::Terminal.new(rows: 1, cols: 20)
    t.feed("foo,bar baz")
    t.place_selection_cursor(0, 0)
    t.selection_cursor_word_forward(big: true)
    assert_equal [0, 8], t.selection_cursor_visible # 'b' of "baz"
  end

  def test_word_end_moves_to_end_of_word
    t = Muxr::Terminal.new(rows: 1, cols: 20)
    t.feed("hello world")
    t.place_selection_cursor(0, 0)
    t.selection_cursor_word_end
    assert_equal [0, 4], t.selection_cursor_visible # 'o' of "hello"
    t.selection_cursor_word_end
    assert_equal [0, 10], t.selection_cursor_visible # 'd' of "world"
  end

  def test_word_backward_returns_to_word_start
    t = Muxr::Terminal.new(rows: 1, cols: 20)
    t.feed("hello world foo")
    t.place_selection_cursor(0, 14) # on the last 'o' of "foo"
    t.selection_cursor_word_backward
    assert_equal [0, 12], t.selection_cursor_visible # 'f'
    t.selection_cursor_word_backward
    assert_equal [0, 6], t.selection_cursor_visible # 'w'
    t.selection_cursor_word_backward
    assert_equal [0, 0], t.selection_cursor_visible # 'h'
  end

  def test_word_backward_big_skips_punctuation
    t = Muxr::Terminal.new(rows: 1, cols: 20)
    t.feed("foo,bar baz")
    t.place_selection_cursor(0, 10) # 'z' of "baz"
    t.selection_cursor_word_backward(big: true)
    assert_equal [0, 8], t.selection_cursor_visible # 'b' of "baz"
    t.selection_cursor_word_backward(big: true)
    assert_equal [0, 0], t.selection_cursor_visible # 'f' of "foo,bar" (one WORD)
  end

  def test_first_non_blank_skips_leading_whitespace
    t = Muxr::Terminal.new(rows: 1, cols: 10)
    t.feed("   hello")
    t.place_selection_cursor(0, 0)
    t.selection_cursor_to_first_non_blank
    assert_equal [0, 3], t.selection_cursor_visible
  end

  def test_viewport_jump_places_cursor_on_visible_lines
    t = Muxr::Terminal.new(rows: 3, cols: 5)
    t.feed("aaaaa\r\n bbbb\r\n  ccc")
    t.place_selection_cursor(0, 4)
    t.selection_cursor_to_viewport(:top)
    assert_equal [0, 0], t.selection_cursor_visible
    t.selection_cursor_to_viewport(:middle)
    assert_equal [1, 1], t.selection_cursor_visible # first non-blank of " bbbb"
    t.selection_cursor_to_viewport(:bottom)
    assert_equal [2, 2], t.selection_cursor_visible # first non-blank of "  ccc"
  end

  def test_word_forward_crosses_row_boundary
    # "hello" fills the full row, no internal whitespace, so the next word
    # start is the 'w' that starts on the row below.
    t = Muxr::Terminal.new(rows: 3, cols: 5)
    t.feed("hello\r\nworld\r\nbye")
    t.place_selection_cursor(0, 0)
    t.selection_cursor_word_forward
    assert_equal [1, 0], t.selection_cursor_visible
    t.selection_cursor_word_forward
    assert_equal [2, 0], t.selection_cursor_visible
  end

  def test_osc_8_hyperlink_stamps_cells_with_payload
    t = Muxr::Terminal.new(rows: 1, cols: 5)
    t.feed("\e]8;;https://example.com\e\\link\e]8;;\e\\")
    payload = t.cell(0, 0).hyperlink
    assert_equal "8;;https://example.com", payload
    # All four chars of "link" share the same interned payload object.
    assert_same payload, t.cell(0, 1).hyperlink
    assert_same payload, t.cell(0, 2).hyperlink
    assert_same payload, t.cell(0, 3).hyperlink
    # Outside the link, no hyperlink is attached.
    assert_nil t.cell(0, 4).hyperlink
  end

  def test_osc_8_hyperlink_survives_autowrap
    # The defining bug: a URL that wraps across rows. After autowrap, the
    # cells on the second row must still carry the hyperlink so the renderer
    # can re-wrap them in one OSC 8 region.
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("\e]8;;https://example.com/longpath\e\\abcdef\e]8;;\e\\")
    assert_equal "8;;https://example.com/longpath", t.cell(0, 0).hyperlink
    assert_equal t.cell(0, 0).hyperlink, t.cell(1, 0).hyperlink
    assert_equal "f", t.cell(1, 2).char
    assert_equal t.cell(0, 0).hyperlink, t.cell(1, 2).hyperlink
  end

  def test_osc_8_bel_terminator_is_accepted
    # OSC may be closed by BEL (0x07) instead of ST (ESC \). Older tools
    # commonly emit the BEL form.
    t = Muxr::Terminal.new(rows: 1, cols: 3)
    t.feed("\e]8;;https://x\x07ab\e]8;;\x07c")
    assert_equal "8;;https://x", t.cell(0, 0).hyperlink
    assert_equal "8;;https://x", t.cell(0, 1).hyperlink
    assert_nil t.cell(0, 2).hyperlink
  end

  def test_osc_8_empty_uri_closes_link
    t = Muxr::Terminal.new(rows: 1, cols: 3)
    t.feed("\e]8;;https://x\e\\a\e]8;;\e\\bc")
    assert_equal "8;;https://x", t.cell(0, 0).hyperlink
    assert_nil t.cell(0, 1).hyperlink
    assert_nil t.cell(0, 2).hyperlink
  end

  def test_osc_8_with_id_preserves_full_payload
    # An `id=` parameter is the hint terminals use to merge spans across
    # gaps. Round-trip the whole body so Ghostty (and friends) see what the
    # source emitted.
    t = Muxr::Terminal.new(rows: 1, cols: 1)
    t.feed("\e]8;id=42;https://x\e\\a")
    assert_equal "8;id=42;https://x", t.cell(0, 0).hyperlink
  end

  # ---------- plain-text URL detection ----------

  def test_detects_plain_url_and_stamps_cells
    t = Muxr::Terminal.new(rows: 1, cols: 30)
    t.feed("see https://example.com here")
    link = t.cell(0, 4).hyperlink
    refute_nil link
    assert_includes link, "https://example.com"
    assert_includes link, "id=muxr-url-"
    assert_equal link, t.cell(0, 22).hyperlink
    assert_nil t.cell(0, 0).hyperlink
    assert_nil t.cell(0, 24).hyperlink
  end

  def test_wrapped_url_shares_one_id_across_rows
    # The whole point: a URL that wraps across rows must share one OSC 8
    # `id=` so the outer terminal recognises both halves as one click target.
    t = Muxr::Terminal.new(rows: 2, cols: 20)
    t.feed("https://example.com/some-very-long-path")
    link = t.cell(0, 0).hyperlink
    refute_nil link
    assert_includes link, "id=muxr-url-"
    assert_equal link, t.cell(1, 0).hyperlink
    assert_equal link, t.cell(1, 18).hyperlink
  end

  def test_trims_trailing_sentence_punctuation
    t = Muxr::Terminal.new(rows: 1, cols: 30)
    t.feed("see https://example.com.")
    link = t.cell(0, 4).hyperlink
    refute_nil link
    assert_includes link, "https://example.com"
    refute_includes link, "https://example.com."
    # The trailing period itself is not part of the link.
    assert_nil t.cell(0, 23).hyperlink
  end

  def test_does_not_clobber_program_emitted_hyperlink
    # If an inner program already wrapped the URL in OSC 8, leave its
    # payload alone — the program knows best.
    t = Muxr::Terminal.new(rows: 1, cols: 30)
    t.feed("\e]8;;https://other.com\e\\https://example.com\e]8;;\e\\")
    assert_equal "8;;https://other.com", t.cell(0, 0).hyperlink
  end

  def test_same_url_produces_stable_payload_across_feeds
    # Idempotent scanning: re-feeding the same screen content must yield the
    # exact same hyperlink object, so the renderer's diff doesn't churn.
    t = Muxr::Terminal.new(rows: 1, cols: 30)
    t.feed("https://example.com")
    first = t.cell(0, 0).hyperlink
    t.feed("")
    assert_equal first, t.cell(0, 0).hyperlink
  end

  # ---------- search ----------

  def test_search_finds_matches_across_timeline
    t = Muxr::Terminal.new(rows: 2, cols: 8)
    # First two lines roll into scrollback, last two stay on the grid.
    t.feed("hello\r\nworld\r\nhello\r\nfoo")
    count = t.search("hello")
    assert_equal 2, count
    # Match rows: scrollback row 0 and live buffer row 0 (timeline index 2).
    rows = t.search_matches.map { |m| m[0] }
    assert_equal [0, 2], rows
  end

  def test_search_smart_case_is_insensitive_when_query_is_lowercase
    t = Muxr::Terminal.new(rows: 1, cols: 10)
    t.feed("Hello")
    assert_equal 1, t.search("hello")
  end

  def test_search_smart_case_is_sensitive_when_query_has_uppercase
    t = Muxr::Terminal.new(rows: 1, cols: 10)
    t.feed("hello")
    assert_equal 0, t.search("Hello")
  end

  def test_search_empty_query_clears_state
    t = Muxr::Terminal.new(rows: 1, cols: 5)
    t.feed("hi")
    t.search("hi")
    assert t.search_active?
    t.search("")
    refute t.search_active?
    assert_nil t.search_query
  end

  def test_search_forward_jumps_to_first_match_at_or_after_top
    t = Muxr::Terminal.new(rows: 2, cols: 5)
    t.feed("aaa\r\nbbb\r\naaa\r\nccc") # scrollback: [aaa, bbb], grid: [aaa, ccc]
    t.scroll_to_top
    t.search("aaa", direction: :forward)
    # First forward match from top of viewport is the scrollback "aaa" at tr 0.
    assert_equal 0, t.search_matches[t.search_current][0]
  end

  def test_search_backward_jumps_to_match_at_or_before_top
    t = Muxr::Terminal.new(rows: 2, cols: 5)
    t.feed("aaa\r\nbbb\r\naaa\r\nccc")
    # User has scrolled back so top of viewport == timeline row 1 (bbb).
    t.scroll_back(1)
    t.search("aaa", direction: :backward)
    assert_equal 0, t.search_matches[t.search_current][0]
  end

  def test_find_in_direction_advances_and_wraps
    t = Muxr::Terminal.new(rows: 2, cols: 5)
    t.feed("aaa\r\nbbb\r\naaa\r\nccc")
    t.scroll_to_top
    t.search("aaa", direction: :forward) # lands on tr 0
    t.find_in_direction(:forward)        # advances to tr 2
    assert_equal 2, t.search_matches[t.search_current][0]
    t.find_in_direction(:forward)        # wraps back to tr 0
    assert_equal 0, t.search_matches[t.search_current][0]
  end

  def test_cell_in_match_highlights_visible_match_cells
    t = Muxr::Terminal.new(rows: 1, cols: 5)
    t.feed("hi yo")
    t.search("yo")
    refute t.cell_in_match?(0, 2) # space before match
    assert t.cell_in_match?(0, 3) # 'y'
    assert t.cell_in_match?(0, 4) # 'o'
  end

  def test_clear_search_removes_state
    t = Muxr::Terminal.new(rows: 1, cols: 3)
    t.feed("foo")
    t.search("foo")
    t.clear_search
    refute t.search_active?
    assert_empty t.search_matches
  end

  # ---------- wide / combining characters ----------

  def test_char_width_classifies_codepoints
    assert_equal 1, Muxr::Terminal.char_width("a".ord)
    assert_equal 1, Muxr::Terminal.char_width("é".ord)        # precomposed
    assert_equal 0, Muxr::Terminal.char_width("́".ord)   # combining acute
    assert_equal 2, Muxr::Terminal.char_width("中".ord)        # CJK
    assert_equal 2, Muxr::Terminal.char_width("🐛".ord)        # emoji
    assert_equal 2, Muxr::Terminal.char_width("가".ord)        # Hangul syllable
  end

  def test_wide_char_advances_cursor_two_columns
    t = Muxr::Terminal.new(rows: 2, cols: 10)
    t.feed("中x")
    assert_equal "中", t.cell(0, 0).char
    assert_equal "",  t.cell(0, 1).char   # continuation half
    assert_equal "x", t.cell(0, 2).char   # next glyph lands one column past
    assert_equal 3, t.cursor_col
  end

  def test_wide_char_continuation_inherits_style
    t = Muxr::Terminal.new(rows: 1, cols: 6)
    t.feed("\e[31m中")                       # red foreground (SGR 31 → fg 1)
    assert_equal 1, t.cell(0, 0).fg          # lead half colored
    assert_equal 1, t.cell(0, 1).fg          # continuation half colored too
  end

  def test_combining_mark_folds_onto_previous_cell
    t = Muxr::Terminal.new(rows: 1, cols: 5)
    t.feed("é")                       # e + combining acute
    assert_equal "é", t.cell(0, 0).char
    assert_equal 1, t.cursor_col            # no extra column consumed
    assert_equal " ", t.cell(0, 1).char
  end

  def test_combining_mark_at_line_start_is_dropped
    t = Muxr::Terminal.new(rows: 1, cols: 5)
    t.feed("́a")                       # nothing to attach to
    assert_equal "a", t.cell(0, 0).char
    assert_equal 1, t.cursor_col
  end

  def test_wide_char_defers_past_last_column
    # A wide glyph that can't fit in the final column wraps to the next line
    # rather than being split across the edge.
    t = Muxr::Terminal.new(rows: 2, cols: 3)
    t.feed("ab中")                          # 'a','b' fill cols 0,1; col 2 free
    assert_equal " ", t.cell(0, 2).char     # last column left blank
    assert_equal "中", t.cell(1, 0).char    # wide glyph on next row
    assert_equal "",  t.cell(1, 1).char
  end

  def test_dump_text_preserves_wide_chars
    t = Muxr::Terminal.new(rows: 1, cols: 8)
    t.feed("中文x")
    assert_equal "中文x", t.dump_text
  end

  def test_search_highlights_wide_line_in_column_coordinates
    t = Muxr::Terminal.new(rows: 1, cols: 8)
    t.feed("中x")                            # 中 at cols 0-1, x at col 2
    t.search("x")
    assert t.cell_in_match?(0, 2)           # highlight lands on the real column
    refute t.cell_in_match?(0, 1)
  end

  def test_absolute_positioning_after_wide_char_stays_aligned
    # TUI redraw pattern: a wide glyph followed by an absolute cursor move.
    # The wide glyph must occupy two columns so the later CUP lands where the
    # program expects.
    t = Muxr::Terminal.new(rows: 2, cols: 10)
    t.feed("\e[1;1H中\e[1;5HX")              # 中 at 0-1, then jump to column 5
    assert_equal "中", t.cell(0, 0).char
    assert_equal "",  t.cell(0, 1).char
    assert_equal "X", t.cell(0, 4).char
  end

  def test_url_detection_after_wide_char_targets_correct_cells
    t = Muxr::Terminal.new(rows: 1, cols: 30)
    t.feed("中 http://example.com")          # 中 occupies cols 0-1
    # The URL starts at column 3 (中=0-1, space=2). The synthetic hyperlink
    # must land on the URL's actual cells, not be shifted by the wide glyph.
    link = t.cell(0, 3).hyperlink
    refute_nil link
    assert link.start_with?("8;id=muxr-url-")
    assert_includes link, "http://example.com"
    assert_nil t.cell(0, 0).hyperlink         # the 中 cell is not part of the URL
  end

  # The width probe flips Terminal.ambiguous_wide to match the outer terminal.
  # When narrow (default), an ambiguous glyph is one column; when wide it claims
  # two. Restore the default afterwards so the process-global toggle doesn't
  # leak into other tests.
  def test_ambiguous_width_follows_toggle
    refute Muxr::Terminal.ambiguous_wide, "expected narrow default"
    assert_equal 1, Muxr::Terminal.char_width("●".ord)
    # CJK and ASCII are unaffected by the ambiguous setting.
    assert_equal 2, Muxr::Terminal.char_width("中".ord)
    assert_equal 1, Muxr::Terminal.char_width("a".ord)

    Muxr::Terminal.ambiguous_wide = true
    assert_equal 2, Muxr::Terminal.char_width("●".ord)
    assert_equal 1, Muxr::Terminal.char_width("a".ord)
    # Box-drawing band stays narrow even when ambiguous is wide.
    assert_equal 1, Muxr::Terminal.char_width("─".ord)
  ensure
    Muxr::Terminal.ambiguous_wide = false
  end

  # Per-glyph overrides are ground truth: they win over every heuristic and
  # cover glyphs (Claude Code's ⏺) that no width class predicts. They apply
  # regardless of the ambiguous toggle.
  def test_width_overrides_take_precedence
    assert_equal 1, Muxr::Terminal.char_width(0x23FA)   # ⏺ default narrow
    Muxr::Terminal.width_overrides = { 0x23FA => 2 }
    assert_equal 2, Muxr::Terminal.char_width(0x23FA)
    # An override can also demote a glyph muxr would otherwise call wide.
    Muxr::Terminal.width_overrides = { "中".ord => 1 }
    assert_equal 1, Muxr::Terminal.char_width("中".ord)
  ensure
    Muxr::Terminal.width_overrides = {}
  end

  def test_overridden_wide_glyph_gets_continuation_cell
    Muxr::Terminal.width_overrides = { 0x23FA => 2 }   # ⏺
    t = Muxr::Terminal.new(rows: 1, cols: 10)
    t.feed("⏺x")
    assert_equal "⏺", t.cell(0, 0).char
    assert_equal "",  t.cell(0, 1).char       # reserved continuation half
    assert_equal "x", t.cell(0, 2).char       # pushed one column right
  ensure
    Muxr::Terminal.width_overrides = {}
  end

  def test_cursor_visibility_tracks_dectcem
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    assert t.cursor_visible?, "starts visible"
    t.feed("\e[?25l")
    refute t.cursor_visible?, "hidden by \\e[?25l"
    t.feed("\e[?25h")
    assert t.cursor_visible?, "shown by \\e[?25h"
  end

  def test_cursor_visibility_independent_of_sync_and_paste
    # A combined DECSET must not bleed mode 25 into 2026/2004 or vice versa.
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    t.feed("\e[?25l")
    refute t.cursor_visible?
    refute t.sync_pending?
    refute t.bracketed_paste?
    t.feed("\e[?2026h\e[?2004h")
    refute t.cursor_visible?, "still hidden after unrelated DECSETs"
    assert t.sync_pending?
    assert t.bracketed_paste?
  end

  def test_full_reset_restores_cursor_visibility
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    t.feed("\e[?25l")
    refute t.cursor_visible?
    t.feed("\ec") # RIS
    assert t.cursor_visible?, "\\ec restores the cursor"
  end

  def test_bell_is_queued_as_a_notification
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    assert_nil t.take_pending_notifications!, "nothing queued initially"
    t.feed("x\ay")
    assert_equal "\a", t.take_pending_notifications!
    assert_nil t.take_pending_notifications!, "drained"
    # The bell is out-of-band: it does not disturb the grid.
    assert_equal "x", t.cell(0, 0).char
    assert_equal "y", t.cell(0, 1).char
  end

  def test_osc_9_desktop_notification_is_forwarded_verbatim
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    t.feed("\e]9;build done\a")
    assert_equal "\e]9;build done\a", t.take_pending_notifications!
  end

  def test_osc_777_notification_is_forwarded
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    t.feed("\e]777;notify;Claude;needs input\e\\")
    # ST terminator is normalized to BEL; the payload is preserved.
    assert_equal "\e]777;notify;Claude;needs input\a", t.take_pending_notifications!
  end

  def test_osc_8_hyperlink_is_not_treated_as_a_notification
    t = Muxr::Terminal.new(rows: 1, cols: 10)
    t.feed("\e]8;;http://x\e\\A\e]8;;\e\\")
    assert_nil t.take_pending_notifications!, "OSC 8 stays on the grid, not the bell queue"
  end

  def test_osc_52_clipboard_write_is_decoded_and_queued
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    assert_nil t.take_pending_clipboard!, "nothing queued initially"
    b64 = ["hello world"].pack("m0")
    t.feed("\e]52;c;#{b64}\a")
    assert_equal "hello world", t.take_pending_clipboard!
    assert_nil t.take_pending_clipboard!, "drained"
  end

  def test_osc_52_is_out_of_band_and_does_not_touch_the_grid
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    t.feed("x")
    t.feed("\e]52;c;#{["yo"].pack("m0")}\e\\")
    t.feed("y")
    assert_equal "x", t.cell(0, 0).char
    assert_equal "y", t.cell(0, 1).char
    assert_equal "yo", t.take_pending_clipboard!
  end

  def test_osc_52_query_is_ignored
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    t.feed("\e]52;c;?\a")
    assert_nil t.take_pending_clipboard!, "a clipboard query must not be treated as a write"
  end

  def test_osc_52_empty_payload_does_not_clear_clipboard
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    t.feed("\e]52;c;#{["keep"].pack("m0")}\a")
    t.feed("\e]52;c;\a")
    assert_equal "keep", t.take_pending_clipboard!, "empty OSC 52 is a no-op, not a wipe"
  end

  def test_osc_52_last_write_wins
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    t.feed("\e]52;c;#{["first"].pack("m0")}\a")
    t.feed("\e]52;c;#{["second"].pack("m0")}\a")
    assert_equal "second", t.take_pending_clipboard!
  end

  def test_osc_52_default_target_is_accepted
    t = Muxr::Terminal.new(rows: 5, cols: 5)
    # Empty target field (just `52;;<base64>`) — defaults to the clipboard.
    t.feed("\e]52;;#{["nt"].pack("m0")}\a")
    assert_equal "nt", t.take_pending_clipboard!
  end

  def test_notification_queue_is_capped
    t = Muxr::Terminal.new(rows: 1, cols: 1)
    # Far more bells than NOTIFY_MAX bytes; the queue must not grow past the cap.
    (Muxr::Terminal::NOTIFY_MAX + 1000).times { t.feed("\a") }
    assert_operator t.take_pending_notifications!.bytesize, :<=, Muxr::Terminal::NOTIFY_MAX
  end
end
