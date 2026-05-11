module Muxr
  # Translates raw keystrokes into either commands (when the Ctrl-a prefix is
  # active) or passthrough bytes to the focused pane. The handler is a small
  # state machine: :idle → :prefix → :idle, with a separate :command branch
  # for the ":"-driven mini-command line.
  class InputHandler
    PREFIX = "\x01".freeze # Ctrl-a

    PREFIX_BINDINGS = {
      "c"    => :new_pane,
      "n"    => :focus_next,
      "p"    => :focus_prev,
      "a"    => :focus_last,
      "k"    => :close_focused,
      "\t"   => :cycle_layout,
      "\r"   => :promote_master,
      "\n"   => :promote_master,
      "~"    => :toggle_drawer,
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
      "g"    => :top,
      "G"    => :bottom,
      "\x04" => :half_down, # Ctrl-d
      "\x15" => :half_up,   # Ctrl-u
      "d"    => :half_down,
      "u"    => :half_up,
      "\x06" => :full_down, # Ctrl-f
      "\x02" => :full_up,   # Ctrl-b
      "f"    => :full_down,
      "b"    => :full_up,
      " "    => :full_down
    }.freeze

    SELECTION_YANK = ["\r", "\n", "y"].freeze
    SELECTION_CANCEL = ["q", "\e", "\x03"].freeze # q, Esc, Ctrl-c

    DIGIT_RE = /\A[1-9]\z/.freeze

    attr_reader :state, :command_buffer

    def initialize(app)
      @app = app
      @state = :idle
      @command_buffer = +""
    end

    def feed(data)
      data.each_char do |ch|
        case @state
        when :help
          @app.dismiss_help
          @state = :idle
        when :confirm_quit
          handle_confirm_quit(ch)
        when :idle
          if ch == PREFIX
            @state = :prefix
          else
            @app.send_to_focused(ch)
          end
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

    def enter_scrollback_mode
      @state = :scrollback
    end

    def enter_selection_mode
      @state = :selection
    end

    def enter_idle_mode
      @state = :idle
    end

    def cancel
      @state = :idle
      @command_buffer = +""
    end

    private

    def handle_prefix(ch)
      action = PREFIX_BINDINGS[ch]
      case
      when ch == ":"
        @state = :command
        @command_buffer = +""
      when ch == PREFIX
        @app.send_to_focused(PREFIX)
        @state = :idle
      when DIGIT_RE.match?(ch)
        @app.focus_pane_number(ch.to_i)
        @state = :idle
      when action
        @app.public_send(action)
        @state = :idle if @state == :prefix
      else
        # Unknown prefix-key: return to idle silently.
        @state = :idle
      end
    end

    def handle_confirm_quit(ch)
      @state = :idle
      if ch == "y" || ch == "Y"
        @app.confirm_quit
      else
        @app.cancel_quit
      end
    end

    def handle_scrollback_input(ch)
      if SCROLLBACK_EXITS.include?(ch)
        @state = :idle
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
      when "v"
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
        @state = :idle
        @app.run_command(cmd)
      when "\e"
        @command_buffer = +""
        @state = :idle
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
