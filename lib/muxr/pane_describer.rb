require "digest"
require "open3"
require "tmpdir"

module Muxr
  class PaneDescriber
    DEFAULT_INTERVAL = 120
    FIRST_SWEEP_DELAY = 15
    DEFAULT_MODEL = "haiku".freeze
    RUN_TIMEOUT = 60
    SCREEN_MAX_CHARS = 6000
    DESCRIPTION_MAX = 80

    SYSTEM_PROMPT = <<~PROMPT.freeze
      You label panes in a terminal multiplexer so their owner can tell them apart in a pane switcher.
      You are given the foreground command, the window title and the visible screen of one pane.
      Reply with a single line of at most 60 characters saying what the pane is doing or showing right now,
      most specific detail first, e.g. "rake test: 1 failure in test_resize", "claude: fixing switcher layout",
      "vim lib/muxr/pane.rb", "idle zsh in ~/src/app after git push". No quotes, no preamble, no trailing period.
    PROMPT

    CHILD_ENV = %w[CLAUDECODE CLAUDE_CODE_ENTRYPOINT MUXR_SESSION MUXR_PANE MUXR_CONTROL_SOCKET].to_h { |key| [key, nil] }.freeze

    attr_accessor :interval, :model

    def self.find_claude(path = ENV["PATH"])
      path.to_s.split(File::PATH_SEPARATOR).map { |dir| File.join(dir, "claude") }.find { |file| File.executable?(file) }
    end

    def initialize(interval: DEFAULT_INTERVAL, model: DEFAULT_MODEL, runner: nil, claude: self.class.find_claude, on_update: nil)
      @interval = interval
      @model = model
      @claude = claude
      @runner = runner
      @on_update = on_update
      @jobs = Queue.new
      @described = {}
      @next_sweep_at = nil
      @worker = nil
    end

    def available?
      !(@runner || @claude).nil?
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
      screen = pane.terminal.dump_text.gsub(/\n{3,}/, "\n\n").strip
      screen = screen[-SCREEN_MAX_CHARS..] if screen.length > SCREEN_MAX_CHARS
      [
        "Command: #{pane.foreground_command || "shell"}",
        "Title: #{pane.terminal.title}",
        "Screen:",
        screen
      ].join("\n")
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
      text = clean((@runner || method(:run_claude)).call(context))
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

    def run_claude(context)
      command = [
        @claude, "-p", "Describe this pane.",
        "--model", @model,
        "--system-prompt", SYSTEM_PROMPT,
        "--tools", "",
        "--strict-mcp-config",
        "--setting-sources", "",
        "--disable-slash-commands",
        "--no-session-persistence"
      ]
      Open3.popen2(CHILD_ENV, *command, chdir: Dir.tmpdir, pgroup: true, err: File::NULL) do |stdin, stdout, wait|
        stdin.write(context)
        stdin.close
        unless stdout.wait_readable(RUN_TIMEOUT) && wait.join(RUN_TIMEOUT)
          Process.kill("TERM", -wait.pid) rescue nil
          raise "claude timed out after #{RUN_TIMEOUT}s"
        end
        output = stdout.read
        raise "claude exited #{wait.value.exitstatus}" unless wait.value.success?
        output
      end
    end
  end
end
