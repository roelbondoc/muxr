require "json"
require "socket"

module Muxr
  # Enumerates the panes of every muxr server currently running on this
  # machine by asking each one over its control socket. Used to populate the
  # attach picker, which is the only place muxr looks outside its own process.
  #
  # Every query is best-effort and deadline-bounded: a session whose server is
  # wedged, mid-shutdown, or newer/older than us simply doesn't appear in the
  # list rather than hanging the event loop that is asking.
  module SessionDirectory
    QUERY_TIMEOUT = 0.5

    Entry = Struct.new(:session, :socket_path, :pane_id, :slot, :cwd, :rows, :cols, :focused, keyword_init: true) do
      def label
        "#{session}:#{pane_id}"
      end
    end

    # Session names with a live server, paired with their control socket path.
    # A name is only reported when both its TTY socket and its control socket
    # accept a connection, which is what makes a session actually attachable.
    def self.live_sessions
      dir = Application::SOCKETS_DIR
      return {} unless File.directory?(dir)
      Dir.children(dir).sort.each_with_object({}) do |entry, acc|
        next unless entry.end_with?(".sock")
        next if entry.end_with?(".ctrl.sock")
        name = File.basename(entry, ".sock")
        control = Application.control_socket_path_for(name)
        next unless Application.alive_socket?(File.join(dir, entry))
        next unless Application.alive_socket?(control)
        acc[name] = control
      end
    end

    # Every non-private pane of every live session other than +exclude+, in
    # session then slot order. Private panes are omitted for the same reason
    # the MCP surface hides them: the user marked them not-for-sharing.
    def self.panes(exclude: nil)
      live_sessions.flat_map do |name, control|
        next [] if name == exclude
        list = query(control, "panes.list")
        next [] unless list
        (list["panes"] || []).filter_map do |pane|
          next if pane["private"]
          next unless pane["alive"]
          Entry.new(
            session: name,
            socket_path: control,
            pane_id: pane["id"].to_s,
            slot: pane["slot"],
            cwd: pane["cwd"],
            rows: pane["rows"],
            cols: pane["cols"],
            focused: !!pane["focused"]
          )
        end
      end
    end

    def self.query(control_path, method, params = {})
      socket = UNIXSocket.new(control_path)
      begin
        socket.write(JSON.generate("id" => 1, "method" => method, "params" => params) + "\n")
        read_response(socket)
      ensure
        socket.close rescue nil
      end
    rescue SystemCallError, IOError
      nil
    end

    def self.read_response(socket)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + QUERY_TIMEOUT
      buffer = +""
      loop do
        while (line = buffer.slice!(/\A.*\n/))
          msg = begin
            JSON.parse(line)
          rescue JSON::ParserError
            next
          end
          next unless msg["id"] == 1
          return msg["result"]
        end
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return nil if remaining <= 0
        return nil unless IO.select([socket], nil, nil, remaining)
        begin
          buffer << socket.read_nonblock(4096)
        rescue IO::WaitReadable
          next
        end
      end
    rescue EOFError, SystemCallError, IOError
      nil
    end
  end
end
