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
  #   :search, :selection.
  #
  # One-shot sub-states (prefix, command, confirm_quit, help) return to
  # @base_mode (whichever of :normal/:passthrough is active) when they
  # finish. :scrollback and :selection also return to @base_mode so that
  # exiting back from a scroll/yank lands you back in passthrough if that's
  # where you came from.
  #
  # Scrollback is effectively pane-bound. Ctrl-a is honored from inside
  # :scrollback and :selection — it drops into :prefix (with @prefix_return
  # = :scrollback) so a pane switch keeps you in scrollback on the pane you
  # move to, while the pane you left keeps its own scroll position. Coming
  # the other way, the Application re-enters scrollback whenever you focus a
  # pane that was left scrolled back. `i` from scrollback drops to insert
  # (passthrough) without snapping to the bottom; only `q`/Esc returns the
  # pane to the live bottom.
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
      "w"  => [:set_layout, :wide],
      "g"  => [:set_layout, :grid],
      "m"  => [:set_layout, :monocle],
      "|"  => [:set_layout, :columns],
      "-"  => [:set_layout, :rows],
      "f"  => [:set_layout, :spiral],
      "e"  => [:set_layout, :centered],
      "S"  => [:set_layout, :stack],
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
      "r"  => :refresh_focused,
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
      "r"    => :refresh_focused,
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

    # CSI sequences (arrow / page keys) recognized in scrollback mode. Built
    # for terminal raw-mode emission: arrow keys come through as ESC `[`
    # followed by a single final letter, PageUp/PageDown as ESC `[5~` /
    # `[6~`. Lookahead in #feed peels these off as one chunk so a bare ESC
    # still exits scrollback the way it always has.
    SCROLLBACK_CSI = {
      "\e[A"  => :line_back,    # Up
      "\e[B"  => :line_forward, # Down
      "\e[5~" => :half_back,    # PageUp
      "\e[6~" => :half_forward, # PageDown
      "\e[H"  => :top,          # Home
      "\e[F"  => :bottom        # End
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

    attr_reader :state, :command_buffer, :search_buffer, :search_direction, :base_mode

    def initialize(app)
      @app = app
      @state = :normal
      @base_mode = :normal
      @command_buffer = +""
      @search_buffer = +""
      @search_direction = :forward
      # When the prefix state is entered from scrollback/selection (Ctrl-a),
      # this records :scrollback so that a pane switch lands you back in
      # scrollback on the newly-focused pane instead of dropping to the base
      # mode. nil means "use @base_mode" (the normal passthrough behavior).
      @prefix_return = nil
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

        # Multi-byte CSI lookahead for scrollback / search: arrow / page
        # keys arrive as `\e[<final>` and would otherwise trip the
        # bare-Esc-exits behavior. In :scrollback we map them to scroll
        # actions; in :search we silently consume them so a stray arrow
        # doesn't kick the user out of the prompt. An incomplete `\e[…`
        # (rare in raw-mode TTY) falls through and the bare `\e` exits as
        # before.
        if (@state == :scrollback || @state == :search) && remaining.start_with?("\e[")
          consumed = consume_csi_escape(remaining)
          if consumed > 0
            remaining = remaining[consumed..] || ""
            next
          end
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
        when :search
          handle_search_input(ch)
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

    def enter_search_mode(direction: :forward)
      @state = :search
      @search_direction = direction
      @search_buffer = +""
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
      # Where to land once the prefix binding finishes. Normally the base
      # mode, but :scrollback when we entered the prefix from scrollback /
      # selection so a pane switch keeps you in scrollback on the new pane.
      # Consume it immediately so it never leaks into the next prefix.
      ret = @prefix_return || @base_mode
      @prefix_return = nil
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
        # The focus action may auto-enter scrollback (landing on a pane that
        # was left scrolled). Only fall back to `ret` if it didn't.
        @state = ret if @state == :prefix
      when action
        @app.public_send(action)
        # The action may have set a new state (confirm_quit, confirm_close,
        # scrollback via auto-enter, help). Only fall back to `ret` if we're
        # still in :prefix.
        @state = ret if @state == :prefix
      else
        # Unknown prefix key: return to where we came from silently.
        @state = ret
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
      if ch == PREFIX
        # Ctrl-a is the escape hatch even from scrollback: drop into the
        # prefix state so the user can switch panes (Ctrl-a n/p/a/1-9) or
        # run any other prefix binding without first leaving scrollback.
        # @prefix_return = :scrollback keeps the user in scrollback on the
        # pane they switch to; the source pane keeps its scroll position so
        # it stays put. Scrollback is effectively pane-bound now.
        @prefix_return = :scrollback
        @state = :prefix
        return
      end
      if ch == "i"
        # Drop straight into insert (passthrough) without snapping to the
        # live bottom — the pane stays where it's scrolled. Mirrors the
        # normal-mode `i` so "type now" is one key from scrollback too.
        enter_passthrough_mode
        @app.enter_passthrough_mode
        return
      end
      if SCROLLBACK_EXITS.include?(ch)
        enter_idle_mode
        @app.exit_scrollback
        return
      end
      if ch == "v"
        @app.enter_selection
        return
      end
      case ch
      when "/"
        # Flip state directly so tests with a bare FakeApp transition; the
        # Application callback redundantly flips state and runs side-effects.
        enter_search_mode(direction: :forward)
        @app.enter_search(direction: :forward)
        return
      when "?"
        enter_search_mode(direction: :backward)
        @app.enter_search(direction: :backward)
        return
      when "n"
        @app.find_next
        return
      when "N"
        @app.find_prev
        return
      end
      action = SCROLLBACK_BINDINGS[ch]
      @app.scroll_focused(action) if action
      # Unknown keys: ignored. Avoids accidental shell input when the user
      # mistypes inside scrollback mode.
    end

    def handle_search_input(ch)
      case ch
      when "\r", "\n"
        query = @search_buffer.dup
        @search_buffer = +""
        @state = :scrollback
        @app.commit_search(query)
      when "\e", "\x03"
        @search_buffer = +""
        @state = :scrollback
        @app.cancel_search
      when "\x7f", "\b"
        @search_buffer.chop!
        @app.invalidate
      else
        # Printable ASCII / UTF-8. We treat anything at or above 0x20 as
        # input; control bytes besides the ones handled above are dropped
        # to keep stray Ctrl-keys from corrupting the query.
        @search_buffer << ch if ch.ord >= 0x20
        @app.invalidate
      end
    end

    # Find the final byte of a CSI escape sequence and return the number
    # of bytes consumed. In :scrollback we map recognized sequences to
    # scroll actions; in :search we just swallow them so a stray arrow
    # key doesn't kick the user out of the prompt. Returns 0 only when
    # the sequence is incomplete in this chunk — the caller falls through
    # so a bare \e still exits.
    def consume_csi_escape(remaining)
      i = 2
      max = [remaining.bytesize, 16].min
      while i < max
        b = remaining.getbyte(i)
        if b >= 0x40 && b <= 0x7e
          seq = remaining.byteslice(0, i + 1)
          if @state == :scrollback
            action = SCROLLBACK_CSI[seq]
            @app.scroll_focused(action) if action
          end
          return i + 1
        end
        return 0 if b < 0x20 || b > 0x7e # malformed; fall through
        i += 1
      end
      0
    end

    def handle_selection_input(ch)
      if ch == PREFIX
        # Same escape hatch as scrollback: Ctrl-a enters the prefix state so
        # pane switching (and any other prefix binding) works mid-selection.
        # We return to :scrollback (not :selection) on the new pane — you
        # don't want to be mid-select on a pane you just arrived at — while
        # the source pane keeps its scroll position and selection intact.
        @prefix_return = :scrollback
        @state = :prefix
        return
      end
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
