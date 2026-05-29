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

  def test_wide_with_single_pane_fills_area
    rects = Muxr::LayoutManager.compute(:wide, 1, @area)
    assert_equal 1, rects.length
    assert_equal [0, 0, 80, 24], rects[0].to_a
  end

  def test_wide_with_two_panes_splits_master_top_and_stack_bottom
    rects = Muxr::LayoutManager.compute(:wide, 2, @area, master_index: 0)
    assert_equal 2, rects.length
    assert_equal [0, 0, 80, 12], rects[0].to_a
    assert_equal [0, 12, 80, 12], rects[1].to_a
  end

  def test_wide_stack_widths_sum_to_total
    rects = Muxr::LayoutManager.compute(:wide, 4, @area)
    master = rects[0]
    slaves = rects[1..]
    assert_equal 80, slaves.sum(&:w)
    slaves.each { |r| assert_equal master.h, r.y }
  end

  def test_wide_respects_master_index
    rects = Muxr::LayoutManager.compute(:wide, 3, @area, master_index: 2)
    refute_nil rects[2]
    assert_equal @area.w, rects[2].w
    assert_equal 0, rects[2].y
  end

  def test_wide_clamps_master_index_out_of_range
    rects = Muxr::LayoutManager.compute(:wide, 3, @area, master_index: 99)
    assert_equal 3, rects.compact.length
  end

  def test_columns_are_equal_width_full_height_strips
    rects = Muxr::LayoutManager.compute(:columns, 4, @area)
    assert_equal 4, rects.length
    assert_equal [20], rects.map(&:w).uniq
    rects.each { |r| assert_equal 24, r.h; assert_equal 0, r.y }
    assert_equal [0, 20, 40, 60], rects.map(&:x)
  end

  def test_columns_cover_full_width_with_remainder
    rects = Muxr::LayoutManager.compute(:columns, 3, @area)
    assert_equal 80, rects.sum(&:w)
    assert_equal [0, rects[0].w, rects[0].w + rects[1].w], rects.map(&:x)
  end

  def test_rows_are_equal_height_full_width_strips
    rects = Muxr::LayoutManager.compute(:rows, 3, @area)
    assert_equal 3, rects.length
    assert_equal 24, rects.sum(&:h)
    rects.each { |r| assert_equal 80, r.w; assert_equal 0, r.x }
    assert_equal [0, rects[0].h, rects[0].h + rects[1].h], rects.map(&:y)
  end

  def test_spiral_single_pane_fills_area
    rects = Muxr::LayoutManager.compute(:spiral, 1, @area)
    assert_equal [0, 0, 80, 24], rects[0].to_a
  end

  def test_spiral_winds_inward_without_gaps_or_zero_sizes
    rects = Muxr::LayoutManager.compute(:spiral, 5, @area)
    assert_equal 5, rects.length
    rects.each { |r| assert_operator r.w, :>=, 1; assert_operator r.h, :>=, 1 }
    # First pane takes the left half, full height; last pane is the inner remainder.
    assert_equal [0, 0, 40, 24], rects[0].to_a
    assert_operator rects.last.w, :<, 40
  end

  def test_centered_master_in_middle_with_slaves_each_side
    rects = Muxr::LayoutManager.compute(:centered, 5, @area, master_index: 0)
    master = rects[0]
    slaves = rects[1..]
    # Master is centred: slaves exist both to its left and to its right.
    assert(slaves.any? { |r| r.x < master.x })
    assert(slaves.any? { |r| r.x >= master.x + master.w })
    assert_equal 24, master.h
  end

  def test_centered_single_slave_falls_back_to_vertical_split
    rects = Muxr::LayoutManager.compute(:centered, 2, @area, master_index: 0)
    assert_equal [0, 0, 40, 24], rects[0].to_a
    assert_equal [40, 0, 40, 24], rects[1].to_a
  end

  def test_stack_focused_pane_expands_others_are_slivers
    rects = Muxr::LayoutManager.compute(:stack, 3, @area, focused_index: 1)
    assert_equal 24, rects.sum(&:h)
    rects.each { |r| assert_equal 80, r.w; assert_equal 0, r.x }
    assert_operator rects[1].h, :>, rects[0].h
    assert_operator rects[1].h, :>, rects[2].h
    assert_equal rects[0].h, rects[2].h
  end

  def test_stack_single_pane_fills_area
    rects = Muxr::LayoutManager.compute(:stack, 1, @area)
    assert_equal [0, 0, 80, 24], rects[0].to_a
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
