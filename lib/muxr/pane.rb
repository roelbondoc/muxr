module Muxr
  # A Pane bundles a Terminal emulator buffer with the PTYProcess running the
  # shell that feeds it. The Window keeps a list of panes; the Renderer asks
  # each pane for its current grid contents and cursor position.
  class Pane
    attr_reader :id, :terminal, :process
    attr_accessor :rect

    def initialize(id:, rows: 24, cols: 80, cwd: nil, command: nil, process: nil)
      @id = id
      @rows = rows
      @cols = cols
      @terminal = Terminal.new(rows: rows, cols: cols)
      @process = process || PTYProcess.new(rows: rows, cols: cols, cwd: cwd, command: command)
      @rect = nil
      @initial_cwd = cwd || @process.cwd
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

    def read_from_pty
      data = @process.read_nonblock
      return nil unless data
      @terminal.feed(data)
      data
    end

    def resize(rows, cols)
      return if rows == @terminal.rows && cols == @terminal.cols
      @terminal.resize(rows, cols)
      @process.resize(rows, cols)
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
