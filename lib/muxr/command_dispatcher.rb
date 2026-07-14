module Muxr
  # Parses ":"-prefixed commands typed at the command prompt and routes them
  # to the Application. Unknown commands result in a flashed status message
  # rather than a hard error so the user never gets dropped out of the
  # multiplexer for a typo.
  class CommandDispatcher
    # Command names offered by Tab-completion. Deliberately the canonical
    # names only — the terse aliases (ls/q/exit/c/k/kill) still *work* when
    # typed, but completing to a shorter alias would be surprising, and
    # offering both halves would clutter the ambiguity list.
    COMPLETIONS = %w[
      layout drawer claude private save restore sessions
      new close next prev master detach help quit
    ].freeze

    # Argument candidates for the commands that take a fixed vocabulary.
    DRAWER_ARGS = %w[toggle show hide reset].freeze

    # Tab-completion entry point. Given the current command buffer, returns
    # [completed_line, candidates]: `completed_line` extends the active token
    # to the longest common prefix of its matches (plus a trailing space on a
    # unique match), and `candidates` is the full match list so the caller can
    # show it when the completion is ambiguous. A no-match returns the line
    # unchanged with an empty candidate list.
    def self.complete(line)
      line = line.to_s
      words = line.split(/\s+/)
      words.shift if words.first == "" # leading whitespace → drop the empty
      at_new_token = !!(line =~ /\s\z/) || line.empty?

      index = at_new_token ? words.length : words.length - 1
      prefix = at_new_token ? "" : (words.last || "")

      matches = candidates_for(index, words).select { |c| c.start_with?(prefix) }.sort
      return [line, []] if matches.empty?

      head = at_new_token ? words : words[0...index]
      completed = common_prefix(matches)
      new_line = (head + [completed]).join(" ")
      new_line += " " if matches.length == 1
      [new_line, matches]
    end

    # Candidate list for the token at `index` given the words typed so far.
    # index 0 is the command name; index 1 is an argument keyed off the command.
    def self.candidates_for(index, words)
      return COMPLETIONS if index.zero?

      case words[0]
      when "layout" then Window::LAYOUTS.map(&:to_s)
      when "drawer" then DRAWER_ARGS
      else []
      end
    end

    def self.common_prefix(strings)
      ref = strings.min_by(&:length) || ""
      ref.length.downto(0) do |len|
        pre = ref[0, len]
        return pre if strings.all? { |s| s.start_with?(pre) }
      end
      ""
    end

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
      when "claude"  then @app.toggle_claude_drawer
      when "private" then @app.toggle_private_focused
      when "save"    then @app.save_session
      when "restore" then @app.restore_session
      when "sessions", "ls" then @app.list_sessions
      when "quit", "q", "exit"
        @app.quit
      when "new", "c"
        @app.new_pane
      when "close", "kill", "k"
        @app.request_close
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
      matches = Window::LAYOUTS.select { |l| l.to_s.start_with?(name) }
      if matches.length == 1
        @app.session.window.set_layout(matches.first)
        @app.invalidate
      elsif matches.length > 1
        @app.flash("ambiguous layout: #{name} (#{matches.join(", ")})")
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
