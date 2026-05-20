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
    # ~60 Hz cap on full repaints. Keystrokes in fzf or vim navigation can
    # trigger PTY bursts faster than the terminal can usefully display them;
    # the cap collapses those bursts and stops intermediate frames from
    # showing through.
    MIN_FRAME_INTERVAL = 1.0 / 60
    SOCKETS_DIR    = File.join(Dir.home, ".muxr", "sockets").freeze
    DEFAULT_WIDTH  = 80
    DEFAULT_HEIGHT = 24

    attr_reader :session, :renderer, :input, :session_name, :control_server

    def self.socket_path_for(name)
      File.join(SOCKETS_DIR, "#{name}.sock")
    end

    def self.control_socket_path_for(name)
      File.join(SOCKETS_DIR, "#{name}.ctrl.sock")
    end

    # Names of sessions whose server socket is currently accepting connections.
    # Stale sockets (file exists, no listener) are skipped but left in place;
    # cleanup happens on the next attach attempt.
    def self.list_active
      return [] unless File.directory?(SOCKETS_DIR)
      Dir.children(SOCKETS_DIR).filter_map do |entry|
        next unless entry.end_with?(".sock")
        path = File.join(SOCKETS_DIR, entry)
        next unless alive_socket?(path)
        File.basename(entry, ".sock")
      end.sort
    end

    def self.alive_socket?(path)
      return false unless File.exist?(path)
      UNIXSocket.new(path).close
      true
    rescue SystemCallError
      false
    end

    def initialize(argv = [])
      @argv = argv
      @session_name = parse_session_name(argv)
      @running = false
      @needs_render = true
      @message = nil
      @message_expires = nil
      @help_visible = false
      @current_client = nil
      @client_write_buffer = +"".b
      @listening_socket = nil
      @socket_path = self.class.socket_path_for(@session_name)
      @control_socket_path = self.class.control_socket_path_for(@session_name)
      @control_server = nil
      @paste_buffer = +""
      @last_render_at = nil
      @foreground_poller = nil
    end

    # Interval for the background thread that refreshes each pane's
    # foreground-command label. Picked to feel responsive (a long-running
    # `npm test` shows up within a second of starting) without burning CPU
    # on macOS, where each tick costs a `ps` fork+exec per pane.
    FOREGROUND_POLL_INTERVAL = 0.75

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

    def new_pane(cwd: nil)
      cwd ||= focused_pane&.cwd
      pane = make_pane(cwd: cwd)
      @session.window.add_pane(pane)
      @session.focus_drawer = false
      @session.window.focused_index = @session.window.panes.length - 1
      invalidate
      pane
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

    # Move focus to the pane spatially adjacent in `direction` (:left/:right/
    # :up/:down). Called by the normal-mode hjkl bindings. Pulling the live
    # layout rects keeps this in sync with whatever the renderer is showing.
    # Monocle has no meaningful direction (every rect is identical) so we
    # fall back to linear nav so hjkl still does something.
    def focus_direction(direction)
      return if @session.window.panes.empty?
      if @session.focus_drawer && @session.drawer&.visible?
        @session.focus_drawer = false
        invalidate
        return
      end

      win = @session.window
      idx = LayoutManager.neighbor(current_pane_rects, win.focused_index, direction)
      if idx.nil? && win.layout == :monocle
        case direction
        when :right, :down then win.focus_next
        when :left, :up    then win.focus_prev
        end
        invalidate
        return
      end

      return unless idx
      win.focus_index(idx)
      invalidate
    end

    # Swap the focused pane with its spatial neighbor in `direction`. Bound
    # to shift-HJKL in normal mode. Mirrors focus_direction's geometry-aware
    # lookup so the same "what does my arrow point at" intuition decides
    # which neighbor gets bumped. Monocle has no spatial layout, so HJKL
    # falls back to reordering by linear next/prev — useful for shuffling
    # the master before flipping back to tall/grid.
    def move_direction(direction)
      return if @session.window.panes.empty?
      # The drawer isn't part of the tiled pane list; HJKL while focused on
      # it would be ambiguous. No-op.
      return if @session.focus_drawer && @session.drawer&.visible?

      win = @session.window
      idx = LayoutManager.neighbor(current_pane_rects, win.focused_index, direction)
      if idx.nil? && win.layout == :monocle
        target = case direction
                 when :right, :down then (win.focused_index + 1) % win.panes.length
                 when :left, :up    then (win.focused_index - 1) % win.panes.length
                 end
        if target && target != win.focused_index
          win.move_focused_to(target)
          invalidate
        end
        return
      end

      return unless idx
      win.move_focused_to(idx)
      invalidate
    end

    # Explicit layout set, used by the normal-mode t/g/m bindings and the
    # `:layout <name>` command.
    def set_layout(layout)
      @session.window.set_layout(layout)
      flash("layout: #{@session.window.layout}")
      invalidate
    rescue ArgumentError => e
      flash(e.message)
    end

    # Bound to `i` in normal mode — drops the user into the historical
    # Ctrl-a-prefixed multiplexer mode.
    def enter_passthrough_mode
      @input.enter_passthrough_mode
      flash("passthrough mode (^a esc to return)")
      invalidate
    end

    # Bound to `Ctrl-a Esc` from passthrough — return to normal mode.
    def enter_normal_mode
      @input.enter_normal_mode
      flash("normal mode")
      invalidate
    end

    # Two-step close — same shape as the quit flow. Hiding the drawer is
    # cheap and reversible, so we skip the prompt for the drawer case.
    def request_close
      if @session.focus_drawer && @session.drawer&.visible?
        hide_drawer
        return
      end
      return unless focused_pane
      return if @input.state == :confirm_close
      @input.enter_confirm_close
      flash("close pane? (y/n)")
      invalidate
    end

    def confirm_close
      close_focused
    end

    def cancel_close
      @message = nil
      @message_expires = nil
      flash("cancelled")
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

    # Toggle the privacy flag on the focused pane. Private panes are
    # redacted from the MCP control surface (panes.list strips cwd; read /
    # send_input / run / subscribe / kill all refuse). Only the human can
    # flip this — there is intentionally no control method to do it.
    def toggle_private_focused
      pane = focused_pane
      return unless pane
      pane.toggle_private!
      flash(pane.private? ? "pane #{pane.id} marked private (hidden from MCP)" : "pane #{pane.id} unmarked private")
      invalidate
    end

    def toggle_drawer
      toggle_drawer_kind(command: nil)
    end

    # Ctrl-a C / :claude — opens a drawer whose shell is `claude`, with
    # MUXR_SESSION + MUXR_CONTROL_SOCKET + MUXR_FOCUSED_PANE in the env so
    # the muxr-mcp bridge inside that claude process auto-attaches to this
    # session.
    def toggle_claude_drawer
      toggle_drawer_kind(command: "claude")
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
      yanked = false
      if yank
        # No anchor → no-op. User is still positioning; they can press v
        # first, then yank. Esc/q is the way to exit from navigation.
        return unless term&.selection_active?
        text = term.extract_selection_text
        unless text.empty?
          @paste_buffer = text
          spawn_pbcopy(text)
          flash("yanked #{text.bytesize} bytes")
          yanked = true
        end
      end
      term&.clear_selection
      if yanked
        # vim-style: yanking drops you straight back to "normal" (idle),
        # not back into scrollback navigation.
        term&.scroll_to_bottom
        @input.enter_idle_mode
      else
        @input.enter_scrollback_mode
      end
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
      when :line_first_nonblank then term.selection_cursor_to_first_non_blank
      when :top              then term.selection_cursor_to_top
      when :bottom           then term.selection_cursor_to_bottom
      when :screen_top       then term.selection_cursor_to_viewport(:top)
      when :screen_middle    then term.selection_cursor_to_viewport(:middle)
      when :screen_bottom    then term.selection_cursor_to_viewport(:bottom)
      when :word_forward      then term.selection_cursor_word_forward(big: false)
      when :word_forward_big  then term.selection_cursor_word_forward(big: true)
      when :word_end          then term.selection_cursor_word_end(big: false)
      when :word_end_big      then term.selection_cursor_word_end(big: true)
      when :word_backward     then term.selection_cursor_word_backward(big: false)
      when :word_backward_big then term.selection_cursor_word_backward(big: true)
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

    # Called by the FramedOutput adapter; queues one OUTPUT frame to the
    # currently attached client and tries to push as much as the socket
    # will take without blocking. Anything left over stays in
    # @client_write_buffer and gets flushed by the event loop when the
    # socket reports writable. This prevents a slow client (or slow
    # terminal upstream of the client) from deadlocking the server when
    # the server is also trying to read from that same client.
    def deliver_output(bytes)
      return unless @current_client
      @client_write_buffer << Protocol.frame(Protocol::OUTPUT, bytes)
      drain_client_writes
    end

    def drain_client_writes
      return unless @current_client
      return if @client_write_buffer.empty?
      loop do
        n = @current_client.write_nonblock(@client_write_buffer)
        @client_write_buffer = @client_write_buffer.byteslice(n..-1) || +"".b
        break if @client_write_buffer.empty?
      end
    rescue IO::WaitWritable
      # Socket send buffer is full; the rest stays queued.
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

    # Live pane rects for the current layout/size, computed the same way the
    # Renderer does so spatial neighbor lookup matches what the user sees.
    def current_pane_rects
      win = @session.window
      area = LayoutManager::Rect.new(0, 0, @session.width, @session.height - 1)
      LayoutManager.compute(
        win.layout,
        win.panes.length,
        area,
        focused_index: win.focused_index,
        master_index: win.master_index
      )
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

      # Sibling control socket — multi-client, NDJSON, used by bin/muxr-mcp
      # and any other programmatic driver. Connected control clients do not
      # count as "attached", so a Claude Code session can poke the muxr
      # server without contending with the human's TTY client.
      @control_server = ControlServer.new(self, @control_socket_path)
      @control_server.start

      @session  = Session.new(name: @session_name, width: DEFAULT_WIDTH, height: DEFAULT_HEIGHT)
      @renderer = Renderer.new(out: FramedOutput.new(self))
      @input    = InputHandler.new(self)

      saved = Session.load(@session_name)
      first_id = saved && saved.dig("panes", 0, "id")
      @session.window.add_pane(make_pane(id: first_id))

      restore_panes_if_saved(saved) if saved

      @running = true
      start_foreground_poller
    end

    def teardown
      stop_foreground_poller
      disconnect_client
      @control_server&.stop
      @control_server = nil
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
        read_ios  = [@listening_socket]
        read_ios << @current_client if @current_client
        @session.window.panes.each { |p| read_ios << p.io if p.alive? }
        drawer_pane = @session.drawer&.pane
        read_ios << drawer_pane.io if drawer_pane&.alive?
        read_ios.concat(@control_server.read_ios) if @control_server

        write_ios = []
        @session.window.panes.each do |p|
          write_ios << p.writer_io if p.alive? && p.pending_write?
        end
        if drawer_pane&.alive? && drawer_pane.pending_write?
          write_ios << drawer_pane.writer_io
        end
        write_ios << @current_client if @current_client && !@client_write_buffer.empty?
        write_ios.concat(@control_server.write_ios) if @control_server

        timeout = @message ? 0.25 : SELECT_TIMEOUT
        # If a render is queued but we're inside the frame-rate budget, wake
        # up as soon as the budget expires so the deferred paint lands on time.
        if @current_client && @needs_render && @last_render_at
          budget = MIN_FRAME_INTERVAL - (monotonic_now - @last_render_at)
          timeout = budget.clamp(0, timeout) if budget < timeout
        end
        # If a pane is mid-synchronized-output (DEC 2026), wake up no later
        # than its safety deadline so a crashed inner program can't wedge
        # rendering past Terminal::SYNC_TIMEOUT.
        deadline = nearest_sync_deadline
        if deadline
          remaining = deadline - monotonic_now
          timeout = remaining.clamp(0, timeout) if remaining < timeout
        end
        ready_r, ready_w, = IO.select(read_ios, write_ios, nil, timeout)

        ready_r&.each do |io|
          if io == @listening_socket
            accept_client
          elsif io == @current_client
            consume_client_frame
          elsif @control_server&.owns?(io)
            @control_server.handle_read(io)
          else
            consume_pane_io(io)
          end
        end

        ready_w&.each do |io|
          if io == @current_client
            drain_client_writes
          elsif @control_server&.owns?(io)
            @control_server.handle_write(io)
          else
            pane = pane_for_writer_io(io)
            pane&.drain_writes
          end
        end

        @control_server&.tick

        prune_dead_panes
        prune_dead_drawer
        expire_message

        if @session.window.panes.empty?
          @running = false
          break
        end

        if @current_client && @needs_render && !any_pane_syncing?
          now = monotonic_now
          if @last_render_at.nil? || (now - @last_render_at) >= MIN_FRAME_INTERVAL
            render
            @last_render_at = now
            @needs_render = false
          end
        end
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # True iff any pane (or the drawer) has opened a DEC 2026 synchronized
    # output block that hasn't yet closed or timed out. Used to defer the
    # outer paint so it lands on a fully-formed inner frame.
    def any_pane_syncing?
      return true if @session.window.panes.any? { |p| p.terminal.sync_pending? }
      drawer = @session.drawer&.pane
      return true if drawer && drawer.terminal.sync_pending?
      false
    end

    def nearest_sync_deadline
      deadlines = @session.window.panes.filter_map { |p| p.terminal.sync_deadline }
      d = @session.drawer&.pane&.terminal&.sync_deadline
      deadlines << d if d
      deadlines.min
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
      if data
        invalidate
        # Notify the control surface so any pending pane.run waiters reset
        # their idle window and any pane.subscribe clients get a new frame.
        # read_from_pty already fed the bytes into the Terminal; the control
        # server pulls the resulting text out of pane.terminal.dump_text.
        @control_server&.on_pane_output(pane.id, data) if pane.id.is_a?(String)
      end
    end

    def pane_for_io(io)
      pane = @session.window.panes.find { |p| p.io == io }
      return pane if pane
      return @session.drawer.pane if @session.drawer&.pane && @session.drawer.pane.io == io
      nil
    end

    def pane_for_writer_io(io)
      pane = @session.window.panes.find { |p| p.writer_io == io }
      return pane if pane
      return @session.drawer.pane if @session.drawer&.pane && @session.drawer.pane.writer_io == io
      nil
    end

    def prune_dead_panes
      dead = @session.window.panes.reject(&:alive?)
      return if dead.empty?
      dead.each { |p| @session.window.remove_pane(p) }
      invalidate
    end

    # When the shell (or claude) inside the drawer exits, tear the drawer
    # down so the next Ctrl-a ~ / Ctrl-a C spawns a fresh one. Without this
    # the drawer pane stays mounted around a dead PTY and looks like the
    # multiplexer is wedged.
    def prune_dead_drawer
      drawer = @session.drawer
      return unless drawer
      pane = drawer.pane
      return unless pane
      return if pane.alive?
      kind = drawer.command ? "#{drawer.command} drawer" : "drawer"
      drawer.close
      @session.drawer = nil
      @session.focus_drawer = false
      renderer.reset_frame!
      flash("#{kind} exited")
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
      # Best-effort: drop any queued OUTPUT (the client is going away),
      # send a final BYE, then close. BYE is small enough that one
      # blocking write won't meaningfully wedge anything even if the
      # client's recv is sluggish.
      @client_write_buffer = +"".b
      safe_protocol_write(@current_client, Protocol::BYE, reason || "")
      @current_client.close rescue nil
      @current_client = nil
    end

    def drop_client_silently
      return unless @current_client
      @current_client.close rescue nil
      @current_client = nil
      @client_write_buffer = +"".b
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
    # Background thread that walks every pane and writes its foreground
    # command back onto pane.foreground_command. Lives off the event loop
    # because the macOS `ps` path is fork+exec'y; on Linux the procfs reads
    # would be fast enough on the main thread but a single code path is
    # easier to reason about. Atomic pointer writes (MRI GVL) mean we don't
    # need a lock for the renderer's per-frame read.
    def start_foreground_poller
      return if @foreground_poller
      @foreground_poller = Thread.new do
        while @running
          begin
            poll_foreground_commands
          rescue StandardError
            # Never let a poller crash kill the server. If the lookup keeps
            # failing the titles just won't show commands — that's fine.
          end
          sleep FOREGROUND_POLL_INTERVAL
        end
      end
    end

    def stop_foreground_poller
      thread = @foreground_poller
      @foreground_poller = nil
      return unless thread
      # @running has already been flipped off; the thread exits on its next
      # wake. join with a small timeout so we don't hang teardown if the
      # thread is mid-`ps`.
      thread.join(2.0) || thread.kill
    end

    def poll_foreground_commands
      # Snapshot so add/remove on the main thread can't trip us mid-iter.
      panes = @session.window.panes.dup
      drawer_pane = @session.drawer&.pane
      panes << drawer_pane if drawer_pane
      changed = false
      panes.each do |pane|
        next unless pane.alive?
        next unless pane.respond_to?(:pid) && pane.pid
        name = ForegroundCommand.lookup(pane.pid)
        if pane.foreground_command != name
          pane.foreground_command = name
          changed = true
        end
      end
      invalidate if changed
    end

    def spawn_pbcopy(text)
      Thread.new do
        IO.popen("pbcopy", "w") { |io| io.write(text) }
      rescue Errno::ENOENT, Errno::EPIPE, IOError, StandardError
        # pbcopy unavailable or pipe broken — selection still lives in
        # @paste_buffer.
      end
    end

    def make_pane(cwd: nil, id: nil)
      Pane.new(id: id, rows: 24, cols: 80, cwd: cwd)
    end

    def ensure_drawer(command: nil)
      return if @session.drawer
      cwd = focused_pane&.cwd
      pane = Pane.new(
        id: :drawer,
        rows: 10,
        cols: 80,
        cwd: cwd,
        command: command,
        env_overrides: drawer_env
      )
      @session.drawer = Drawer.new(pane: pane, origin_cwd: cwd, command: command)
    end

    # Toggle the drawer; if a different kind is currently up, tear it down
    # and replace it with the requested kind. Keeps the drawer slot a single
    # PTY so users don't end up with a confusing menagerie of overlays.
    def toggle_drawer_kind(command:)
      current = @session.drawer
      if current.nil?
        ensure_drawer(command: command)
        @session.drawer.show!
        @session.focus_drawer = true
      elsif current.command == command
        current.toggle!
        @session.focus_drawer = current.visible?
      else
        current.close
        @session.drawer = nil
        ensure_drawer(command: command)
        @session.drawer.show!
        @session.focus_drawer = true
      end
      renderer.reset_frame!
      invalidate
    end

    # Env vars exposed to every drawer PTY. The MCP bridge reads these to
    # auto-connect to the right session; MUXR_DRAWER_SELF lets it refuse
    # drawer.* methods so a claude drawer can't recurse into its own PTY.
    def drawer_env
      env = {
        "MUXR_SESSION"        => @session_name.to_s,
        "MUXR_CONTROL_SOCKET" => @control_socket_path.to_s,
        "MUXR_DRAWER_SELF"    => "1"
      }
      focused = focused_pane
      env["MUXR_FOCUSED_PANE"] = focused.id.to_s if focused&.id.is_a?(String)
      env
    end

    def restore_panes_if_saved(data)
      return unless data

      if data["layout"] && Window::LAYOUTS.include?(data["layout"].to_sym)
        @session.window.set_layout(data["layout"].to_sym)
      end

      panes_data = data["panes"] || []
      # Restore privacy flag for the already-created first pane.
      if panes_data[0] && panes_data[0]["private"] && @session.window.panes[0]
        @session.window.panes[0].mark_private!
      end
      panes_data[1..]&.each do |entry|
        cwd = entry["cwd"]
        id  = entry["id"]
        pane = make_pane(cwd: cwd, id: id)
        pane.mark_private! if entry["private"]
        @session.window.add_pane(pane)
      end

      if data["drawer"]
        cwd = data["drawer"]["cwd"]
        command = data["drawer"]["command"]
        pane = Pane.new(
          id: :drawer,
          rows: 10,
          cols: 80,
          cwd: cwd,
          command: command,
          env_overrides: drawer_env
        )
        drawer = Drawer.new(pane: pane, origin_cwd: cwd, command: command)
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
