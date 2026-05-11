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

      shell = command || ENV["SHELL"] || "/bin/sh"
      env = ENV.to_h.merge("TERM" => "xterm-256color").merge(env_overrides)
      env["LINES"]   = rows.to_s
      env["COLUMNS"] = cols.to_s

      chdir = (cwd && File.directory?(cwd)) ? cwd : Dir.pwd

      @reader, @writer, @pid = PTY.spawn(env, shell, chdir: chdir)
      @io = @reader
      resize(rows, cols)
    end

    def write(data)
      @writer.write(data)
      @writer.flush
    rescue Errno::EIO, IOError, Errno::EPIPE
      @exited = true
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
