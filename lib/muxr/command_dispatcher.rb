module Muxr
  # Parses ":"-prefixed commands typed at the command prompt and routes them
  # to the Application. Unknown commands result in a flashed status message
  # rather than a hard error so the user never gets dropped out of the
  # multiplexer for a typo.
  class CommandDispatcher
    def initialize(app)
      @app = app
    end

    def dispatch(line)
      parts = line.to_s.strip.split(/\s+/)
      return if parts.empty?

      cmd, *args = parts
      case cmd
      when "layout"  then handle_layout(args)
      when "drawer"  then handle_drawer(args)
      when "save"    then @app.save_session
      when "restore" then @app.restore_session
      when "sessions", "ls" then @app.list_sessions
      when "quit", "q", "exit"
        @app.quit
      when "new", "c"
        @app.new_pane
      when "close", "kill", "k"
        @app.close_focused
      when "next"    then @app.focus_next
      when "prev"    then @app.focus_prev
      when "master"  then @app.promote_master
      when "help"    then @app.show_help
      when "detach"  then @app.detach
      else
        @app.flash("unknown command: #{cmd}")
      end
    end

    private

    def handle_layout(args)
      name = args[0]
      if name.nil?
        @app.cycle_layout
        return
      end
      sym = name.to_sym
      if Window::LAYOUTS.include?(sym)
        @app.session.window.set_layout(sym)
        @app.invalidate
      else
        @app.flash("unknown layout: #{name}")
      end
    end

    def handle_drawer(args)
      case args[0]
      when nil, "toggle" then @app.toggle_drawer
      when "show"        then @app.show_drawer
      when "hide"        then @app.hide_drawer
      when "reset"       then @app.reset_drawer
      else                    @app.flash("drawer: #{args[0]}?")
      end
    end
  end
end
