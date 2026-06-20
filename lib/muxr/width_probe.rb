module Muxr
  # Measures how the *outer* terminal actually draws glyphs whose width muxr
  # would otherwise have to guess, so the emulator and Renderer can be tuned to
  # match it instead of disagreeing (the disagreement is what corrupts in-place
  # animations — see Terminal::AMBIGUOUS_RANGES and Renderer#contiguous_after?).
  #
  # The technique is the classic cursor-position probe: print a test glyph at a
  # known column, ask the terminal where its cursor landed with DSR-CPR
  # (`\e[6n` → `\e[<row>;<col>R`), and the column delta is the glyph's real
  # display width. This only works against a live TTY in raw mode, which is why
  # it runs in the client (the piece that owns the terminal) and ships its
  # verdict to the server in the HELLO handshake.
  module WidthProbe
    # Formal East Asian Ambiguous glyphs (all > U+0300 so the class toggle can
    # actually reach them). A terminal in "ambiguous = wide" mode draws all of
    # these two columns wide; a narrow terminal draws them one. We sample several
    # and take a majority vote — the verdict configures Terminal.ambiguous_wide,
    # which covers the long tail of ambiguous glyphs we don't sample by hand.
    AMBIGUOUS_SAMPLES = ["…", "●", "→", "★", "◆"].freeze

    # Specific glyphs whose width no Unicode class reliably predicts because a
    # font may give them emoji presentation (drawn two wide) regardless of the
    # terminal's ambiguous setting. These are exactly the glyphs Claude Code's
    # UI animates in place. We measure each one individually and record its
    # exact width as a per-codepoint override — ground truth beats any heuristic.
    GLYPH_SAMPLES = ["⏺", "✻", "❯", "✦", "✳", "◼", "▪"].freeze

    # Overall wall-clock budget for the whole probe. A terminal that never
    # answers DSR (rare, but possible over flaky ttys / odd emulators) must not
    # wedge attach — we give up and fall back to defaults.
    TIMEOUT = 0.3

    # Probe the terminal reachable via +out+ (writable) and +input+ (readable),
    # which must already be in raw mode. Returns a capabilities hash suitable
    # for Protocol.encode_caps, e.g. {ambiguous: 2, glyphs: {0x23FA => 2}}.
    # Returns {} when the terminal doesn't answer (callers treat that as "use
    # defaults").
    def self.run(out: $stdout, input: $stdin, timeout: TIMEOUT)
      deadline = now + timeout
      caps = {}

      amb = AMBIGUOUS_SAMPLES.filter_map { |g| measure(g, out, input, deadline) }
      # No answers at all → terminal doesn't speak CPR; don't claim to know.
      return caps if amb.empty?
      wide = amb.count { |w| w >= 2 }
      caps[:ambiguous] = wide > (amb.length - wide) ? 2 : 1

      glyphs = {}
      GLYPH_SAMPLES.each do |g|
        w = measure(g, out, input, deadline)
        # Clamp to the 1/2 the grid understands; ignore non-answers and any
        # zero-advance oddity (an unrenderable glyph the terminal swallowed).
        glyphs[g.ord] = (w >= 2 ? 2 : 1) if w && w >= 1
      end
      caps[:glyphs] = glyphs unless glyphs.empty?
      caps
    ensure
      # Wipe whatever the probe painted; the server's first frame repaints all.
      out.write("\e[H\e[2J")
      out.flush
    end

    # Print +glyph+ at column 1 of the home row, then read the cursor column.
    # Returns the glyph's display width (col - 1) or nil if no CPR came back in
    # time. Latin-1 / ASCII control bytes in the glyph would skew the result,
    # so callers pass only printable test glyphs.
    def self.measure(glyph, out, input, deadline)
      out.write("\e[H#{glyph}\e[6n")
      out.flush
      col = read_cpr_col(input, deadline)
      return nil unless col
      col - 1
    end

    # Read a DSR-CPR reply (`\e[<row>;<col>R`, optionally `\e[?<row>;<col>R`)
    # from +input+, honoring the shared deadline. Bytes that aren't part of the
    # reply (none are expected this early in attach) are discarded. Returns the
    # column, or nil on timeout / closed input.
    def self.read_cpr_col(input, deadline)
      buf = +"".b
      loop do
        remaining = deadline - now
        return nil if remaining <= 0
        ready, = IO.select([input], nil, nil, remaining)
        return nil unless ready
        begin
          chunk = input.read_nonblock(64)
        rescue IO::WaitReadable
          next
        rescue EOFError, IOError, Errno::EIO
          return nil
        end
        buf << chunk
        if (m = buf.match(/\e\[\??\d+;(\d+)R/))
          return m[1].to_i
        end
        # Guard against a stream that never contains a terminator.
        return nil if buf.bytesize > 256
      end
    end

    def self.now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
