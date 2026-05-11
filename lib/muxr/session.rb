require "json"
require "fileutils"

module Muxr
  # A Session bundles the user's Window + Drawer plus a snapshot of the
  # terminal dimensions. It is responsible for persisting/restoring its own
  # state as JSON on disk (~/.muxr/sessions/<name>.json). Only the shape of
  # the session (pane count, layout, cwds, drawer state) is persisted — the
  # live shell history is not.
  class Session
    SESSIONS_DIR = File.join(Dir.home, ".muxr", "sessions").freeze

    attr_accessor :width, :height, :window, :drawer, :focus_drawer
    attr_reader :name

    def initialize(name: "default", width: 80, height: 24)
      @name = name
      @width = width
      @height = height
      @window = Window.new(name: name)
      @drawer = nil
      @focus_drawer = false
    end

    def save_path
      File.join(SESSIONS_DIR, "#{@name}.json")
    end

    def self.save_path_for(name)
      File.join(SESSIONS_DIR, "#{name}.json")
    end

    def save
      FileUtils.mkdir_p(SESSIONS_DIR)
      File.write(save_path, JSON.pretty_generate(serialize))
      save_path
    end

    def serialize
      {
        "name"           => @name,
        "width"          => @width,
        "height"         => @height,
        "layout"         => @window.layout.to_s,
        "focused_index"  => @window.focused_index,
        "master_index"   => @window.master_index,
        "focus_drawer"   => @focus_drawer,
        "panes"          => @window.panes.map { |p| { "cwd" => safe_cwd(p) } },
        "drawer"         => serialize_drawer
      }
    end

    def self.load(name)
      path = save_path_for(name)
      return nil unless File.exist?(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def self.exists?(name)
      File.exist?(save_path_for(name))
    end

    def self.list
      return [] unless File.directory?(SESSIONS_DIR)
      Dir.children(SESSIONS_DIR).filter_map do |entry|
        next unless entry.end_with?(".json")
        File.basename(entry, ".json")
      end.sort
    end

    private

    def safe_cwd(pane)
      pane.respond_to?(:cwd) ? pane.cwd : nil
    end

    def serialize_drawer
      return nil unless @drawer
      {
        "visible" => @drawer.visible?,
        "cwd"     => @drawer.cwd
      }
    end
  end
end
