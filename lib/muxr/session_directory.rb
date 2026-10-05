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

    Entry = Struct.new(
      :session, :socket_path, :pane_id, :slot, :cwd, :rows, :cols, :focused, :name,
      :command, :title, :state, :idle, :notice, :notice_age, :bell, :activity, :silent,
      :private, :origin, :here,
      keyword_init: true
    ) do
      def label
        "#{session}:#{pane_id}"
      end

      def attention?
        !!(bell || activity || silent)
      end

      def self.from_listing(session, socket_path, pane, here: false)
        new(
          session: session,
          socket_path: socket_path,
          pane_id: pane["id"].to_s,
          slot: pane["slot"],
          cwd: pane["cwd"],
          rows: pane["rows"],
          cols: pane["cols"],
          focused: !!pane["focused"],
          name: pane["name"],
          command: pane["command"],
          title: pane["title"],
          state: pane["state"],
          idle: pane["idle"],
          notice: pane["notice"],
          notice_age: pane["notice_age"],
          bell: !!pane["bell"],
          activity: !!pane["activity"],
          silent: !!pane["silent"],
          private: !!pane["private"],
          origin: pane["origin"],
          here: here
        )
      end

      def to_h
        super.reject { |key, _| key == :socket_path }
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
      listings(live_sessions.reject { |name, _| name == exclude }).flat_map do |name, control, list|
        list.filter_map do |pane|
          next if pane["private"]
          next unless pane["alive"]
          Entry.from_listing(name, control, pane)
        end
      end
    end

    def self.all_panes(local: nil)
      sessions = live_sessions
      remote = local ? sessions.reject { |name, _| name == local[0] } : sessions
      found = listings(remote)
      found.unshift([local[0], sessions[local[0]], local[1]]) if local
      entries = found.flat_map do |name, control, list|
        list.filter_map do |pane|
          next if pane.key?("alive") && !pane["alive"]
          next if pane["origin"]
          Entry.from_listing(name, control, pane, here: local && name == local[0])
        end
      end
      most_recently_updated_first(entries)
    end

    def self.most_recently_updated_first(entries)
      entries.each_with_index.sort_by { |entry, i| [entry.idle ? 0 : 1, entry.idle || 0, i] }.map(&:first)
    end

    def self.listings(sessions)
      sessions.map { |name, control| [name, control, Thread.new { query(control, "panes.list") }] }
              .filter_map do |name, control, thread|
                list = thread.value
                [name, control, list["panes"] || []] if list
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
