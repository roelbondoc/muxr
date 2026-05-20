module Muxr
  # A Window is a single logical "screen" containing an ordered list of panes,
  # a focused-index, a master-index (which pane is the master for tall/grid
  # layouts), and the currently-selected layout.
  class Window
    LAYOUTS = LayoutManager::LAYOUTS

    attr_accessor :name, :layout, :master_index
    attr_reader :panes, :focused_index

    def initialize(name: "main")
      @name = name
      @panes = []
      @focused_index = 0
      @last_focused_pane = nil
      @master_index = 0
      @layout = :tall
    end

    # Setter records the outgoing focused pane (by reference) so focus_last can
    # return to it even after the panes array is reordered (e.g. by
    # promote_to_master).
    def focused_index=(value)
      return if value == @focused_index
      @last_focused_pane = focused_pane
      @focused_index = value
    end

    def add_pane(pane)
      @panes << pane
      pane
    end

    def remove_pane(pane)
      idx = @panes.index(pane)
      return false unless idx
      pane.close
      @panes.delete_at(idx)
      @last_focused_pane = nil if @last_focused_pane == pane
      clamp_indices!
      true
    end

    def focused_pane
      return nil if @panes.empty?
      @panes[@focused_index]
    end

    def focus_next
      return if @panes.empty?
      self.focused_index = (@focused_index + 1) % @panes.length
    end

    def focus_prev
      return if @panes.empty?
      self.focused_index = (@focused_index - 1) % @panes.length
    end

    def focus_last
      return unless @last_focused_pane
      idx = @panes.index(@last_focused_pane)
      return unless idx
      self.focused_index = idx
    end

    def focus_index(idx)
      return if @panes.empty?
      return unless idx.is_a?(Integer) && idx >= 0 && idx < @panes.length
      self.focused_index = idx
    end

    def promote_to_master
      return if @panes.empty?
      return if @master_index == @focused_index
      # Move the focused pane into the master slot and shift the others down,
      # preserving relative order so tall/grid layouts stay stable.
      pane = @panes.delete_at(@focused_index)
      @panes.unshift(pane)
      @master_index = 0
      @focused_index = 0
    end

    def swap_panes(i, j)
      return if i == j
      return unless @panes[i] && @panes[j]
      @panes[i], @panes[j] = @panes[j], @panes[i]
    end

    # Swap the focused pane with the pane at `idx` and keep focus on the
    # moved pane (so HJKL can keep dragging it across the layout). Unlike
    # `focused_index=`, this does not record a last_focused_pane — the user
    # is still on the same pane, just at a new index in the array.
    def move_focused_to(idx)
      return false if @panes.empty?
      return false unless idx.is_a?(Integer) && idx >= 0 && idx < @panes.length
      return false if idx == @focused_index
      @panes[@focused_index], @panes[idx] = @panes[idx], @panes[@focused_index]
      @focused_index = idx
      true
    end

    def cycle_layout
      i = LAYOUTS.index(@layout) || 0
      @layout = LAYOUTS[(i + 1) % LAYOUTS.length]
    end

    def set_layout(layout)
      layout = layout.to_sym
      raise ArgumentError, "Unknown layout: #{layout}" unless LAYOUTS.include?(layout)
      @layout = layout
    end

    def clamp_indices!
      if @panes.empty?
        @focused_index = 0
        @master_index = 0
      else
        @focused_index = @focused_index.clamp(0, @panes.length - 1)
        @master_index  = @master_index.clamp(0, @panes.length - 1)
      end
    end
  end
end
