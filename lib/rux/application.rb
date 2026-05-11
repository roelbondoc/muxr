require "io/console"

module Rux
  # The Application is the top-level coordinator. It owns the Session, the
  # Renderer, the InputHandler, and the IO.select-based event loop. It also
  # exposes a public action API (new_pane, focus_next, toggle_drawer, ...)
  # which the InputHandler and CommandDispatcher call into.
  class Application
    SELECT_TIMEOUT = 0.05

    attr_reader :session, :renderer, :input

    def initialize(argv = [])
      @argv = argv
      @session_name = parse_session_name(argv)
      @running = false
      @needs_render = true
      @resize_pending = false
      @message = nil
      @message_expires = nil
      @help_visible = false
      @next_pane_id = 0
    end

    def run
      setup
      begin
        loop_forever
      ensure
        teardown
      end
    end

    # ---------- public action API (called from InputHandler / CommandDispatcher) ----------

    def send_to_focused(data)
      target = focused_target
      target&.write(data)
    end

    def new_pane
      cwd = focused_pane&.cwd
      @session.window.add_pane(make_pane(cwd: cwd))
      @session.focus_drawer = false
      @session.window.focused_index = @session.window.panes.length - 1
      invalidate
    end

    def focus_next
      return if @session.window.panes.empty?
      if @session.focus_drawer && @session.drawer&.visible?
        @session.focus_drawer = false
      else
        @session.window.focus_next
      end
      invalidate
    end

    def focus_prev
      return if @session.window.panes.empty?
      if @session.focus_drawer && @session.drawer&.visible?
        @session.focus_drawer = false
      else
        @session.window.focus_prev
      end
      invalidate
    end

    def close_focused
      if @session.focus_drawer && @session.drawer&.visible?
        hide_drawer
        return
      end
      pane = focused_pane
      return unless pane
      @session.window.remove_pane(pane)
      invalidate
    end

    def cycle_layout
      @session.window.cycle_layout
      flash("layout: #{@session.window.layout}")
      invalidate
    end

    def promote_master
      @session.window.promote_to_master
      invalidate
    end

    def toggle_drawer
      ensure_drawer
      @session.drawer.toggle!
      @session.focus_drawer = @session.drawer.visible?
      # On hide, refocus a regular pane.
      @session.focus_drawer = false unless @session.drawer.visible?
      renderer.reset_frame!
      invalidate
    end

    def show_drawer
      ensure_drawer
      @session.drawer.show!
      @session.focus_drawer = true
      renderer.reset_frame!
      invalidate
    end

    def hide_drawer
      return unless @session.drawer&.visible?
      @session.drawer.hide!
      @session.focus_drawer = false
      renderer.reset_frame!
      invalidate
    end

    def reset_drawer
      if @session.drawer
        @session.drawer.close
        @session.drawer = nil
      end
      @session.focus_drawer = false
      renderer.reset_frame!
      flash("drawer reset")
      invalidate
    end

    def detach
      flash("detached")
      @running = false
    end

    def quit
      flash("bye")
      @running = false
    end

    def quit_immediate
      @running = false
    end

    def run_command(cmd_line)
      CommandDispatcher.new(self).dispatch(cmd_line)
      invalidate
    end

    def show_help
      @help_visible = true
      @input.enter_help_mode
      invalidate
    end

    def dismiss_help
      @help_visible = false
      invalidate
    end

    def flash(msg)
      @message = msg
      @message_expires = Time.now + 2.5
      invalidate
    end

    def invalidate
      @needs_render = true
    end

    def save_session
      path = @session.save
      flash("saved: #{path}")
    end

    def restore_session
      data = Session.load(@session_name)
      if data
        flash("session file: #{Session.save_path_for(@session_name)}")
      else
        flash("no saved session")
      end
    end

    # ---------- internals ----------

    private

    def parse_session_name(argv)
      idx = argv.index("-s") || argv.index("--session")
      if idx && argv[idx + 1]
        argv[idx + 1]
      else
        argv.find { |a| !a.start_with?("-") } || "default"
      end
    end

    def focused_target
      if @session.focus_drawer && @session.drawer&.visible? && @session.drawer.pane
        @session.drawer.pane
      else
        focused_pane
      end
    end

    def focused_pane
      @session.window.focused_pane
    end

    def setup
      rows, cols = IO.console.winsize
      @session = Session.new(name: @session_name, width: cols, height: rows)
      @renderer = Renderer.new
      @input = InputHandler.new(self)

      first_pane = make_pane
      @session.window.add_pane(first_pane)

      restore_panes_if_saved

      STDIN.raw!
      STDIN.echo = false

      Signal.trap("WINCH") { @resize_pending = true }
      Signal.trap("INT")   { @resize_pending = false }

      @renderer.enter_alt_screen
      @running = true
    end

    def teardown
      @renderer.exit_alt_screen if @renderer
      begin
        STDIN.cooked!
        STDIN.echo = true
      rescue StandardError
        # The terminal may already have been reset by a signal handler.
      end

      @session.window.panes.each(&:close)
      @session.drawer&.close
    end

    def loop_forever
      while @running
        if @resize_pending
          @resize_pending = false
          handle_resize
        end

        ready_ios = [STDIN]
        @session.window.panes.each { |p| ready_ios << p.io if p.alive? }
        if @session.drawer&.pane && @session.drawer.pane.alive?
          ready_ios << @session.drawer.pane.io
        end

        timeout = @message ? 0.25 : SELECT_TIMEOUT
        ready, = IO.select(ready_ios, nil, nil, timeout)

        if ready
          ready.each do |io|
            if io == STDIN
              consume_stdin
            else
              consume_pane_io(io)
            end
          end
        end

        prune_dead_panes
        expire_message

        if @session.window.panes.empty?
          @running = false
          break
        end

        if @needs_render
          render
          @needs_render = false
        end
      end
    end

    def consume_stdin
      data = STDIN.read_nonblock(4096)
      @input.feed(data)
      invalidate
    rescue IO::WaitReadable
      # spurious wakeup
    rescue EOFError
      @running = false
    end

    def consume_pane_io(io)
      pane = pane_for_io(io)
      return unless pane
      data = pane.read_from_pty
      invalidate if data
    end

    def pane_for_io(io)
      pane = @session.window.panes.find { |p| p.io == io }
      return pane if pane
      return @session.drawer.pane if @session.drawer&.pane && @session.drawer.pane.io == io
      nil
    end

    def prune_dead_panes
      dead = @session.window.panes.reject(&:alive?)
      return if dead.empty?
      dead.each { |p| @session.window.remove_pane(p) }
      invalidate
    end

    def expire_message
      return unless @message_expires
      if Time.now >= @message_expires
        @message = nil
        @message_expires = nil
        invalidate
      end
    end

    def handle_resize
      rows, cols = IO.console.winsize
      @session.width = cols
      @session.height = rows
      @renderer.reset_frame!
      invalidate
    end

    def render
      @renderer.render(
        @session,
        input_state: @input.state,
        command_buffer: @input.command_buffer,
        message: @message,
        help: @help_visible
      )
    end

    def make_pane(cwd: nil)
      @next_pane_id += 1
      Pane.new(id: @next_pane_id, rows: 24, cols: 80, cwd: cwd)
    end

    def ensure_drawer
      return if @session.drawer
      cwd = focused_pane&.cwd
      pane = Pane.new(id: :drawer, rows: 10, cols: 80, cwd: cwd)
      @session.drawer = Drawer.new(pane: pane, origin_cwd: cwd)
    end

    def restore_panes_if_saved
      data = Session.load(@session_name)
      return unless data

      if data["layout"] && Window::LAYOUTS.include?(data["layout"].to_sym)
        @session.window.set_layout(data["layout"].to_sym)
      end

      panes_data = data["panes"] || []
      # The first pane already exists; reuse it but reseat cwd if possible
      # cannot rewind cwd of the running shell, so just spawn extras.
      panes_data[1..]&.each do |entry|
        cwd = entry["cwd"]
        @session.window.add_pane(make_pane(cwd: cwd))
      end

      if data["drawer"]
        cwd = data["drawer"]["cwd"]
        pane = Pane.new(id: :drawer, rows: 10, cols: 80, cwd: cwd)
        drawer = Drawer.new(pane: pane, origin_cwd: cwd)
        drawer.visible = !!data["drawer"]["visible"]
        @session.drawer = drawer
        @session.focus_drawer = drawer.visible?
      end

      @session.window.focused_index = (data["focused_index"] || 0).clamp(0, @session.window.panes.length - 1)
      @session.window.master_index  = (data["master_index"]  || 0).clamp(0, @session.window.panes.length - 1)
      flash("session restored")
    end
  end
end
