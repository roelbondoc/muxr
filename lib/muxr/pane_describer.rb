require "digest"
require "json"
require "net/http"

module Muxr
  class PaneDescriber
    DEFAULT_INTERVAL = 120
    FIRST_SWEEP_DELAY = 15
    DEFAULT_MODEL = "qwen3.5:4b".freeze
    DEFAULT_HOST = "http://localhost:11434".freeze
    RUN_TIMEOUT = 60
    CONNECT_TIMEOUT = 2
    SCREEN_MAX_LINES = 25
    SCREEN_MAX_CHARS = 2000
    CONTEXT_TOKENS = 2048
    REPLY_TOKENS = 32
    DESCRIPTION_MAX = 80

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You label panes in a terminal multiplexer so their owner can tell them apart in a pane switcher.
      You are given the foreground command, the window title and the visible screen of one pane.
      Reply with a single line of at most 60 characters saying what the pane is doing or showing right now,
      most specific detail first, e.g. "rake test: 1 failure in test_resize", "claude: fixing switcher layout",
      "vim lib/muxr/pane.rb", "idle zsh in ~/src/app after git push". No quotes, no preamble, no trailing period.
    PROMPT

    attr_accessor :interval, :model

    def self.ollama_host(env = ENV)
      host = env["OLLAMA_HOST"].to_s
      return DEFAULT_HOST if host.empty?
      host.include?("://") ? host : "http://#{host}"
    end

    def initialize(interval: DEFAULT_INTERVAL, model: DEFAULT_MODEL, runner: nil, host: self.class.ollama_host, on_update: nil)
      @interval = interval
      @model = model
      @host = host
      @runner = runner
      @on_update = on_update
      @jobs = Queue.new
      @described = {}
      @next_sweep_at = nil
      @worker = nil
    end

    def available?
      !(@runner || @host).nil?
    end

    def tick(panes, now)
      return unless available?
      @next_sweep_at ||= now + FIRST_SWEEP_DELAY
      return if now < @next_sweep_at
      @next_sweep_at = now + @interval
      return unless @jobs.empty?
      sweep(panes, now)
    end

    def sweep(panes, now)
      live = panes.map(&:id)
      @described.select! { |id, _| live.include?(id) }
      panes.each do |pane|
        next unless describable?(pane)
        last = @described[pane.id]
        next if last && pane.idle_seconds(now) >= now - last[:at]
        context = context_for(pane)
        digest = Digest::SHA1.hexdigest(context)
        @described[pane.id] = { at: now, digest: digest }
        next if last && last[:digest] == digest
        enqueue(pane, context)
      end
    end

    def stop
      thread = @worker
      @worker = nil
      return unless thread
      @jobs.close
      thread.join(2.0) || thread.kill
    end

    private

    def describable?(pane)
      pane.alive? && !pane.mirror? && !pane.private?
    end

    def context_for(pane)
      lines = pane.terminal.dump_text.lines.map(&:rstrip).reject(&:empty?).last(SCREEN_MAX_LINES)
      screen = lines.join("\n")
      screen = screen[-SCREEN_MAX_CHARS..] if screen.length > SCREEN_MAX_CHARS
      title = pane.terminal.title.to_s.strip
      [
        "Command: #{pane.foreground_command || "shell"}",
        ("Title: #{title}" unless title.empty?),
        "Screen:",
        screen
      ].compact.join("\n")
    end

    def enqueue(pane, context)
      @jobs << [pane, context]
      start_worker
    end

    def start_worker
      return if @worker&.alive?
      @worker = Thread.new do
        while (job = @jobs.pop)
          describe(*job)
        end
      end
    end

    def describe(pane, context)
      text = clean((@runner || method(:run_ollama)).call(context))
      return if text.nil?
      pane.description = text
      @on_update&.call(pane)
    rescue StandardError => e
      warn("muxr: describe pane #{pane.id}: #{e.message}")
    end

    def clean(output)
      line = output.to_s.lines.map(&:strip).find { |l| !l.empty? }
      return nil unless line
      line = line.gsub(/[[:cntrl:]]/, "").delete_prefix('"').delete_suffix('"')
      line.length > DESCRIPTION_MAX ? "#{line[0, DESCRIPTION_MAX - 1]}…" : line
    end

    def run_ollama(context)
      uri = URI.join(@host, "/api/chat")
      body = {
        model: @model,
        stream: false,
        think: false,
        options: { num_ctx: CONTEXT_TOKENS, num_predict: REPLY_TOKENS, temperature: 0.2 },
        messages: [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: context }
        ]
      }
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: CONNECT_TIMEOUT, read_timeout: RUN_TIMEOUT) do |http|
        http.post(uri.path, body.to_json, "Content-Type" => "application/json")
      end
      reply = JSON.parse(response.body)
      raise "ollama #{response.code}: #{reply["error"]}" unless response.is_a?(Net::HTTPSuccess)
      reply.dig("message", "content")
    end
  end
end
