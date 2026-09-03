$LOAD_PATH.unshift(File.expand_path("../../../lib", __dir__))
require "muxr/image_store"
require "base64"

WIDTH  = 640
HEIGHT = 400

pixels = +"".b
HEIGHT.times do |y|
  WIDTH.times do |x|
    pixels << ((x * 255) / WIDTH) << ((y * 255) / HEIGHT) << (200 - (x * 120) / WIDTH) << 255
  end
end

png = Muxr::ImageStore.encode_png(pixels, WIDTH, HEIGHT, 4)
payload = Base64.strict_encode64(png)

chunks = payload.scan(/.{1,4000}/)
chunks.each_with_index do |chunk, i|
  more = i == chunks.length - 1 ? 0 : 1
  keys = i.zero? ? "a=T,f=100,m=#{more}" : "m=#{more}"
  print "\e_G#{keys};#{chunk}\e\\"
end
$stdout.flush
