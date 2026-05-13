module Muxr
  # Translates an array of "keys" entries (a mix of literal text and vim-style
  # named keys like "<esc>") into a stream of byte segments tagged by kind.
  #
  # Each input element is either:
  #
  #   - Literal text (UTF-8) — emitted as [:literal, bytes].
  #   - A named key wrapped in angle brackets like "<esc>", "<c-c>", "<up>" —
  #     emitted as [:special, bytes] using the appropriate control sequence.
  #
  # The tagged form lets callers wrap *only* literal segments in
  # bracketed-paste markers when desired. Concatenating the bytes of all
  # segments gives the raw byte stream to write to the PTY.
  module KeyParser
    NAMED_KEY_RE = /\A<([^<>]+)>\z/.freeze

    # CSI = ESC [ , SS3 = ESC O — both standard xterm key encodings.
    CSI = "\e[".b.freeze
    SS3 = "\eO".b.freeze

    # Single canonical map. Keys are lowercased; aliases live alongside their
    # canonical forms. Values are ASCII byte strings.
    NAMED_KEYS = {
      "esc"      => "\e".b,
      "escape"   => "\e".b,
      "enter"    => "\r".b,
      "cr"       => "\r".b,
      "return"   => "\r".b,
      "tab"      => "\t".b,
      "s-tab"    => "#{CSI}Z".b,
      "bs"       => "\x7f".b, # what real backspace keys send through a PTY
      "backspace"=> "\x7f".b,
      "space"    => " ".b,
      "up"       => "#{CSI}A".b,
      "down"     => "#{CSI}B".b,
      "right"    => "#{CSI}C".b,
      "left"     => "#{CSI}D".b,
      "home"     => "#{CSI}H".b,
      "end"      => "#{CSI}F".b,
      "pageup"   => "#{CSI}5~".b,
      "pagedown" => "#{CSI}6~".b,
      "f1"       => "#{SS3}P".b,
      "f2"       => "#{SS3}Q".b,
      "f3"       => "#{SS3}R".b,
      "f4"       => "#{SS3}S".b,
      "f5"       => "#{CSI}15~".b,
      "f6"       => "#{CSI}17~".b,
      "f7"       => "#{CSI}18~".b,
      "f8"       => "#{CSI}19~".b,
      "f9"       => "#{CSI}20~".b,
      "f10"      => "#{CSI}21~".b,
      "f11"      => "#{CSI}23~".b,
      "f12"      => "#{CSI}24~".b
    }.freeze

    CTRL_RE = /\Ac-([a-z])\z/.freeze

    module_function

    # Returns an array of [kind, bytes] pairs. Raises Dispatcher::Error on a
    # non-array input or an unrecognized `<name>`.
    def translate(entries)
      raise Dispatcher::Error.new("`keys` must be an array of strings") unless entries.is_a?(Array)

      entries.map do |entry|
        raise Dispatcher::Error.new("`keys` entries must be strings") unless entry.is_a?(String)
        classify(entry)
      end
    end

    def classify(entry)
      m = NAMED_KEY_RE.match(entry)
      return [:literal, entry.b] unless m

      name = m[1].downcase
      bytes = NAMED_KEYS[name] || ctrl_bytes(name)
      raise Dispatcher::Error.new("unknown named key #{entry.inspect}") unless bytes

      [:special, bytes]
    end

    def ctrl_bytes(name)
      m = CTRL_RE.match(name)
      return nil unless m
      # <c-a>=0x01 .. <c-z>=0x1A
      (m[1].ord - "a".ord + 1).chr.b
    end
  end
end
