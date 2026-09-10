require "test_helper"

class TestHistoryRow < Minitest::Test
  def tuple(cell)
    [cell.char, cell.fg, cell.bg, cell.attrs, cell.hyperlink]
  end

  def push_into_history(t, payload)
    t.feed(payload)
    expected = (0...t.cols).map { |c| tuple(t.cell(0, c)) }
    t.feed("\r\n\r\n")
    [expected, t.instance_variable_get(:@scrollback).first]
  end

  def assert_history_matches(expected, row)
    2.times do |pass|
      row.length.times do |c|
        assert_equal expected[c], tuple(row[c]), "cell #{c} (pass #{pass})"
      end
      row.release!
    end
    (row.length...expected.length).each do |c|
      assert_equal [" ", nil, nil, 0, nil], expected[c], "trimmed cell #{c} was not blank"
    end
  end

  def test_a_plain_row_round_trips
    t = Muxr::Terminal.new(rows: 2, cols: 20)
    expected, row = push_into_history(t, "plain text")
    assert_equal 10, row.length
    assert_history_matches(expected, row)
  end

  def test_sixteen_colour_256_colour_and_truecolour_runs_round_trip
    t = Muxr::Terminal.new(rows: 2, cols: 40)
    expected, row = push_into_history(
      t, "\e[31mred\e[38;5;208mfixed\e[38;2;10;20;30mtrue\e[46mbg\e[0m"
    )
    assert_equal 1, row[0].fg
    assert_equal [:c256, 208], row[3].fg
    assert_equal [:rgb, 10, 20, 30], row[8].fg
    assert_equal 6, row[12].bg
    assert_history_matches(expected, row)
  end

  def test_character_attributes_round_trip
    t = Muxr::Terminal.new(rows: 2, cols: 20)
    expected, row = push_into_history(t, "\e[1mb\e[4mu\e[7mr\e[2md\e[0m")
    assert_equal Muxr::Terminal::BOLD, row[0].attrs
    assert_equal Muxr::Terminal::BOLD | Muxr::Terminal::UNDERLINE, row[1].attrs
    assert_history_matches(expected, row)
  end

  def test_a_background_run_to_end_of_line_survives_packing
    t = Muxr::Terminal.new(rows: 2, cols: 10)
    expected, row = push_into_history(t, "\e[41m#{' ' * 10}\e[0m")
    assert_equal 10, row.length
    assert_equal 1, row[9].bg
    assert_history_matches(expected, row)
  end

  def test_wide_glyphs_keep_their_continuation_cells
    t = Muxr::Terminal.new(rows: 2, cols: 10)
    expected, row = push_into_history(t, "\e[32m\u4f60\u597d\e[0m")
    assert_equal ["\u4f60", "", "\u597d", ""], row.map(&:char)
    assert_equal 2, row[1].fg
    assert_history_matches(expected, row)
  end

  def test_combining_marks_stay_folded_onto_one_cell
    t = Muxr::Terminal.new(rows: 2, cols: 10)
    expected, row = push_into_history(t, "e\u0301x")
    assert_equal 2, row.length
    assert_equal "e\u0301", row[0].char
    assert_equal "x", row[1].char
    assert_history_matches(expected, row)
  end

  def test_hyperlinks_round_trip
    t = Muxr::Terminal.new(rows: 2, cols: 20)
    expected, row = push_into_history(t, "\e]8;;https://example.com\e\\link\e]8;;\e\\ nope")
    assert_equal "8;;https://example.com", row[0].hyperlink
    assert_nil row[5].hyperlink
    assert_history_matches(expected, row)
  end

  def test_a_blank_row_packs_to_the_shared_empty_row
    t = Muxr::Terminal.new(rows: 2, cols: 20)
    t.feed("\r\n\r\n\r\n")
    sb = t.instance_variable_get(:@scrollback)
    assert_empty sb[0]
    assert_same Muxr::HistoryRow::EMPTY, sb[0]
    assert_nil sb[0][0]
  end

  def test_a_url_wrapping_out_of_history_is_stamped_and_repacked
    t = Muxr::Terminal.new(rows: 2, cols: 20)
    t.feed("see https://example.com/aaa")
    t.feed("\r\n")
    row = t.instance_variable_get(:@scrollback).first
    payload = row[4].hyperlink
    refute_nil payload
    assert payload.start_with?(Muxr::Terminal::SYNTH_URL_PREFIX)
    assert_same payload, t.cell(0, 0).hyperlink
    row.release!
    assert_equal payload, row[4].hyperlink
    assert_equal payload, row[19].hyperlink
    assert_nil row[0].hyperlink
  end

  def test_materialized_rows_are_released_past_the_cache_limit
    t = Muxr::Terminal.new(rows: 2, cols: 10)
    (Muxr::HistoryRow::CACHE_LIMIT + 22).times { |i| t.feed("line#{i}\r\n") }
    sb = t.instance_variable_get(:@scrollback)
    assert_operator sb.size, :>, Muxr::HistoryRow::CACHE_LIMIT
    sb.each { |row| row[0] }
    assert_nil sb.first.instance_variable_get(:@cells)
    refute_nil sb.last.instance_variable_get(:@cells)
    assert_equal "line0", sb.first.map(&:char).join
  end
end
