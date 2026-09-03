require "base64"
require "json"
require "socket"

module Muxr
  # Stands in for a PTYProcess when a pane is borrowed from another muxr
  # server. It speaks the owner's control protocol (NDJSON over
  # ~/.muxr/sockets/<name>.ctrl.sock) but presents the same surface a Pane
  # expects from a local PTY, so the borrowed pane joins the event loop, the
  # layout, and the Renderer with no special-casing anywhere else.
  #
  # The owner keeps the PTY and stays the only reader of it. What crosses the
  # socket is the raw byte stream in one direction and keystrokes in the other,
  # which makes the local Terminal a byte-exact replica rather than a
  # screen-scrape: colors, cursor, alternate screen and bracketed paste all
  # behave. The price is that geometry belongs to the owner — see Pane#resize.
  #
  # Lifecycle at both ends is failure-shaped rather than negotiated. If the
  # owning server stops, the socket EOFs, #alive? goes false and the borrowing
  # session prunes the pane. If the borrowing server stops, #close drops the
  # mirror and the pane carries on at home at full size.
  class RemotePane
    class Error < StandardError; end

    HANDSHAKE_TIMEOUT = 2.0
    READ_CHUNK = 64 * 1024

    attr_reader :session, :pane_id, :rows, :cols, :cwd

    def self.connect(socket_path:, pane_id:, rows:, cols:)
      new(socket_path: socket_path, pane_id: pane_id, rows: rows, cols: cols)
    end

    def initialize(socket_path:, pane_id:, rows:, cols:, socket: nil)
      @socket_path = socket_path
      @pane_id = pane_id.to_s
      @requested = [rows, cols]
      @in_buffer = +""
      @write_buffer = +"".b
      @queue = []
      @closed = false
      @terminal = nil
      @socket = socket || connect_socket
      handshake(rows, cols)
    end

    def mirror?
      true
    end

    # The replica emulator this mirror drives. Bound after construction because
    # the Pane builds its Terminal from the geometry we hand back.
    def bind(terminal)
      @terminal = terminal
    end

    def origin
      "#{@session}:#{@pane_id}"
    end

    def io
      @socket
    end

    def writer_io
      @socket
    end

    def pid
      nil
    end

    def pending_write?
      !@write_buffer.empty?
    end

    def alive?
      !@closed
    end

    def write(data)
      return if @closed || data.nil? || data.empty?
      request("pane.send_input", "pane" => @pane_id, "data" => Base64.strict_encode64(data), "base64" => true)
    end

    def resize(rows, cols)
      return if @closed
      return if [rows, cols] == @requested
      @requested = [rows, cols]
      request("pane.mirror_resize", "pane" => @pane_id, "rows" => rows, "cols" => cols)
    end

    def nudge_redraw
      return if @closed
      request("pane.redraw", "pane" => @pane_id)
    end

    def read_nonblock(_max = READ_CHUNK)
      loop do
        chunk = take_queued
        return chunk if chunk
        return nil unless fill
      end
    end

    def drain
      return if @closed || @write_buffer.empty?
      loop do
        n = @socket.write_nonblock(@write_buffer)
        @write_buffer = @write_buffer.byteslice(n..-1) || +"".b
        break if @write_buffer.empty?
      end
    rescue IO::WaitWritable
      # Owner's receive buffer is full; the rest stays queued.
    rescue SystemCallError, IOError
      @closed = true
      @write_buffer.clear
    end

    def close
      return if @closed
      @closed = true
      begin
        @socket.write(JSON.generate("method" => "pane.unmirror", "params" => { "pane" => @pane_id }) + "\n")
      rescue SystemCallError, IOError
        # Owner already gone; it drops the mirror when our socket closes.
      end
      @socket.close rescue nil
    end

    private

    def connect_socket
      UNIXSocket.new(@socket_path)
    rescue SystemCallError => e
      raise Error, "cannot reach session socket: #{e.message}"
    end

    def handshake(rows, cols)
      send_line(JSON.generate(
        "id" => 1,
        "method" => "pane.mirror",
        "params" => { "pane" => @pane_id, "rows" => rows, "cols" => cols }
      ))
      result = await_response(1)
      @session = result["session"].to_s
      @cwd     = result["cwd"]
      @rows    = result["rows"].to_i
      @cols    = result["cols"].to_i
      snapshot = decode(result["snapshot"])
      @queue << [:bytes, snapshot] if snapshot && !snapshot.empty?
    end

    def await_response(id)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HANDSHAKE_TIMEOUT
      loop do
        line = @in_buffer.slice!(/\A.*\n/)
        if line
          msg = parse(line)
          next unless msg && msg["id"] == id
          if (err = msg["error"])
            raise Error, err["message"].to_s
          end
          return msg["result"] || {}
        end
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise Error, "timed out waiting for the owning session" if remaining <= 0
        raise Error, "timed out waiting for the owning session" unless IO.select([@socket], nil, nil, remaining)
        chunk = begin
          @socket.read_nonblock(READ_CHUNK)
        rescue IO::WaitReadable
          next
        rescue EOFError, SystemCallError, IOError
          raise Error, "owning session closed the connection"
        end
        @in_buffer << chunk
      end
    end

    def request(method, params)
      send_line(JSON.generate("method" => method, "params" => params))
    end

    def send_line(line)
      @write_buffer << (line + "\n").b
      drain
    end

    # Pull the next relayed output chunk off the queue, applying any geometry
    # change that precedes it first: the owner's repaint snapshot is only
    # meaningful against a replica that has already taken the new size.
    def take_queued
      while (entry = @queue.shift)
        kind, *rest = entry
        case kind
        when :bytes
          return rest[0]
        when :geometry
          rows, cols, snapshot = rest
          @rows = rows
          @cols = cols
          @terminal&.resize(rows, cols)
          return snapshot unless snapshot.nil? || snapshot.empty?
        when :gone
          @closed = true
          return nil
        end
      end
      nil
    end

    def fill
      return false if @closed
      chunk = begin
        @socket.read_nonblock(READ_CHUNK)
      rescue IO::WaitReadable
        return false
      rescue EOFError, SystemCallError, IOError
        @closed = true
        return false
      end
      @in_buffer << chunk
      queued = false
      while (line = @in_buffer.slice!(/\A.*\n/))
        queued = true if enqueue(line)
      end
      queued
    end

    def enqueue(line)
      msg = parse(line)
      return false unless msg
      params = msg["params"] || {}
      return false unless params["pane"].to_s == @pane_id
      case msg["method"]
      when "event.pane.mirror"
        data = decode(params["data"])
        return false if data.nil? || data.empty?
        @queue << [:bytes, data]
      when "event.pane.geometry"
        @queue << [:geometry, params["rows"].to_i, params["cols"].to_i, decode(params["snapshot"])]
      when "event.pane.gone"
        @queue << [:gone]
      else
        return false
      end
      true
    end

    def parse(line)
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end

    def decode(value)
      return nil unless value.is_a?(String)
      Base64.strict_decode64(value)
    rescue ArgumentError
      nil
    end
  end
end
