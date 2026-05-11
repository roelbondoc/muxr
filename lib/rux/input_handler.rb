module Rux
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
      "q"    => :quit_immediate
    }.freeze

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
        end
      end
    end

    def enter_help_mode
      @state = :help
    end

    def enter_confirm_quit
      @state = :confirm_quit
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
