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
end
