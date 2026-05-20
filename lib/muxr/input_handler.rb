module Muxr
  # Translates raw keystrokes into either commands or pane input. Two top-level
  # modes:
  #
  #   :normal       Default. Single-key bindings (hjkl navigation, t/g/m for
  #                 layouts, c/K for create/kill, etc.) act directly without
  #                 any prefix. `i` drops into passthrough.
  #
  #   :passthrough  Historical mode: every key is forwarded to the focused
  #                 pane unless prefixed by Ctrl-a. `Ctrl-a Esc` returns to
  #                 normal mode.
  #
  # Plus the sub-states pre-existing from before modes existed:
  #   :prefix, :command, :confirm_quit, :confirm_close, :help, :scrollback,
  #   :selection.
  #
  # One-shot sub-states (prefix, command, confirm_quit, help) return to
  # @base_mode (whichever of :normal/:passthrough is active) when they
  # finish. :scrollback and :selection also return to @base_mode so that
  # exiting back from a scroll/yank lands you back in passthrough if that's
  # where you came from.
  class InputHandler
    PREFIX = "\x01".freeze # Ctrl-a

    # Single-key bindings in normal mode. Same actions as their Ctrl-a-
    # prefixed counterparts in passthrough, just without the prefix.
    # Value forms:
    #   :symbol            → @app.public_send(:symbol)
    #   [:symbol, *args]   → @app.public_send(:symbol, *args)
    NORMAL_BINDINGS = {
      "c"  => :new_pane,
      "x"  => :request_close,
      "t"  => [:set_layout, :tall],
      "g"  => [:set_layout, :grid],
      "m"  => [:set_layout, :monocle],
      "\t" => :cycle_layout,
      "\r" => :promote_master,
      "\n" => :promote_master,
      "h"  => [:focus_direction, :left],
      "j"  => [:focus_direction, :down],
      "k"  => [:focus_direction, :up],
      "l"  => [:focus_direction, :right],
      "H"  => [:move_direction, :left],
      "J"  => [:move_direction, :down],
      "K"  => [:move_direction, :up],
      "L"  => [:move_direction, :right],
      "a"  => :focus_last,
      "~"  => :toggle_drawer,
      "C"  => :toggle_claude_drawer,
      "P"  => :toggle_private_focused,
      "d"  => :detach,
      "?"  => :show_help,
      "q"  => :quit_immediate,
      "s"  => :enter_scrollback,
      "]"  => :paste_from_buffer
    }.freeze

    PREFIX_BINDINGS = {
      "c"    => :new_pane,
      "n"    => :focus_next,
      "p"    => :focus_prev,
      "a"    => :focus_last,
      "x"    => :request_close,
      "\t"   => :cycle_layout,
      "\r"   => :promote_master,
      "\n"   => :promote_master,
      "~"    => :toggle_drawer,
      "C"    => :toggle_claude_drawer,
      "P"    => :toggle_private_focused,
      "d"    => :detach,
      "?"    => :show_help,
      "q"    => :quit_immediate,
      "["    => :enter_scrollback,
      "]"    => :paste_from_buffer
    }.freeze

    SCROLLBACK_BINDINGS = {
      "j"    => :line_forward,
      "k"    => :line_back,
      "\x04" => :half_forward, # Ctrl-d
      "\x15" => :half_back,    # Ctrl-u
      "d"    => :half_forward,
      "u"    => :half_back,
      "\x06" => :full_forward, # Ctrl-f
      "\x02" => :full_back,    # Ctrl-b
      "f"    => :full_forward,
      "b"    => :full_back,
      " "    => :full_forward,
      "g"    => :top,
      "G"    => :bottom
    }.freeze

    SCROLLBACK_EXITS = ["q", "\e", "\x03"].freeze # q, Esc, Ctrl-c

    SELECTION_BINDINGS = {
      "h"    => :left,
      "l"    => :right,
      "j"    => :down,
      "k"    => :up,
      "0"    => :line_start,
      "$"    => :line_end,
      "^"    => :line_first_nonblank,
      "g"    => :top,
      "G"    => :bottom,
      "H"    => :screen_top,
      "M"    => :screen_middle,
      "L"    => :screen_bottom,
      "w"    => :word_forward,
      "W"    => :word_forward_big,
      "e"    => :word_end,
      "E"    => :word_end_big,
      # `b` is vim word-back here; the tmux-style page-back alias lives on Ctrl-b.
      "b"    => :word_backward,
      "B"    => :word_backward_big,
      "\x04" => :half_down, # Ctrl-d
      "\x15" => :half_up,   # Ctrl-u
      "d"    => :half_down,
      "u"    => :half_up,
      "\x06" => :full_down, # Ctrl-f
      "\x02" => :full_up,   # Ctrl-b
      "f"    => :full_down
      # NOTE: space is intentionally absent here — it's a top-level toggle
      # for linear selection (see handle_selection_input), mirroring vim's
      # `v` so the right thumb has a one-key way to anchor/release.
    }.freeze

    SELECTION_YANK = ["\r", "\n", "y"].freeze
    SELECTION_CANCEL = ["q", "\e", "\x03"].freeze # q, Esc, Ctrl-c

    DIGIT_RE = /\A[1-9]\z/.freeze

    attr_reader :state, :command_buffer, :base_mode

    def initialize(app)
      @app = app
      @state = :normal
      @base_mode = :normal
      @command_buffer = +""
    end

    def feed(data)
      remaining = data
      until remaining.empty?
        if @state == :passthrough
          # Fast path: batch everything up to the next Ctrl-a as one chunk so
          # a large paste doesn't turn into one PTY write per byte. PREFIX is
          # single-byte ASCII (\x01) and never appears mid-UTF-8.
          idx = remaining.index(PREFIX)
          if idx.nil?
            @app.send_to_focused(remaining)
            return
          end
          @app.send_to_focused(remaining[0...idx]) if idx > 0
          @state = :prefix
          remaining = remaining[(idx + 1)..] || ""
          next
        end

        ch = remaining[0]
        remaining = remaining[1..] || ""
        case @state
        when :normal
          handle_normal(ch)
        when :help
          @app.dismiss_help
          @state = @base_mode
        when :confirm_quit
          handle_confirm_quit(ch)
        when :confirm_close
          handle_confirm_close(ch)
        when :prefix
          handle_prefix(ch)
        when :command
          handle_command_input(ch)
        when :scrollback
          handle_scrollback_input(ch)
        when :selection
          handle_selection_input(ch)
        end
      end
    end

    def enter_help_mode
      @state = :help
    end

    def enter_confirm_quit
      @state = :confirm_quit
    end

    def enter_confirm_close
      @state = :confirm_close
    end

    def enter_scrollback_mode
      @state = :scrollback
    end

    def enter_selection_mode
      @state = :selection
    end

    # Drop into passthrough — every key reaches the focused pane until the
    # user issues Ctrl-a Esc.
    def enter_passthrough_mode
      @state = :passthrough
      @base_mode = :passthrough
    end

    # Return to normal mode. Used by the `Ctrl-a Esc` binding from
    # passthrough — explicitly resets @base_mode so the user genuinely
    # leaves passthrough.
    def enter_normal_mode
      @state = :normal
      @base_mode = :normal
    end

    # Exit a sub-state (scrollback, selection-yank) and resume the mode the
    # user was in before they entered scrollback. Preserves @base_mode so
    # a passthrough → scrollback → exit round-trip lands back in passthrough.
    def enter_idle_mode
      @state = @base_mode
    end

    def cancel
      @state = @base_mode
      @command_buffer = +""
    end

    private

    def handle_normal(ch)
      if ch == "i"
        # Internal state flip happens here so a bare FakeApp in tests still
        # transitions; the Application callback redundantly flips state
        # (idempotent) and adds the user-visible flash.
        enter_passthrough_mode
        @app.enter_passthrough_mode
        return
      end
      if ch == ":"
        @state = :command
        @command_buffer = +""
        return
      end
      if DIGIT_RE.match?(ch)
        @app.focus_pane_number(ch.to_i)
        return
      end

      action = NORMAL_BINDINGS[ch]
      case action
      when Symbol
        @app.public_send(action)
      when Array
        @app.public_send(*action)
      end
      # Unknown key: ignore. Avoids accidental side-effects when the user
      # mistypes — same rationale as scrollback mode.
    end

    def handle_prefix(ch)
      action = PREFIX_BINDINGS[ch]
      case
      when ch == "\e"
        # Ctrl-a Esc → return to normal mode. Flip state directly so tests
        # with a bare FakeApp transition; the Application callback is
        # idempotent and adds the flash message.
        enter_normal_mode
        @app.enter_normal_mode
      when ch == ":"
        @state = :command
        @command_buffer = +""
      when ch == PREFIX
        @app.send_to_focused(PREFIX)
        @state = @base_mode
      when DIGIT_RE.match?(ch)
        @app.focus_pane_number(ch.to_i)
        @state = @base_mode
      when action
        @app.public_send(action)
        # The action may have set a new state (confirm_quit, confirm_close,
        # scrollback, help). Only revert to base mode if we're still in :prefix.
        @state = @base_mode if @state == :prefix
      else
        # Unknown prefix key: return to base mode silently.
        @state = @base_mode
      end
    end

    def handle_confirm_quit(ch)
      @state = @base_mode
      if ch == "y" || ch == "Y"
        @app.confirm_quit
      else
        @app.cancel_quit
      end
    end

    def handle_confirm_close(ch)
      @state = @base_mode
      if ch == "y" || ch == "Y"
        @app.confirm_close
      else
        @app.cancel_close
      end
    end

    def handle_scrollback_input(ch)
      if SCROLLBACK_EXITS.include?(ch)
        enter_idle_mode
        @app.exit_scrollback
        return
      end
      if ch == "v"
        @app.enter_selection
        return
      end
      action = SCROLLBACK_BINDINGS[ch]
      @app.scroll_focused(action) if action
      # Unknown keys: ignored. Avoids accidental shell input when the user
      # mistypes inside scrollback mode.
    end

    def handle_selection_input(ch)
      if SELECTION_YANK.include?(ch)
        @app.exit_selection(yank: true)
        return
      end
      if SELECTION_CANCEL.include?(ch)
        @app.exit_selection(yank: false)
        return
      end
      case ch
      when "v", " "
        @app.toggle_selection(:linear)
        return
      when "\x16" # Ctrl-v
        @app.toggle_selection(:block)
        return
      end
      action = SELECTION_BINDINGS[ch]
      @app.move_selection(action) if action
      # Unknown keys ignored — same rationale as scrollback mode.
    end

    def handle_command_input(ch)
      case ch
      when "\r", "\n"
        cmd = @command_buffer.dup
        @command_buffer = +""
        @state = @base_mode
        @app.run_command(cmd)
      when "\e"
        @command_buffer = +""
        @state = @base_mode
        @app.invalidate
      when "\x7f", "\b"
        @command_buffer.chop!
        @app.invalidate
      else
        @command_buffer << ch if ch.ord >= 0x20
        @app.invalidate
      end
    end
  end
end
