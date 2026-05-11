module Rux
  # A minimal VT100/ANSI terminal emulator. It maintains a fixed grid of cells
  # plus a cursor and parser state. Bytes fed from a PTY are interpreted into
  # mutations of the grid which the Renderer then composites into the final
  # frame. The emulator implements enough of the protocol to host typical
  # interactive shells (bash, zsh) and line-oriented programs.
  class Terminal
    BOLD      = 1
    UNDERLINE = 2
    REVERSE   = 4

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

    attr_reader :rows, :cols, :cursor_row, :cursor_col

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
    end

    def cell(r, c)
      @buffer[r][c]
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

    def handle_csi(final)
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
        apply_sgr(pms)
      when "s"
        @saved_cursor = [@cursor_row, @cursor_col]
      when "u"
        @cursor_row, @cursor_col = @saved_cursor
      when "h", "l"
        # Modes (?25 cursor visibility, ?1049 alt screen, etc.) — ignored;
        # rux already owns the host terminal's alt screen.
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
      @buffer[@scroll_top, @scroll_bottom - @scroll_top + 1] =
        @buffer[(@scroll_top + 1)..@scroll_bottom] + [Array.new(@cols) { blank_cell }]
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

    def apply_sgr(pms)
      pms = [0] if pms.empty?
      i = 0
      while i < pms.length
        p = pms[i]
        case p
        when 0
          @fg = nil
          @bg = nil
          @attrs = 0
        when 1 then @attrs |= BOLD
        when 4 then @attrs |= UNDERLINE
        when 7 then @attrs |= REVERSE
        when 22 then @attrs &= ~BOLD
        when 24 then @attrs &= ~UNDERLINE
        when 27 then @attrs &= ~REVERSE
        when 30..37 then @fg = p - 30
        when 38
          if pms[i + 1] == 5
            @fg = [:c256, pms[i + 2]]
            i += 2
          elsif pms[i + 1] == 2
            @fg = [:rgb, pms[i + 2], pms[i + 3], pms[i + 4]]
            i += 4
          end
        when 39 then @fg = nil
        when 40..47 then @bg = p - 40
        when 48
          if pms[i + 1] == 5
            @bg = [:c256, pms[i + 2]]
            i += 2
          elsif pms[i + 1] == 2
            @bg = [:rgb, pms[i + 2], pms[i + 3], pms[i + 4]]
            i += 4
          end
        when 49 then @bg = nil
        when 90..97 then @fg = p - 90 + 8
        when 100..107 then @bg = p - 100 + 8
        end
        i += 1
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
