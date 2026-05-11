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
end
