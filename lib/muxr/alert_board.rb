require "json"
require "fileutils"

module Muxr
  class AlertBoard
    DIR = File.join(Dir.home, ".muxr", "alerts").freeze
    POLL_INTERVAL = 1.0
    TEXT_MAX = 40
    KEY_PATTERN = /\A[A-Za-z0-9_.-]+\z/

    Alert = Struct.new(:key, :text, :url, :urgent, keyword_init: true)

    def self.write(key, text, url: nil, urgent: false, ttl: nil, dir: DIR)
      raise ArgumentError, "alert key must match #{KEY_PATTERN.source}" unless key.to_s.match?(KEY_PATTERN)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{key}.json")
      tmp = "#{path}.#{Process.pid}.tmp"
      payload = { "text" => text, "url" => url, "urgent" => urgent || nil, "expires_at" => ttl && Time.now.to_f + ttl }
      File.write(tmp, JSON.generate(payload.compact))
      File.rename(tmp, path)
    end

    def self.clear(key, dir: DIR)
      File.delete(File.join(dir, "#{key}.json"))
      true
    rescue Errno::ENOENT
      false
    end

    def self.read_all(dir: DIR, now: Time.now.to_f)
      return [] unless File.directory?(dir)
      Dir.children(dir).sort.filter_map do |entry|
        next unless entry.end_with?(".json")
        data = JSON.parse(File.read(File.join(dir, entry)))
        next if data["expires_at"] && data["expires_at"] < now
        text = data["text"].to_s.gsub(/[[:cntrl:]]/, " ").strip[0, TEXT_MAX]
        next if text.empty?
        Alert.new(key: File.basename(entry, ".json"), text: text, url: data["url"], urgent: !!data["urgent"])
      rescue JSON::ParserError, SystemCallError
        nil
      end
    end

    def self.notify(title, message, url: nil, group: nil)
      argv =
        if system("command -v terminal-notifier >/dev/null 2>&1")
          ["terminal-notifier", "-title", title, "-message", message, *(url ? ["-open", url] : []), *(group ? ["-group", group] : [])]
        else
          ["osascript", "-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run", title, message]
        end
      Process.detach(Process.spawn(*argv, in: File::NULL, out: File::NULL, err: File::NULL))
    rescue SystemCallError
      nil
    end

    attr_reader :alerts

    def initialize(dir: DIR)
      @dir = dir
      @alerts = []
      @checked_at = nil
    end

    def refresh(now)
      return false if @checked_at && now - @checked_at < POLL_INTERVAL
      @checked_at = now
      latest = self.class.read_all(dir: @dir)
      return false if latest == @alerts
      @alerts = latest
      true
    end
  end
end
