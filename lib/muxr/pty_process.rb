require "pty"

module Muxr
  # Owns a single pseudo-terminal pair plus the child shell process attached to
  # the slave side. The parent side is exposed via #io / #read_nonblock / #write.
  class PTYProcess
    attr_reader :pid, :io, :rows, :cols

    def initialize(command: nil, rows: 24, cols: 80, cwd: nil, env_overrides: {})
      @rows = rows
      @cols = cols
      @exited = false
      @write_buffer = +"".b

      shell = command || ENV["SHELL"] || "/bin/sh"
      env = ENV.to_h.merge("TERM" => "xterm-256color").merge(env_overrides)
      env["LINES"]   = rows.to_s
      env["COLUMNS"] = cols.to_s

      chdir = (cwd && File.directory?(cwd)) ? cwd : Dir.pwd

      @reader, @writer, @pid = PTY.spawn(env, shell, chdir: chdir)
      @io = @reader
      resize(rows, cols)
    end

    # Appends bytes to the per-process outgoing buffer and tries to flush as
    # many as the PTY will accept right now. Any remainder stays buffered;
    # the event loop drains it later when the writer fd is reported writable.
    # This avoids deadlocking the single-threaded server when the inner
    # program is slow to read (large pastes were the original motivating
    # case — see CHANGELOG 0.1.3).
    def write(data)
      return if @exited
      return if data.nil? || data.empty?
      @write_buffer << data.b
      drain
    end

    # Push as much of @write_buffer through the PTY as it'll take without
    # blocking. Safe to call repeatedly — both from write() and from the
    # event loop when select reports the writer fd writable.
    def drain
      return if @exited || @write_buffer.empty?
      loop do
        n = @writer.write_nonblock(@write_buffer)
        @write_buffer = @write_buffer.byteslice(n..-1) || +"".b
        break if @write_buffer.empty?
      end
    rescue IO::WaitWritable
      # Kernel buffer full; the rest stays queued.
    rescue Errno::EIO, IOError, Errno::EPIPE
      @exited = true
      @write_buffer.clear
    end

    def pending_write?
      !@write_buffer.empty?
    end

    def writer_io
      @writer
    end

    def read_nonblock(max = 8192)
      @reader.read_nonblock(max)
    rescue IO::WaitReadable
      nil
    rescue EOFError, Errno::EIO
      @exited = true
      nil
    end

    def resize(rows, cols)
      @rows = rows
      @cols = cols
      begin
        @reader.winsize = [rows, cols, 0, 0]
      rescue StandardError
        # Some platforms reject zero pixel sizes; ignore.
      end
    end

    # Coax the foreground program into repainting from scratch by briefly
    # toggling the PTY window size, which delivers SIGWINCH to the tty's
    # foreground process group. Full-screen TUIs (vim, htop, less, fzf) redraw
    # on WINCH, which rewrites muxr's Terminal grid and clears any emulation
    # drift (e.g. a wide glyph that desynced the cursor). The size is restored
    # immediately, so the program redraws at the real dimensions: it reads the
    # current (restored) winsize in its handler and never observes the
    # transient size. No-op when the pane is too narrow to wiggle.
    def nudge_redraw
      return if @exited
      smaller = [@cols - 1, 1].max
      return if smaller == @cols
      begin
        @reader.winsize = [@rows, smaller, 0, 0]
        @reader.winsize = [@rows, @cols, 0, 0]
      rescue StandardError
        # Some platforms reject winsize pokes; reset_frame! still re-emits.
      end
    end

    def alive?
      return false if @exited
      Process.kill(0, @pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      @exited = true
      false
    end

    def reap
      Process.waitpid(@pid, Process::WNOHANG)
    rescue Errno::ECHILD
      nil
    end

    def close
      reap
      Process.kill("TERM", @pid) if alive?
      @reader.close unless @reader.closed?
      @writer.close if @writer != @reader && !@writer.closed?
    rescue Errno::ESRCH, Errno::EBADF, IOError
      # already gone
    end

    # Best-effort cwd of the child process. Used to inherit cwd when opening
    # the drawer or for session save/restore. Falls back to nil if the system
    # doesn't expose the information.
    def cwd
      if File.directory?("/proc/#{@pid}")
        File.readlink("/proc/#{@pid}/cwd")
      else
        # macOS / BSD fallback via lsof.
        out = `lsof -a -p #{@pid} -d cwd -Fn 2>/dev/null`
        line = out.lines.find { |l| l.start_with?("n/") }
        line && line[1..].strip
      end
    rescue StandardError
      nil
    end
  end
end
