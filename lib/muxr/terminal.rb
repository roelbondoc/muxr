module Muxr
  # A minimal VT100/ANSI terminal emulator. It maintains a fixed grid of cells
  # plus a cursor and parser state. Bytes fed from a PTY are interpreted into
  # mutations of the grid which the Renderer then composites into the final
  # frame. The emulator implements enough of the protocol to host typical
  # interactive shells (bash, zsh) and line-oriented programs.
  class Terminal
    BOLD      = 1
    UNDERLINE = 2
    REVERSE   = 4
    DIM       = 8

    SCROLLBACK_MAX = 5000

    # Codepoint ranges that occupy two display columns (East Asian Wide /
    # Fullwidth per UAX #11, plus the common emoji blocks). A wide glyph is
    # stored in its lead cell with a continuation cell (char "") to its right
    # reserving the second column — see #put_char. Kept as a flat, sorted list
    # of ranges; #char_width only consults it for codepoints >= 0x300, so the
    # ASCII/Latin-1 fast path never pays for the scan.
    WIDE_RANGES = [
      0x1100..0x115F,   # Hangul Jamo
      0x2329..0x232A,   # angle brackets
      0x2E80..0x303E,   # CJK radicals, Kangxi, CJK symbols & punctuation
      0x3041..0x33FF,   # Hiragana … CJK compatibility
      0x3400..0x4DBF,   # CJK Unified Ext A
      0x4E00..0x9FFF,   # CJK Unified Ideographs
      0xA000..0xA4CF,   # Yi
      0xA960..0xA97F,   # Hangul Jamo Ext-A
      0xAC00..0xD7A3,   # Hangul Syllables
      0xF900..0xFAFF,   # CJK Compatibility Ideographs
      0xFE10..0xFE19,   # vertical forms
      0xFE30..0xFE6F,   # CJK compatibility / small form variants
      0xFF00..0xFF60,   # Fullwidth Forms
      0xFFE0..0xFFE6,   # Fullwidth signs
      0x1B000..0x1B16F, # Kana supplement / extended
      0x1F300..0x1F64F, # Misc symbols & pictographs, emoticons
      0x1F680..0x1F6FF, # transport & map symbols
      0x1F900..0x1F9FF, # supplemental symbols & pictographs
      0x1FA70..0x1FAFF, # symbols & pictographs extended-A
      0x20000..0x3FFFD  # CJK Unified Ext B and beyond
    ].freeze

    # Codepoint ranges that occupy zero display columns: combining marks,
    # variation selectors, and zero-width formatting characters. These fold
    # onto the preceding glyph rather than consuming a column (#attach_combining)
    # so the cursor stays aligned with what a real terminal would do.
    ZERO_WIDTH_RANGES = [
      0x0300..0x036F,     # combining diacritical marks
      0x0483..0x0489,     # Cyrillic combining
      0x0591..0x05BD, 0x05BF..0x05BF, 0x05C1..0x05C2, 0x05C4..0x05C5,
      0x0610..0x061A, 0x064B..0x065F, 0x0670..0x0670,
      0x06D6..0x06DC, 0x06DF..0x06E4, 0x06E7..0x06E8, 0x06EA..0x06ED,
      0x0711..0x0711, 0x0730..0x074A,
      0x200B..0x200F,     # zero-width space/joiner/non-joiner, marks
      0x2028..0x202E, 0x2060..0x2064,
      0x20D0..0x20FF,     # combining marks for symbols
      0x1AB0..0x1AFF, 0x1DC0..0x1DFF, # combining extensions
      0xFE00..0xFE0F,     # variation selectors
      0xFE20..0xFE2F,     # combining half marks
      0xFEFF..0xFEFF,     # BOM / zero-width no-break space
      0xE0100..0xE01EF    # variation selectors supplement
    ].freeze

    # East Asian *Ambiguous* width (UAX #11 class "A"): codepoints that some
    # terminals draw one column wide and others two, depending on the font and
    # the terminal's "ambiguous-as-wide" setting. This is where muxr and the
    # outer terminal most often disagree — and the disagreement is exactly what
    # corrupts in-place animations (Claude Code's ⏺/✻/❯ spinner, ·, …, ●, arrows).
    # We don't hardcode a width for them: #char_width consults `ambiguous_wide`,
    # which the width probe (see WidthProbe / the client handshake) sets to
    # match the actual outer terminal. Curated to the BMP symbol/punctuation
    # ranges that show up in practice rather than the full UAX #11 table.
    AMBIGUOUS_RANGES = [
      0x00A1..0x00A1, 0x00A4..0x00A4, 0x00A7..0x00A8, 0x00AA..0x00AA,
      0x00AD..0x00AE, 0x00B0..0x00B4, 0x00B6..0x00BA, 0x00BC..0x00BF,
      0x00C6..0x00C6, 0x00D0..0x00D0, 0x00D7..0x00D8, 0x00DE..0x00E1,
      0x00E6..0x00E6, 0x00E8..0x00EA, 0x00EC..0x00ED, 0x00F0..0x00F0,
      0x00F2..0x00F3, 0x00F7..0x00FA, 0x00FC..0x00FC, 0x00FE..0x00FE,
      0x2010..0x2010, 0x2013..0x2016, 0x2018..0x2019, 0x201C..0x201D,
      0x2020..0x2022, 0x2024..0x2027, 0x2030..0x2030, 0x2032..0x2033,
      0x2035..0x2035, 0x203B..0x203B, 0x203E..0x203E, 0x2074..0x2074,
      0x207F..0x207F, 0x2081..0x2084, 0x20AC..0x20AC, 0x2103..0x2103,
      0x2105..0x2105, 0x2109..0x2109, 0x2113..0x2113, 0x2116..0x2116,
      0x2121..0x2122, 0x2126..0x2126, 0x212B..0x212B, 0x2153..0x2154,
      0x215B..0x215E, 0x2160..0x216B, 0x2170..0x2179, 0x2189..0x2189,
      0x2190..0x2199, 0x21B8..0x21B9, 0x21D2..0x21D2, 0x21D4..0x21D4,
      0x21E7..0x21E7, 0x2200..0x2200, 0x2202..0x2203, 0x2207..0x2208,
      0x220B..0x220B, 0x220F..0x220F, 0x2211..0x2211, 0x2215..0x2215,
      0x221A..0x221A, 0x221D..0x2220, 0x2223..0x2223, 0x2225..0x2225,
      0x2227..0x222C, 0x222E..0x222E, 0x2234..0x2237, 0x223C..0x223D,
      0x2248..0x2248, 0x224C..0x224C, 0x2252..0x2252, 0x2260..0x2261,
      0x2264..0x2267, 0x226A..0x226B, 0x226E..0x226F, 0x2282..0x2283,
      0x2286..0x2287, 0x2295..0x2295, 0x2299..0x2299, 0x22A5..0x22A5,
      0x22BF..0x22BF, 0x2312..0x2312, 0x2460..0x24E9, 0x24EB..0x24FF,
      # NOTE: the box-drawing / block-element band 0x2500-0x259F is deliberately
      # excluded — Renderer#contiguous_after? trusts it as width-1 and terminals
      # draw it narrow regardless of the ambiguous setting. Geometric shapes
      # (0x25A0+) are fair game.
      0x25A0..0x25A1,
      0x25A3..0x25A9, 0x25B2..0x25B3, 0x25B6..0x25B7, 0x25BC..0x25BD,
      0x25C0..0x25C1, 0x25C6..0x25C8, 0x25CB..0x25CB, 0x25CE..0x25D1,
      0x25E2..0x25E5, 0x25EF..0x25EF, 0x2605..0x2606, 0x2609..0x2609,
      0x260E..0x260F, 0x261C..0x261C, 0x261E..0x261E, 0x2640..0x2640,
      0x2642..0x2642, 0x2660..0x2661, 0x2663..0x2665, 0x2667..0x266A,
      0x266C..0x266D, 0x266F..0x266F, 0x269E..0x269F, 0x26BF..0x26BF,
      0x26C6..0x26CD, 0x26CF..0x26D3, 0x26D5..0x26E1, 0x273D..0x273D,
      0x2776..0x277F, 0xFFFD..0xFFFD
    ].freeze

    class << self
      # Whether the outer terminal draws East Asian Ambiguous glyphs two columns
      # wide. Set per attach by the width probe (default narrow, matching most
      # modern terminals). Covers the long tail of ambiguous glyphs the probe
      # doesn't sample individually.
      attr_accessor :ambiguous_wide
      # Exact per-codepoint widths the probe measured against the live terminal,
      # cp => 1|2. These WIN over every heuristic below, because a direct
      # measurement is ground truth. This is what catches glyphs whose width no
      # class captures — Claude Code's ⏺/✻/❯, which a font may draw two columns
      # wide via emoji presentation even when the terminal's ambiguous setting
      # is narrow (the exact case the class toggle alone would miss).
      attr_reader :width_overrides
    end
    # Both are process-global: the server hosts exactly one session / outer
    # terminal at a time, and both #char_width call sites (the emulator and the
    # Renderer) must agree.
    self.ambiguous_wide = false
    @width_overrides = {}

    def self.width_overrides=(map)
      @width_overrides = map || {}
    end

    # Display width of a codepoint in terminal columns: 0 (combining /
    # zero-width), 2 (East Asian wide / emoji, plus anything the probe measured
    # or Ambiguous when the probed terminal draws those wide), or 1 (everything
    # else). The Renderer uses this to advance its emit cursor by the right
    # number of columns; #put_char uses it to lay glyphs into the grid.
    def self.char_width(cp)
      return 1 if cp < 0x0300
      return 0 if ZERO_WIDTH_RANGES.any? { |r| r.cover?(cp) }
      ov = @width_overrides[cp]
      return ov if ov
      return 2 if WIDE_RANGES.any? { |r| r.cover?(cp) }
      return 2 if @ambiguous_wide && AMBIGUOUS_RANGES.any? { |r| r.cover?(cp) }
      1
    end

    # Cap on the OSC payload we buffer before parsing. URLs in OSC 8 rarely
    # exceed a few hundred bytes, but OSC 52 clipboard writes (a vim yank, etc.)
    # carry the base64 of whatever the inner program copied, so the cap doubles
    # as the practical clipboard size limit. 100 KiB stays bounded per parser
    # (it's freed on finalize) while comfortably fitting normal yanks; a payload
    # longer than this is truncated rather than copied wholesale.
    OSC_MAX_LEN = 100 * 1024

    # Cap on the outbound notification queue (bell + notification OSCs). While a
    # client is attached the Application drains it every read, so it stays tiny;
    # the cap only matters for a detached session, where nobody is listening and
    # a noisy inner program would otherwise grow it without bound.
    NOTIFY_MAX = 64 * 1024

    # Match plain-text URLs the inner program printed without wrapping them
    # in OSC 8. We stamp the matching cells with a synthetic hyperlink so the
    # outer terminal treats a wrapped URL as one click target instead of two
    # truncated halves. The character class excludes whitespace, control
    # bytes, and the punctuation that almost never sits inside a URL.
    URL_REGEX = %r{(?:https?|ftp)://[^\s<>"\\^`\x00-\x1f\x7f]+}
    # Trailing punctuation we trim from a detected URL — these usually belong
    # to the surrounding sentence ("see https://x.com.") rather than the URL
    # itself. Parens/brackets are intentionally left alone since they're
    # commonly part of Wikipedia-style URLs.
    URL_TRIM_TRAILING = ".,;:!?'\""
    # Prefix on the OSC 8 payload of cells we tagged ourselves. Used to tell
    # synthetic links apart from program-emitted ones so we never clobber
    # OSC 8 links the inner program set.
    SYNTH_URL_PREFIX = "8;id=muxr-url-"

    # Inner programs (fzf ≥ 0.41, neovim, helix, …) bracket coherent screen
    # updates with `\e[?2026h … \e[?2026l` (DECSET 2026 — "Synchronized
    # Output"). When we see the open, we know more bytes are coming that
    # belong to the same logical frame; rendering before the close shows a
    # half-painted state. SYNC_TIMEOUT is the safety cap so a crashed inner
    # program (which left ?2026h open) cannot wedge the pane indefinitely.
    SYNC_TIMEOUT = 0.2

    Cell = Struct.new(:char, :fg, :bg, :attrs, :hyperlink) do
      def reset!
        self.char = " "
        self.fg = nil
        self.bg = nil
        self.attrs = 0
        self.hyperlink = nil
      end

      def copy_from(other)
        self.char = other.char
        self.fg = other.fg
        self.bg = other.bg
        self.attrs = other.attrs
        self.hyperlink = other.hyperlink
      end
    end

    attr_reader :rows, :cols, :cursor_row, :cursor_col, :view_offset

    def initialize(rows: 24, cols: 80)
      @rows = rows
      @cols = cols
      @buffer = Array.new(rows) { Array.new(cols) { blank_cell } }
      @cursor_row = 0
      @cursor_col = 0
      @saved_cursor = [0, 0]
      @fg = nil
      @bg = nil
      @attrs = 0
      @autowrap_pending = false
      @scroll_top = 0
      @scroll_bottom = rows - 1
      @parser_state = :ground
      @parser_params = +""
      @parser_osc = +""
      @feed_remainder = +"".b
      # Currently-active OSC 8 hyperlink body (the "8;params;URI" payload that
      # we'll wrap back around runs of cells when rendering), or nil when no
      # hyperlink is open. Interned via @hyperlink_intern so repeated identical
      # links share one frozen string for fast equality and small memory.
      @current_hyperlink = nil
      @hyperlink_intern = {}
      # Stable interning for synthetic URL hyperlinks. Keyed by the URI text
      # so the same URL produces the same payload string across scans —
      # otherwise every feed would churn the renderer diff.
      @synth_url_intern = {}
      @dirty = true
      @scrollback = []
      @view_offset = 0
      @selection_anchor = nil
      @selection_cursor = nil
      @selection_mode = :linear
      @sync_pending = false
      @sync_started_at = nil
      # True once the inner program enables bracketed-paste mode (DECSET
      # 2004). The Application consults this to decide whether to forward the
      # \e[200~…\e[201~ paste markers the outer terminal wraps around a paste
      # or strip them — see Application#send_to_focused.
      @bracketed_paste = false
      # Whether the inner program wants its cursor shown (DECTCEM, DEC private
      # mode 25). Claude Code and other Ink UIs hide the cursor (\e[?25l) for
      # the whole render and only show it (\e[?25h) at a text-input prompt —
      # the Renderer consults this so we don't paint a stray block cursor on
      # top of an animating progress line.
      @cursor_visible = true
      @pending_replies = +"".b
      # Out-of-band bytes the emulator owes the OUTER terminal (not the inner
      # program): the bell and desktop-notification OSCs (OSC 9, OSC 777) that
      # Claude Code emits to get your attention. We don't model these on the
      # grid — they're forwarded verbatim so the user's real terminal rings /
      # raises the notification, even when the emitting pane isn't focused.
      # The Application drains this in consume_pane_io. Capped so a detached
      # session (nobody to forward to) can't grow it without bound.
      @pending_notifications = +"".b
      # The most recent clipboard write the inner program requested via OSC 52
      # (`\e]52;c;<base64>\a` — what vim/tmux/Ghostty emit on a "copy to system
      # clipboard" yank), already base64-decoded to raw bytes. Not grid state;
      # the Application drains it in consume_pane_io and pipes it to pbcopy.
      # Last-write-wins (a clipboard holds one value) so this can't grow without
      # bound, and it's drained even while detached since pbcopy is local to the
      # server host and doesn't need an attached client.
      @pending_clipboard = nil
      @search_query = nil
      @search_direction = :forward
      @search_matches = []
      @search_current = nil
    end

    # Bytes the emulator owes back to the inner program in response to a
    # query (currently DSR / Device Status Report — `\e[5n` and `\e[6n`).
    # The Pane drains this after each feed and writes it to the PTY's input
    # side. Without it, programs like the AWS CLI fall back with a warning
    # ("your terminal doesn't support cursor position requests (CPR)").
    def take_pending_replies!
      return nil if @pending_replies.empty?
      data = @pending_replies
      @pending_replies = +"".b
      data
    end

    # True iff the inner program has opened a synchronized-output block
    # (\e[?2026h) and not yet closed it, and the safety timeout has not
    # elapsed. The Application uses this to defer rendering so the diff lands
    # on a fully-formed frame instead of a half-painted one.
    def sync_pending?
      return false unless @sync_pending
      if @sync_started_at && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @sync_started_at) > SYNC_TIMEOUT
        @sync_pending = false
        @sync_started_at = nil
        return false
      end
      true
    end

    def sync_deadline
      return nil unless @sync_pending && @sync_started_at
      @sync_started_at + SYNC_TIMEOUT
    end

    # True iff the inner program has enabled bracketed-paste mode (DECSET
    # 2004). When false, the Application strips paste markers before writing
    # so a program that doesn't speak bracketed paste never prints a literal
    # "^[[200~".
    def bracketed_paste?
      @bracketed_paste
    end

    # True iff the inner program currently wants its cursor shown (DEC private
    # mode 25, DECTCEM). The Renderer suppresses the focused pane's cursor when
    # this is false so a hidden-cursor UI (Claude Code mid-render, a spinner)
    # doesn't get a phantom block painted at its last write position.
    def cursor_visible?
      @cursor_visible
    end

    # Bytes the emulator owes the OUTER terminal: bell + desktop-notification
    # OSCs the inner program emitted. The Application drains this after each
    # read and forwards it to the attached client so the user's real terminal
    # rings / notifies. Returns nil when empty (mirrors take_pending_replies!).
    def take_pending_notifications!
      return nil if @pending_notifications.empty?
      data = @pending_notifications
      @pending_notifications = +"".b
      data
    end

    # The latest OSC 52 clipboard write (raw, already base64-decoded), or nil if
    # the inner program hasn't asked to set the clipboard since the last drain.
    # The Application pulls this in consume_pane_io and hands it to pbcopy.
    def take_pending_clipboard!
      data = @pending_clipboard
      @pending_clipboard = nil
      data
    end

    attr_reader :selection_mode

    def cell(r, c)
      @buffer[r][c]
    end

    # Return the currently-visible grid as a text string (rows joined by "\n",
    # trailing whitespace stripped on each row). Used by the control surface
    # to expose pane contents to programmatic clients (the MCP bridge in
    # particular). This walks visible_cell so callers see whatever the user
    # is currently looking at, including scrollback.
    def dump_text
      lines = Array.new(@rows) do |r|
        row = String.new(capacity: @cols)
        @cols.times { |c| row << visible_cell(r, c).char }
        row.rstrip
      end
      lines.join("\n")
    end

    # Returns the Cell that should be visible at (r, c) given the current
    # scrollback view_offset. When view_offset == 0 this is the live grid.
    # When view_offset > 0, rows in the top of the visible area are sourced
    # from @scrollback instead.
    def visible_cell(r, c)
      return @buffer[r][c] if @view_offset.zero?
      idx = @scrollback.size - @view_offset + r
      if idx < @scrollback.size
        row = @scrollback[idx]
        return blank_cell if row.nil? || c >= row.length
        row[c]
      else
        @buffer[idx - @scrollback.size][c]
      end
    end

    def scrollback_size
      @scrollback.size
    end

    def scrolled_back?
      @view_offset > 0
    end

    def scroll_back(n = 1)
      set_view_offset(@view_offset + n)
    end

    def scroll_forward(n = 1)
      set_view_offset(@view_offset - n)
    end

    def scroll_to_top
      set_view_offset(@scrollback.size)
    end

    def scroll_to_bottom
      set_view_offset(0)
    end

    # ---------- selection ----------
    #
    # Selection coordinates are in the combined "timeline":
    #   0..scrollback.size-1                 → @scrollback rows
    #   scrollback.size..scrollback.size+rows-1 → @buffer rows
    # so the selection stays anchored to the same text as the user pages
    # through history.

    def selection_active?
      !@selection_anchor.nil?
    end

    # Place the moving cursor at a viewport position without dropping an
    # anchor — the user is still navigating, not yet selecting.
    def place_selection_cursor(r, c)
      tr = timeline_row_for_visible(r).clamp(0, timeline_size - 1)
      tc = c.clamp(0, @cols - 1)
      @selection_cursor = [tr, tc]
      @selection_anchor = nil
      @dirty = true
    end

    # Drop the anchor at the cursor's current position. `mode` controls the
    # selection shape: :linear (character-by-character, reading order) or
    # :block (rectangular).
    def anchor_selection!(mode: :linear)
      return unless @selection_cursor
      @selection_anchor = @selection_cursor.dup
      @selection_mode = mode
      @dirty = true
    end

    # Drop the anchor but keep the cursor so the user can continue navigating
    # (vim's behavior when pressing v while already in linear visual mode).
    def clear_anchor!
      return unless @selection_anchor
      @selection_anchor = nil
      @dirty = true
    end

    # Convenience for tests: place cursor at (r,c) AND anchor immediately.
    def start_selection_at_visible(r, c, mode: :linear)
      place_selection_cursor(r, c)
      anchor_selection!(mode: mode)
    end

    def move_selection_cursor_by(dr, dc)
      return unless @selection_cursor
      tr, tc = @selection_cursor
      ntr = (tr + dr).clamp(0, timeline_size - 1)
      ntc = (tc + dc).clamp(0, @cols - 1)
      return if ntr == tr && ntc == tc
      @selection_cursor = [ntr, ntc]
      ensure_selection_cursor_visible
      @dirty = true
    end

    def selection_cursor_to(tr, tc)
      return unless @selection_cursor
      ntr = tr.clamp(0, timeline_size - 1)
      ntc = tc.clamp(0, @cols - 1)
      @selection_cursor = [ntr, ntc]
      ensure_selection_cursor_visible
      @dirty = true
    end

    def selection_cursor_to_line_start
      return unless @selection_cursor
      selection_cursor_to(@selection_cursor[0], 0)
    end

    def selection_cursor_to_line_end
      return unless @selection_cursor
      selection_cursor_to(@selection_cursor[0], @cols - 1)
    end

    def selection_cursor_to_top
      selection_cursor_to(0, 0)
    end

    def selection_cursor_to_bottom
      selection_cursor_to(timeline_size - 1, @cols - 1)
    end

    def selection_cursor_to_first_non_blank
      return unless @selection_cursor
      tr = @selection_cursor[0]
      selection_cursor_to(tr, first_non_blank_col(tr))
    end

    # Jump to top/middle/bottom of the visible viewport (vim H/M/L), landing
    # on the first non-blank column of the destination line.
    def selection_cursor_to_viewport(where)
      return unless @selection_cursor
      vr = case where
           when :top    then 0
           when :middle then @rows / 2
           when :bottom then @rows - 1
           end
      return if vr.nil?
      tr = timeline_row_for_visible(vr).clamp(0, timeline_size - 1)
      selection_cursor_to(tr, first_non_blank_col(tr))
    end

    def selection_cursor_word_forward(big: false)
      return unless @selection_cursor
      tr, tc = @selection_cursor
      prev_cls = char_class_at(tr, tc, big: big)
      loop do
        nxt = step_forward(tr, tc)
        break unless nxt
        ntr, ntc = nxt
        cur_cls = char_class_at(ntr, ntc, big: big)
        # Row boundaries act as whitespace breaks even when the row is fully
        # packed (no trailing pad) — visually the user sees a new line.
        effective_prev = (ntr != tr) ? :space : prev_cls
        if effective_prev != cur_cls && cur_cls != :space
          selection_cursor_to(ntr, ntc)
          return
        end
        tr, tc = ntr, ntc
        prev_cls = cur_cls
      end
      selection_cursor_to(timeline_size - 1, @cols - 1)
    end

    def selection_cursor_word_end(big: false)
      return unless @selection_cursor
      tr, tc = @selection_cursor
      pos = step_forward(tr, tc)
      return unless pos
      tr, tc = pos
      while char_class_at(tr, tc, big: big) == :space
        pos = step_forward(tr, tc)
        break unless pos
        tr, tc = pos
      end
      return if char_class_at(tr, tc, big: big) == :space
      cls = char_class_at(tr, tc, big: big)
      loop do
        pos = step_forward(tr, tc)
        if pos.nil? || pos[0] != tr || char_class_at(pos[0], pos[1], big: big) != cls
          selection_cursor_to(tr, tc)
          return
        end
        tr, tc = pos
      end
    end

    def selection_cursor_word_backward(big: false)
      return unless @selection_cursor
      tr, tc = @selection_cursor
      pos = step_backward(tr, tc)
      return unless pos
      tr, tc = pos
      while char_class_at(tr, tc, big: big) == :space
        pos = step_backward(tr, tc)
        unless pos
          selection_cursor_to(tr, tc)
          return
        end
        tr, tc = pos
      end
      cls = char_class_at(tr, tc, big: big)
      loop do
        pos = step_backward(tr, tc)
        if pos.nil? || pos[0] != tr || char_class_at(pos[0], pos[1], big: big) != cls
          selection_cursor_to(tr, tc)
          return
        end
        tr, tc = pos
      end
    end

    def clear_selection
      return unless @selection_anchor
      @selection_anchor = nil
      @selection_cursor = nil
      @dirty = true
    end

    # ---------- search ----------
    #
    # Substring search over the full timeline (scrollback + live buffer).
    # Smart-case: case-insensitive if the query is all-lowercase, sensitive
    # otherwise. Matches are kept in timeline coordinates so they stay
    # anchored to the same text as the user pages history.

    attr_reader :search_query, :search_matches, :search_current, :search_direction

    def search(query, direction: :forward)
      query = query.to_s
      if query.empty?
        clear_search
        return 0
      end
      @search_query = query
      @search_direction = direction
      @search_matches = collect_matches(query)
      if @search_matches.empty?
        @search_current = nil
        @dirty = true
        return 0
      end
      @search_current = nearest_match_in_direction(current_search_anchor_row, direction, inclusive: true)
      @search_current ||= direction == :forward ? 0 : @search_matches.length - 1
      scroll_view_to_match(@search_current)
      @dirty = true
      @search_matches.length
    end

    # Move to the next/previous match in the given direction, wrapping.
    # Returns the new current match index, or nil if there are no matches.
    # Anchors on the current match (not the viewport top) so n always
    # advances even when scroll_view_to_match has centered the previous
    # hit and dragged the viewport top behind it.
    def find_in_direction(direction)
      return nil if @search_matches.empty?
      anchor_tr =
        if @search_current && @search_matches[@search_current]
          @search_matches[@search_current][0]
        else
          current_search_anchor_row
        end
      idx = strict_next_in_direction(anchor_tr, direction)
      if idx.nil?
        # Wrap: pick the far end depending on direction.
        idx = direction == :forward ? 0 : @search_matches.length - 1
      end
      @search_current = idx
      scroll_view_to_match(idx)
      @dirty = true
      idx
    end

    def cell_in_match?(visible_r, c)
      return false if @search_matches.empty?
      tr = timeline_row_for_visible(visible_r)
      # Linear scan is fine: SCROLLBACK_MAX caps matches at O(rows*cols), and
      # the renderer touches each visible cell once per frame. A row-indexed
      # cache would matter at much larger buffer sizes than ours.
      @search_matches.any? { |mr, sc, ec| mr == tr && c >= sc && c <= ec }
    end

    def search_active?
      !(@search_query.nil? || @search_matches.empty?)
    end

    def clear_search
      return if @search_query.nil? && @search_matches.empty?
      @search_query = nil
      @search_matches = []
      @search_current = nil
      @dirty = true
    end

    def selected_at_visible?(r, c)
      return false unless @selection_anchor
      tr = timeline_row_for_visible(r)
      inside_selection?(tr, c)
    end

    def selection_cursor_visible
      return nil unless @selection_cursor
      tr, tc = @selection_cursor
      vr = tr - (@scrollback.size - @view_offset)
      return nil unless vr.between?(0, @rows - 1)
      [vr, tc]
    end

    def extract_selection_text
      return "" unless @selection_anchor
      if @selection_mode == :block
        ar, ac = @selection_anchor
        br, bc = @selection_cursor
        min_r, max_r = ar <= br ? [ar, br] : [br, ar]
        min_c, max_c = ac <= bc ? [ac, bc] : [bc, ac]
        lines = []
        (min_r..max_r).each do |tr|
          row = timeline_row(tr)
          if row.nil? || min_c >= row.length
            lines << ""
            next
          end
          last = [max_c, row.length - 1].min
          chars = (min_c..last).map { |c| row[c]&.char || " " }
          lines << chars.join.rstrip
        end
        return lines.join("\n")
      end
      sr, sc, er, ec = ordered_selection
      lines = []
      (sr..er).each do |tr|
        row = timeline_row(tr)
        if row.nil?
          lines << ""
          next
        end
        first = (tr == sr) ? sc : 0
        last = (tr == er) ? ec : row.length - 1
        last = [last, row.length - 1].min
        chars = (first..last).map { |c| row[c]&.char || " " }
        lines << chars.join.rstrip
      end
      lines.join("\n")
    end

    def dirty?
      @dirty
    end

    def clear_dirty!
      @dirty = false
    end

    def resize(rows, cols)
      return if rows == @rows && cols == @cols
      new_buf = Array.new(rows) { Array.new(cols) { blank_cell } }
      keep_rows = [rows, @rows].min
      keep_cols = [cols, @cols].min
      src_start = @rows - keep_rows
      keep_rows.times do |i|
        keep_cols.times do |j|
          new_buf[i][j].copy_from(@buffer[src_start + i][j])
        end
      end
      @buffer = new_buf
      @rows = rows
      @cols = cols
      @scroll_top = 0
      @scroll_bottom = rows - 1
      @cursor_row = @cursor_row.clamp(0, rows - 1)
      @cursor_col = @cursor_col.clamp(0, cols - 1)
      @autowrap_pending = false
      # Selection points at timeline rows whose shape can't be remapped
      # meaningfully through a resize, so drop it rather than show a smear.
      @selection_anchor = nil
      @selection_cursor = nil
      @dirty = true
    end

    def feed(data)
      bytes = @feed_remainder + data.b
      @feed_remainder = +"".b
      str = bytes.dup.force_encoding(Encoding::UTF_8)
      unless str.valid_encoding?
        # Find the longest valid UTF-8 prefix and stash the remainder for the
        # next feed call so multi-byte characters don't get garbled across PTY
        # read boundaries.
        raw = bytes.bytes
        while raw.any?
          candidate = raw.pack("C*").force_encoding(Encoding::UTF_8)
          break if candidate.valid_encoding?
          @feed_remainder = ([raw.last] + @feed_remainder.bytes).pack("C*").b
          raw.pop
        end
        str = raw.pack("C*").force_encoding(Encoding::UTF_8)
        # Bail out completely if we couldn't decode anything yet.
        return if str.empty?
      end
      str.each_char { |c| process_char(c) }
      detect_urls!
      @dirty = true
    end

    # Walk the buffer (plus the last scrollback row so wraps across the
    # scrollback boundary still join), find plain-text URLs, and stamp the
    # covering cells with an OSC 8 hyperlink carrying an `id=` parameter.
    # Outer terminals (Ghostty, iTerm2, kitty, WezTerm) use `id=` to merge
    # spans that wrap across rows into a single click target — without this
    # a wrapped URL like https://very.long.example.com/path-that-wraps would
    # be detected as two truncated URLs on consecutive lines.
    def detect_urls!
      rows = []
      rows << @scrollback.last if @scrollback.any?
      rows.concat(@buffer)

      rows.each do |row|
        row.each do |cell|
          link = cell.hyperlink
          cell.hyperlink = nil if link && link.start_with?(SYNTH_URL_PREFIX)
        end
      end

      # Build the scan text alongside a codepoint→cell map. A wide
      # continuation half (char "") contributes no codepoints, and a
      # base+combining cell contributes more than one, so we can't assume the
      # old 1:1 cell↔codepoint indexing — map every codepoint back to its
      # source cell instead. URLs are ASCII, but a wide glyph earlier on the
      # line would otherwise shift every later offset off its cell.
      text = String.new(capacity: rows.length * @cols)
      cells = []
      rows.each do |row|
        row.each do |cell|
          ch = cell.char
          next if ch.empty?
          ch.each_char { cells << cell }
          text << ch
        end
      end

      pos = 0
      while (md = URL_REGEX.match(text, pos))
        start_off = md.begin(0)
        end_off = md.end(0)
        while end_off > start_off + 1 && URL_TRIM_TRAILING.include?(text[end_off - 1])
          end_off -= 1
        end
        uri = text[start_off...end_off]
        payload = (@synth_url_intern[uri] ||=
          "#{SYNTH_URL_PREFIX}#{uri.hash.abs.to_s(16)};#{uri}".freeze)

        (start_off...end_off).each do |off|
          cell = cells[off]
          existing = cell.hyperlink
          next if existing && !existing.start_with?(SYNTH_URL_PREFIX)
          cell.hyperlink = payload
        end

        pos = end_off
      end
    end

    private

    def blank_cell
      Cell.new(" ", nil, nil, 0, nil)
    end

    # Queue bytes for the outer terminal (bell / notification OSC). Dropped once
    # the buffer is full so a detached, never-drained session can't grow without
    # bound — see NOTIFY_MAX.
    def queue_notification(bytes)
      return if @pending_notifications.bytesize >= NOTIFY_MAX
      @pending_notifications << bytes
    end

    # Parse the just-completed OSC payload. We care about three families:
    #   OSC 8  (hyperlinks): `8;params;URI` — modeled on the grid (below).
    #   OSC 52 (clipboard): `52;<targets>;<base64>` — decoded and queued for
    #     pbcopy (a vim yank with OSC 52 enabled lands here).
    #   OSC 9 / OSC 777 (desktop notifications) — not grid state; forwarded to
    #     the outer terminal verbatim so the user's real terminal raises the
    #     notification. Claude Code emits these (alongside the bell) when it
    #     wants your attention.
    # Anything else (window-title OSC 0/1/2, palette OSC 4, …) is silently
    # consumed — the emulator doesn't model it.
    def finalize_osc
      payload = @parser_osc
      @parser_osc = +""
      return if payload.empty?
      if payload.start_with?("9;", "777;")
        # Re-wrap with a BEL terminator (universally accepted) — the original
        # ST/BEL was consumed by the parser. The OUTPUT path carries raw bytes,
        # so this reaches the outer terminal unchanged.
        queue_notification("\e]#{payload}\a")
        return
      end
      if payload.start_with?("52;")
        finalize_clipboard(payload)
        return
      end
      return unless payload.start_with?("8;")
      parts = payload.split(";", 3)
      uri = parts[2]
      if uri.nil? || uri.empty?
        @current_hyperlink = nil
      else
        @current_hyperlink = (@hyperlink_intern[payload] ||= payload.dup.freeze)
      end
    end

    # Decode an OSC 52 clipboard write and stash it for the Application to pipe
    # to pbcopy. The payload is `52;<targets>;<base64>`; <targets> selects which
    # X-style clipboard ("c" clipboard, "p" primary, …) and is irrelevant here
    # since the host has one system clipboard. A base64 of "?" is a *query*
    # ("tell me the clipboard"), and an empty body is a clear request — we honor
    # neither (we can't safely read the host clipboard, and silently wiping it on
    # an inner program's whim would be surprising), so both are dropped.
    def finalize_clipboard(payload)
      b64 = payload.split(";", 3)[2]
      return if b64.nil? || b64.empty? || b64 == "?"
      decoded = b64.unpack1("m")
      @pending_clipboard = decoded unless decoded.nil? || decoded.empty?
    end

    def process_char(ch)
      b = ch.ord
      case @parser_state
      when :ground
        ground_char(ch, b)
      when :escape
        escape_char(ch, b)
      when :csi
        csi_char(ch, b)
      when :osc
        if b == 0x07 || b == 0x9c
          finalize_osc
          @parser_state = :ground
        elsif b == 0x1b
          @parser_state = :osc_esc
        elsif @parser_osc.bytesize < OSC_MAX_LEN
          @parser_osc << ch
        end
      when :osc_esc
        # ST is `ESC \`. Anything else is malformed but we still flush — most
        # terminals are lenient here, and being strict would swallow the
        # payload on slightly buggy emitters.
        finalize_osc
        @parser_state = :ground
      when :charset
        @parser_state = :ground
      end
    end

    def ground_char(ch, b)
      case b
      when 0x1b
        @parser_state = :escape
      when 0x07 # BEL
        queue_notification("\a")
      when 0x08 # BS
        @cursor_col -= 1 if @cursor_col > 0
        @autowrap_pending = false
      when 0x09 # HT
        @cursor_col = [((@cursor_col / 8) + 1) * 8, @cols - 1].min
        @autowrap_pending = false
      when 0x0a, 0x0b, 0x0c # LF
        line_feed
        @autowrap_pending = false
      when 0x0d # CR
        @cursor_col = 0
        @autowrap_pending = false
      when 0x00..0x1f
        # ignore other C0 controls
      else
        put_char(ch)
      end
    end

    def escape_char(_ch, b)
      case b
      when 0x5b # [
        @parser_state = :csi
        @parser_params = +""
      when 0x5d # ]
        @parser_state = :osc
        @parser_osc = +""
      when 0x28, 0x29, 0x2a, 0x2b # ( ) * +
        @parser_state = :charset
      when 0x37 # 7  save cursor
        @saved_cursor = [@cursor_row, @cursor_col]
        @parser_state = :ground
      when 0x38 # 8  restore cursor
        @cursor_row, @cursor_col = @saved_cursor
        @parser_state = :ground
      when 0x44 # D  index
        line_feed
        @parser_state = :ground
      when 0x45 # E  next line
        @cursor_col = 0
        line_feed
        @parser_state = :ground
      when 0x4d # M  reverse index
        if @cursor_row == @scroll_top
          scroll_down_region
        else
          @cursor_row -= 1
        end
        @parser_state = :ground
      when 0x63 # c  reset
        reset_terminal
        @parser_state = :ground
      else
        @parser_state = :ground
      end
    end

    def csi_char(_ch, b)
      if (b >= 0x30 && b <= 0x3f) || b == 0x3b
        @parser_params << b.chr
      elsif b >= 0x20 && b <= 0x2f
        @parser_params << b.chr
      elsif b >= 0x40 && b <= 0x7e
        handle_csi(b.chr)
        @parser_state = :ground
      else
        @parser_state = :ground
      end
    end

    def csi_params(default = 0)
      raw = @parser_params.delete_prefix("?").delete_prefix(">").delete_prefix("!")
      raw.split(";", -1).map { |p| p.empty? ? default : p.to_i }
    end

    # SGR allows colon-separated subparameters within a single semicolon-delimited
    # piece (e.g. `4:3` for curly underline, `38:2:R:G:B` for RGB foreground,
    # `58:5:N` for an indexed underline color). csi_params collapses these to a
    # single int via `to_i`, which silently turns `4:0` (underline off) into
    # `4` (underline on). Return Integers for plain pieces and Arrays for any
    # piece that contained a colon so apply_sgr can dispatch on the difference.
    def sgr_params
      raw = @parser_params.delete_prefix("?").delete_prefix(">").delete_prefix("!")
      raw.split(";", -1).map do |piece|
        if piece.include?(":")
          piece.split(":", -1).map { |p| p.empty? ? 0 : p.to_i }
        else
          piece.empty? ? 0 : piece.to_i
        end
      end
    end

    def handle_csi(final)
      # Private / extended CSI sequences share final bytes with the standard
      # ones but mean entirely different things. The most damaging example:
      # `\e[>4;2m` (xterm modifyOtherKeys mode 2) shares its final `m` with
      # SGR. If we stripped the `>` and dispatched into apply_sgr, the `4`
      # would latch underline ON globally — Claude Code emits this sequence
      # once at startup and never clears underline afterward, which made the
      # entire UI underlined. Same shape for `\e[<u` (kitty kbd pop),
      # `\e[=...`, `\e[?...r/s` (XTRESTORE/XTSAVE), `\e[!p` (DECSTR).
      case @parser_params[0]
      when ">", "<", "=", "!"
        return
      when "?"
        # DEC private modes — most we treat as no-ops, but two we track:
        #   2026 (Synchronized Output) — a render-timing hint we honor so the
        #        outer paint lands on fully-formed frames from fzf/nvim/helix.
        #   2004 (Bracketed Paste) — whether the inner program wants pastes
        #        wrapped in \e[200~…\e[201~; the Application strips those
        #        markers when it's off (see Application#send_to_focused).
        #   25   (DECTCEM) — cursor show/hide; the Renderer honors it so a
        #        hidden-cursor UI doesn't get a phantom block painted on it.
        if final == "h" || final == "l"
          enabled = (final == "h")
          params = csi_params
          if params.include?(2026)
            @sync_pending = enabled
            @sync_started_at = enabled ? Process.clock_gettime(Process::CLOCK_MONOTONIC) : nil
          end
          @bracketed_paste = enabled if params.include?(2004)
          @cursor_visible = enabled if params.include?(25)
        end
        return
      end

      pms = csi_params
      case final
      when "A"
        n = [pms[0] || 1, 1].max
        @cursor_row = [@cursor_row - n, 0].max
        @autowrap_pending = false
      when "B", "e"
        n = [pms[0] || 1, 1].max
        @cursor_row = [@cursor_row + n, @rows - 1].min
        @autowrap_pending = false
      when "C", "a"
        n = [pms[0] || 1, 1].max
        @cursor_col = [@cursor_col + n, @cols - 1].min
        @autowrap_pending = false
      when "D"
        n = [pms[0] || 1, 1].max
        @cursor_col = [@cursor_col - n, 0].max
        @autowrap_pending = false
      when "E"
        n = [pms[0] || 1, 1].max
        @cursor_row = [@cursor_row + n, @rows - 1].min
        @cursor_col = 0
        @autowrap_pending = false
      when "F"
        n = [pms[0] || 1, 1].max
        @cursor_row = [@cursor_row - n, 0].max
        @cursor_col = 0
        @autowrap_pending = false
      when "G", "`"
        @cursor_col = ((pms[0] || 1) - 1).clamp(0, @cols - 1)
        @autowrap_pending = false
      when "d"
        @cursor_row = ((pms[0] || 1) - 1).clamp(0, @rows - 1)
        @autowrap_pending = false
      when "H", "f"
        row = (pms[0] || 1) - 1
        col = (pms[1] || 1) - 1
        @cursor_row = row.clamp(0, @rows - 1)
        @cursor_col = col.clamp(0, @cols - 1)
        @autowrap_pending = false
      when "J"
        erase_display(pms[0] || 0)
      when "K"
        erase_line(pms[0] || 0)
      when "L"
        insert_lines(pms[0] || 1)
      when "M"
        delete_lines(pms[0] || 1)
      when "P"
        delete_chars(pms[0] || 1)
      when "@"
        insert_chars(pms[0] || 1)
      when "X"
        n = [pms[0] || 1, 1].max
        n.times do |i|
          c = @cursor_col + i
          @buffer[@cursor_row][c].reset! if c < @cols
        end
      when "r"
        top = ((pms[0] || 1) - 1).clamp(0, @rows - 1)
        bottom = ((pms[1] || @rows) - 1).clamp(top, @rows - 1)
        @scroll_top = top
        @scroll_bottom = bottom
        @cursor_row = 0
        @cursor_col = 0
        @autowrap_pending = false
      when "m"
        apply_sgr(sgr_params)
      when "s"
        @saved_cursor = [@cursor_row, @cursor_col]
      when "u"
        @cursor_row, @cursor_col = @saved_cursor
      when "n"
        # DSR — Device Status Report. `\e[5n` asks if the terminal is OK,
        # `\e[6n` (CPR) asks for the cursor position. The reply rides back
        # through the PTY's input side; see take_pending_replies!.
        case pms[0] || 0
        when 5
          @pending_replies << "\e[0n".b
        when 6
          @pending_replies << "\e[#{@cursor_row + 1};#{@cursor_col + 1}R".b
        end
      when "h", "l"
        # Non-private mode set/reset — nothing we need to honor. (DEC private
        # `?`-prefixed mode sequences are short-circuited above.)
      end
    end

    def put_char(ch)
      width = self.class.char_width(ch.ord)

      # Zero-width: fold the mark onto the preceding glyph instead of taking a
      # column, so the cursor stays where a real terminal would leave it.
      return attach_combining(ch) if width.zero?

      if @autowrap_pending
        @cursor_col = 0
        line_feed
        @autowrap_pending = false
      end

      # A wide glyph needs two columns; if only the last column is free, leave
      # it blank and wrap first (matching xterm/VTE deferral behavior).
      if width == 2 && @cursor_col == @cols - 1
        @buffer[@cursor_row][@cursor_col].reset!
        @cursor_col = 0
        line_feed
      end

      c = @cursor_col
      write_cell(@buffer[@cursor_row][c], ch)
      if width == 2
        # The continuation half carries no glyph (char "") but inherits the
        # lead's colors so a styled wide cell paints both columns; the Renderer
        # skips emitting it since the lead already covers both columns.
        write_cell(@buffer[@cursor_row][c + 1], "")
      end

      last_col = c + width - 1
      if last_col >= @cols - 1
        @cursor_col = @cols - 1
        @autowrap_pending = true
      else
        @cursor_col = last_col + 1
      end
    end

    def write_cell(cell, ch)
      cell.char = ch
      cell.fg = @fg
      cell.bg = @bg
      cell.attrs = @attrs
      cell.hyperlink = @current_hyperlink
    end

    # Fold a zero-width mark (combining accent, variation selector, …) onto the
    # glyph in the cell the cursor just left, so the outer terminal composes
    # them (e + ◌́ → é) without the mark consuming a column. Marks with nothing
    # to attach to — start of line, or landing on a wide continuation half —
    # are dropped; column alignment matters more than the lost accent.
    def attach_combining(ch)
      target =
        if @autowrap_pending then @buffer[@cursor_row][@cols - 1]
        elsif @cursor_col > 0 then @buffer[@cursor_row][@cursor_col - 1]
        end
      return unless target
      return if target.char.empty?
      target.char += ch
    end

    def line_feed
      if @cursor_row == @scroll_bottom
        scroll_up_region
      elsif @cursor_row < @rows - 1
        @cursor_row += 1
      end
    end

    def scroll_up_region
      # Only the default full-screen region contributes to scrollback. Partial
      # regions (vi/less status lines) scroll inner content that's not really
      # "off the top of the screen" and shouldn't pollute history.
      if @scroll_top.zero? && @scroll_bottom == @rows - 1
        @scrollback << @buffer[0]
        if @scrollback.size > SCROLLBACK_MAX
          @scrollback.shift
          # Selection coordinates are timeline-indexed; an eviction shifts the
          # whole timeline down by one. Track that or selection points at the
          # wrong row.
          if @selection_anchor
            @selection_anchor[0] = [@selection_anchor[0] - 1, 0].max
            @selection_cursor[0] = [@selection_cursor[0] - 1, 0].max
          end
          unless @search_matches.empty?
            @search_matches.each { |m| m[0] -= 1 }
            @search_matches.reject! { |m| m[0] < 0 }
            @search_current = nil if @search_current && @search_current >= @search_matches.length
          end
        end
        # Keep the user's view frozen on the same content when new rows arrive
        # while they're scrolled back.
        if @view_offset.positive?
          @view_offset = (@view_offset + 1).clamp(0, @scrollback.size)
        end
      end
      @buffer[@scroll_top, @scroll_bottom - @scroll_top + 1] =
        @buffer[(@scroll_top + 1)..@scroll_bottom] + [Array.new(@cols) { blank_cell }]
    end

    def set_view_offset(v)
      new_v = v.clamp(0, @scrollback.size)
      return if new_v == @view_offset
      @view_offset = new_v
      @dirty = true
    end

    def timeline_size
      @scrollback.size + @rows
    end

    def timeline_row(tr)
      if tr < @scrollback.size
        @scrollback[tr]
      else
        @buffer[tr - @scrollback.size]
      end
    end

    def timeline_row_for_visible(r)
      @scrollback.size - @view_offset + r
    end

    def first_non_blank_col(tr)
      row = timeline_row(tr)
      return 0 unless row
      @cols.times do |c|
        ch = row[c]&.char
        return c if ch && ch != " " && ch != "\t"
      end
      0
    end

    def char_class_at(tr, tc, big:)
      row = timeline_row(tr)
      classify_char(row && row[tc] && row[tc].char, big: big)
    end

    # vim "word" = run of \w (alnum + _); "WORD" = any run of non-whitespace.
    def classify_char(ch, big:)
      return :space if ch.nil? || ch == " " || ch == "\t" || ch == ""
      return :word if big
      ch.match?(/\A\w\z/) ? :word : :punct
    end

    def step_forward(tr, tc)
      if tc + 1 < @cols
        [tr, tc + 1]
      elsif tr + 1 < timeline_size
        [tr + 1, 0]
      end
    end

    def step_backward(tr, tc)
      if tc > 0
        [tr, tc - 1]
      elsif tr > 0
        [tr - 1, @cols - 1]
      end
    end

    def ordered_selection
      a = @selection_anchor
      b = @selection_cursor
      if a[0] < b[0] || (a[0] == b[0] && a[1] <= b[1])
        [a[0], a[1], b[0], b[1]]
      else
        [b[0], b[1], a[0], a[1]]
      end
    end

    def inside_selection?(tr, c)
      if @selection_mode == :block
        ar, ac = @selection_anchor
        br, bc = @selection_cursor
        min_r, max_r = ar <= br ? [ar, br] : [br, ar]
        min_c, max_c = ac <= bc ? [ac, bc] : [bc, ac]
        return tr.between?(min_r, max_r) && c.between?(min_c, max_c)
      end
      sr, sc, er, ec = ordered_selection
      return false if tr < sr || tr > er
      if sr == er
        c.between?(sc, ec)
      elsif tr == sr
        c >= sc
      elsif tr == er
        c <= ec
      else
        true
      end
    end

    def collect_matches(query)
      case_sensitive = query.match?(/[A-Z]/)
      needle = case_sensitive ? query : query.downcase
      matches = []
      timeline_size.times do |tr|
        row = timeline_row(tr)
        next if row.nil?
        # Build the row text and a parallel codepoint→column map so matches can
        # be reported in column coordinates even when wide glyphs (one cell, two
        # columns) and combining marks (multi-codepoint, one cell) break the
        # 1:1 char-index↔column relationship. For all-ASCII rows col_at[i] == i,
        # so this is identical to the old behavior on the common path.
        line = String.new(capacity: @cols)
        col_at = []
        @cols.times do |c|
          ch = row[c]&.char
          next if ch == "" # wide continuation half — occupies no text slot
          ch = " " if ch.nil?
          ch.each_char { col_at << c }
          line << ch
        end
        haystack = case_sensitive ? line : line.downcase
        start = 0
        while (idx = haystack.index(needle, start))
          last = idx + needle.length - 1
          matches << [tr, col_at[idx], col_at[last] || col_at.last || idx]
          # Advance past the start of this match so overlapping needles
          # ("aa" in "aaaa") still emit one match per starting position.
          start = idx + 1
        end
      end
      matches
    end

    # Top of the current viewport in timeline coordinates. Used as the
    # reference point for "search from where the user is looking now".
    def current_search_anchor_row
      timeline_row_for_visible(0)
    end

    # Smallest match index whose row is >= anchor_tr (forward) or largest
    # match index whose row is <= anchor_tr (backward). Used by search() so
    # the first jump lands on the nearest match in the search direction
    # without forcing the user to press n.
    def nearest_match_in_direction(anchor_tr, direction, inclusive:)
      if direction == :forward
        @search_matches.each_with_index do |(mr, _, _), i|
          return i if inclusive ? mr >= anchor_tr : mr > anchor_tr
        end
        nil
      else
        best = nil
        @search_matches.each_with_index do |(mr, _, _), i|
          if (inclusive ? mr <= anchor_tr : mr < anchor_tr)
            best = i
          else
            break
          end
        end
        best
      end
    end

    # Strict next match (n/N) — never matches the current row; that would
    # leave the user stuck on the same line they're already on.
    def strict_next_in_direction(anchor_tr, direction)
      nearest_match_in_direction(anchor_tr, direction, inclusive: false)
    end

    # Center the match in the viewport when possible. set_view_offset clamps
    # to [0, scrollback.size] so recent matches end up showing the live
    # buffer at the bottom and very old ones pin to the top.
    def scroll_view_to_match(idx)
      match = @search_matches[idx]
      return unless match
      tr = match[0]
      desired = @scrollback.size - tr + (@rows / 2)
      set_view_offset(desired)
    end

    def ensure_selection_cursor_visible
      return unless @selection_cursor
      tr = @selection_cursor[0]
      top = @scrollback.size - @view_offset
      bottom = top + @rows - 1
      if tr < top
        set_view_offset(@scrollback.size - tr)
      elsif tr > bottom
        set_view_offset(@scrollback.size - tr + @rows - 1)
      end
    end

    def scroll_down_region
      @buffer[@scroll_top, @scroll_bottom - @scroll_top + 1] =
        [Array.new(@cols) { blank_cell }] + @buffer[@scroll_top..(@scroll_bottom - 1)]
    end

    def erase_display(mode)
      case mode
      when 0
        (@cursor_col...@cols).each { |c| @buffer[@cursor_row][c].reset! }
        ((@cursor_row + 1)...@rows).each do |r|
          @buffer[r].each(&:reset!)
        end
      when 1
        (0..@cursor_col).each { |c| @buffer[@cursor_row][c].reset! }
        (0...@cursor_row).each { |r| @buffer[r].each(&:reset!) }
      when 2, 3
        @buffer.each { |row| row.each(&:reset!) }
      end
    end

    def erase_line(mode)
      case mode
      when 0
        (@cursor_col...@cols).each { |c| @buffer[@cursor_row][c].reset! }
      when 1
        (0..@cursor_col).each { |c| @buffer[@cursor_row][c].reset! }
      when 2
        @buffer[@cursor_row].each(&:reset!)
      end
    end

    def insert_lines(n)
      return unless @cursor_row.between?(@scroll_top, @scroll_bottom)
      n = [n, @scroll_bottom - @cursor_row + 1].min
      n.times do
        @buffer.insert(@cursor_row, Array.new(@cols) { blank_cell })
        @buffer.delete_at(@scroll_bottom + 1)
      end
    end

    def delete_lines(n)
      return unless @cursor_row.between?(@scroll_top, @scroll_bottom)
      n = [n, @scroll_bottom - @cursor_row + 1].min
      n.times do
        @buffer.delete_at(@cursor_row)
        @buffer.insert(@scroll_bottom, Array.new(@cols) { blank_cell })
      end
    end

    def delete_chars(n)
      n = [n, @cols - @cursor_col].min
      n.times do
        @buffer[@cursor_row].delete_at(@cursor_col)
        @buffer[@cursor_row].push(blank_cell)
      end
    end

    def insert_chars(n)
      n = [n, @cols - @cursor_col].min
      n.times do
        @buffer[@cursor_row].insert(@cursor_col, blank_cell)
        @buffer[@cursor_row].pop
      end
    end

    def apply_sgr(tokens)
      tokens = [0] if tokens.empty?
      i = 0
      while i < tokens.length
        t = tokens[i]
        if t.is_a?(Array)
          apply_sgr_colon(t)
          i += 1
          next
        end
        p = t
        case p
        when 0
          @fg = nil
          @bg = nil
          @attrs = 0
        when 1 then @attrs |= BOLD
        when 2 then @attrs |= DIM
        when 4 then @attrs |= UNDERLINE
        when 7 then @attrs |= REVERSE
        when 22 then @attrs &= ~(BOLD | DIM)
        when 24 then @attrs &= ~UNDERLINE
        when 27 then @attrs &= ~REVERSE
        when 30..37 then @fg = p - 30
        when 38
          if tokens[i + 1] == 5
            @fg = [:c256, tokens[i + 2]]
            i += 2
          elsif tokens[i + 1] == 2
            @fg = [:rgb, tokens[i + 2], tokens[i + 3], tokens[i + 4]]
            i += 4
          end
        when 39 then @fg = nil
        when 40..47 then @bg = p - 40
        when 48
          if tokens[i + 1] == 5
            @bg = [:c256, tokens[i + 2]]
            i += 2
          elsif tokens[i + 1] == 2
            @bg = [:rgb, tokens[i + 2], tokens[i + 3], tokens[i + 4]]
            i += 4
          end
        when 49 then @bg = nil
        when 58
          # Set underline color. We don't render underline color separately,
          # but the params must be consumed or they'll be re-interpreted as
          # standalone SGR codes (e.g. an R/G/B value of 4 would spuriously
          # turn on underline for every cell that follows).
          if tokens[i + 1] == 5
            i += 2
          elsif tokens[i + 1] == 2
            i += 4
          end
        when 59
          # Default underline color — nothing to track.
        when 90..97 then @fg = p - 90 + 8
        when 100..107 then @bg = p - 100 + 8
        end
        i += 1
      end
    end

    def apply_sgr_colon(parts)
      return if parts.empty?
      case parts[0]
      when 4
        # `4:0` disables underline; `4:1..5` selects a style (straight, double,
        # curly, dotted, dashed) — we render them all as plain underline.
        if parts[1] == 0
          @attrs &= ~UNDERLINE
        else
          @attrs |= UNDERLINE
        end
      when 24
        @attrs &= ~UNDERLINE
      when 38
        apply_extended_color(parts, foreground: true)
      when 48
        apply_extended_color(parts, foreground: false)
      when 58
        # Underline color — ignored, but consumed.
      end
    end

    def apply_extended_color(parts, foreground:)
      case parts[1]
      when 5
        color = [:c256, parts[2] || 0]
        foreground ? @fg = color : @bg = color
      when 2
        # ITU T.416 allows an optional colorspace id, giving `38:2::R:G:B`
        # (length 6) rather than `38:2:R:G:B` (length 5).
        rgb_start = parts.length >= 6 ? 3 : 2
        r = parts[rgb_start] || 0
        g = parts[rgb_start + 1] || 0
        b = parts[rgb_start + 2] || 0
        color = [:rgb, r, g, b]
        foreground ? @fg = color : @bg = color
      end
    end

    def reset_terminal
      @buffer = Array.new(@rows) { Array.new(@cols) { blank_cell } }
      @cursor_row = 0
      @cursor_col = 0
      @fg = nil
      @bg = nil
      @attrs = 0
      @scroll_top = 0
      @scroll_bottom = @rows - 1
      @autowrap_pending = false
      @current_hyperlink = nil
      @cursor_visible = true
    end
  end
end
