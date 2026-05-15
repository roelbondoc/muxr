require "test_helper"

class TestLayoutManager < Minitest::Test
  Area = Muxr::LayoutManager::Rect

  def setup
    @area = Area.new(0, 0, 80, 24)
  end

  def test_returns_empty_for_zero_panes
    assert_equal [], Muxr::LayoutManager.compute(:tall, 0, @area)
    assert_equal [], Muxr::LayoutManager.compute(:grid, 0, @area)
    assert_equal [], Muxr::LayoutManager.compute(:monocle, 0, @area)
  end

  def test_tall_with_single_pane_fills_area
    rects = Muxr::LayoutManager.compute(:tall, 1, @area)
    assert_equal 1, rects.length
    assert_equal [0, 0, 80, 24], rects[0].to_a
  end

  def test_tall_with_two_panes_splits_master_and_stack
    rects = Muxr::LayoutManager.compute(:tall, 2, @area, master_index: 0)
    assert_equal 2, rects.length
    assert_equal [0, 0, 40, 24], rects[0].to_a
    assert_equal [40, 0, 40, 24], rects[1].to_a
  end

  def test_tall_stack_heights_sum_to_total
    rects = Muxr::LayoutManager.compute(:tall, 4, @area)
    master = rects[0]
    slaves = rects[1..]
    assert_equal 24, slaves.sum(&:h)
    slaves.each { |r| assert_equal 80 - master.w, r.x + r.w - master.w }
  end

  def test_tall_respects_master_index
    rects = Muxr::LayoutManager.compute(:tall, 3, @area, master_index: 2)
    refute_nil rects[2]
    assert_equal @area.h, rects[2].h
    assert_equal 0, rects[2].x
  end

  def test_tall_clamps_master_index_out_of_range
    rects = Muxr::LayoutManager.compute(:tall, 3, @area, master_index: 99)
    assert_equal 3, rects.compact.length
  end

  def test_grid_with_four_panes_two_by_two
    rects = Muxr::LayoutManager.compute(:grid, 4, @area)
    assert_equal 4, rects.length
    widths  = rects.map(&:w).uniq
    heights = rects.map(&:h).uniq
    assert_equal 1, widths.size
    assert_equal 1, heights.size
    assert_equal 40, widths.first
    assert_equal 12, heights.first
  end

  def test_grid_fills_full_width_on_underfull_row
    rects = Muxr::LayoutManager.compute(:grid, 3, @area)
    # 3 panes -> 2 cols x 2 rows, last row has 1 pane and should span full width
    bottom = rects.max_by { |r| r.y }
    assert_equal 80, bottom.w
  end

  def test_grid_covers_full_area
    rects = Muxr::LayoutManager.compute(:grid, 5, @area)
    total = rects.sum { |r| r.w * r.h }
    assert_equal 80 * 24, total
  end

  def test_monocle_returns_full_area_for_every_pane
    rects = Muxr::LayoutManager.compute(:monocle, 3, @area)
    assert_equal 3, rects.length
    rects.each do |r|
      assert_equal [0, 0, 80, 24], r.to_a
    end
  end

  def test_unknown_layout_raises
    assert_raises(ArgumentError) do
      Muxr::LayoutManager.compute(:tabbed, 2, @area)
    end
  end

  # ---------- spatial neighbor lookup (powers hjkl in normal mode) ----------

  def test_neighbor_returns_nil_for_empty_or_missing_focused
    assert_nil Muxr::LayoutManager.neighbor([], 0, :right)
    assert_nil Muxr::LayoutManager.neighbor(nil, 0, :right)
    rects = Muxr::LayoutManager.compute(:tall, 2, @area)
    assert_nil Muxr::LayoutManager.neighbor(rects, 99, :right)
  end

  def test_neighbor_tall_two_panes_master_right_goes_to_slave
    rects = Muxr::LayoutManager.compute(:tall, 2, @area)
    assert_equal 1, Muxr::LayoutManager.neighbor(rects, 0, :right)
    # And the reverse.
    assert_equal 0, Muxr::LayoutManager.neighbor(rects, 1, :left)
  end

  def test_neighbor_tall_three_panes_picks_vertically_overlapping_slave
    # Master full-height; two slaves stacked. From master, :right should
    # prefer the slave whose y-range overlaps the focused y-range more.
    # With master at y=0..24, both slaves overlap fully, so tie goes to the
    # top one (first in the list).
    rects = Muxr::LayoutManager.compute(:tall, 3, @area)
    assert_equal 1, Muxr::LayoutManager.neighbor(rects, 0, :right)
    # j (down) from top slave goes to bottom slave.
    assert_equal 2, Muxr::LayoutManager.neighbor(rects, 1, :down)
    # k (up) from bottom slave goes to top slave.
    assert_equal 1, Muxr::LayoutManager.neighbor(rects, 2, :up)
    # h (left) from either slave goes back to the master.
    assert_equal 0, Muxr::LayoutManager.neighbor(rects, 1, :left)
    assert_equal 0, Muxr::LayoutManager.neighbor(rects, 2, :left)
  end

  def test_neighbor_returns_nil_at_edges
    rects = Muxr::LayoutManager.compute(:tall, 2, @area)
    # Master has no pane to its left.
    assert_nil Muxr::LayoutManager.neighbor(rects, 0, :left)
    # Slave has no pane to its right.
    assert_nil Muxr::LayoutManager.neighbor(rects, 1, :right)
    # Two-pane tall has nothing above master.
    assert_nil Muxr::LayoutManager.neighbor(rects, 0, :up)
  end

  def test_neighbor_grid_2x2
    # Layout: 0 1 / 2 3 (rows). From 0 right→1, down→2, etc.
    rects = Muxr::LayoutManager.compute(:grid, 4, @area)
    assert_equal 1, Muxr::LayoutManager.neighbor(rects, 0, :right)
    assert_equal 2, Muxr::LayoutManager.neighbor(rects, 0, :down)
    assert_equal 0, Muxr::LayoutManager.neighbor(rects, 1, :left)
    assert_equal 3, Muxr::LayoutManager.neighbor(rects, 1, :down)
    assert_equal 0, Muxr::LayoutManager.neighbor(rects, 2, :up)
    assert_equal 3, Muxr::LayoutManager.neighbor(rects, 2, :right)
    assert_equal 2, Muxr::LayoutManager.neighbor(rects, 3, :left)
    assert_equal 1, Muxr::LayoutManager.neighbor(rects, 3, :up)
  end

  def test_neighbor_monocle_returns_nil_for_all_directions
    rects = Muxr::LayoutManager.compute(:monocle, 3, @area)
    %i[left right up down].each do |dir|
      assert_nil Muxr::LayoutManager.neighbor(rects, 0, dir), "expected nil for #{dir}"
    end
  end

  def test_neighbor_unknown_direction_returns_nil
    rects = Muxr::LayoutManager.compute(:tall, 2, @area)
    assert_nil Muxr::LayoutManager.neighbor(rects, 0, :diagonal)
  end
end
