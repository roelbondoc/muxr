module Muxr
  # Length-prefixed framing for client <-> server messages over a Unix socket.
  #
  # Wire format per message:
  #   [1 byte type][4 bytes BE length][length bytes payload]
  #
  # Types are single ASCII letters so they're easy to recognise in tcpdump or
  # hex dumps:
  #   H  hello   (client -> server, payload: "ROWS COLS")
  #   I  input   (client -> server, payload: raw STDIN bytes)
  #   R  resize  (client -> server, payload: "ROWS COLS")
  #   B  bye     (either way, payload: optional reason string)
  #   O  output  (server -> client, payload: raw bytes to write to STDOUT)
  module Protocol
    HELLO  = "H".freeze
    INPUT  = "I".freeze
    RESIZE = "R".freeze
    BYE    = "B".freeze
    OUTPUT = "O".freeze

    HEADER_SIZE = 5

    # Reads exactly one framed message from +io+. Returns [type, payload] or
    # nil on EOF / truncated frame. Blocks until the full message arrives.
    def self.read(io)
      header = read_exact(io, HEADER_SIZE)
      return nil unless header
      type = header[0]
      length = header.byteslice(1, 4).unpack1("N")
      payload =
        if length.zero?
          ""
        else
          read_exact(io, length)
        end
      return nil unless payload
      [type, payload]
    end

    # Writes one framed message. +payload+ is treated as raw bytes (binary).
    def self.write(io, type, payload = "")
      io.write(frame(type, payload))
    end

    # Builds the on-the-wire bytes for a single frame without writing them.
    # Lets callers append to an outgoing buffer (for non-blocking flushes
    # later) instead of doing a synchronous io.write.
    def self.frame(type, payload = "")
      raise ArgumentError, "type must be a single byte" unless type.is_a?(String) && type.bytesize == 1
      bytes = payload.to_s.b
      buf = +"".b
      buf << type.b
      buf << [bytes.bytesize].pack("N")
      buf << bytes
      buf
    end

    # Encodes a "ROWS COLS" string for HELLO / RESIZE payloads.
    def self.encode_size(rows, cols)
      "#{rows.to_i} #{cols.to_i}"
    end

    # Returns [rows, cols] or nil if malformed.
    def self.decode_size(payload)
      parts = payload.to_s.strip.split(/\s+/)
      return nil unless parts.length == 2
      r = Integer(parts[0]) rescue nil
      c = Integer(parts[1]) rescue nil
      return nil unless r && c
      [r, c]
    end

    def self.read_exact(io, n)
      buf = +""
      while buf.bytesize < n
        chunk = io.read(n - buf.bytesize)
        return nil if chunk.nil? || chunk.empty?
        buf << chunk
      end
      buf
    end
    private_class_method :read_exact
  end
end
