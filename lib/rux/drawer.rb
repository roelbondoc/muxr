module Rux
  # A Drawer is a single persistent overlay pane, rendered on top of the tiled
  # layout. Toggling visibility never tears down the underlying PTY — the
  # drawer's shell process and scrollback survive across hide/show.
  #
  # The actual Pane is injected (rather than constructed here) so tests can
  # exercise the visibility/state machine without spawning real shells.
  class Drawer
    attr_accessor :pane, :visible
    attr_reader :origin_cwd

    def initialize(pane: nil, origin_cwd: nil)
      @pane = pane
      @visible = false
      @origin_cwd = origin_cwd
    end

    def visible?
      @visible
    end

    def show!
      @visible = true
    end

    def hide!
      @visible = false
    end

    def toggle!
      @visible = !@visible
    end

    def cwd
      pane&.cwd || @origin_cwd
    end

    def close
      @pane&.close
      @pane = nil
      @visible = false
    end
  end
end
