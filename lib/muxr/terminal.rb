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

    # Inner programs (fzf ≥ 0.41, neovim, helix, …) bracket coherent screen
    # updates with `\e[?2026h … \e[?2026l` (DECSET 2026 — "Synchronized
    # Output"). When we see the open, we know more bytes are coming that
    # belong to the same logical frame; rendering before the close shows a
    # half-painted state. SYNC_TIMEOUT is the safety cap so a crashed inner
    # program (which left ?2026h open) cannot wedge the pane indefinitely.
    SYNC_TIMEOUT = 0.2

    Cell = Struct.new(:char, :fg, :bg, :attrs) do
      def reset!
        self.char = " "
        self.fg = nil
        self.bg = nil
        self.attrs = 0
      end

      def copy_from(other)
        self.char = other.char
        self.fg = other.fg
        self.bg = other.bg
        self.attrs = other.attrs
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
      @feed_remainder = +"".b
      @dirty = true
      @scrollback = []
      @view_offset = 0
      @selection_anchor = nil
      @selection_cursor = nil
      @selection_mode = :linear
      @sync_pending = false
      @sync_started_at = nil
      @pending_replies = +"".b
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
      @dirty = true
    end

    private

    def blank_cell
      Cell.new(" ", nil, nil, 0)
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
          @parser_state = :ground
        elsif b == 0x1b
          @parser_state = :osc_esc
        end
      when :osc_esc
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
        # ignore
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
        # DEC private modes — most we treat as no-ops, but mode 2026
        # (Synchronized Output) is a render-timing hint we honor so the
        # outer paint lands on fully-formed frames from fzf/nvim/helix.
        if final == "h" || final == "l"
          if csi_params.include?(2026)
            if final == "h"
              @sync_pending = true
              @sync_started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            else
              @sync_pending = false
              @sync_started_at = nil
            end
          end
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
      if @autowrap_pending
        @cursor_col = 0
        line_feed
        @autowrap_pending = false
      end
      cell = @buffer[@cursor_row][@cursor_col]
      cell.char = ch
      cell.fg = @fg
      cell.bg = @bg
      cell.attrs = @attrs
      if @cursor_col >= @cols - 1
        @autowrap_pending = true
      else
        @cursor_col += 1
      end
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
    end
  end
end
