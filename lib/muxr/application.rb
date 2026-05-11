require "socket"
require "fileutils"

module Muxr
  # The Application is the muxr server. It owns the Session, panes, Renderer,
  # and InputHandler, and listens on a Unix socket at
  # ~/.muxr/sockets/<name>.sock for a Client to attach. Shells and other PTY
  # processes survive client detach/reattach — only the listening socket and
  # the one currently-attached client come and go.
  #
  # The Renderer's output sink is a small adapter that frames its bytes into
  # OUTPUT messages on the attached client; when no client is attached the
  # bytes are silently dropped (we also skip the render entirely in that
  # case). PTY data still gets drained even with no client, so the in-memory
  # Terminal grids stay up to date and are repainted in full on the next
  # attach via Renderer#reset_frame!.
  class Application
    SELECT_TIMEOUT = 0.05
    SOCKETS_DIR    = File.join(Dir.home, ".muxr", "sockets").freeze
    DEFAULT_WIDTH  = 80
    DEFAULT_HEIGHT = 24

    attr_reader :session, :renderer, :input, :session_name

    def self.socket_path_for(name)
      File.join(SOCKETS_DIR, "#{name}.sock")
    end

    def initialize(argv = [])
      @argv = argv
      @session_name = parse_session_name(argv)
      @running = false
      @needs_render = true
      @message = nil
      @message_expires = nil
      @help_visible = false
      @next_pane_id = 0
      @current_client = nil
      @listening_socket = nil
      @socket_path = self.class.socket_path_for(@session_name)
      @paste_buffer = +""
    end

    attr_reader :paste_buffer

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

    def focus_last
      return if @session.window.panes.empty?
      if @session.focus_drawer && @session.drawer&.visible?
        @session.focus_drawer = false
      else
        @session.window.focus_last
      end
      invalidate
    end

    def focus_pane_number(n)
      return if @session.window.panes.empty?
      idx = n - 1
      return unless idx >= 0 && idx < @session.window.panes.length
      @session.focus_drawer = false
      @session.window.focus_index(idx)
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
      disconnect_client(reason: "detached")
      # Server keeps running. Next `bin/muxr <name>` invocation will re-attach.
    end

    # Both Ctrl-a q and :quit funnel through here. We don't kill the server
    # immediately — InputHandler enters a confirmation state and the user
    # has to press 'y' to actually shut down (see :request_quit_confirmed).
    def quit
      request_quit
    end

    def quit_immediate
      request_quit
    end

    def request_quit
      return if @input.state == :confirm_quit
      @input.enter_confirm_quit
      flash("kill session? (y/n)")
      invalidate
    end

    def confirm_quit
      shutdown_server
    end

    def cancel_quit
      @message = nil
      @message_expires = nil
      flash("cancelled")
      invalidate
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

    def enter_scrollback
      target = focused_target
      return unless target
      @input.enter_scrollback_mode
      @renderer.reset_frame!
      invalidate
    end

    def exit_scrollback
      target = focused_target
      target&.terminal&.clear_selection
      target&.terminal&.scroll_to_bottom
      @renderer.reset_frame!
      invalidate
    end

    def scroll_focused(action)
      target = focused_target
      return unless target
      term = target.terminal
      rows = term.rows
      case action
      when :line_back     then term.scroll_back(1)
      when :line_forward  then term.scroll_forward(1)
      when :half_back     then term.scroll_back([rows / 2, 1].max)
      when :half_forward  then term.scroll_forward([rows / 2, 1].max)
      when :full_back     then term.scroll_back([rows - 1, 1].max)
      when :full_forward  then term.scroll_forward([rows - 1, 1].max)
      when :top           then term.scroll_to_top
      when :bottom        then term.scroll_to_bottom
      end
      invalidate
    end

    def enter_selection
      target = focused_target
      return unless target
      # Vim-style: drop the user at a movable cursor with NO selection yet.
      # They navigate with h/j/k/l, then press v (linear) or C-v (block) to
      # anchor.
      target.terminal.place_selection_cursor(0, 0)
      @input.enter_selection_mode
      @renderer.reset_frame!
      invalidate
    end

    def toggle_selection(mode)
      target = focused_target
      return unless target
      term = target.terminal
      if term.selection_active? && term.selection_mode == mode
        # Same mode pressed again — drop the anchor, return to navigation.
        term.clear_anchor!
      else
        # No anchor, or switching between linear/block — anchor at the
        # current cursor in the requested mode (vim keeps the visual range
        # when switching shapes, and we mirror that by not moving the
        # cursor).
        term.anchor_selection!(mode: mode)
      end
      invalidate
    end

    def exit_selection(yank:)
      target = focused_target
      term = target&.terminal
      if yank
        # No anchor → no-op. User is still positioning; they can press v
        # first, then yank. Esc/q is the way to exit from navigation.
        return unless term&.selection_active?
        text = term.extract_selection_text
        unless text.empty?
          @paste_buffer = text
          spawn_pbcopy(text)
          flash("yanked #{text.bytesize} bytes")
        end
      end
      term&.clear_selection
      @input.enter_scrollback_mode
      @renderer.reset_frame!
      invalidate
    end

    def move_selection(action)
      target = focused_target
      return unless target
      term = target.terminal
      rows = term.rows
      cols = term.cols
      case action
      when :left       then term.move_selection_cursor_by(0, -1)
      when :right      then term.move_selection_cursor_by(0, 1)
      when :up         then term.move_selection_cursor_by(-1, 0)
      when :down       then term.move_selection_cursor_by(1, 0)
      when :half_up    then term.move_selection_cursor_by(-[rows / 2, 1].max, 0)
      when :half_down  then term.move_selection_cursor_by([rows / 2, 1].max, 0)
      when :full_up    then term.move_selection_cursor_by(-[rows - 1, 1].max, 0)
      when :full_down  then term.move_selection_cursor_by([rows - 1, 1].max, 0)
      when :line_start then term.selection_cursor_to_line_start
      when :line_end   then term.selection_cursor_to_line_end
      when :top        then term.selection_cursor_to_top
      when :bottom     then term.selection_cursor_to_bottom
      end
      invalidate
    end

    def paste_from_buffer
      return if @paste_buffer.nil? || @paste_buffer.empty?
      target = focused_target
      target&.write(@paste_buffer)
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

    def list_sessions
      names = Session.list
      if names.empty?
        flash("no saved sessions")
      else
        marker = ->(n) { n == @session_name ? "*#{n}" : n }
        flash("sessions: #{names.map(&marker).join(", ")}")
      end
    end

    # Called by the FramedOutput adapter; ships one OUTPUT frame to the
    # currently attached client. No-op when nobody is attached.
    def deliver_output(bytes)
      sock = @current_client
      return unless sock
      Protocol.write(sock, Protocol::OUTPUT, bytes)
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      drop_client_silently
    end

    # ---------- internals ----------

    private

    def existing_server_alive?
      s = UNIXSocket.new(@socket_path)
      s.close
      true
    rescue Errno::ECONNREFUSED, Errno::ENOENT
      false
    end

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
      FileUtils.mkdir_p(SOCKETS_DIR)
      if File.exist?(@socket_path) && existing_server_alive?
        raise "muxr server already running for session '#{@session_name}'"
      end
      File.unlink(@socket_path) if File.exist?(@socket_path)
      @listening_socket = UNIXServer.new(@socket_path)
      File.chmod(0o600, @socket_path) rescue nil

      @session  = Session.new(name: @session_name, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT)
      @renderer = Renderer.new(out: FramedOutput.new(self))
      @input    = InputHandler.new(self)

      first_pane = make_pane
      @session.window.add_pane(first_pane)

      restore_panes_if_saved

      @running = true
    end

    def teardown
      disconnect_client
      if @listening_socket
        @listening_socket.close rescue nil
      end
      if @socket_path && File.exist?(@socket_path)
        File.unlink(@socket_path) rescue nil
      end
      @session&.window&.panes&.each(&:close)
      @session&.drawer&.close
    end

    def loop_forever
      while @running
        ready_ios = [@listening_socket]
        ready_ios << @current_client if @current_client
        @session.window.panes.each { |p| ready_ios << p.io if p.alive? }
        if @session.drawer&.pane && @session.drawer.pane.alive?
          ready_ios << @session.drawer.pane.io
        end

        timeout = @message ? 0.25 : SELECT_TIMEOUT
        ready, = IO.select(ready_ios, nil, nil, timeout)

        if ready
          ready.each do |io|
            if io == @listening_socket
              accept_client
            elsif io == @current_client
              consume_client_frame
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

        if @current_client && @needs_render
          render
          @needs_render = false
        end
      end
    end

    def accept_client
      sock = @listening_socket.accept
      if @current_client
        # Single attached client at a time. Reject newcomers politely.
        safe_protocol_write(sock, Protocol::BYE, "busy")
        sock.close rescue nil
        return
      end

      type, payload = Protocol.read(sock)
      unless type == Protocol::HELLO
        safe_protocol_write(sock, Protocol::BYE, "expected HELLO")
        sock.close rescue nil
        return
      end

      size = Protocol.decode_size(payload)
      apply_size(*size) if size

      @current_client = sock
      @renderer.reset_frame!
      invalidate
    end

    def consume_client_frame
      type, payload = Protocol.read(@current_client)
      if type.nil?
        drop_client_silently
        return
      end

      case type
      when Protocol::INPUT
        @input.feed(payload)
        invalidate
      when Protocol::RESIZE
        size = Protocol.decode_size(payload)
        if size
          apply_size(*size)
          @renderer.reset_frame!
          invalidate
        end
      when Protocol::BYE
        drop_client_silently
      else
        # Unknown frame type — ignore quietly.
      end
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

    def apply_size(rows, cols)
      @session.width  = cols
      @session.height = rows
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

    def disconnect_client(reason: nil)
      return unless @current_client
      safe_protocol_write(@current_client, Protocol::BYE, reason || "")
      @current_client.close rescue nil
      @current_client = nil
    end

    def drop_client_silently
      return unless @current_client
      @current_client.close rescue nil
      @current_client = nil
    end

    def safe_protocol_write(io, type, payload = "")
      Protocol.write(io, type, payload)
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      # peer gone; nothing to do.
    end

    def shutdown_server
      flash("bye")
      disconnect_client(reason: "shutdown")
      @running = false
    end

    # Fire-and-forget pipe to pbcopy. Runs on its own thread so even a slow
    # macOS pbcopy doesn't stall the event loop. Silent when pbcopy is absent
    # (Linux/headless) — selection still goes to the internal buffer.
    def spawn_pbcopy(text)
      Thread.new do
        IO.popen("pbcopy", "w") { |io| io.write(text) }
      rescue Errno::ENOENT, Errno::EPIPE, IOError, StandardError
        # pbcopy unavailable or pipe broken — selection still lives in
        # @paste_buffer.
      end
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

    # Renderer expects an IO-ish sink with #write and #flush. We frame every
    # write as one OUTPUT message on the attached client; nobody attached =
    # bytes go nowhere (and Application skips render entirely in that case,
    # so this path is rarely exercised).
    class FramedOutput
      def initialize(app)
        @app = app
      end

      def write(bytes)
        @app.deliver_output(bytes)
        bytes.bytesize
      end

      def flush
        # Unix sockets do not need a Ruby-level flush.
      end
    end
  end
end
