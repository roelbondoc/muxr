require "fileutils"
require "securerandom"
require "zlib"

module Muxr
  class ImageStore
    IMAGES_DIR = File.join(Dir.home, ".muxr", "images").freeze
    KEEP_RECENT = 200
    PNG_MAGIC = "\x89PNG\r\n\x1a\n".b.freeze

    def initialize(dir: IMAGES_DIR, keep: KEEP_RECENT)
      @dir = dir
      @keep = keep
    end

    def write(bytes)
      FileUtils.mkdir_p(@dir)
      path = File.join(@dir, "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}.png")
      File.binwrite(path, bytes)
      prune
      path
    end

    def self.png?(bytes)
      bytes.byteslice(0, PNG_MAGIC.bytesize) == PNG_MAGIC
    end

    def self.png_dimensions(bytes)
      return nil unless png?(bytes) && bytes.bytesize >= 24
      return nil unless bytes.byteslice(12, 4) == "IHDR"
      bytes.byteslice(16, 8).unpack("NN")
    end

    def self.encode_png(pixels, width, height, channels)
      return nil if width <= 0 || height <= 0
      stride = width * channels
      return nil if pixels.bytesize < stride * height
      scanlines = +"".b
      height.times { |y| scanlines << "\x00".b << pixels.byteslice(y * stride, stride) }
      header = [width, height].pack("NN") << [8, channels == 4 ? 6 : 2, 0, 0, 0].pack("C5")
      +"".b << PNG_MAGIC <<
        png_chunk("IHDR", header) <<
        png_chunk("IDAT", Zlib::Deflate.deflate(scanlines)) <<
        png_chunk("IEND", +"".b)
    end

    def self.png_chunk(type, data)
      body = type.b << data.b
      +"".b << [data.bytesize].pack("N") << body << [Zlib.crc32(body)].pack("N")
    end
    private_class_method :png_chunk

    private

    def prune
      entries = Dir.glob(File.join(@dir, "*.png"))
      return if entries.length <= @keep
      FileUtils.rm_f(entries.sort_by { |p| File.mtime(p) }.first(entries.length - @keep))
    end
  end
end
