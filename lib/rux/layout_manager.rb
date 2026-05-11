module Rux
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
  end
end
