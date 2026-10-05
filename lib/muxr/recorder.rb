require "json"
require "fileutils"

module Muxr
  class Recorder
    def self.open(path, rows:, cols:)
      FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
      new(File.open(path, "w"), rows: rows, cols: cols)
    end

    def initialize(io, rows:, cols:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, now: Time.now)
      @io = io
      @clock = clock
      @started = clock.call
      @pending = +"".b
      write_line(version: 2, width: cols, height: rows, timestamp: now.to_i, env: { "TERM" => ENV.fetch("TERM", "xterm-256color") })
    end

    def output(bytes)
      text = @pending + bytes.b
      held = incomplete_tail_length(text)
      @pending = text.byteslice(text.bytesize - held, held)
      text = text.byteslice(0, text.bytesize - held).force_encoding(Encoding::UTF_8).scrub
      event("o", text) unless text.empty?
    end

    def resize(rows, cols)
      event("r", "#{cols}x#{rows}")
    end

    def close
      @io.close unless @io.closed?
    end

    private

    def event(type, data)
      write_line([(@clock.call - @started).round(6), type, data])
    end

    def write_line(value)
      @io.write(JSON.generate(value), "\n")
      @io.flush
    end

    def incomplete_tail_length(bytes)
      (1..[3, bytes.bytesize].min).each do |back|
        b = bytes.getbyte(bytes.bytesize - back)
        return 0 if b < 0x80
        next if b < 0xc0
        needed = b >= 0xf0 ? 4 : b >= 0xe0 ? 3 : 2
        return needed > back ? back : 0
      end
      0
    end
  end
end
