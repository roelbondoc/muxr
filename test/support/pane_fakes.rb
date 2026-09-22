module PaneFakes
  class ScriptedProcess
    attr_reader :io, :written

    def initialize(chunks = [])
      @chunks = chunks
      @io = Object.new
      @written = +""
    end

    def feed(*chunks)
      @chunks.concat(chunks)
    end

    def read_nonblock(_ = 8192)
      @chunks.shift
    end

    def writer_io; nil; end
    def pending_write?; false; end
    def drain; end
    def write(data); @written << data; end
    def resize(_, _); end
    def alive?; true; end
    def cwd; "/tmp"; end
    def pid; nil; end
    def close; end
  end

  class FakeClient
    attr_reader :bytes

    def initialize
      @bytes = +"".b
    end

    def write_nonblock(data)
      @bytes << data
      data.bytesize
    end
  end

  FakeSession = Struct.new(:window, :focus_drawer, :drawer)
end
