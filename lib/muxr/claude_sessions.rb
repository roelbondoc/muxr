require "json"

module Muxr
  module ClaudeSessions
    CLAUDE_DIR = File.join(Dir.home, ".claude")
    TRANSCRIPT_LIMIT = 150
    TAIL_BYTES = 512 * 1024
    ANCESTOR_DEPTH = 16

    Entry = Struct.new(
      :session_id, :title, :cwd, :state, :updated_at, :pid, :session, :pane_id, :slot, :here, :focused,
      keyword_init: true
    ) do
      def label = session_id
      def running? = !pid.nil?
      def in_muxr? = !pane_id.nil?
      def current? = !!(here && focused)
      def name = nil
      def command = "claude"
      def description = session_id
      def notice = nil
      def private = false
      def bell = false
      def activity = false
      def silent = false
      def attention? = false

      def idle
        updated_at && [Time.now.to_f - updated_at, 0].max
      end
    end

    Transcript = Struct.new(:title, :cwd, keyword_init: true)

    @transcripts = {}

    class << self
      attr_accessor :claude_dir

      def entries(panes: [], process_parents: nil)
        parents = process_parents || self.process_parents
        pane_by_pid = panes.each_with_object({}) { |pane, acc| acc[pane.pid] = pane if pane.pid }
        files = transcript_files
        live = live_sessions(parents).map { |info| live_entry(info, files[info["sessionId"]], pane_by_pid, parents) }
        running = live.map(&:session_id)
        saved = files.reject { |id, _| running.include?(id) }
                     .sort_by { |_, path| -mtime(path) }
                     .first(TRANSCRIPT_LIMIT)
                     .filter_map { |id, path| saved_entry(id, path) }
        (live + saved).sort_by { |entry| -(entry.updated_at || 0) }
      end

      def process_parents
        `ps -axo pid=,ppid= 2>/dev/null`.each_line.each_with_object({}) do |line, acc|
          pid, ppid = line.split.map(&:to_i)
          acc[pid] = ppid if pid
        end
      rescue SystemCallError
        {}
      end

      def transcript(path)
        stamp = mtime(path)
        cached = @transcripts[path]
        return cached[1] if cached && cached[0] == stamp
        found = scan_transcript(path)
        @transcripts[path] = [stamp, found]
        found
      end

      private

      def dir
        claude_dir || CLAUDE_DIR
      end

      def live_sessions(parents)
        Dir.glob(File.join(dir, "sessions", "*.json")).filter_map do |path|
          info = JSON.parse(File.read(path))
          next unless info["sessionId"] && info["pid"].is_a?(Integer)
          next unless parents.key?(info["pid"])
          next if info["kind"] && info["kind"] != "interactive"
          info
        rescue JSON::ParserError, SystemCallError
          nil
        end
      end

      def live_entry(info, path, pane_by_pid, parents)
        found = path && transcript(path)
        pane = owning_pane(info["pid"], pane_by_pid, parents)
        Entry.new(
          session_id: info["sessionId"],
          title: found&.title || info["name"],
          cwd: info["cwd"] || found&.cwd,
          state: info["status"] == "busy" ? "busy" : "idle",
          updated_at: [path ? mtime(path) : 0, info["updatedAt"].to_f / 1000].max,
          pid: info["pid"],
          session: pane&.session,
          pane_id: pane&.pane_id,
          slot: pane&.slot,
          here: pane&.here,
          focused: pane&.focused
        )
      end

      def saved_entry(id, path)
        found = transcript(path)
        return nil unless found.cwd && found.title
        Entry.new(session_id: id, title: found.title, cwd: found.cwd, state: "saved", updated_at: mtime(path))
      end

      def owning_pane(pid, pane_by_pid, parents)
        ANCESTOR_DEPTH.times do
          return pane_by_pid[pid] if pane_by_pid.key?(pid)
          pid = parents[pid]
          return nil if pid.nil? || pid <= 1
        end
        nil
      end

      def transcript_files
        Dir.glob(File.join(dir, "projects", "*", "*.jsonl")).to_h { |path| [File.basename(path, ".jsonl"), path] }
      end

      def mtime(path)
        File.mtime(path).to_f
      rescue SystemCallError
        0
      end

      def scan_transcript(path)
        File.open(path, "rb") do |file|
          size = file.size
          file.seek([size - TAIL_BYTES, 0].max)
          title, cwd = scan_lines(file.read.to_s.force_encoding("UTF-8").scrub.each_line)
          if (title.nil? || cwd.nil?) && size > TAIL_BYTES
            file.rewind
            head_title, head_cwd = scan_lines(file.each_line)
            title ||= head_title
            cwd ||= head_cwd
          end
          Transcript.new(title: title, cwd: cwd)
        end
      rescue SystemCallError, IOError
        Transcript.new
      end

      def scan_lines(lines)
        title = nil
        cwd = nil
        prompt = nil
        lines.each do |line|
          if line.start_with?('{"type":"ai-title"') || line.start_with?('{"type":"custom-title"')
            record = parse(line)
            title = record["customTitle"] || record["aiTitle"] || title if record
          elsif line.start_with?('{"type":"last-prompt"')
            prompt = parse(line)&.fetch("lastPrompt", nil) || prompt
          elsif cwd.nil? && line.include?('"cwd":"')
            cwd = parse(line)&.fetch("cwd", nil)
          end
        end
        [title || prompt&.lines&.first&.strip, cwd]
      end

      def parse(line)
        JSON.parse(line.dup.force_encoding(Encoding::UTF_8))
      rescue JSON::ParserError
        nil
      end
    end
  end
end
