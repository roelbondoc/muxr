require "securerandom"

module Muxr
  # A Pane bundles a Terminal emulator buffer with the PTYProcess running the
  # shell that feeds it. The Window keeps a list of panes; the Renderer asks
  # each pane for its current grid contents and cursor position.
  #
  # Each pane has a stable 6-hex id generated at creation. The id survives
  # promote_to_master and other array reshuffles (since it lives on the Pane,
  # not on the index) and is persisted in the session JSON so it also survives
  # a full cold restart. The drawer pane uses the symbol `:drawer` as its id;
  # the MCP control surface treats it specially and never lists it under
  # `panes.list`.
  class Pane
    attr_reader :id, :terminal, :process
    attr_accessor :rect
    # "<session>:<pane id>" when this pane mirrors a pane owned by another muxr
    # server; nil for a locally-owned PTY.
    attr_accessor :origin
    # Smallest viewport any remote mirror is showing this pane through, as
    # [rows, cols], or nil when nobody is mirroring.
    attr_accessor :mirror_size
    # Last value written by Application's foreground poller thread. nil when
    # the shell itself is foreground (the common empty-prompt case) or when
    # the lookup hasn't run / couldn't read. Renderer surfaces this in the
    # pane title.
    attr_accessor :foreground_command

    def initialize(id: nil, rows: 24, cols: 80, cwd: nil, command: nil, env_overrides: nil, process: nil)
      @id = id || SecureRandom.hex(3)
      @rows = rows
      @cols = cols
      @terminal = Terminal.new(rows: rows, cols: cols)
      @process = process || PTYProcess.new(
        rows: rows,
        cols: cols,
        cwd: cwd,
        command: command,
        env_overrides: env_overrides || {}
      )
      @rect = nil
      @initial_cwd = cwd || @process.cwd
      @private_flag = false
      @foreground_command = nil
      @origin = nil
      @mirror_size = nil
    end

    def mirror?
      @process.respond_to?(:mirror?) && @process.mirror?
    end

    def pid
      @process.pid
    end

    # Private panes are invisible to the MCP control surface — their cwd is
    # stripped from panes.list and pane.read/send_input/run/subscribe/kill
    # all refuse. Toggled by the human via Ctrl-a P or `:private`. Never
    # settable from the control surface itself (so a misbehaving MCP client
    # can't unmark a pane it shouldn't see).
    def private?
      @private_flag
    end

    def mark_private!
      @private_flag = true
    end

    def mark_public!
      @private_flag = false
    end

    def toggle_private!
      @private_flag = !@private_flag
    end

    def io
      @process.io
    end

    def writer_io
      @process.writer_io
    end

    def pending_write?
      @process.pending_write?
    end

    def drain_writes
      @process.drain
    end

    def write(data)
      @process.write(data)
    end

    # Drain everything currently in the PTY's kernel read buffer, feeding
    # each chunk to the Terminal. Coalescing reads here means we render once
    # per fully-formed output burst (fzf re-render, vim cursor+status redraw,
    # etc.) instead of once per ~8 KiB chunk — the latter shows intermediate
    # frames and is the main source of in-pane flicker. Bounded by a byte cap
    # so a runaway producer can't starve other panes on a single tick.
    READ_BUDGET = 1 << 20 # 1 MiB
    def read_from_pty
      total = 0
      while total < READ_BUDGET
        chunk = @process.read_nonblock
        break unless chunk
        @terminal.feed(chunk)
        yield chunk if block_given?
        total += chunk.bytesize
      end
      # The emulator may owe the inner program a reply (DSR / CPR — see
      # Terminal#take_pending_replies!). Ship it back through the PTY's
      # input side as if it had been typed. Failure here is non-fatal: the
      # process can have exited between read and write. A mirror stays quiet:
      # the pane's owner already answered, and a second answer would reach the
      # program as spurious keystrokes.
      if (reply = @terminal.take_pending_replies!) && !mirror?
        begin
          @process.write(reply)
        rescue Errno::EIO, Errno::EPIPE
        end
      end
      total.positive? ? total : nil
    end

    # A mirror's grid is sized by the pane's owner: the relayed stream carries
    # absolute cursor addresses for *that* geometry. We only forward the
    # viewport we can offer and wait for the size the owner settles on.
    def resize(rows, cols)
      return @process.resize(rows, cols) if mirror?
      rows, cols = fit_to_mirrors(rows, cols)
      return if rows == @terminal.rows && cols == @terminal.cols
      @terminal.resize(rows, cols)
      @process.resize(rows, cols)
    end

    def fit_to_mirrors(rows, cols)
      return [rows, cols] unless @mirror_size
      [[rows, @mirror_size[0]].min.clamp(1, rows), [cols, @mirror_size[1]].min.clamp(1, cols)]
    end

    # Shrink to fit a mirror that just arrived, without waiting for a render —
    # this session may be detached, in which case no render is coming. Growing
    # back is the layout's call on the next frame it draws.
    def clamp_to_mirrors!
      rows, cols = fit_to_mirrors(@terminal.rows, @terminal.cols)
      return if rows == @terminal.rows && cols == @terminal.cols
      @terminal.resize(rows, cols)
      @process.resize(rows, cols)
    end

    # Force the inner program to repaint itself (see PTYProcess#nudge_redraw).
    # Used by the refresh keybinding to recover from emulation drift.
    def request_redraw
      @process.nudge_redraw
    end

    def alive?
      @process.alive?
    end

    def cwd
      @process.cwd || @initial_cwd
    end

    def close
      @process.close
    end
  end
end
