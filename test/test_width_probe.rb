require "test_helper"
require "stringio"
require "muxr/width_probe"

class TestWidthProbe < Minitest::Test
  # Stand in for a real terminal: read what the probe writes, and for every
  # DSR-CPR query (`\e[6n`) reply with a cursor column that reflects a fixed
  # per-glyph display width. Each sample prints exactly one glyph before its
  # query, so col = 1 + width is the right answer without parsing the glyph.
  def with_fake_terminal(width:)
    probe_out_r, probe_out_w = IO.pipe   # probe writes here; terminal reads
    reply_r, reply_w = IO.pipe           # terminal writes here; probe reads

    responder = Thread.new do
      buf = +"".b
      begin
        loop do
          chunk = probe_out_r.readpartial(256)
          buf << chunk
          while buf.sub!(/\A.*?\e\[6n/m, "")
            reply_w.write("\e[1;#{1 + width}R")
            reply_w.flush
          end
        end
      rescue EOFError, IOError
        # probe closed its write end — done.
      end
    end

    yield probe_out_w, reply_r
  ensure
    probe_out_w.close rescue nil
    responder&.join
    [probe_out_r, reply_r, reply_w].each { |io| io.close rescue nil }
  end

  def test_reports_ambiguous_wide_when_terminal_draws_two_columns
    with_fake_terminal(width: 2) do |out, input|
      caps = Muxr::WidthProbe.run(out: out, input: input, timeout: 1.0)
      assert_equal 2, caps[:ambiguous]
    end
  end

  def test_reports_ambiguous_narrow_when_terminal_draws_one_column
    with_fake_terminal(width: 1) do |out, input|
      caps = Muxr::WidthProbe.run(out: out, input: input, timeout: 1.0)
      assert_equal 1, caps[:ambiguous]
    end
  end

  def test_records_per_glyph_overrides_for_emoji_presentation_glyphs
    with_fake_terminal(width: 2) do |out, input|
      caps = Muxr::WidthProbe.run(out: out, input: input, timeout: 1.0)
      # ⏺/✻/❯ — the glyphs Claude Code animates — get exact measured widths,
      # keyed by codepoint, even though no Unicode width class predicts them.
      assert_equal 2, caps[:glyphs][0x23FA]
      assert_equal 2, caps[:glyphs][0x273B]
      assert_equal 2, caps[:glyphs][0x276F]
    end
  end

  def test_returns_empty_caps_when_terminal_never_answers
    # A read end with no writer: select blocks until the deadline, then we give
    # up. No verdict is better than a wrong default.
    _r, w = IO.pipe
    silent = StringIO.new
    caps = Muxr::WidthProbe.run(out: silent, input: _r, timeout: 0.05)
    assert_empty caps
  ensure
    [_r, w].each { |io| io.close rescue nil }
  end
end
