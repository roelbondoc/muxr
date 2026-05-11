require "test_helper"

class TestLayoutManager < Minitest::Test
  Area = Rux::LayoutManager::Rect

  def setup
    @area = Area.new(0, 0, 80, 24)
  end

  def test_returns_empty_for_zero_panes
    assert_equal [], Rux::LayoutManager.compute(:tall, 0, @area)
    assert_equal [], Rux::LayoutManager.compute(:grid, 0, @area)
    assert_equal [], Rux::LayoutManager.compute(:monocle, 0, @area)
  end

  def test_tall_with_single_pane_fills_area
    rects = Rux::LayoutManager.compute(:tall, 1, @area)
    assert_equal 1, rects.length
    assert_equal [0, 0, 80, 24], rects[0].to_a
  end

  def test_tall_with_two_panes_splits_master_and_stack
    rects = Rux::LayoutManager.compute(:tall, 2, @area, master_index: 0)
    assert_equal 2, rects.length
    assert_equal [0, 0, 40, 24], rects[0].to_a
    assert_equal [40, 0, 40, 24], rects[1].to_a
  end

  def test_tall_stack_heights_sum_to_total
    rects = Rux::LayoutManager.compute(:tall, 4, @area)
    master = rects[0]
    slaves = rects[1..]
    assert_equal 24, slaves.sum(&:h)
    slaves.each { |r| assert_equal 80 - master.w, r.x + r.w - master.w }
  end

  def test_tall_respects_master_index
    rects = Rux::LayoutManager.compute(:tall, 3, @area, master_index: 2)
    refute_nil rects[2]
    assert_equal @area.h, rects[2].h
    assert_equal 0, rects[2].x
  end

  def test_tall_clamps_master_index_out_of_range
    rects = Rux::LayoutManager.compute(:tall, 3, @area, master_index: 99)
    assert_equal 3, rects.compact.length
  end

  def test_grid_with_four_panes_two_by_two
    rects = Rux::LayoutManager.compute(:grid, 4, @area)
    assert_equal 4, rects.length
    widths  = rects.map(&:w).uniq
    heights = rects.map(&:h).uniq
    assert_equal 1, widths.size
    assert_equal 1, heights.size
    assert_equal 40, widths.first
    assert_equal 12, heights.first
  end

  def test_grid_fills_full_width_on_underfull_row
    rects = Rux::LayoutManager.compute(:grid, 3, @area)
    # 3 panes -> 2 cols x 2 rows, last row has 1 pane and should span full width
    bottom = rects.max_by { |r| r.y }
    assert_equal 80, bottom.w
  end

  def test_grid_covers_full_area
    rects = Rux::LayoutManager.compute(:grid, 5, @area)
    total = rects.sum { |r| r.w * r.h }
    assert_equal 80 * 24, total
  end

  def test_monocle_returns_full_area_for_every_pane
    rects = Rux::LayoutManager.compute(:monocle, 3, @area)
    assert_equal 3, rects.length
    rects.each do |r|
      assert_equal [0, 0, 80, 24], r.to_a
    end
  end

  def test_unknown_layout_raises
    assert_raises(ArgumentError) do
      Rux::LayoutManager.compute(:tabbed, 2, @area)
    end
  end
end
