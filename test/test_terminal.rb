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
end
