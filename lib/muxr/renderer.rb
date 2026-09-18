module Muxr
  # The Renderer composites the Session into a single grid of cells and then
  # emits ANSI escape sequences to write that grid to STDOUT. It compares the
  # new frame against the previous one and only repositions/redraws cells
  # whose contents changed, keeping output volume low between ticks.
  class Renderer
    BORDER_FOCUSED      = [:c256, 11].freeze  # yellow (fallback when no mode color)
    BORDER_UNFOCUSED    = [:c256, 8].freeze   # grey
    BORDER_DRAWER_FOCUS = [:c256, 13].freeze  # magenta
    BORDER_DRAWER_IDLE  = [:c256, 5].freeze   # dark magenta
    STATUS_BG           = [:c256, 236].freeze
    STATUS_FG           = [:c256, 252].freeze

    # Vim-style mode palette. Used in two places: the focused pane border
    # (so the user can see at a glance what mode they're in) and the
    # [MODE] chip in the status bar (same color, smaller real estate).
    # :prefix maps to the same green as :passthrough because :prefix is a
    # transient sub-state under passthrough — sharing the color avoids a
    # one-frame border flicker when pressing Ctrl-a.
    MODE_COLOR = {
      normal:       [:c256, 51].freeze,   # cyan
      passthrough:  [:c256, 42].freeze,   # green
      prefix:       [:c256, 42].freeze,   # green (passthrough sub-state)
      command:      [:c256, 226].freeze,  # yellow
      scrollback:   [:c256, 214].freeze,  # orange
      search:       [:c256, 214].freeze,  # orange (scrollback sub-state)
      selection:    [:c256, 201].freeze,  # magenta
      confirm_quit:  [:c256, 196].freeze, # red
      confirm_close: [:c256, 196].freeze, # red
      help:          [:c256, 39].freeze,  # blue
      pane_picker:   [:c256, 39].freeze   # blue
    }.freeze

    # Background applied to cells that match the active scrollback search.
    # Bright enough to stand out over typical foreground SGRs while leaving
    # the original glyph readable.
    SEARCH_MATCH_BG = [:c256, 226].freeze # yellow
    SEARCH_MATCH_FG = [:c256, 16].freeze  # black

    HORIZONTAL = "─".freeze
    VERTICAL   = "│".freeze
    TL         = "┌".freeze
    TR         = "┐".freeze
    BL         = "└".freeze
    BR         = "┘".freeze

    Cell = Struct.new(:char, :fg, :bg, :attrs, :hyperlink) do
      def ==(other)
        other.is_a?(Cell) && char == other.char && fg == other.fg && bg == other.bg && attrs == other.attrs && hyperlink == other.hyperlink
      end
    end

    def initialize(out: $stdout)
      @out = out
      @prev = nil
      @prev_w = 0
      @prev_h = 0
      @scroll_source = :ring
    end

    def enter_alt_screen
      # Close any stale OSC 8 hyperlink the outer terminal might be carrying
      # from before we attached, so the first frame's run-tracker matches
      # reality.
      @out.write("\e[?1049h\e[?25l\e[2J\e[H\e[0m\e]8;;\e\\")
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

    def render(session, input_state: :normal, scroll_source: :ring, command_buffer: "", command_completions: nil, search_buffer: "", search_direction: :forward, message: nil, help: false, picker: nil)
      w = session.width
      h = session.height
      return if w < 4 || h < 3

      frame = Array.new(h) { Array.new(w) { Cell.new(" ", nil, nil, 0, nil) } }

      @scroll_source = scroll_source
      compose_panes(frame, session, input_state: input_state)
      compose_drawer(frame, session, input_state: input_state) if session.drawer&.visible?
      compose_status_bar(
        frame, session,
        input_state: input_state,
        command_buffer: command_buffer,
        command_completions: command_completions,
        search_buffer: search_buffer,
        search_direction: search_direction,
        message: message
      )
      compose_help(frame, session) if help
      compose_pane_picker(frame, session, picker) if picker

      emit_frame(frame, session, input_state: input_state, command_buffer: command_buffer, search_buffer: search_buffer)
    end

    private

    def content_area(session)
      LayoutManager::Rect.new(0, 0, session.width, session.height - 1)
    end

    def layout_label(win, session)
      return win.layout.to_s unless win.layout == :auto
      "auto:#{LayoutManager.resolve(:auto, content_area(session))}"
    end

    def compose_panes(frame, session, input_state: :normal)
      win = session.window
      area = content_area(session)
      layout = LayoutManager.resolve(win.layout, area)
      rects = LayoutManager.compute(
        layout,
        win.panes.length,
        area,
        focused_index: win.focused_index,
        master_index: win.master_index
      )

      monocle = layout == :monocle

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
        # Stable id sits after the slot number so monocle reads "#1/3 a3f9b2".
        # respond_to? guard keeps renderer tests (which use simple struct fakes)
        # from blowing up when a pane stand-in doesn't implement #id.
        title += " #{pane.id}" if pane.respond_to?(:id) && pane.id.is_a?(String)
        title += " [P]" if pane.respond_to?(:private?) && pane.private?
        # A borrowed pane names the session that actually owns its shell, so
        # "who am I about to type at" is answerable without leaving the layout.
        title += " @#{pane.origin}" if pane.respond_to?(:origin) && pane.origin
        title += " ★" if i == win.master_index
        # Foreground command (e.g. "npm test", "vim"). Set by the poller
        # thread; nil when the shell itself is foreground. Truncate so a
        # long invocation doesn't push the title past what draw_box will
        # render — draw_box silently drops titles that don't fit.
        if pane.respond_to?(:foreground_command) && pane.foreground_command
          cmd = pane.foreground_command.to_s[0, 16]
          title += " · #{cmd}"
        end
        if pane.terminal.scrolled_back?
          title += " [scrollback #{pane.terminal.view_offset}/#{pane.terminal.scrollback_size}]"
        end
        draw_box(frame, rect,
                 border: focused ? mode_color(input_state) : BORDER_UNFOCUSED,
                 bold_border: focused,
                 title: title,
                 title_focused: focused)
        # Mode chip lives in the top-right corner of the focused container
        # (this pane, or the drawer — see compose_drawer). Showing it on
        # the same edge as the title but on the opposite side keeps both
        # readable without one crowding the other.
        draw_mode_chip(frame, rect, input_state, title) if focused
        copy_terminal(frame, pane, rect)
      end
    end

    def compose_drawer(frame, session, input_state: :normal)
      drawer = session.drawer
      return unless drawer&.pane

      w = session.width
      h = session.height
      # Drawer height is the larger of "16 rows" or 35% of the screen — the
      # 35% rule is fine on tall terminals but uselessly small on short ones,
      # so we floor it at 16 to keep the drawer practical. Final clamp keeps
      # room for panes + status bar on very small terminals.
      dh = [16, (h * 0.35).round].max.clamp(5, h - 2)
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
      draw_mode_chip(frame, rect, input_state, title) if focused
      copy_terminal(frame, drawer.pane, rect)
    end

    def mode_color(input_state)
      MODE_COLOR[input_state] || BORDER_FOCUSED
    end

    # Paint the " [MODE] " chip on the top border, hugging the right corner.
    # Skipped when there isn't at least one column of breathing room between
    # the title (anchored at the top-left) and the chip — otherwise long
    # titles + a wide chip would overdraw each other and produce garbage.
    def draw_mode_chip(frame, rect, input_state, title)
      chip = " [#{mode_label(input_state)}] "
      chip_start = rect.x + rect.w - 1 - chip.length
      title_text = " #{title} "
      title_end = rect.x + 2 + title_text.length - 1
      return if chip_start <= title_end + 1
      chip_color = mode_color(input_state)
      chip.each_char.with_index do |ch, j|
        set_cell(frame, rect.y, chip_start + j, ch, fg: chip_color, attrs: Terminal::BOLD)
      end
    end

    # Two-letter-ish mode label shown in the leftmost slot of the status bar.
    # Lets the user see at a glance whether single-key bindings are active
    # (NORMAL) or every key passes through to the focused pane (PASS).
    def mode_label(input_state)
      case input_state
      when :normal       then "NORMAL"
      when :passthrough  then "PASS"
      when :prefix       then "^A"
      when :command      then "CMD"
      when :scrollback   then @scroll_source == :app ? "SCROLL:APP" : "SCROLL"
      when :search       then "SEARCH"
      when :selection    then "SEL"
      when :confirm_quit  then "QUIT?"
      when :confirm_close then "CLOSE?"
      when :help          then "HELP"
      when :pane_picker   then "ATTACH"
      else                    "?"
      end
    end

    def compose_status_bar(frame, session, input_state:, command_buffer:, command_completions: nil, search_buffer: "", search_direction: :forward, message: nil)
      y = session.height - 1
      w = session.width
      win = session.window
      drawer_state =
        if session.drawer.nil?           then "off"
        elsif session.drawer.visible?    then "shown"
        else                                  "hidden"
        end

      left = " [#{mode_label(input_state)}]"
      left << " [#{session.name}]"
      left << " panes:#{win.panes.length}"
      left << " layout:#{layout_label(win, session)}"
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

      # Recolor the leading "[MODE]" chip in the mode's accent color. The
      # chip lives at offset 1 (after one leading space) and runs for
      # bracket+label+bracket characters. Full-row overlays below will
      # overwrite this when active (command/scrollback/selection) — that's
      # fine, those modes already convey themselves loudly.
      chip = "[#{mode_label(input_state)}]"
      chip_color = mode_color(input_state)
      chip_start = 1
      chip_end = [chip_start + chip.length, w].min
      (chip_start...chip_end).each do |x|
        c = frame[y][x]
        c.fg = chip_color
        c.attrs |= Terminal::BOLD
      end

      if input_state == :command
        prompt = ":#{command_buffer}"
        # Ambiguous Tab-completion candidates trail the prompt in a muted
        # color, e.g. `:layout s      spiral stack`. Cosmetic — the cursor
        # stays at the end of the buffer (see #cursor_position).
        hint = command_completions && !command_completions.empty? ? "    #{command_completions.join(" ")}" : ""
        overlay = (prompt + hint)[0, w]
        overlay.each_char.with_index do |ch, x|
          c = frame[y][x]
          c.char = ch
          c.fg = x < prompt.length ? [:c256, 232] : [:c256, 240]
          c.bg = [:c256, 226]
          c.attrs = x < prompt.length ? Terminal::BOLD : 0
        end
        (overlay.length...w).each do |x|
          c = frame[y][x]
          c.char = " "
          c.fg = nil
          c.bg = [:c256, 226]
          c.attrs = 0
        end
      elsif input_state == :scrollback
        overlay =
          if @scroll_source == :app
            " APP SCROLL  ↑↓/j/k line  d/u half  f/b page  v select  Tab muxr history  q quit "
          else
            " SCROLLBACK  ↑↓/j/k line  d/u half  f/b page  g/G top/bot  / search  n/N next/prev  v select  Tab app scroll  q quit "
          end
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
      elsif input_state == :search
        prefix = search_direction == :backward ? "?" : "/"
        overlay = "#{prefix}#{search_buffer}"
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
        overlay = " #{label}  h/j/k/l move  v/space char  C-v block  y/Enter yank  q cancel "
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
      end

      draw_status_message(frame, y, w, message) if message
    end

    def draw_status_message(frame, y, w, message)
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

    HELP_LINES = [
      "muxr — keybindings",
      "",
      "NORMAL mode (default; no prefix)",
      "  h / j / k / l   focus pane left / down / up / right",
      "  H / J / K / L   move pane left / down / up / right",
      "  i               drop into passthrough mode",
      "  c / x           new / close pane (close asks y/n)",
      "  t / w / g / m   layout: tall / wide / grid / monocle",
      "  | - f e S       layout: columns / rows / spiral / centered / stack",
      "  F               layout: auto (spiral on a roomy screen, else stack)",
      "  Tab / Enter     cycle layout / promote to master",
      "  a / 1..9        last pane / jump by number",
      "  r               refresh / redraw (fixes a corrupted pane)",
      "  s               enter scrollback",
      "  ~ / C / P       drawer / Claude drawer / toggle private",
      "  A               share or move a pane from another muxr session",
      "  : / ?           command prompt / toggle this help",
      "  ] / d / q       paste buffer / detach / kill session",
      "",
      "PASSTHROUGH mode (keys reach the focused pane; prefix is Ctrl-a)",
      "  C-a Esc         return to normal mode",
      "  C-a c / x       new / close pane (close asks y/n)",
      "  C-a Tab Enter   cycle layout / promote master",
      "  C-a n / p / a   next / prev / last pane",
      "  C-a r           refresh / redraw (fixes a corrupted pane)",
      "  C-a [ ]         scrollback / paste buffer",
      "  C-a A           share or move a pane from another muxr session",
      "  C-a C-a         send literal Ctrl-a to focused pane",
      "",
      "SCROLLBACK mode (pane-bound: follows you as you switch panes)",
      "  j/k ↑/↓ d/u f/b g/G  scroll  C-b/C-f page  v→cursor",
      "  Tab  switch between the app's own scroll and muxr's history",
      "       (C-a [ starts on the app's scroll when the pane has one)",
      "  / search-fwd  ? search-back  n/N next/prev match",
      "  C-a n/p/a/1-9   switch pane, stay in scrollback (each keeps its pos)",
      "  i   insert here (keeps scroll pos)   q/Esc  exit to live bottom",
      "  cursor: h/j/k/l 0/^/$ w/e/b W/E/B H/M/L g/G",
      "          v select, C-v block, y/Enter yank (stays in scrollback)",
      "          q/Esc cancel   C-a n/p/a/1-9 switch pane",
      "",
      "COMMAND prompt (: to open;  Tab completes,  Esc/C-c cancels)",
      "Commands: layout {tall|wide|columns|rows|grid|spiral|centered|stack|monocle|auto},",
      "          drawer {toggle|show|hide|reset},",
      "          claude, save, restore, sessions, attach, quit, new, close, next, prev",
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

    PICKER_BG          = [:c256, 236].freeze
    PICKER_FG          = [:c256, 252].freeze
    PICKER_SESSION_FG  = [:c256, 45].freeze
    PICKER_DIM_FG      = [:c256, 245].freeze
    PICKER_SELECTED_BG = [:c256, 24].freeze
    PICKER_BORDER      = [:c256, 39].freeze
    PICKER_HINT        = "j/k select · Enter share · m move here · Esc cancel".freeze

    def compose_pane_picker(frame, session, picker)
      lines = picker_lines(picker)
      w = session.width
      h = session.height
      box_w = [lines.map { |l| l[0].length }.max + 4, PICKER_HINT.length + 4, 30].max
      box_w = [box_w, w - 4].min
      box_h = [lines.length + 4, h - 4].min
      rect = LayoutManager::Rect.new((w - box_w) / 2, (h - box_h) / 2, box_w, box_h)

      (rect.y...(rect.y + rect.h)).each do |yy|
        (rect.x...(rect.x + rect.w)).each do |xx|
          set_cell(frame, yy, xx, " ", fg: PICKER_FG, bg: PICKER_BG)
        end
      end
      draw_box(frame, rect, border: PICKER_BORDER, bold_border: true,
               title: "Attach pane", title_focused: true)

      inner_w = box_w - 4
      visible = picker_window(lines, picker.index, box_h - 4)
      visible.each_with_index do |(text, fg, selected), i|
        bg = selected ? PICKER_SELECTED_BG : PICKER_BG
        row = text[0, inner_w].ljust(inner_w)
        row.chars.each_with_index do |ch, j|
          set_cell(frame, rect.y + 1 + i, rect.x + 2 + j, ch,
                   fg: fg, bg: bg, attrs: selected ? Terminal::BOLD : 0)
        end
      end

      hint_y = rect.y + rect.h - 2
      PICKER_HINT[0, inner_w].chars.each_with_index do |ch, j|
        set_cell(frame, hint_y, rect.x + 2 + j, ch, fg: PICKER_DIM_FG, bg: PICKER_BG)
      end
    end

    def picker_lines(picker)
      picker.rows.each_with_index.map do |row, i|
        selected = i == picker.index
        if row.selectable?
          entry = row.entry
          text = "  ##{entry.slot} #{entry.pane_id}"
          text += "  #{shorten_path(entry.cwd)}" if entry.cwd
          [text, PICKER_FG, selected]
        else
          ["#{row.session}", PICKER_SESSION_FG, false]
        end
      end
    end

    # Scroll the list so the selected row stays on screen without moving more
    # than it has to — the cursor sits still until it reaches an edge.
    def picker_window(lines, index, height)
      return lines if height <= 0 || lines.length <= height
      start = (index - height / 2).clamp(0, lines.length - height)
      lines[start, height]
    end

    def shorten_path(path)
      home = Dir.home
      path.to_s.start_with?(home) ? path.to_s.sub(home, "~") : path.to_s
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

    # Paint a pane's grid into the inside of its box. Clipped to the box, not
    # just to the frame: a mirrored pane's grid is sized by the session that
    # owns it, so it can be a row or column out of step with the box we drew
    # for it here, and overrunning would eat the border.
    def copy_terminal(frame, pane, rect)
      term = pane.terminal
      dst_x = rect.x + 1
      dst_y = rect.y + 1
      rows = [term.rows, rect.h - 2].min
      cols = [term.cols, rect.w - 2].min
      selection = term.selection_active?
      search = term.search_active?
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
          if search && term.cell_in_match?(r, c)
            # Highlight wins over the cell's own bg so matches stay visible
            # across whatever SGR the underlying program was using. Selection
            # still applies on top via REVERSE below.
            dst.fg = SEARCH_MATCH_FG
            dst.bg = SEARCH_MATCH_BG
          end
          dst.attrs |= Terminal::REVERSE if selection && term.selected_at_visible?(r, c)
          dst.hyperlink = src.hyperlink
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

    def emit_frame(frame, session, input_state:, command_buffer:, search_buffer: "")
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
      # We close any open hyperlink at end-of-frame, so the outer terminal
      # always starts a new frame in the "no hyperlink" state.
      cur_hyperlink = nil
      last_y = nil
      last_x = nil

      frame.each_with_index do |row, y|
        # When the previous glyph on this row had an uncertain display width
        # (set below), the outer terminal may have drawn it two columns wide and
        # stolen the column to its right. Force that next cell to repaint even
        # if our model says it's unchanged, so a phantom second half can't
        # linger until a full repaint. Reset per row — a steal can't cross a
        # line boundary.
        force_next = false
        row.each_with_index do |cell, x|
          if same_size && @prev[y][x] == cell && !force_next
            next
          end
          force_next = false
          # The right half of a wide glyph (char "") is painted by its lead
          # cell to the left, which spans both columns in the outer terminal.
          # Emitting anything here would clobber that glyph, so skip it — and
          # leave last_x untouched, since we didn't move the outer cursor.
          next if cell.char.empty?
          if last_y != y || last_x != x
            out << "\e[#{y + 1};#{x + 1}H"
          end
          unless cell.fg == cur_fg && cell.bg == cur_bg && cell.attrs == cur_attrs
            out << sgr(cell)
            cur_fg = cell.fg
            cur_bg = cell.bg
            cur_attrs = cell.attrs
          end
          if cell.hyperlink != cur_hyperlink
            out << "\e]8;;\e\\" if cur_hyperlink
            out << "\e]#{cell.hyperlink}\e\\" if cell.hyperlink
            cur_hyperlink = cell.hyperlink
          end
          out << cell.char
          last_y = y
          if contiguous_after?(cell.char)
            # Advance by the glyph's display width, not its codepoint count: a
            # wide char ("中") moves the outer cursor two columns though it's
            # one codepoint, and a base+combining cell ("é") moves one though
            # it's two. Keeping last_x in sync with the real cursor lets the
            # next cell skip a redundant CUP.
            last_x = x + Terminal.char_width(cell.char.ord)
          else
            # The outer terminal might advance its cursor by a different number
            # of columns than we think for this glyph — force an absolute
            # reposition for the next cell so the disagreement can't cascade.
            last_x = nil
            # For a glyph WE model as a single column but whose real width the
            # outer terminal may stretch to two (East Asian Ambiguous symbols
            # like ·, …, ●, and the ⏺/✻/❯ glyphs Claude Code animates in place),
            # also force the next cell to repaint. Otherwise an in-place spinner
            # leaves its unchanged neighbour skipped by the diff, and the glyph's
            # phantom second half sits on that column until a manual refresh.
            # Width-2 glyphs (CJK/emoji) own their continuation cell already, so
            # they don't need this — only the model-1/draw-2 mismatch does.
            force_next = true if Terminal.char_width(cell.char.ord) == 1
          end
        end
      end
      out << "\e]8;;\e\\" if cur_hyperlink
      out << "\e[0m"
      out << cursor_position(session, input_state: input_state, command_buffer: command_buffer, search_buffer: search_buffer)
      out << "\e[?2026l"
      @out.write(out)
      @out.flush
      @prev = frame.map { |row| row.map(&:dup) }
      @prev_w = frame[0].length
      @prev_h = frame.length
    end

    # Whether we can trust the outer terminal's cursor to be exactly one
    # display-width past this glyph, so the next contiguous cell needs no
    # cursor-position escape. Safe for ASCII (always one column), and for the
    # box-drawing / block-element band 0x2500–0x259F unless the width probe
    # measured this terminal drawing that band wide — we emit a lot of those for
    # borders, so keeping them contiguous matters when it's sound. Everything
    # else non-ASCII —
    # CJK, emoji, and East Asian Ambiguous symbols like ·, …, ●, arrows, and
    # the ⏺/✻/❯ glyphs Claude Code's UI is full of — can be drawn two columns
    # wide by some terminals. We can't know which, so we force an absolute
    # reposition after them: a width disagreement then clips a single glyph
    # instead of shifting the whole rest of the line. A base+combining cell
    # (multi-codepoint) is treated the same way out of caution.
    def contiguous_after?(char)
      return false if char.length > 1
      cp = char.ord
      return true if cp < 0x80
      !Terminal.box_wide && Terminal::BOX_RANGES.any? { |r| r.cover?(cp) }
    end

    def cursor_position(session, input_state:, command_buffer:, search_buffer: "")
      return "\e[?25l" if input_state == :pane_picker
      if input_state == :command
        col = 1 + command_buffer.length + 1 # ':' + buffer
        return "\e[#{session.height};#{col}H\e[?25h"
      end
      if input_state == :search
        col = 1 + search_buffer.length + 1 # '/' or '?' + buffer
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
      # Honor the inner program's own cursor visibility (DECTCEM): Claude Code
      # and other Ink UIs hide the cursor while rendering and only show it at a
      # text prompt. Painting our block at its last write position otherwise
      # leaves a phantom cursor smeared across the animating UI.
      return "\e[?25l" unless term.cursor_visible?
      row = rect.y + 1 + term.cursor_row + 1
      col = rect.x + 1 + term.cursor_col + 1
      "\e[#{row};#{col}H\e[?25h"
    end

    def sgr(cell)
      Terminal.sgr(cell)
    end
  end
end
