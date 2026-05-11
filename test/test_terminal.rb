require "test_helper"

class TestTerminal < Minitest::Test
  def test_writes_plain_text_into_buffer
    t = Rux::Terminal.new(rows: 5, cols: 10)
    t.feed("hi")
    assert_equal "h", t.cell(0, 0).char
    assert_equal "i", t.cell(0, 1).char
    assert_equal 0, t.cursor_row
    assert_equal 2, t.cursor_col
  end

  def test_line_feed_advances_row
    # VT100 LF advances the row but preserves the column (line-discipline
    # ONLCR is the layer responsible for the implicit CR).
    t = Rux::Terminal.new(rows: 3, cols: 5)
    t.feed("a\r\nb")
    assert_equal "a", t.cell(0, 0).char
    assert_equal "b", t.cell(1, 0).char
  end

  def test_carriage_return_resets_column
    t = Rux::Terminal.new(rows: 3, cols: 5)
    t.feed("ab\rX")
    assert_equal "X", t.cell(0, 0).char
    assert_equal "b", t.cell(0, 1).char
  end

  def test_csi_cursor_position
    t = Rux::Terminal.new(rows: 5, cols: 10)
    t.feed("\e[3;5HX")
    assert_equal "X", t.cell(2, 4).char
  end

  def test_erase_display_to_end
    t = Rux::Terminal.new(rows: 4, cols: 5)
    t.feed("abcd\r\nfghi\r\nklmn")
    t.feed("\e[1;3H\e[0J") # cursor home -> (0,0), then (0;2), then erase to end
    assert_equal "a", t.cell(0, 0).char
    assert_equal "b", t.cell(0, 1).char
    assert_equal " ", t.cell(0, 2).char
    assert_equal " ", t.cell(1, 0).char
  end

  def test_sgr_color_persists
    t = Rux::Terminal.new(rows: 1, cols: 4)
    t.feed("\e[31mAB")
    assert_equal 1, t.cell(0, 0).fg
    assert_equal "A", t.cell(0, 0).char
    assert_equal 1, t.cell(0, 1).fg
  end

  def test_sgr_reset
    t = Rux::Terminal.new(rows: 1, cols: 4)
    t.feed("\e[31mA\e[0mB")
    assert_equal 1, t.cell(0, 0).fg
    assert_nil t.cell(0, 1).fg
  end

  def test_resize_preserves_content_within_bounds
    t = Rux::Terminal.new(rows: 4, cols: 5)
    t.feed("abc\r\ndef")
    t.resize(4, 5)
    assert_equal "a", t.cell(0, 0).char
    assert_equal "d", t.cell(1, 0).char
    t.resize(5, 6)
    assert_equal "a", t.cell(0, 0).char
    assert_equal "d", t.cell(1, 0).char
  end

  def test_autowrap_at_right_edge
    t = Rux::Terminal.new(rows: 2, cols: 3)
    t.feed("abcd")
    assert_equal "a", t.cell(0, 0).char
    assert_equal "b", t.cell(0, 1).char
    assert_equal "c", t.cell(0, 2).char
    assert_equal "d", t.cell(1, 0).char
  end
end
