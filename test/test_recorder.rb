require "test_helper"
require "json"
require "stringio"
require "muxr/recorder"

class TestRecorder < Minitest::Test
  def setup
    @io = StringIO.new
    @now = 100.0
    @recorder = Muxr::Recorder.new(@io, rows: 24, cols: 80, clock: -> { @now }, now: Time.at(1_700_000_000))
  end

  def lines
    @io.string.lines.map { |line| JSON.parse(line) }
  end

  def test_the_header_is_asciicast_v2_at_the_terminal_size
    header = lines.first
    assert_equal 2, header["version"]
    assert_equal 80, header["width"]
    assert_equal 24, header["height"]
    assert_equal 1_700_000_000, header["timestamp"]
  end

  def test_output_and_resize_are_timed_from_the_start
    @now = 101.25
    @recorder.output("\e[H\e[31mhi".b)
    @now = 102.5
    @recorder.resize(30, 120)
    assert_equal [[1.25, "o", "\e[H\e[31mhi"], [2.5, "r", "120x30"]], lines.drop(1)
  end

  def test_a_glyph_split_across_frames_is_held_until_it_is_whole
    bytes = "a⏺b".b
    @recorder.output(bytes.byteslice(0, 3))
    @recorder.output(bytes.byteslice(3..))
    assert_equal ["a", "⏺b"], lines.drop(1).map(&:last)
  end

  def test_a_stray_byte_is_scrubbed_rather_than_breaking_the_file
    @recorder.output("x\xffy".b)
    assert_equal "x�y", lines.last.last
  end

  def test_open_creates_the_directory
    Dir.mktmpdir do |dir|
      path = File.join(dir, "casts", "demo.cast")
      recorder = Muxr::Recorder.open(path, rows: 10, cols: 40)
      recorder.output("ok".b)
      recorder.close
      assert_equal 40, JSON.parse(File.readlines(path).first)["width"]
    end
  end
end
