module Muxr
  class DirectoryPrompt
    Preview = Struct.new(:dir, :session, :running, keyword_init: true)

    attr_reader :buffer, :base, :candidates

    def initialize(base:, buffer: "")
      @base = base
      @buffer = +buffer.to_s
      @candidates = []
    end

    def type(text)
      @buffer << text
      @candidates = []
    end

    def backspace
      @buffer.chop!
      @candidates = []
    end

    def clear
      @buffer.clear
      @candidates = []
    end

    def delete_component
      @buffer.sub!(%r{[^/]*/?\z}, "")
      @candidates = []
    end

    def complete
      head, partial = split_buffer
      names = matching_directories(head, partial)
      return @candidates = [] if names.empty?
      @buffer = +"#{head}#{common_prefix(names)}"
      if names.length == 1
        @buffer << "/"
        @candidates = []
      else
        @candidates = names
      end
    end

    def resolved_dir
      return nil if @buffer.strip.empty?
      path = File.expand_path(@buffer.strip, @base)
      File.directory?(path) ? File.realpath(path) : nil
    rescue SystemCallError
      nil
    end

    def preview
      dir = resolved_dir
      return nil unless dir
      session = Application.default_session_name(dir)
      Preview.new(dir: dir, session: session, running: File.exist?(Application.socket_path_for(session)))
    end

    private

    def split_buffer
      slash = @buffer.rindex("/")
      return ["", @buffer] unless slash
      [@buffer[0..slash], @buffer[(slash + 1)..]]
    end

    def matching_directories(head, partial)
      search = File.expand_path(head.empty? ? "." : head, @base)
      Dir.children(search).select do |name|
        next false if name.start_with?(".") && !partial.start_with?(".")
        name.start_with?(partial) && File.directory?(File.join(search, name))
      end.sort
    rescue SystemCallError
      []
    end

    def common_prefix(names)
      shortest = names.min_by(&:length)
      shortest.length.downto(0) do |len|
        prefix = shortest[0, len]
        return prefix if names.all? { |name| name.start_with?(prefix) }
      end
      ""
    end
  end
end
