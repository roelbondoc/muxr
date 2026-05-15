module Muxr
  # Looks up the foreground command running inside a PTY by walking from the
  # shell's pid → its tpgid (foreground process group on the controlling tty)
  # → that process's command name. Hides the result when the shell itself is
  # foreground so titles aren't full of "bash" / "zsh" noise.
  #
  # Two platform paths:
  #   Linux: /proc/<pid>/stat (no fork — runs fast even on the main thread,
  #          though Application uses a background thread anyway)
  #   macOS: ps -o tpgid=,pgid= -p <pid> + ps -o comm= -p <tpgid>. Two
  #          fork+execs, ~10–20ms total — exactly the reason callers run
  #          this off the event-loop thread.
  #
  # Returns the command name string or nil. nil also covers "couldn't read"
  # so callers degrade silently rather than risk showing stale data.
  module ForegroundCommand
    # Command names we never want to surface — these are the empty-prompt
    # case. If a user genuinely runs `bash` inside `bash` we'll under-report
    # rather than mis-report.
    SHELLS = %w[bash zsh fish sh dash ksh tcsh csh].freeze

    module_function

    def lookup(pid)
      return nil unless pid.is_a?(Integer) && pid > 0
      tpgid, pgid =
        if File.exist?("/proc/#{pid}/stat")
          linux_tpgid(pid)
        else
          macos_tpgid(pid)
        end
      return nil unless tpgid && pgid
      return nil if tpgid <= 0
      return nil if tpgid == pgid # shell is its own foreground — empty prompt

      name =
        if File.exist?("/proc/#{tpgid}/comm")
          File.read("/proc/#{tpgid}/comm").strip
        else
          `ps -o comm= -p #{tpgid} 2>/dev/null`.strip
        end
      normalize(name)
    rescue StandardError
      nil
    end

    # Public for testing — strips path/dash/whitespace and filters shells.
    def normalize(name)
      return nil if name.nil? || name.empty?
      name = name.strip
      name = name.sub(/\A-/, "") # login shells appear as "-bash"
      name = File.basename(name)
      return nil if name.empty?
      return nil if SHELLS.include?(name)
      name
    end

    # Public for testing — parses Linux /proc/<pid>/stat into [tpgid, pgid].
    # The comm field can contain spaces and parens, so we slice from the
    # last ')' rather than splitting from the start.
    def parse_linux_stat(raw)
      idx = raw.rindex(")")
      return [nil, nil] unless idx
      tail = raw[(idx + 2)..]
      return [nil, nil] unless tail
      fields = tail.split(" ")
      # After the closing paren the fields are:
      #   state(0) ppid(1) pgrp(2) session(3) tty_nr(4) tpgid(5) ...
      pgid  = fields[2]&.to_i
      tpgid = fields[5]&.to_i
      [tpgid, pgid]
    end

    def linux_tpgid(pid)
      raw = File.read("/proc/#{pid}/stat")
      parse_linux_stat(raw)
    end

    def macos_tpgid(pid)
      out = `ps -o tpgid=,pgid= -p #{pid} 2>/dev/null`.strip
      return [nil, nil] if out.empty?
      tpgid, pgid = out.split.map(&:to_i)
      [tpgid, pgid]
    end
  end
end
