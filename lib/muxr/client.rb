require "socket"
require "io/console"

module Muxr
  # The muxr client. It is a small front-end whose only jobs are:
  #   1. Connect to the server's Unix socket and send HELLO with the
  #      terminal's current size.
  #   2. Put the controlling TTY into the alt screen + raw mode.
  #   3. Forward every STDIN read as an INPUT frame.
  #   4. Write every OUTPUT frame payload straight to STDOUT.
  #   5. Send RESIZE on SIGWINCH; exit cleanly on BYE / server EOF.
  #
  # The client owns no Session, no PTYs, and no Renderer — that all lives in
  # the server process. This is the piece that comes and goes during detach
  # / reattach.
  class Client
    SELECT_TIMEOUT = 0.1

    def initialize(session_name)
      @session_name = session_name
      @socket_path = Application.socket_path_for(session_name)
      @sock = nil
      @running = false
      @resize_pending = false
      @exit_code = 0
      @bye_reason = nil
    end

    # Opens the socket. Returns true on success. Raises Errno::ENOENT /
    # Errno::ECONNREFUSED to the caller, which is bin/muxr's job to handle by
    # spawning a server.
    def connect
      @sock = UNIXSocket.new(@socket_path)
      rows, cols = terminal_size
      Protocol.write(@sock, Protocol::HELLO, Protocol.encode_size(rows, cols))
      true
    end

    def run
      raise "must call #connect first" unless @sock

      enter_terminal_mode
      install_winch_trap
      @running = true

      begin
        loop_forever
      ensure
        leave_terminal_mode
        @sock.close rescue nil
      end

      @exit_code
    end

    private

    def loop_forever
      while @running
        if @resize_pending
          @resize_pending = false
          send_resize
        end

        ready, = IO.select([STDIN, @sock], nil, nil, SELECT_TIMEOUT)
        next unless ready

        ready.each do |io|
          if io == STDIN
            forward_stdin
          else
            consume_server_frame
          end
        end
      end
    end

    def forward_stdin
      data = STDIN.read_nonblock(4096)
      Protocol.write(@sock, Protocol::INPUT, data)
    rescue IO::WaitReadable
      # spurious wake-up; nothing to do.
    rescue EOFError, Errno::EPIPE, Errno::ECONNRESET, IOError
      @running = false
    end

    def consume_server_frame
      type, payload = Protocol.read(@sock)
      if type.nil?
        @running = false
        @bye_reason ||= "server closed connection"
        return
      end

      case type
      when Protocol::OUTPUT
        STDOUT.write(payload)
        STDOUT.flush
      when Protocol::BYE
        @bye_reason = payload.to_s
        @running = false
      else
        # Unknown frame type; ignore.
      end
    end

    def send_resize
      rows, cols = terminal_size
      Protocol.write(@sock, Protocol::RESIZE, Protocol.encode_size(rows, cols))
    rescue Errno::EPIPE, Errno::ECONNRESET, IOError
      @running = false
    end

    def terminal_size
      IO.console.winsize
    rescue StandardError
      [24, 80]
    end

    def install_winch_trap
      Signal.trap("WINCH") { @resize_pending = true }
    end

    def enter_terminal_mode
      STDIN.raw!
      STDIN.echo = false
      STDOUT.write("\e[?1049h\e[?25l\e[2J\e[H\e[0m")
      STDOUT.flush
    end

    def leave_terminal_mode
      STDOUT.write("\e[0m\e[?25h\e[?1049l")
      STDOUT.flush
      begin
        STDIN.cooked!
        STDIN.echo = true
      rescue StandardError
        # terminal may have already been reset by a signal handler.
      end
      if @bye_reason && !@bye_reason.empty? && @bye_reason != "detached"
        $stderr.puts "muxr: #{@bye_reason}"
      end
    end
  end
end
