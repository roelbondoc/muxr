module Muxr
  class KeyDisplay
    TTL = 2.5
    MAX_KEYS = 10
    TEXT_STATES = %i[command search switcher directory_prompt].freeze
    NAMES = { "\r" => "Enter", "\t" => "Tab", "\e" => "Esc", " " => "Space", "\x7f" => "BS" }.freeze
    CSI_NAMES = {
      "A" => "Up", "B" => "Down", "C" => "Right", "D" => "Left", "H" => "Home", "F" => "End",
      "Z" => "S-Tab", "5~" => "PgUp", "6~" => "PgDn", "3~" => "Del"
    }.freeze
    KEY_PATTERN = /\e\[[0-9;?]*[\x40-\x7e]|\eO.|\e.|./mu

    attr_writer :prefix

    def initialize(prefix: InputHandler::PREFIX, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @prefix = prefix
      @clock = clock
      @keys = []
    end

    def note(bytes, state)
      keys = bytes.dup.force_encoding(Encoding::UTF_8).scrub.scan(KEY_PATTERN)
      if state == :passthrough
        start = keys.index(@prefix)
        return if start.nil?
        keys = keys[start..]
      end
      keys = keys.reject { |key| typed_text?(key) } if TEXT_STATES.include?(state)
      now = @clock.call
      keys.each { |key| @keys << [label(key), now] }
      @keys.shift while @keys.length > MAX_KEYS
    end

    def labels
      @keys.map(&:first)
    end

    def expire!
      cutoff = @clock.call - TTL
      before = @keys.length
      @keys.reject! { |_, at| at < cutoff }
      @keys.length != before
    end

    private

    def typed_text?(key)
      key.length == 1 && key.ord >= 0x20 && key != "\x7f"
    end

    def label(key)
      return NAMES[key] if NAMES.key?(key)
      return "C-#{(key.ord + 0x60).chr}" if key.length == 1 && key.ord < 0x20
      return CSI_NAMES.fetch(key[2..].sub(/\A1;\d/, ""), "Esc") if key.start_with?("\e[")
      return CSI_NAMES.fetch(key[2], "Esc") if key.start_with?("\eO")
      return "M-#{key[1]}" if key.start_with?("\e")
      key
    end
  end
end
