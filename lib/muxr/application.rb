require "socket"
require "fileutils"
require "securerandom"
require "muxr/remote_pane"
require "muxr/pane_transfer"
require "muxr/pane_picker"
require "muxr/session_directory"

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

    attr_reader :session, :renderer, :input, :session_name, :control_server, :pane_picker

    def self.socket_path_for(name)
      File.join(SOCKETS_DIR, "#{name}.sock")
    end

    # The name a bare `muxr` (no name argument) resolves to: a slug of the
    # current working directory, so re-running `muxr` in the same directory
    # reattaches the same session. The name is interpolated straight into
    # <name>.sock / <name>.json / <name>.log filenames, so the path's slashes
    # (and any other filesystem-unfriendly bytes) are folded to "-"; the
    # leading "-" from the root slash is trimmed for readability in --list.
    def self.default_session_name(dir = Dir.pwd)
      slug = dir.gsub(%r{/}, "-").gsub(/[^A-Za-z0-9._-]/, "-").sub(/\A-+/, "")
      slug.empty? ? "default" : slug
    end

    def self.control_socket_path_for(name)
      File.join(SOCKETS_DIR, "#{name}.ctrl.sock")
    end

    # Names of sessions whose server socket is currently accepting connections.
    # Stale sockets (file exists, no listener) are skipped but left in place;
    # cleanup happens on the next attach attempt. The sibling control socket
    # lives in the same directory under <name>.ctrl.sock and is not a session.
    def self.list_active
      return [] unless File.directory?(SOCKETS_DIR)
      Dir.children(SOCKETS_DIR).filter_map do |entry|
        next unless entry.end_with?(".sock")
        next if entry.end_with?(".ctrl.sock")
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
      @pane_picker = nil
      @current_client = nil
      @client_write_buffer = +"".b
      @listening_socket = nil
      # The directory bin/muxr was launched from — Process.daemon(true, ...)
      # preserves it across daemonization. Every new pane (and the drawer)
      # starts here, treating it as the session's project root regardless of
      # where the focused pane's shell has wandered.
      @origin_cwd = Dir.pwd
      @socket_path = self.class.socket_path_for(@session_name)
      @control_socket_path = self.class.control_socket_path_for(@session_name)
      @control_server = nil
      @paste_buffer = +""
      # Trailing bytes of an in-flight INPUT chunk that look like the start of
      # a bracketed-paste marker but were cut off by the 4 KiB read boundary.
      # Held back and prepended to the next chunk so a split marker still gets
      # recognized — see #strip_bracketed_paste_markers.
      @paste_marker_tail = +"".b
      @last_render_at = nil
      @foreground_poller = nil
      # Opt-in diagnostic tap. When MUXR_TRACE_OUTPUT names a writable path, the
      # server appends every byte it sends to the client — i.e. exactly what the
      # outer terminal receives. Replaying it (`cat` it into a fresh terminal, or
      # feed it to a reference emulator) reproduces a rendering bug from the byte
      # stream alone, which tells us whether corruption is in muxr's emitted
      # output or somewhere downstream. Off unless the env var is set.
      @trace_output = open_trace(ENV["MUXR_TRACE_OUTPUT"])
    end

    def open_trace(path)
      return nil if path.nil? || path.empty?
      File.open(path, "ab")
    rescue SystemCallError
      nil
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

    # Bytes the outer terminal wraps around a paste once bracketed-paste mode
    # is on (the client enables it unconditionally — see
    # Client#enter_terminal_mode).
    BRACKETED_PASTE_MARKERS = ["\e[200~".b, "\e[201~".b].freeze

    def send_to_focused(data)
      target = focused_target
      return unless target
      data = strip_bracketed_paste_markers(data, target)
      input_targets.each { |pane| pane.write(data) } unless data.empty?
    end

    def input_targets
      target = focused_target
      return [] unless target
      return [target] unless broadcasting?
      @session.window.panes.select { |pane| pane.alive? && !handing_off?(pane) }
    end

    def broadcasting?
      @session.window.synchronized && !(@session.focus_drawer && @session.drawer&.visible?)
    end

    def rename_focused(name)
      pane = focused_pane
      return unless pane
      pane.name = name
      flash(pane.name ? "pane ##{@session.window.focused_index + 1} is now #{pane.name}" : "pane ##{@session.window.focused_index + 1} name cleared")
      invalidate
    end

    def set_sync(arg)
      win = @session.window
      case arg
      when nil then win.synchronized = !win.synchronized
      when "on" then win.synchronized = true
      when "off" then win.synchronized = false
      else return flash("sync: expected on or off")
      end
      flash(win.synchronized ? "sync on: typing reaches all #{win.panes.length} panes" : "sync off")
      invalidate
    end

    # The client turns bracketed-paste mode on for the *outer* terminal so big
    # pastes arrive wrapped in \e[200~…\e[201~ (which lets shells/editors that
    # speak the protocol collapse them). But the focused program may not speak
    # it — in that case the markers would print as a literal "^[[200~" before
    # and after the text. So: forward the markers untouched when the focused
    # program enabled DECSET 2004, strip them otherwise.
    #
    # A marker can straddle a 4 KiB read boundary, so any trailing bytes that
    # form a partial marker (but not a bare ESC, which must reach the program
    # immediately as the Escape key) are held back and prepended next chunk.
    def strip_bracketed_paste_markers(data, target)
      data = data.b
      term = target.respond_to?(:terminal) ? target.terminal : nil
      buf = @paste_marker_tail + data
      @paste_marker_tail = +"".b

      if term&.bracketed_paste?
        # Program wants the markers — hand back everything, partial included.
        return buf
      end

      hold = pending_marker_prefix(buf)
      if hold.positive?
        @paste_marker_tail = buf.byteslice(buf.bytesize - hold, hold)
        buf = buf.byteslice(0, buf.bytesize - hold) || +"".b
      end
      BRACKETED_PASTE_MARKERS.each { |m| buf = buf.gsub(m, "") }
      buf
    end

    # Length (2..5) of the longest suffix of `buf` that is a proper prefix of a
    # bracketed-paste marker, so the remainder can arrive in the next chunk. A
    # bare trailing ESC (length 1) is deliberately not held: it's almost always
    # the Escape key and the program must see it without waiting on the next
    # keystroke. Worst case a marker split right after its ESC leaks a few
    # bytes, which the program reads as a harmless unknown escape.
    def pending_marker_prefix(buf)
      max = [buf.bytesize, 5].min
      max.downto(2) do |k|
        tail = buf.byteslice(buf.bytesize - k, k)
        return k if BRACKETED_PASTE_MARKERS.any? { |m| m.byteslice(0, k) == tail }
      end
      0
    end

    def new_pane(cwd: nil)
      cwd ||= @origin_cwd
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
      sync_input_mode_to_focus
      invalidate
    end

    def focus_prev
      return if @session.window.panes.empty?
      if @session.focus_drawer && @session.drawer&.visible?
        @session.focus_drawer = false
      else
        @session.window.focus_prev
      end
      sync_input_mode_to_focus
      invalidate
    end

    def focus_last
      return if @session.window.panes.empty?
      if @session.focus_drawer && @session.drawer&.visible?
        @session.focus_drawer = false
      else
        @session.window.focus_last
      end
      sync_input_mode_to_focus
      invalidate
    end

    def focus_pane_number(n)
      return if @session.window.panes.empty?
      idx = n - 1
      return unless idx >= 0 && idx < @session.window.panes.length
      @session.focus_drawer = false
      @session.window.focus_index(idx)
      sync_input_mode_to_focus
      invalidate
    end

    # After a focus change, reconcile the input mode with the newly-focused
    # pane: if it was left scrolled back, re-enter scrollback so the user
    # lands exactly where they were reading ("navigating back to the scrolled
    # pane puts you back into scrollback"). We only ever auto-ENTER here —
    # the InputHandler's @prefix_return is what keeps you in scrollback when
    # you hop onto a live pane, so we never auto-leave.
    def sync_input_mode_to_focus
      target = focused_target
      return unless target
      if target.terminal.scrolled_back?
        @input.enter_scrollback_mode(source: :ring)
        @renderer.reset_frame!
      elsif @input.state == :scrollback
        @input.enter_scrollback_mode(source: default_scroll_source(target))
      end
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
        sync_input_mode_to_focus
        invalidate
        return
      end

      return unless idx
      win.focus_index(idx)
      sync_input_mode_to_focus
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

    def toggle_zoom
      win = @session.window
      return flash("already in monocle") if win.layout == :monocle && !win.zoomed?
      win.toggle_zoom
      flash(win.zoomed? ? "zoomed (z to restore #{win.zoom_return})" : "layout: #{win.layout}")
      @renderer.reset_frame!
      invalidate
    end

    def cycle_layout
      @session.window.cycle_layout
      flash("layout: #{@session.window.layout}")
      invalidate
    end

    # Bound to `r` (normal) / `Ctrl-a r` (passthrough). Two-layer repaint to
    # recover from a corrupted display, whichever layer drifted:
    #   1. Nudge the focused program to redraw itself (SIGWINCH wiggle). This
    #      fixes muxr's own Terminal grid when an unhandled or wide glyph
    #      desynced the cursor — reset_frame! alone can't, since it would just
    #      faithfully re-emit the wrong grid.
    #   2. Force a full re-emit of our composed frame to the outer terminal,
    #      fixing the case where the outer display lost/garbled bytes but our
    #      grid is correct.
    def refresh_focused
      target = focused_target
      target.request_redraw if target.respond_to?(:request_redraw)
      @renderer.reset_frame!
      flash("refreshed")
      invalidate
    end

    def promote_master
      @session.window.promote_to_master
      invalidate
    end

    def grow_master
      resize_master(Window::RATIO_STEP)
    end

    def shrink_master
      resize_master(-Window::RATIO_STEP)
    end

    def resize_master(delta)
      @session.window.adjust_master_ratio(delta)
      flash_master_shape
    end

    def add_master
      @session.window.adjust_master_count(1)
      flash_master_shape
    end

    def remove_master
      @session.window.adjust_master_count(-1)
      flash_master_shape
    end

    def set_master_ratio(arg)
      value = Float(arg.to_s.delete_suffix("%"), exception: false)
      return flash("ratio: expected a percentage like 60") unless value&.positive?
      @session.window.master_ratio = value > 1 ? value / 100.0 : value
      flash_master_shape
    end

    def set_master_count(arg)
      value = Integer(arg.to_s, exception: false)
      return flash("masters: expected a number like 2") unless value&.positive?
      @session.window.master_count = value
      flash_master_shape
    end

    def flash_master_shape
      win = @session.window
      flash("master #{(win.master_ratio * 100).round}% · masters #{win.master_count}")
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

    # Open the attach overlay: every pane every other live muxr server is
    # willing to share, grouped by session. Building the list means a short
    # blocking round-trip to each server's control socket, which is fine for a
    # deliberate keypress and bounded by SessionDirectory::QUERY_TIMEOUT.
    def open_pane_picker
      entries = SessionDirectory.panes(exclude: @session_name)
      if entries.empty?
        flash("no panes to attach (no other muxr sessions running)")
        return
      end
      @pane_picker = PanePicker.new(entries)
      @input.enter_pane_picker_mode
      invalidate
    end

    def move_pane_picker(delta)
      @pane_picker&.move(delta)
      invalidate
    end

    def cancel_pane_picker
      @pane_picker = nil
      @renderer.reset_frame!
      invalidate
    end

    def confirm_pane_picker(move: false)
      entry = @pane_picker&.selected
      cancel_pane_picker
      return unless entry
      move ? move_remote_pane(entry) : attach_remote_pane(entry)
    end

    # Take the pane away from its session rather than sharing it. The pty fd
    # itself crosses over, so the shell and everything running under it carry
    # on uninterrupted — it just answers to this session now, and disappears
    # from the one it came from.
    def move_remote_pane(entry)
      result = PaneTransfer.claim(socket_path: entry.socket_path, pane_id: entry.pane_id)
      pane = result.pane
      pane.foreground_command = nil
      @session.window.add_pane(pane)
      @session.focus_drawer = false
      @session.window.focused_index = @session.window.panes.length - 1
      @renderer.reset_frame!
      flash("moved #{result.session}:#{pane.id} here")
      invalidate
      pane
    rescue PaneTransfer::Error => e
      flash("move failed: #{e.message}")
      nil
    end

    # Mount another session's pane here as a live mirror. The pane keeps
    # running where it is — both sessions see the same shell, and either can
    # type into it. Closing it here (or quitting) only drops the mirror; losing
    # the owning server is what makes the pane go away, and prune_dead_panes
    # takes care of that.
    def attach_remote_pane(entry)
      remote = RemotePane.connect(
        socket_path: entry.socket_path,
        pane_id: entry.pane_id,
        rows: mirror_viewport[0],
        cols: mirror_viewport[1]
      )
      pane = Pane.new(rows: remote.rows, cols: remote.cols, process: remote)
      remote.bind(pane.terminal)
      pane.origin = remote.origin
      pane.name = entry.name if entry.respond_to?(:name)
      @session.window.add_pane(pane)
      @session.focus_drawer = false
      @session.window.focused_index = @session.window.panes.length - 1
      @renderer.reset_frame!
      flash("attached #{remote.origin}")
      invalidate
      pane
    rescue RemotePane::Error => e
      flash("attach failed: #{e.message}")
      nil
    end

    # Size to ask the owner for before the Renderer has laid the new pane out.
    # One more pane in the current layout is the honest guess, and the very next
    # frame corrects it through Pane#resize.
    def mirror_viewport
      rects = LayoutManager.compute(
        @session.window.layout,
        @session.window.panes.length + 1,
        LayoutManager::Rect.new(0, 0, @session.width, @session.height - 1),
        focused_index: @session.window.panes.length,
        **@session.window.layout_options
      )
      rect = rects.last
      return [DEFAULT_HEIGHT, DEFAULT_WIDTH] unless rect
      [[rect.h - 2, 1].max, [rect.w - 2, 1].max]
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
      @input.enter_scrollback_mode(source: default_scroll_source(target))
      @renderer.reset_frame!
      invalidate
    end

    def app_scroll_available?(target)
      term = target&.terminal
      return false unless term
      term.mouse_tracking? || term.alt_screen?
    end

    def default_scroll_source(target)
      app_scroll_available?(target) ? :app : :ring
    end

    def toggle_scroll_source
      target = focused_target
      return unless target
      if @input.scroll_source == :app
        if target.terminal.alt_screen?
          flash("no history while a full-screen app is running")
          return
        end
        @input.enter_scrollback_mode(source: :ring)
        flash("scrolling muxr history")
      else
        unless app_scroll_available?(target)
          flash("this pane has no scroll of its own")
          return
        end
        target.terminal.scroll_to_bottom
        @input.enter_scrollback_mode(source: :app)
        flash("scrolling the app")
      end
      @renderer.reset_frame!
      invalidate
    end

    def exit_scrollback
      target = focused_target
      target&.terminal&.confine_selection_to_screen!(false)
      target&.terminal&.clear_selection
      target&.terminal&.clear_search
      target&.terminal&.scroll_to_bottom
      @renderer.reset_frame!
      invalidate
    end

    # Bound to `/` (forward) and `?` (backward) in scrollback mode. Drops
    # the user into a buffered prompt; commit_search / cancel_search exit
    # back to scrollback.
    def enter_search(direction: :forward)
      if @input.scroll_source == :app
        flash("search reads muxr history — Tab to switch")
        return
      end
      @input.enter_search_mode(direction: direction)
      invalidate
    end

    def commit_search(query)
      target = focused_target
      return unless target
      term = target.terminal
      direction = @input.search_direction
      count = term.search(query, direction: direction)
      if query.empty?
        # Empty query just dismisses the prompt; leave the prior search
        # state alone (term.search already cleared it though).
      elsif count.zero?
        flash("not found: #{query}")
      else
        flash("#{count} match#{count == 1 ? "" : "es"} (n/N to navigate)")
      end
      @renderer.reset_frame!
      invalidate
    end

    def cancel_search
      @renderer.reset_frame!
      invalidate
    end

    def find_next
      step_search(@input.search_direction)
    end

    def find_prev
      step_search(@input.search_direction == :forward ? :backward : :forward)
    end

    def step_search(direction)
      target = focused_target
      return unless target
      if @input.scroll_source == :app
        flash("search reads muxr history — Tab to switch")
        return
      end
      term = target.terminal
      if term.search_matches.empty?
        flash("no search active")
        return
      end
      term.find_in_direction(direction)
      invalidate
    end

    WHEEL_BURST_MAX = 200

    def scroll_focused(action)
      target = focused_target
      return unless target
      return scroll_app(target, action) if @input.scroll_source == :app
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

    def scroll_app(target, action)
      term = target.terminal
      rows = term.rows
      direction, count =
        case action
        when :line_back    then [:up, 1]
        when :line_forward then [:down, 1]
        when :half_back    then [:up, [rows / 2, 1].max]
        when :half_forward then [:down, [rows / 2, 1].max]
        when :full_back    then [:up, [rows - 1, 1].max]
        when :full_forward then [:down, [rows - 1, 1].max]
        end
      unless direction
        flash("only the app knows where its history starts")
        return
      end
      target.write(app_scroll_bytes(term, direction, count))
      invalidate
    end

    def app_scroll_bytes(term, direction, count)
      count = count.clamp(1, WHEEL_BURST_MAX)
      if term.mouse_tracking?
        MouseReport.wheel(
          direction,
          row: [term.rows / 2 + 1, 1].max,
          col: [term.cols / 2 + 1, 1].max,
          encoding: term.mouse_encoding
        ) * count
      else
        arrow_key(term, direction) * count
      end
    end

    def arrow_key(term, direction)
      if term.app_cursor_keys?
        direction == :up ? "\eOA".b : "\eOB".b
      else
        direction == :up ? "\e[A".b : "\e[B".b
      end
    end

    def enter_selection
      target = focused_target
      return unless target
      # Vim-style: drop the user at a movable cursor with NO selection yet.
      # They navigate with h/j/k/l, then press v (linear) or C-v (block) to
      # anchor. Start at the live cursor's visible position so the user lands
      # where their attention already is, instead of the top-left corner.
      term = target.terminal
      term.confine_selection_to_screen!(@input.scroll_source == :app)
      term.place_selection_cursor(term.cursor_row, term.cursor_col)
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
      # Drop back into scrollback at the current position whether or not we
      # yanked. We no longer snap to the live bottom on yank — the user stays
      # where they were reading so they can keep selecting or scrolling, and
      # `q`/Esc is still there when they want to return to the bottom.
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

    SILENCE_ARG = /\A(\d+)(s|m)?\z/

    def monitor_silence(arg)
      pane = focused_pane
      return unless pane
      if arg.nil?
        flash(pane.silence_after ? "silence: #{format_seconds(pane.silence_after)}" : "silence: off")
      elsif arg == "off"
        pane.watch_silence(nil)
        flash("silence monitor off")
      elsif (m = SILENCE_ARG.match(arg)) && m[1].to_i.positive?
        seconds = m[1].to_i * (m[2] == "m" ? 60 : 1)
        pane.watch_silence(seconds)
        flash("alert when pane ##{@session.window.focused_index + 1} is silent for #{format_seconds(seconds)}")
      else
        flash("silence: expected seconds (30, 30s, 2m) or off")
      end
      invalidate
    end

    def format_seconds(seconds)
      seconds % 60 == 0 && seconds >= 60 ? "#{seconds / 60}m" : "#{seconds}s"
    end

    def paste_from_buffer
      return if @paste_buffer.nil? || @paste_buffer.empty?
      input_targets.each { |pane| pane.write(@paste_buffer) }
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
      names = (Session.list | self.class.list_active).sort
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
      if @trace_output
        @trace_output.write(bytes) rescue nil
      end
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
        argv.find { |a| !a.start_with?("-") } || self.class.default_session_name
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
        **win.layout_options
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
      if @trace_output
        @trace_output.close rescue nil
        @trace_output = nil
      end
    end

    def loop_forever
      while @running
        read_ios  = [@listening_socket]
        read_ios << @current_client if @current_client
        @session.window.panes.each { |p| read_ios << p.io if p.alive? && !handing_off?(p) }
        drawer_pane = @session.drawer&.pane
        read_ios << drawer_pane.io if drawer_pane&.alive?
        read_ios.concat(@control_server.read_ios) if @control_server

        write_ios = []
        @session.window.panes.each do |p|
          write_ios << p.writer_io if p.alive? && p.pending_write? && !handing_off?(p)
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
        report_silent_panes
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
      apply_caps(Protocol.decode_caps(payload))

      @current_client = sock
      @renderer.reset_frame!
      invalidate
    end

    # Apply the client's width-probe verdict so the emulator and Renderer measure
    # glyphs exactly as this terminal draws them, eliminating the width
    # disagreement that smears in-place animations:
    #   ambiguous (1 narrow / 2 wide) — tunes the broad East Asian Ambiguous
    #     class for the long tail of glyphs the probe didn't sample by hand.
    #   glyphs ({codepoint => width}) — exact per-glyph overrides for the
    #     emoji-presentation glyphs (Claude Code's ⏺/✻/❯) no class predicts.
    # A reattaching client re-probes, so a different terminal re-tunes; the full
    # repaint on attach absorbs the change.
    def apply_caps(caps)
      return if caps.nil? || caps.empty?
      Terminal.ambiguous_wide = (caps[:ambiguous] == 2) if caps.key?(:ambiguous)
      Terminal.box_wide = (caps[:box] == 2) if caps.key?(:box)
      Terminal.width_overrides = caps[:glyphs] if caps.key?(:glyphs)
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
      control = @control_server
      relay = pane.id.is_a?(String) && control&.mirrored?(pane.id)
      data =
        if relay
          pane.read_from_pty { |chunk| control.on_pane_raw(pane.id, chunk) }
        else
          pane.read_from_pty
        end
      if data
        invalidate
        pane.note_output(attended: attended?(pane))
        # Notify the control surface so any pending pane.run waiters reset
        # their idle window and any pane.subscribe clients get a new frame.
        # read_from_pty already fed the bytes into the Terminal; the control
        # server pulls the resulting text out of pane.terminal.dump_text.
        @control_server&.on_pane_output(pane.id, data) if pane.id.is_a?(String)
      end
      forward_notifications(pane)
      forward_clipboard(pane)
    end

    # Push any bell / desktop-notification bytes the pane's emulator collected
    # straight to the outer terminal — out of band from the rendered frame, so a
    # background pane (an unfocused Claude Code finishing a task) still alerts
    # the user. When no client is attached deliver_output is a no-op; the queue
    # is still drained so it can't accumulate while detached.
    def forward_notifications(pane)
      bytes = pane.terminal.take_pending_notifications!
      return unless bytes
      pane.note_bell unless attended?(pane)
      deliver_output(bytes) if @current_client
    end

    def report_silent_panes
      now = Pane.now
      @session.window.panes.each_with_index do |pane, i|
        next unless pane.silence_due?(now)
        pane.note_silence!
        flash("pane ##{i + 1} silent for #{format_seconds(pane.silence_after)}")
        deliver_output("\a".b) if @current_client
      end
    end

    def attended?(pane)
      !@current_client.nil? && pane.equal?(focused_target)
    end

    def clear_focused_attention
      target = focused_target
      target.clear_attention! if target.respond_to?(:clear_attention!)
    end

    # Copy any OSC 52 clipboard write the pane's emulator collected to the
    # system clipboard, and mirror it into the internal paste buffer so Ctrl-a p
    # pastes the same text (same as copy-mode's yank). Unlike notifications this
    # runs even when no client is attached — pbcopy is local to the server host,
    # so a background pane's yank still lands on the clipboard.
    def forward_clipboard(pane)
      text = pane.terminal.take_pending_clipboard!
      return if text.nil? || text.empty?
      @paste_buffer = text
      spawn_pbcopy(text)
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

    # A pane whose pty has been sent to another server but whose move is not
    # committed yet. Its fd stays out of the select sets: two servers reading
    # one master would split the byte stream between them.
    def handing_off?(pane)
      !!@control_server&.handing_off?(pane)
    end

    def prune_dead_panes
      dead = @session.window.panes.reject { |p| p.alive? || handing_off?(p) }
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
      leave_stale_scrollback
      clear_focused_attention
      @renderer.render(
        @session,
        input_state: @input.state,
        scroll_source: @input.scroll_source,
        command_buffer: @input.command_buffer,
        command_completions: @input.command_completions,
        search_buffer: @input.search_buffer,
        search_direction: @input.search_direction,
        message: @message,
        help: @help_visible,
        picker: @pane_picker
      )
    end

    def leave_stale_scrollback
      return unless @input.state == :scrollback
      target = focused_target
      term = target&.terminal
      return unless term
      if @input.scroll_source == :app
        return if app_scroll_available?(target)
        @input.enter_scrollback_mode(source: :ring)
        flash("app exited — scrolling muxr history")
        @renderer.reset_frame!
        return
      end
      return unless term.alt_screen?
      @input.enter_idle_mode
      @renderer.reset_frame!
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
      pane_id = id || SecureRandom.hex(3)
      Pane.new(id: pane_id, rows: 24, cols: 80, cwd: cwd, env_overrides: pane_env(pane_id))
    end

    def ensure_drawer(command: nil)
      return if @session.drawer
      cwd = @origin_cwd
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

    def session_env
      {
        "MUXR_SESSION"        => @session_name.to_s,
        "MUXR_CONTROL_SOCKET" => @control_socket_path.to_s
      }
    end

    def pane_env(pane_id)
      session_env.merge("MUXR_PANE" => pane_id.to_s)
    end

    def drawer_env
      env = session_env.merge("MUXR_DRAWER_SELF" => "1")
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
      panes_data.each_with_index do |entry, i|
        pane = @session.window.panes[i]
        pane.name = entry["name"] if pane && entry["name"]
        pane.watch_silence(entry["silence"]) if pane && entry["silence"].is_a?(Integer) && entry["silence"].positive?
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
      @session.window.master_ratio = data["master_ratio"] if data["master_ratio"].is_a?(Numeric)
      @session.window.master_count = data["master_count"] if data["master_count"].is_a?(Integer)
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
