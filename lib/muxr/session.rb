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
        "panes"          => own_panes.map { |p| serialize_pane(p) },
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

    # Panes borrowed from another session are that session's to restore, not
    # ours: persisting one here would cold-start a second shell in its cwd and
    # quietly fork the thing the user was sharing.
    def own_panes
      @window.panes.reject { |p| p.respond_to?(:mirror?) && p.mirror? }
    end

    def serialize_pane(pane)
      entry = { "id" => safe_id(pane), "cwd" => safe_cwd(pane), "private" => safe_private(pane) }
      silence = pane.respond_to?(:silence_after) ? pane.silence_after : nil
      entry["silence"] = silence if silence
      entry
    end

    def safe_cwd(pane)
      pane.respond_to?(:cwd) ? pane.cwd : nil
    end

    def safe_id(pane)
      return nil unless pane.respond_to?(:id)
      id = pane.id
      id.is_a?(String) ? id : nil
    end

    def safe_private(pane)
      pane.respond_to?(:private?) && pane.private?
    end

    def serialize_drawer
      return nil unless @drawer
      {
        "visible" => @drawer.visible?,
        "cwd"     => @drawer.cwd,
        "command" => @drawer.respond_to?(:command) ? @drawer.command : nil
      }
    end
  end
end
