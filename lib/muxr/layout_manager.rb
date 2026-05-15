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

    LAYOUTS = %i[tall grid monocle].freeze

    module_function

    def compute(layout, count, area, focused_index: 0, master_index: 0)
      return [] if count <= 0
      master_index = master_index.clamp(0, count - 1)
      focused_index = focused_index.clamp(0, count - 1)
      case layout
      when :tall    then tall(count, area, master_index)
      when :grid    then grid(count, area)
      when :monocle then monocle(count, area, focused_index)
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
