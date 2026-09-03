require "test_helper"
require "muxr/pane_picker"
require "muxr/session_directory"

class TestPanePicker < Minitest::Test
  def entry(session, slot, id, cwd = "/tmp")
    Muxr::SessionDirectory::Entry.new(
      session: session, socket_path: "/dev/null", pane_id: id,
      slot: slot, cwd: cwd, rows: 24, cols: 80, focused: false
    )
  end

  def picker
    Muxr::PanePicker.new([
      entry("work", 1, "aaa111"),
      entry("work", 2, "bbb222"),
      entry("notes", 1, "ccc333")
    ])
  end

  def test_sessions_become_headings_above_their_panes
    kinds = picker.rows.map(&:kind)
    assert_equal %i[session pane pane session pane], kinds
  end

  def test_selection_starts_on_the_first_pane_not_the_heading
    assert_equal "aaa111", picker.selected.pane_id
  end

  def test_moving_skips_headings
    p = picker
    p.move(1)
    assert_equal "bbb222", p.selected.pane_id
    p.move(1)
    assert_equal "ccc333", p.selected.pane_id
  end

  def test_moving_wraps_around_the_ends
    p = picker
    p.move(-1)
    assert_equal "ccc333", p.selected.pane_id
    p.move(1)
    assert_equal "aaa111", p.selected.pane_id
  end

  def test_empty_picker_has_nothing_to_select
    p = Muxr::PanePicker.new([])
    assert p.empty?
    assert_nil p.selected
    p.move(1)
    assert_nil p.selected
  end
end
