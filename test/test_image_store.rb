require "test_helper"
require "muxr/image_store"

class TestImageStore < Minitest::Test
  def test_write_returns_a_path_holding_the_bytes
    Dir.mktmpdir do |dir|
      store = Muxr::ImageStore.new(dir: dir)
      path = store.write("payload")
      assert_equal dir, File.dirname(path)
      assert_equal "payload", File.binread(path)
    end
  end

  def test_write_creates_the_directory
    Dir.mktmpdir do |tmp|
      dir = File.join(tmp, "nested", "images")
      path = Muxr::ImageStore.new(dir: dir).write("x")
      assert File.file?(path)
    end
  end

  def test_prune_keeps_only_the_most_recent
    Dir.mktmpdir do |dir|
      existing = 5.times.map do |i|
        path = File.join(dir, "old-#{i}.png")
        File.binwrite(path, "old")
        File.utime(Time.now - (100 - i), Time.now - (100 - i), path)
        path
      end
      fresh = Muxr::ImageStore.new(dir: dir, keep: 3).write("new")
      remaining = Dir.glob(File.join(dir, "*.png")).sort
      assert_equal 3, remaining.length
      assert_equal ([fresh] + existing.last(2)).sort, remaining
    end
  end

  def test_encode_png_round_trips_dimensions
    pixels = ([255, 0, 0].pack("C3") * 6)
    png = Muxr::ImageStore.encode_png(pixels, 3, 2, 3)
    assert Muxr::ImageStore.png?(png)
    assert_equal [3, 2], Muxr::ImageStore.png_dimensions(png)
  end

  def test_encode_png_rejects_truncated_pixel_data
    assert_nil Muxr::ImageStore.encode_png("short", 100, 100, 4)
  end

  def test_encode_png_rejects_zero_dimensions
    assert_nil Muxr::ImageStore.encode_png("", 0, 5, 3)
  end

  def test_png_dimensions_returns_nil_for_non_png
    assert_nil Muxr::ImageStore.png_dimensions("not an image at all really")
  end

  def test_encoded_png_is_decodable_by_sips
    skip "sips is macOS-only" unless File.executable?("/usr/bin/sips")
    Dir.mktmpdir do |dir|
      pixels = ([0, 128, 255, 255].pack("C4") * (4 * 3))
      png = Muxr::ImageStore.encode_png(pixels, 4, 3, 4)
      path = Muxr::ImageStore.new(dir: dir).write(png)
      out = `/usr/bin/sips -g pixelWidth -g pixelHeight #{path} 2>&1`
      assert_match(/pixelWidth: 4/, out)
      assert_match(/pixelHeight: 3/, out)
    end
  end
end
