module Muxr
  # Pure functions that turn (layout_name, pane_count, screen_rect) into an
  # array of pane rectangles. No mutable state; safe to call repeatedly on
  # every render. Following xmonad, layouts decide geometry — users never
  # resize panes by hand.
  module LayoutManager
    Rect = Struct.new(:x, :y, :w, :h) do
      def to_a
        [x, y, w, h]
      end
    end

    LAYOUTS = %i[tall wide columns rows grid spiral centered stack monocle].freeze

    module_function

    def compute(layout, count, area, focused_index: 0, master_index: 0)
      return [] if count <= 0
      master_index = master_index.clamp(0, count - 1)
      focused_index = focused_index.clamp(0, count - 1)
      case layout
      when :tall     then tall(count, area, master_index)
      when :wide     then wide(count, area, master_index)
      when :columns  then columns(count, area)
      when :rows     then rows(count, area)
      when :grid     then grid(count, area)
      when :spiral   then spiral(count, area)
      when :centered then centered(count, area, master_index)
      when :stack    then stack(count, area, focused_index)
      when :monocle  then monocle(count, area, focused_index)
      else
        raise ArgumentError, "Unknown layout: #{layout.inspect}"
      end
    end

    # Master pane on the left taking half the width; remaining panes stack
    # vertically on the right, dividing the remaining height evenly.
    def tall(count, area, master_index = 0)
      master_index = master_index.clamp(0, count - 1)
      return [Rect.new(area.x, area.y, area.w, area.h)] if count == 1

      master_w = [area.w / 2, 1].max
      stack_w  = [area.w - master_w, 1].max
      others   = (0...count).to_a - [master_index]
      slave_count = others.length
      base_h = area.h / slave_count
      remainder = area.h - base_h * slave_count

      rects = Array.new(count)
      rects[master_index] = Rect.new(area.x, area.y, master_w, area.h)

      y = area.y
      others.each_with_index do |idx, i|
        h = base_h + (i < remainder ? 1 : 0)
        rects[idx] = Rect.new(area.x + master_w, y, stack_w, h)
        y += h
      end
      rects
    end

    # The transpose of `tall`: master pane spans the full width across the top
    # half; remaining panes sit side-by-side in the bottom half, dividing the
    # remaining width evenly.
    def wide(count, area, master_index = 0)
      master_index = master_index.clamp(0, count - 1)
      return [Rect.new(area.x, area.y, area.w, area.h)] if count == 1

      master_h = [area.h / 2, 1].max
      stack_h  = [area.h - master_h, 1].max
      others   = (0...count).to_a - [master_index]
      slave_count = others.length
      base_w = area.w / slave_count
      remainder = area.w - base_w * slave_count

      rects = Array.new(count)
      rects[master_index] = Rect.new(area.x, area.y, area.w, master_h)

      x = area.x
      others.each_with_index do |idx, i|
        w = base_w + (i < remainder ? 1 : 0)
        rects[idx] = Rect.new(x, area.y + master_h, w, stack_h)
        x += w
      end
      rects
    end

    # Equal-width, full-height vertical strips, side by side. No master.
    def columns(count, area)
      base_w = area.w / count
      rem    = area.w - base_w * count
      rects  = []
      x = area.x
      count.times do |i|
        w = base_w + (i < rem ? 1 : 0)
        rects << Rect.new(x, area.y, w, area.h)
        x += w
      end
      rects
    end

    # Equal-height, full-width horizontal strips, stacked. The dual of columns.
    def rows(count, area)
      base_h = area.h / count
      rem    = area.h - base_h * count
      rects  = []
      y = area.y
      count.times do |i|
        h = base_h + (i < rem ? 1 : 0)
        rects << Rect.new(area.x, y, area.w, h)
        y += h
      end
      rects
    end

    # Fibonacci spiral: each pane takes half of the remaining region, splitting
    # vertically then horizontally in alternation, so panes wind inward toward
    # the bottom-right. The last pane fills whatever is left.
    def spiral(count, area)
      x, y, w, h = area.x, area.y, area.w, area.h
      rects = []
      count.times do |i|
        if i == count - 1
          rects << Rect.new(x, y, w, h)
        elsif i.even?
          left = [w / 2, 1].max
          rects << Rect.new(x, y, left, h)
          x += left
          w = [w - left, 1].max
        else
          top = [h / 2, 1].max
          rects << Rect.new(x, y, w, top)
          y += top
          h = [h - top, 1].max
        end
      end
      rects
    end

    # Three-column master: master occupies the centre column full-height; the
    # remaining panes are dealt alternately to a left and a right column and
    # stacked within each. With a single slave there is no symmetry to keep, so
    # it falls back to a simple master/slave vertical split (like `tall`).
    def centered(count, area, master_index = 0)
      master_index = master_index.clamp(0, count - 1)
      return [Rect.new(area.x, area.y, area.w, area.h)] if count == 1

      others = (0...count).to_a - [master_index]
      rects  = Array.new(count)

      if others.length == 1
        master_w = [area.w / 2, 1].max
        rects[master_index] = Rect.new(area.x, area.y, master_w, area.h)
        rects[others[0]] = Rect.new(area.x + master_w, area.y, [area.w - master_w, 1].max, area.h)
        return rects
      end

      master_w = [area.w / 2, 1].max
      side_w   = area.w - master_w
      left_w   = [side_w / 2, 1].max
      right_w  = [side_w - left_w, 1].max

      rects[master_index] = Rect.new(area.x + left_w, area.y, master_w, area.h)
      left  = others.select.with_index { |_, i| i.even? }
      right = others.select.with_index { |_, i| i.odd? }
      stack_column(rects, left,  area.x, area.y, left_w, area.h)
      stack_column(rects, right, area.x + left_w + master_w, area.y, right_w, area.h)
      rects
    end

    # Accordion: the focused pane expands to fill the leftover height while the
    # others collapse to short "title sliver" rows, all stacked vertically.
    # Like monocle but the other panes stay visible (and spatially reachable).
    def stack(count, area, focused_index = 0)
      return [Rect.new(area.x, area.y, area.w, area.h)] if count == 1
      focused_index = focused_index.clamp(0, count - 1)

      others = count - 1
      # Sliver is 3 rows so draw_box can still render the title; shrink it only
      # when the terminal is too short to give the focused pane its own 3 rows.
      sliver = [3, [area.h - 3, 0].max / others].min
      sliver = [sliver, 1].max
      focus_h = area.h - sliver * others

      rects = Array.new(count)
      y = area.y
      count.times do |i|
        h = (i == focused_index) ? focus_h : sliver
        rects[i] = Rect.new(area.x, y, area.w, h)
        y += h
      end
      rects
    end

    # Stack the given pane indices vertically within a single column, dividing
    # the height evenly (remainder to the topmost panes). Used by `centered`.
    def stack_column(rects, indices, x, y, w, total_h)
      return if indices.empty?
      base_h = total_h / indices.length
      rem    = total_h - base_h * indices.length
      cy = y
      indices.each_with_index do |idx, i|
        h = base_h + (i < rem ? 1 : 0)
        rects[idx] = Rect.new(x, cy, w, h)
        cy += h
      end
    end

    # Roughly square grid. Each row stretches its panes to fill the full width
    # so an underfull bottom row doesn't leave gaps.
    def grid(count, area)
      cols_per_row = Math.sqrt(count).ceil
      rows = (count.to_f / cols_per_row).ceil

      base_h = area.h / rows
      h_rem  = area.h - base_h * rows

      rects = []
      idx = 0
      y = area.y
      rows.times do |r|
        remaining = count - idx
        in_row = [cols_per_row, remaining].min
        row_h = base_h + (r < h_rem ? 1 : 0)
        col_w = area.w / in_row
        w_rem = area.w - col_w * in_row
        x = area.x
        in_row.times do |c|
          w = col_w + (c < w_rem ? 1 : 0)
          rects << Rect.new(x, y, w, row_h)
          x += w
          idx += 1
        end
        y += row_h
      end
      rects
    end

    # All panes occupy the full area; the focused pane is the one drawn last
    # (the Renderer is responsible for the z-order).
    def monocle(count, area, _focused_index = 0)
      Array.new(count) { Rect.new(area.x, area.y, area.w, area.h) }
    end

    # Return the index of the closest pane in `direction` (:left/:right/:up/:down)
    # from the focused pane. Pure function over the rect list — does not know
    # about the layout that produced the rects.
    #
    # Selection rule: among panes strictly on the requested side, prefer the
    # one with the largest perpendicular overlap with the focused pane;
    # tie-break by smallest axis-distance, then by smallest center offset.
    # Returns nil when nothing qualifies (e.g. focused is the rightmost pane
    # and direction is :right, or monocle where every rect is identical).
    def neighbor(rects, focused_index, direction)
      return nil if rects.nil? || rects.empty?
      return nil unless focused_index.is_a?(Integer)
      return nil unless focused_index.between?(0, rects.length - 1)
      focused = rects[focused_index]
      return nil unless focused

      best = nil
      rects.each_with_index do |rect, idx|
        next if idx == focused_index || rect.nil?

        case direction
        when :right
          next unless rect.x >= focused.x + focused.w
          axis_dist = rect.x - (focused.x + focused.w)
          overlap   = overlap_extent(focused.y, focused.h, rect.y, rect.h)
          center    = ((rect.y + rect.h / 2.0) - (focused.y + focused.h / 2.0)).abs
        when :left
          next unless rect.x + rect.w <= focused.x
          axis_dist = focused.x - (rect.x + rect.w)
          overlap   = overlap_extent(focused.y, focused.h, rect.y, rect.h)
          center    = ((rect.y + rect.h / 2.0) - (focused.y + focused.h / 2.0)).abs
        when :down
          next unless rect.y >= focused.y + focused.h
          axis_dist = rect.y - (focused.y + focused.h)
          overlap   = overlap_extent(focused.x, focused.w, rect.x, rect.w)
          center    = ((rect.x + rect.w / 2.0) - (focused.x + focused.w / 2.0)).abs
        when :up
          next unless rect.y + rect.h <= focused.y
          axis_dist = focused.y - (rect.y + rect.h)
          overlap   = overlap_extent(focused.x, focused.w, rect.x, rect.w)
          center    = ((rect.x + rect.w / 2.0) - (focused.x + focused.w / 2.0)).abs
        else
          return nil
        end

        score = [-overlap, axis_dist, center]
        if best.nil? || (score <=> best[0]) < 0
          best = [score, idx]
        end
      end
      best && best[1]
    end

    def overlap_extent(a_start, a_size, b_start, b_size)
      finish = [a_start + a_size, b_start + b_size].min
      start  = [a_start, b_start].max
      [finish - start, 0].max
    end
  end
end
