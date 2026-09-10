module Muxr
  class HistoryRow
    include Enumerable

    CACHE_LIMIT = 256
    NO_CELLS = [].freeze

    class << self
      def pack(cells, last)
        return EMPTY if last.nil?
        new(cells, last + 1)
      end

      def retain(row)
        @retained[row] = true
        evict_oldest while @retained.size > CACHE_LIMIT
      end

      private

      def evict_oldest
        oldest, = @retained.first
        @retained.delete(oldest)
        oldest.release!
      end
    end
    @retained = {}

    def initialize(cells, count)
      @count = count
      @cells = count.zero? ? NO_CELLS : nil
      pack_from(cells, count)
    end

    def length
      @count
    end
    alias size length

    def empty?
      @count.zero?
    end

    def [](c)
      return nil if c >= @count
      (@cells || materialize)[c]
    end

    def each(&block)
      return to_enum(:each) unless block
      (@cells || materialize).each(&block)
      self
    end

    def search_text(cols)
      return padded_text(cols), nil unless @lengths
      line = String.new(capacity: @text.bytesize + cols)
      col_at = []
      limit = [@count, cols].min
      each_char_cell do |c, char|
        break if c >= limit
        next if char.empty?
        char.each_char { col_at << c }
        line << char
      end
      (limit...cols).each do |c|
        line << Terminal::BLANK_CHAR
        col_at << c
      end
      [line, col_at]
    end

    def to_ansi
      last = nil
      each_styled_cell { |c, char, fg, bg, attrs, link| last = c if significant?(char, fg, bg, attrs, link) }
      return "" if last.nil?
      out = +""
      sgr = nil
      link_open = nil
      pen = nil
      skip = 0
      each_styled_cell do |c, char, fg, bg, attrs, link|
        break if c > last
        if skip.positive?
          skip -= 1
          next
        end
        unless pen && pen[0] == fg && pen[1] == bg && pen[2] == attrs
          if (s = Terminal.sgr_for(fg, bg, attrs)) != sgr
            out << s
            sgr = s
          end
          pen = [fg, bg, attrs]
        end
        if link != link_open
          out << "\e]8;;\e\\" if link_open
          out << "\e]#{link}\e\\" if link
          link_open = link
        end
        if char.empty?
          out << Terminal::BLANK_CHAR
        else
          out << char
          skip = 1 if Terminal.char_width(char.codepoints.first) == 2
        end
      end
      out << "\e]8;;\e\\" if link_open
      out
    end

    def repack!
      return if @count.zero? || @cells.nil?
      pack_from(@cells, @count)
    end

    def release!
      @cells = nil
    end

    private

    def pack_from(cells, count)
      text = String.new(capacity: count)
      lengths = nil
      runs = nil
      run_len = 0
      fg = nil
      bg = nil
      attrs = 0
      link = nil
      i = 0
      while i < count
        cell = cells[i]
        ch = cell ? cell.char : Terminal::BLANK_CHAR
        n = ch.length
        lengths ||= Array.new(i, 1) unless n == 1
        lengths << n if lengths
        text << ch
        cell_fg = cell ? cell.fg : nil
        cell_bg = cell ? cell.bg : nil
        cell_attrs = cell ? cell.attrs.to_i : 0
        cell_link = cell ? cell.hyperlink : nil
        if run_len.positive? && cell_attrs == attrs && cell_fg == fg &&
           cell_bg == bg && cell_link == link
          run_len += 1
        else
          runs = push_run(runs, run_len, fg, bg, attrs, link)
          run_len = 1
          fg = cell_fg
          bg = cell_bg
          attrs = cell_attrs
          link = cell_link
        end
        i += 1
      end
      runs = push_run(runs, run_len, fg, bg, attrs, link)
      @text = text.freeze
      @lengths = lengths
      @runs = unstyled?(runs) ? nil : runs
    end

    def push_run(runs, len, fg, bg, attrs, link)
      return runs unless len.positive?
      (runs || []).push(len, fg, bg, attrs, link)
    end

    def unstyled?(runs)
      runs.nil? ||
        (runs.length == 5 && runs[1].nil? && runs[2].nil? && runs[3].zero? && runs[4].nil?)
    end

    def padded_text(cols)
      pad = cols - @count
      return @text if pad.zero?
      return @text[0, cols] if pad.negative?
      @text + (Terminal::BLANK_CHAR * pad)
    end

    def significant?(char, fg, bg, attrs, link)
      return true if fg || bg || link || !attrs.zero?
      char != Terminal::BLANK_CHAR && !char.empty?
    end

    def each_char_cell
      if @lengths
        chars = @text.chars
        pos = 0
        @count.times do |i|
          n = @lengths[i]
          ch = case n
               when 0 then Terminal::CONTINUATION_CHAR
               when 1 then Terminal.intern_char(chars[pos])
               else chars[pos, n].join
               end
          pos += n
          yield i, ch
        end
      elsif @text.ascii_only?
        @count.times { |i| yield i, Terminal::ASCII_CHARS[@text.getbyte(i)] }
      else
        i = 0
        @text.each_char do |ch|
          yield i, Terminal.intern_char(ch)
          i += 1
        end
      end
    end

    def each_styled_cell
      runs = @runs
      j = 0
      left = runs ? runs[0] : @count
      each_char_cell do |c, char|
        while left.zero? && runs && j + 5 < runs.length
          j += 5
          left = runs[j]
        end
        left -= 1
        if runs
          yield c, char, runs[j + 1], runs[j + 2], runs[j + 3], runs[j + 4]
        else
          yield c, char, nil, nil, 0, nil
        end
      end
    end

    def materialize
      cells = Array.new(@count)
      each_char_cell { |i, ch| cells[i] = Terminal::Cell.new(ch, nil, nil, 0, nil) }
      apply_runs(cells)
      @cells = cells
      self.class.retain(self)
      cells
    end

    def apply_runs(cells)
      runs = @runs
      return if runs.nil?
      col = 0
      j = 0
      while j < runs.length
        len = runs[j]
        fg = runs[j + 1]
        bg = runs[j + 2]
        attrs = runs[j + 3]
        link = runs[j + 4]
        if fg || bg || link || !attrs.zero?
          len.times do |k|
            cell = cells[col + k]
            next unless cell
            cell.fg = fg
            cell.bg = bg
            cell.attrs = attrs
            cell.hyperlink = link
          end
        end
        col += len
        j += 5
      end
    end

    EMPTY = new(NO_CELLS, 0).freeze
  end
end
