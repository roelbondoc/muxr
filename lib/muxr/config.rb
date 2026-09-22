require "json"

module Muxr
  class Config
    DEFAULT_PATH = File.join(Dir.home, ".muxr", "config.json").freeze

    KEY_NAMES = {
      "Tab"   => "\t",
      "Enter" => "\r",
      "Space" => " ",
      "Esc"   => "\e"
    }.freeze

    RESERVED_NORMAL_KEYS = (["i", ":"] + ("1".."9").to_a).freeze
    RESERVED_PREFIX_KEYS = (["\e", ":"] + ("1".."9").to_a).freeze

    attr_reader :path, :errors, :layout, :scrollback, :master_ratio, :master_count,
                :auto_spiral_min_cols, :auto_spiral_min_rows, :prefix,
                :normal_keys, :prefix_keys

    def self.path_from_env
      path = ENV["MUXR_CONFIG"]
      path.nil? || path.empty? ? DEFAULT_PATH : path
    end

    def self.load(path = path_from_env)
      return new({}, path: path) unless File.exist?(path)
      data = JSON.parse(File.read(path))
      return new({}, path: path, errors: ["top level must be an object"]) unless data.is_a?(Hash)
      new(data, path: path)
    rescue JSON::ParserError => e
      new({}, path: path, errors: ["not valid JSON: #{e.message.lines.first.strip}"])
    rescue SystemCallError => e
      new({}, path: path, errors: ["cannot read: #{e.message}"])
    end

    def self.key_from_name(name)
      return nil unless name.is_a?(String) && !name.empty?
      return KEY_NAMES[name] if KEY_NAMES.key?(name)
      return (name[2].downcase.ord & 0x1f).chr if name.match?(/\AC-[a-zA-Z]\z/)
      name if name.length == 1
    end

    def self.action_name(binding)
      binding.is_a?(Array) ? binding.join(":") : binding.to_s
    end

    def self.actions
      @actions ||= (InputHandler::NORMAL_BINDINGS.values + InputHandler::PREFIX_BINDINGS.values)
                   .uniq.to_h { |binding| [action_name(binding), binding] }.freeze
    end

    def initialize(data, path: DEFAULT_PATH, errors: [])
      @path = path
      @errors = errors.dup
      @normal_keys = {}
      @prefix_keys = {}
      @prefix = InputHandler::PREFIX
      parse(data)
    end

    def empty?
      @layout.nil? && @scrollback.nil? && @master_ratio.nil? && @master_count.nil? &&
        @auto_spiral_min_cols.nil? && @auto_spiral_min_rows.nil? &&
        @prefix == InputHandler::PREFIX && @normal_keys.empty? && @prefix_keys.empty?
    end

    private

    KNOWN = %w[layout scrollback master_ratio master_count auto_spiral_min prefix keys].freeze

    def parse(data)
      (data.keys - KNOWN).each { |k| @errors << "unknown setting #{k.inspect}" }
      parse_layout(data["layout"]) if data.key?("layout")
      @scrollback = positive_integer("scrollback", data["scrollback"]) if data.key?("scrollback")
      parse_ratio(data["master_ratio"]) if data.key?("master_ratio")
      @master_count = positive_integer("master_count", data["master_count"]) if data.key?("master_count")
      parse_auto(data["auto_spiral_min"]) if data.key?("auto_spiral_min")
      parse_prefix(data["prefix"]) if data.key?("prefix")
      parse_keys(data["keys"]) if data.key?("keys")
    end

    def parse_layout(value)
      if value.is_a?(String) && LayoutManager::LAYOUTS.include?(value.to_sym)
        @layout = value.to_sym
      else
        @errors << "layout: #{value.inspect} is not one of #{LayoutManager::LAYOUTS.join(", ")}"
      end
    end

    def parse_ratio(value)
      if value.is_a?(Numeric) && LayoutManager::RATIO_BOUNDS.cover?(value)
        @master_ratio = value.to_f
      else
        @errors << "master_ratio: expected a number from #{LayoutManager::RATIO_BOUNDS.min} to #{LayoutManager::RATIO_BOUNDS.max}"
      end
    end

    def parse_auto(value)
      unless value.is_a?(Hash)
        @errors << "auto_spiral_min: expected {\"cols\": 180, \"rows\": 30}"
        return
      end
      @auto_spiral_min_cols = positive_integer("auto_spiral_min.cols", value["cols"]) if value.key?("cols")
      @auto_spiral_min_rows = positive_integer("auto_spiral_min.rows", value["rows"]) if value.key?("rows")
    end

    def parse_prefix(value)
      key = self.class.key_from_name(value)
      if key && key.ord < 0x20 && key != "\e"
        @prefix = key
      else
        @errors << "prefix: #{value.inspect} must be a control key like \"C-b\""
      end
    end

    def parse_keys(value)
      unless value.is_a?(Hash)
        @errors << "keys: expected {\"normal\": {...}, \"prefix\": {...}}"
        return
      end
      (value.keys - %w[normal prefix]).each { |k| @errors << "keys: unknown mode #{k.inspect}" }
      parse_key_table("normal", value["normal"], @normal_keys, RESERVED_NORMAL_KEYS) if value.key?("normal")
      parse_key_table("prefix", value["prefix"], @prefix_keys, RESERVED_PREFIX_KEYS + [@prefix]) if value.key?("prefix")
    end

    def parse_key_table(mode, table, into, reserved)
      unless table.is_a?(Hash)
        @errors << "keys.#{mode}: expected an object of key => action"
        return
      end
      table.each do |name, action|
        key = self.class.key_from_name(name)
        if key.nil?
          @errors << "keys.#{mode}: #{name.inspect} is not a key (use one character, C-x, Tab, Enter, Space or Esc)"
        elsif reserved.include?(key)
          @errors << "keys.#{mode}: #{name.inspect} is reserved"
        elsif action.nil?
          into[key] = nil
        elsif self.class.actions.key?(action)
          into[key] = self.class.actions[action]
        else
          @errors << "keys.#{mode}.#{name}: unknown action #{action.inspect}"
        end
      end
    end

    def positive_integer(name, value)
      return value if value.is_a?(Integer) && value.positive?
      @errors << "#{name}: expected a positive whole number"
      nil
    end
  end
end
