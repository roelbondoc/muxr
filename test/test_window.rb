require "test_helper"

class TestWindow < Minitest::Test
  class FakePane
    attr_reader :closed
    def initialize(label = nil); @label = label; @closed = false; end
    def close; @closed = true; end
    def to_s; @label.to_s; end
  end

  def test_focus_next_wraps_around
    w = Rux::Window.new
    3.times { w.add_pane(FakePane.new) }
    assert_equal 0, w.focused_index
    w.focus_next; assert_equal 1, w.focused_index
    w.focus_next; assert_equal 2, w.focused_index
    w.focus_next; assert_equal 0, w.focused_index
  end

  def test_focus_prev_wraps_around
    w = Rux::Window.new
    3.times { w.add_pane(FakePane.new) }
    w.focus_prev
    assert_equal 2, w.focused_index
  end

  def test_remove_pane_clamps_indices
    w = Rux::Window.new
    a, b, c = FakePane.new("a"), FakePane.new("b"), FakePane.new("c")
    [a, b, c].each { |p| w.add_pane(p) }
    w.focused_index = 2
    w.master_index = 2
    w.remove_pane(c)
    assert_equal 1, w.focused_index
    assert_equal 1, w.master_index
    assert c.closed
  end

  def test_promote_to_master_moves_pane_to_front
    w = Rux::Window.new
    a, b, c = FakePane.new("a"), FakePane.new("b"), FakePane.new("c")
    [a, b, c].each { |p| w.add_pane(p) }
    w.focused_index = 2
    w.promote_to_master
    assert_equal c, w.panes.first
    assert_equal 0, w.master_index
    assert_equal 0, w.focused_index
  end

  def test_cycle_layout_rotates_through_known_layouts
    w = Rux::Window.new
    w.add_pane(FakePane.new)
    assert_equal :tall, w.layout
    w.cycle_layout; assert_equal :grid, w.layout
    w.cycle_layout; assert_equal :monocle, w.layout
    w.cycle_layout; assert_equal :tall, w.layout
  end

  def test_set_layout_rejects_unknown
    w = Rux::Window.new
    assert_raises(ArgumentError) { w.set_layout(:floating) }
  end

  def test_focus_last_toggles_between_two_panes
    w = Rux::Window.new
    3.times { w.add_pane(FakePane.new) }
    w.focus_next
    assert_equal 1, w.focused_index
    w.focus_last
    assert_equal 0, w.focused_index
    w.focus_last
    assert_equal 1, w.focused_index
  end

  def test_focus_last_noop_with_no_history
    w = Rux::Window.new
    2.times { w.add_pane(FakePane.new) }
    w.focus_last
    assert_equal 0, w.focused_index
  end

  def test_focus_last_tracks_pane_through_promote_to_master
    w = Rux::Window.new
    a, b, c = FakePane.new("a"), FakePane.new("b"), FakePane.new("c")
    [a, b, c].each { |p| w.add_pane(p) }
    w.focused_index = 2 # focused = c, last = a
    w.promote_to_master # panes = [c, a, b], focused = 0
    w.focus_last        # should jump to a, now at index 1
    assert_equal 1, w.focused_index
  end

  def test_focus_last_cleared_when_previous_pane_removed
    w = Rux::Window.new
    a, b, c = FakePane.new("a"), FakePane.new("b"), FakePane.new("c")
    [a, b, c].each { |p| w.add_pane(p) }
    w.focused_index = 2 # focused = c, last = a
    w.remove_pane(a)    # last reference gone
    before = w.focused_index
    w.focus_last
    assert_equal before, w.focused_index
  end

  def test_focus_index_sets_focused_pane
    w = Rux::Window.new
    3.times { w.add_pane(FakePane.new) }
    w.focus_index(2)
    assert_equal 2, w.focused_index
    w.focus_index(0)
    assert_equal 0, w.focused_index
    # focus_last should swing back to the previous index (2).
    w.focus_last
    assert_equal 2, w.focused_index
  end

  def test_focus_index_out_of_range_is_noop
    w = Rux::Window.new
    3.times { w.add_pane(FakePane.new) }
    w.focus_index(5)
    assert_equal 0, w.focused_index
    w.focus_index(-1)
    assert_equal 0, w.focused_index
  end
end
