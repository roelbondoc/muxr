require "test_helper"

# Terminal#dump_ansi has one job: feeding its output to a blank emulator of the
# same size must reproduce the source grid exactly. That round-trip is what a
# borrowed pane relies on to come up showing what the owner already had on
# screen, so every case here asserts the replica, not the byte string.
class TestTerminalSnapshot < Minitest::Test
  def replay(source)
    replica = Muxr::Terminal.new(rows: source.rows, cols: source.cols)
    replica.feed(source.dump_ansi)
    replica
  end

  def assert_round_trips(source)
    replica = replay(source)
    assert_equal source.dump_text, replica.dump_text
    source.rows.times do |r|
      source.cols.times do |c|
        a = source.cell(r, c)
        b = replica.cell(r, c)
        assert_equal [a.char, a.fg, a.bg, a.attrs], [b.char, b.fg, b.bg, b.attrs],
                     "cell (#{r},#{c}) differs"
      end
    end
    replica
  end

  def build(rows: 6, cols: 24)
    term = Muxr::Terminal.new(rows: rows, cols: cols)
    yield term
    term
  end

  def test_plain_text
    assert_round_trips(build { |t| t.feed("hello\r\nworld") })
  end

  def test_blank_grid
    assert_round_trips(build { |_t| })
  end

  def test_basic_and_bright_colors
    assert_round_trips(build { |t| t.feed("\e[31mred\e[92mbright\e[0m plain") })
  end

  def test_256_color_and_truecolor
    assert_round_trips(build { |t| t.feed("\e[38;5;208mx\e[48;2;10;20;30my\e[0m") })
  end

  def test_attributes
    assert_round_trips(build { |t| t.feed("\e[1mb\e[2md\e[4mu\e[7mr\e[0m.") })
  end

  def test_background_runs_to_end_of_line_are_preserved
    assert_round_trips(build { |t| t.feed("\e[44m" + ("x" * 24)) })
  end

  def test_wide_characters_keep_their_continuation_cells
    replica = assert_round_trips(build { |t| t.feed("日本語 ok") })
    assert_equal "", replica.cell(0, 1).char
    assert_equal "本", replica.cell(0, 2).char
  end

  def test_combining_marks_stay_folded_onto_their_base
    assert_round_trips(build { |t| t.feed("éclair") })
  end

  def test_cursor_position_is_restored
    source = build { |t| t.feed("abc\r\nde") }
    replica = replay(source)
    assert_equal source.cursor_row, replica.cursor_row
    assert_equal source.cursor_col, replica.cursor_col
  end

  def test_hidden_cursor_stays_hidden
    source = build { |t| t.feed("\e[?25lhidden") }
    refute replay(source).cursor_visible?
  end

  def test_visible_cursor_stays_visible
    source = build { |t| t.feed("\e[?25l\e[?25hshown") }
    assert replay(source).cursor_visible?
  end

  def test_hyperlinks_survive
    source = build { |t| t.feed("\e]8;;https://example.com\e\\link\e]8;;\e\\ tail") }
    replica = replay(source)
    assert_equal source.cell(0, 0).hyperlink, replica.cell(0, 0).hyperlink
    assert_nil replica.cell(0, 5).hyperlink
  end

  def test_a_scrolled_screen_snapshots_what_is_live_not_the_scrollback_view
    source = build(rows: 4, cols: 10) do |t|
      12.times { |i| t.feed("line#{i}\r\n") }
      t.scroll_back(3)
    end
    assert_equal source.dump_text.lines.length, 4
    replica = replay(source)
    refute replica.scrolled_back?
    assert_includes replica.dump_text, "line11"
  end
end
