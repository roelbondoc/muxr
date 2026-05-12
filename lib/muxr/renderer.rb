module Muxr
  # The Renderer composites the Session into a single grid of cells and then
  # emits ANSI escape sequences to write that grid to STDOUT. It compares the
  # new frame against the previous one and only repositions/redraws cells
  # whose contents changed, keeping output volume low between ticks.
  class Renderer
    BORDER_FOCUSED      = [:c256, 11].freeze  # yellow
    BORDER_UNFOCUSED    = [:c256, 8].freeze   # grey
    BORDER_DRAWER_FOCUS = [:c256, 13].freeze  # magenta
    BORDER_DRAWER_IDLE  = [:c256, 5].freeze   # dark magenta
    STATUS_BG           = [:c256, 236].freeze
    STATUS_FG           = [:c256, 252].freeze

    HORIZONTAL = "─".freeze
    VERTICAL   = "│".freeze
    TL         = "┌".freeze
    TR         = "┐".freeze
    BL         = "└".freeze
    BR         = "┘".freeze

    Cell = Struct.new(:char, :fg, :bg, :attrs) do
      def ==(other)
        other.is_a?(Cell) && char == other.char && fg == other.fg && bg == other.bg && attrs == other.attrs
      end
    end

    def initialize(out: $stdout)
      @out = out
      @prev = nil
      @prev_w = 0
      @prev_h = 0
    end

    def enter_alt_screen
      @out.write("\e[?1049h\e[?25l\e[2J\e[H\e[0m")
      @out.flush
      @prev = nil
    end

    def exit_alt_screen
      @out.write("\e[0m\e[?25h\e[?1049l")
      @out.flush
    end

    def reset_frame!
      @prev = nil
    end

    def render(session, input_state: :idle, command_buffer: "", message: nil, help: false)
      w = session.width
      h = session.height
      return if w < 4 || h < 3

      frame = Array.new(h) { Array.new(w) { Cell.new(" ", nil, nil, 0) } }

      compose_panes(frame, session)
      compose_drawer(frame, session) if session.drawer&.visible?
      compose_status_bar(frame, session, input_state: input_state, command_buffer: command_buffer, message: message)
      compose_help(frame, session) if help

      emit_frame(frame, session, input_state: input_state, command_buffer: command_buffer)
    end

    private

    def compose_panes(frame, session)
      win = session.window
      content_area = LayoutManager::Rect.new(0, 0, session.width, session.height - 1)
      rects = LayoutManager.compute(
        win.layout,
        win.panes.length,
        content_area,
        focused_index: win.focused_index,
        master_index: win.master_index
      )

      monocle = win.layout == :monocle

      win.panes.each_with_index do |pane, i|
        rect = rects[i]
        pane.rect = rect
        next unless rect && rect.w >= 3 && rect.h >= 3

        inner_w = rect.w - 2
        inner_h = rect.h - 2
        pane.resize(inner_h, inner_w)

        # In monocle every rect is identical, so drawing all panes would just
        # stack them and let the last-in-array win. Only composite the focused
        # pane; the others stay resized so their PTYs are ready when focus moves.
        next if monocle && i != win.focused_index

        focused = (i == win.focused_index) && !(session.focus_drawer && session.drawer&.visible?)
        title = "##{i + 1}"
        title += "/#{win.panes.length}" if monocle
        title += " ★" if i == win.master_index
        title += " (" + win.layout.to_s + ")" if i == win.focused_index
        if pane.terminal.scrolled_back?
          title += " [scrollback #{pane.terminal.view_offset}/#{pane.terminal.scrollback_size}]"
        end
        draw_box(frame, rect,
                 border: focused ? BORDER_FOCUSED : BORDER_UNFOCUSED,
                 bold_border: focused,
                 title: title,
                 title_focused: focused)
        copy_terminal(frame, pane, rect.x + 1, rect.y + 1)
      end
    end

    def compose_drawer(frame, session)
      drawer = session.drawer
      return unless drawer&.pane

      w = session.width
      h = session.height
      dh = (h * 0.35).round.clamp(5, h - 2)
      dy = h - 1 - dh
      rect = LayoutManager::Rect.new(0, dy, w, dh)
      drawer.pane.rect = rect
      inner_w = rect.w - 2
      inner_h = rect.h - 2
      drawer.pane.resize(inner_h, inner_w)

      # Wipe the area under the drawer so panes don't bleed through.
      (rect.y...(rect.y + rect.h)).each do |y|
        (rect.x...(rect.x + rect.w)).each do |x|
          c = frame[y][x]
          c.char = " "
          c.fg = nil
          c.bg = nil
          c.attrs = 0
        end
      end

      focused = session.focus_drawer
      title = focused ? "Drawer" : "Drawer (hidden focus)"
      term = drawer.pane.terminal
      title += " [scrollback #{term.view_offset}/#{term.scrollback_size}]" if term.scrolled_back?
      draw_box(frame, rect,
               border: focused ? BORDER_DRAWER_FOCUS : BORDER_DRAWER_IDLE,
               bold_border: true,
               title: title,
               title_focused: focused)
      copy_terminal(frame, drawer.pane, rect.x + 1, rect.y + 1)
    end

    def compose_status_bar(frame, session, input_state:, command_buffer:, message:)
      y = session.height - 1
      w = session.width
      win = session.window
      drawer_state =
        if session.drawer.nil?           then "off"
        elsif session.drawer.visible?    then "shown"
        else                                  "hidden"
        end

      left = " [#{session.name}]"
      left << " panes:#{win.panes.length}"
      left << " layout:#{win.layout}"
      focused_label =
        if session.focus_drawer && session.drawer&.visible?
          "drawer"
        elsif win.panes.empty?
          "-"
        else
          "##{win.focused_index + 1}"
        end
      left << " focused:#{focused_label}"
      left << " drawer:#{drawer_state} "

      right = " muxr ^a ? "

      bar = (left + " " * w)[0, w - right.length] + right
      bar = bar[0, w]

      bar.each_char.with_index do |ch, x|
        c = frame[y][x]
        c.char = ch
        c.fg = STATUS_FG
        c.bg = STATUS_BG
        c.attrs = 0
      end

      if input_state == :command
        overlay = ":#{command_buffer}"
        overlay = overlay[0, w]
        overlay.each_char.with_index do |ch, x|
          c = frame[y][x]
          c.char = ch
          c.fg = [:c256, 232]
          c.bg = [:c256, 226]
          c.attrs = Terminal::BOLD
        end
        (overlay.length...w).each do |x|
          c = frame[y][x]
          c.char = " "
          c.fg = nil
          c.bg = [:c256, 226]
          c.attrs = 0
        end
      elsif input_state == :scrollback
        overlay = " SCROLLBACK  j/k line  d/u half  f/b page  g/G top/bot  v select  q quit "
        overlay = overlay[0, w]
        overlay.each_char.with_index do |ch, x|
          c = frame[y][x]
          c.char = ch
          c.fg = [:c256, 232]
          c.bg = [:c256, 214]
          c.attrs = Terminal::BOLD
        end
        (overlay.length...w).each do |x|
          c = frame[y][x]
          c.char = " "
          c.fg = nil
          c.bg = [:c256, 214]
          c.attrs = 0
        end
      elsif input_state == :selection
        mode = nil
        focused = session.window.focused_pane
        if focused && focused.terminal.selection_active?
          mode = focused.terminal.selection_mode == :block ? "BLOCK" : "CHAR"
        end
        label = mode ? "SELECTION/#{mode}" : "SELECTION (cursor)"
        overlay = " #{label}  h/j/k/l move  v char  C-v block  y/Enter yank  q cancel "
        overlay = overlay[0, w]
        overlay.each_char.with_index do |ch, x|
          c = frame[y][x]
          c.char = ch
          c.fg = [:c256, 232]
          c.bg = [:c256, 156]
          c.attrs = Terminal::BOLD
        end
        (overlay.length...w).each do |x|
          c = frame[y][x]
          c.char = " "
          c.fg = nil
          c.bg = [:c256, 156]
          c.attrs = 0
        end
      elsif message
        msg = " #{message} "
        start = [w - msg.length, 0].max
        msg.each_char.with_index do |ch, i|
          x = start + i
          next unless x < w
          c = frame[y][x]
          c.char = ch
          c.fg = [:c256, 15]
          c.bg = [:c256, 28]
          c.attrs = Terminal::BOLD
        end
      end
    end

    HELP_LINES = [
      "muxr — keybindings",
      "",
      "  C-a c       new pane",
      "  C-a n / p   next / prev pane",
      "  C-a a       toggle to previously focused pane",
      "  C-a 1..9    jump to pane by number",
      "  C-a k       close focused pane",
      "  C-a Tab     cycle layout (tall → grid → monocle)",
      "  C-a Enter   promote focused pane to master",
      "  C-a ~       toggle drawer",
      "  C-a [       enter scrollback (j/k d/u f g/G C-b/C-f; v→cursor, q quits)",
      "              cursor: v select, C-v block, y yank, q cancel",
      "              motions: h/j/k/l 0/^/$ w/e/b W/E/B H/M/L g/G",
      "  C-a ]       paste internal copy buffer",
      "  C-a d       detach (server keeps running)",
      "  C-a q       kill session (asks y/n)",
      "  C-a :       command prompt",
      "  C-a ?       toggle this help",
      "  C-a C-a     send literal C-a",
      "",
      "Commands: layout {tall|grid|monocle}, drawer {toggle|show|hide|reset},",
      "          save, restore, sessions, quit, new, close, next, prev",
      "",
      "press any key to dismiss"
    ].freeze

    def compose_help(frame, session)
      w = session.width
      h = session.height
      max_len = HELP_LINES.map(&:length).max
      box_w = [max_len + 4, w - 4].min
      box_h = [HELP_LINES.length + 2, h - 4].min
      x = (w - box_w) / 2
      y = (h - box_h) / 2
      rect = LayoutManager::Rect.new(x, y, box_w, box_h)

      (rect.y...(rect.y + rect.h)).each do |yy|
        (rect.x...(rect.x + rect.w)).each do |xx|
          c = frame[yy][xx]
          c.char = " "
          c.fg = [:c256, 252]
          c.bg = [:c256, 236]
          c.attrs = 0
        end
      end
      draw_box(frame, rect, border: [:c256, 51], bold_border: true, title: "Help", title_focused: true)

      HELP_LINES.first(box_h - 2).each_with_index do |line, i|
        line[0, box_w - 4].chars.each_with_index do |ch, j|
          c = frame[rect.y + 1 + i][rect.x + 2 + j]
          c.char = ch
          c.fg = [:c256, 252]
          c.bg = [:c256, 236]
          c.attrs = i == 0 ? Terminal::BOLD : 0
        end
      end
    end

    def draw_box(frame, rect, border:, bold_border:, title: nil, title_focused: false)
      attrs = bold_border ? Terminal::BOLD : 0
      x2 = rect.x + rect.w - 1
      y2 = rect.y + rect.h - 1
      (rect.x..x2).each do |x|
        set_cell(frame, rect.y, x, HORIZONTAL, fg: border, attrs: attrs)
        set_cell(frame, y2, x, HORIZONTAL, fg: border, attrs: attrs)
      end
      (rect.y..y2).each do |y|
        set_cell(frame, y, rect.x, VERTICAL, fg: border, attrs: attrs)
        set_cell(frame, y, x2, VERTICAL, fg: border, attrs: attrs)
      end
      set_cell(frame, rect.y, rect.x, TL, fg: border, attrs: attrs)
      set_cell(frame, rect.y, x2, TR, fg: border, attrs: attrs)
      set_cell(frame, y2, rect.x, BL, fg: border, attrs: attrs)
      set_cell(frame, y2, x2, BR, fg: border, attrs: attrs)

      if title && rect.w >= title.length + 4
        text = " #{title} "
        title_attrs = title_focused ? Terminal::BOLD : 0
        text.each_char.with_index do |ch, i|
          set_cell(frame, rect.y, rect.x + 2 + i, ch, fg: border, attrs: title_attrs)
        end
      end
    end

    def copy_terminal(frame, pane, dst_x, dst_y)
      term = pane.terminal
      rows = term.rows
      cols = term.cols
      selection = term.selection_active?
      rows.times do |r|
        fy = dst_y + r
        next if fy < 0 || fy >= frame.length
        cols.times do |c|
          fx = dst_x + c
          next if fx < 0 || fx >= frame[0].length
          src = term.visible_cell(r, c)
          dst = frame[fy][fx]
          dst.char = src.char
          dst.fg = src.fg
          dst.bg = src.bg
          dst.attrs = src.attrs
          dst.attrs |= Terminal::REVERSE if selection && term.selected_at_visible?(r, c)
        end
      end
    end

    def set_cell(frame, y, x, char, fg: nil, bg: nil, attrs: 0)
      return if y < 0 || y >= frame.length
      return if x < 0 || x >= frame[0].length
      c = frame[y][x]
      c.char = char
      c.fg = fg
      c.bg = bg
      c.attrs = attrs
    end

    def emit_frame(frame, session, input_state:, command_buffer:)
      # \e[?2026h enters synchronized-output mode so terminals that support it
      # (Ghostty, kitty, iTerm2 ≥3.5, WezTerm, Alacritty ≥0.13, foot) present
      # the whole frame atomically instead of repainting incrementally as bytes
      # arrive. \e[?25l hides the cursor for the duration of the diff so it
      # doesn't smear across every \e[y;xH position; cursor_position turns it
      # back on at the final spot.
      out = String.new("\e[?2026h\e[?25l\e[0m")
      same_size = @prev && @prev_w == frame[0].length && @prev_h == frame.length
      cur_fg = :unset
      cur_bg = :unset
      cur_attrs = :unset
      last_y = nil
      last_x = nil

      frame.each_with_index do |row, y|
        row.each_with_index do |cell, x|
          if same_size && @prev[y][x] == cell
            next
          end
          if last_y != y || last_x != x
            out << "\e[#{y + 1};#{x + 1}H"
          end
          unless cell.fg == cur_fg && cell.bg == cur_bg && cell.attrs == cur_attrs
            out << sgr(cell)
            cur_fg = cell.fg
            cur_bg = cell.bg
            cur_attrs = cell.attrs
          end
          out << cell.char
          last_y = y
          last_x = x + cell.char.length
        end
      end
      out << "\e[0m"
      out << cursor_position(session, input_state: input_state, command_buffer: command_buffer)
      out << "\e[?2026l"
      @out.write(out)
      @out.flush
      @prev = frame.map { |row| row.map(&:dup) }
      @prev_w = frame[0].length
      @prev_h = frame.length
    end

    def cursor_position(session, input_state:, command_buffer:)
      if input_state == :command
        col = 1 + command_buffer.length + 1 # ':' + buffer
        return "\e[#{session.height};#{col}H\e[?25h"
      end

      target =
        if session.focus_drawer && session.drawer&.visible? && session.drawer.pane
          session.drawer.pane
        else
          session.window.focused_pane
        end
      return "\e[?25l" unless target&.rect

      term = target.terminal
      rect = target.rect
      if input_state == :selection
        pos = term.selection_cursor_visible
        return "\e[?25l" unless pos
        row = rect.y + 1 + pos[0] + 1
        col = rect.x + 1 + pos[1] + 1
        return "\e[#{row};#{col}H\e[?25h"
      end
      return "\e[?25l" if term.scrolled_back?
      row = rect.y + 1 + term.cursor_row + 1
      col = rect.x + 1 + term.cursor_col + 1
      "\e[#{row};#{col}H\e[?25h"
    end

    def sgr(cell)
      parts = ["0"]
      attrs = cell.attrs.to_i
      parts << "1" if (attrs & Terminal::BOLD) != 0
      parts << "2" if (attrs & Terminal::DIM) != 0
      parts << "4" if (attrs & Terminal::UNDERLINE) != 0
      parts << "7" if (attrs & Terminal::REVERSE) != 0
      append_color(parts, cell.fg, true)
      append_color(parts, cell.bg, false)
      "\e[#{parts.join(';')}m"
    end

    def append_color(parts, color, fg)
      return if color.nil?
      case color
      when Integer
        if color < 8
          parts << ((fg ? 30 : 40) + color).to_s
        else
          parts << ((fg ? 90 : 100) + (color - 8)).to_s
        end
      when Array
        case color[0]
        when :c256
          parts << "#{fg ? 38 : 48};5;#{color[1]}"
        when :rgb
          parts << "#{fg ? 38 : 48};2;#{color[1]};#{color[2]};#{color[3]}"
        end
      end
    end
  end
end
