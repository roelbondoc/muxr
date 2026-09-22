require "json"
require "socket"

module Muxr
  # Takes a pane away from another muxr server for good. Where RemotePane
  # borrows a pane by relaying its bytes, this moves the pane itself: the
  # master pty file descriptor crosses the Unix socket via SCM_RIGHTS, so the
  # shell that was running keeps running, with its jobs, its environment and
  # whatever it had on screen, and simply belongs to us afterwards.
  #
  # Two things shape the wire order. The fd has to arrive *before* the bulky
  # emulator state, because pulling it out of the socket needs recvmsg and any
  # plain read that swallows the carrier byte first drops the fd on the floor.
  # And a short preamble has to arrive before *that*, because a refusal (the
  # pane is private, or the last one in its session) has no fd to send and we
  # would otherwise block forever waiting for one. So: preamble, fd, state.
  #
  # The move is two-phase. Nothing is torn down on the far side until we have
  # a working pane here and say so, and a failure anywhere leaves the pane
  # exactly where it was rather than dropping a live shell between servers.
  module PaneTransfer
    class Error < StandardError; end

    TIMEOUT = 5.0

    Result = Struct.new(:pane, :session, keyword_init: true)

    def self.claim(socket_path:, pane_id:)
      socket = connect(socket_path)
      begin
        request(socket, 1, "pane.move", "pane" => pane_id)
        await_preamble(socket)
        io = receive_fd(socket)
        begin
          state = await_state(socket)
          pane = build_pane(io, state)
        rescue StandardError => e
          io.close rescue nil
          notify(socket, "pane.move_abort")
          raise e.is_a?(Error) ? e : Error.new(e.message)
        end
        request(socket, 2, "pane.move_commit")
        await_result(socket, 2)
        Result.new(pane: pane, session: state["session"].to_s)
      ensure
        socket.close rescue nil
      end
    end

    def self.build_pane(io, state)
      rows = state["rows"].to_i
      cols = state["cols"].to_i
      raise Error, "owner sent a nonsense pane size (#{rows}x#{cols})" unless rows.positive? && cols.positive?
      process = PTYProcess.new(
        rows: rows, cols: cols,
        adopt_io: io, adopt_pid: state["pid"]
      )
      pane = Pane.new(id: state["pane"].to_s, rows: rows, cols: cols, cwd: state["cwd"], process: process)
      pane.terminal.restore_transfer!(state)
      pane.name = state["name"] if state["name"]
      pane
    end

    def self.connect(socket_path)
      UNIXSocket.new(socket_path)
    rescue SystemCallError => e
      raise Error, "cannot reach session socket: #{e.message}"
    end

    def self.request(socket, id, method, params = {})
      socket.write(JSON.generate("id" => id, "method" => method, "params" => params) + "\n")
    rescue SystemCallError, IOError => e
      raise Error, e.message
    end

    def self.notify(socket, method, params = {})
      socket.write(JSON.generate("method" => method, "params" => params) + "\n")
    rescue SystemCallError, IOError
      # Owner will time the half-finished move out on its own.
    end

    # Read the preamble a byte at a time. Reading ahead here would be a bug,
    # not an optimization: the very next thing on the socket is the fd, and a
    # buffered read past the newline would consume its carrier byte.
    def self.await_preamble(socket)
      line = +""
      deadline = now + TIMEOUT
      until line.end_with?("\n")
        raise Error, "timed out waiting for the owning session" unless wait_readable(socket, deadline)
        byte = begin
          socket.read_nonblock(1)
        rescue IO::WaitReadable
          next
        rescue EOFError, SystemCallError, IOError
          raise Error, "owning session closed the connection"
        end
        line << byte
        raise Error, "owning session sent an oversized reply" if line.bytesize > 8192
      end
      check(parse(line))
    end

    def self.receive_fd(socket)
      raise Error, "timed out waiting for the pane's terminal" unless wait_readable(socket, now + TIMEOUT)
      socket.recv_io(IO, "r+")
    rescue SystemCallError, IOError => e
      raise Error, "could not take over the pane's terminal: #{e.message}"
    end

    # Safe to buffer freely now — the fd is out of the socket and the state
    # line is the last thing the owner sends before we commit.
    def self.await_state(socket)
      buffer = +""
      deadline = now + TIMEOUT
      until (nl = buffer.index("\n"))
        raise Error, "timed out waiting for the pane's contents" unless wait_readable(socket, deadline)
        begin
          buffer << socket.read_nonblock(READ_CHUNK)
        rescue IO::WaitReadable
          next
        rescue EOFError, SystemCallError, IOError
          raise Error, "owning session closed the connection"
        end
      end
      check(parse(buffer.byteslice(0, nl + 1)))
    end

    def self.await_result(socket, id)
      buffer = +""
      deadline = now + TIMEOUT
      loop do
        while (nl = buffer.index("\n"))
          line = buffer.slice!(0..nl)
          msg = parse(line)
          next unless msg["id"] == id
          return check(msg)
        end
        raise Error, "timed out completing the move" unless wait_readable(socket, deadline)
        begin
          buffer << socket.read_nonblock(READ_CHUNK)
        rescue IO::WaitReadable
          next
        rescue EOFError, SystemCallError, IOError
          raise Error, "owning session closed the connection"
        end
      end
    end

    READ_CHUNK = 64 * 1024

    def self.check(msg)
      raise Error, msg["error"]["message"].to_s if msg["error"]
      msg["result"] || {}
    end

    def self.parse(line)
      JSON.parse(line)
    rescue JSON::ParserError
      raise Error, "owning session sent something that isn't JSON"
    end

    def self.wait_readable(socket, deadline)
      remaining = deadline - now
      return false if remaining <= 0
      !!IO.select([socket], nil, nil, remaining)
    end

    def self.now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
