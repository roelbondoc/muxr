require "test_helper"
require "json"
require "muxr"

class TestConfig < Minitest::Test
  def with_config(data)
    Dir.mktmpdir("muxr-config") do |dir|
      path = File.join(dir, "config.json")
      File.write(path, data.is_a?(String) ? data : JSON.generate(data))
      yield Muxr::Config.load(path), path
    end
  end

  def test_a_missing_file_is_an_empty_config
    config = Muxr::Config.load("/nonexistent/muxr/config.json")
    assert config.empty?
    assert_empty config.errors
    assert_equal "\x01", config.prefix
  end

  def test_settings_are_read
    with_config("layout" => "tall", "scrollback" => 5000, "master_ratio" => 0.6,
                "master_count" => 2, "auto_spiral_min" => { "cols" => 200, "rows" => 40 },
                "prefix" => "C-b") do |config|
      assert_empty config.errors
      assert_equal :tall, config.layout
      assert_equal 5000, config.scrollback
      assert_equal 0.6, config.master_ratio
      assert_equal 2, config.master_count
      assert_equal 200, config.auto_spiral_min_cols
      assert_equal 40, config.auto_spiral_min_rows
      assert_equal "\x02", config.prefix
    end
  end

  def test_bad_values_are_reported_not_applied
    with_config("layout" => "diagonal", "scrollback" => -1, "master_ratio" => 2,
                "prefix" => "b", "colour" => "red") do |config|
      assert_nil config.layout
      assert_nil config.scrollback
      assert_nil config.master_ratio
      assert_equal "\x01", config.prefix
      assert_equal 5, config.errors.length
      assert config.errors.any? { |e| e.include?("unknown setting \"colour\"") }
    end
  end

  def test_invalid_json_is_one_error
    with_config("{ not json") do |config|
      assert config.empty?
      assert_equal 1, config.errors.length
      assert_match(/not valid JSON/, config.errors.first)
    end
  end

  def test_keys_map_to_existing_actions_and_null_unbinds
    with_config("keys" => { "normal" => { "Z" => "toggle_zoom", "T" => "set_layout:tall", "q" => nil },
                            "prefix" => { "Space" => "cycle_layout", "C-l" => "refresh_focused" } }) do |config|
      assert_empty config.errors
      assert_equal :toggle_zoom, config.normal_keys["Z"]
      assert_equal [:set_layout, :tall], config.normal_keys["T"]
      assert config.normal_keys.key?("q")
      assert_nil config.normal_keys["q"]
      assert_equal :cycle_layout, config.prefix_keys[" "]
      assert_equal :refresh_focused, config.prefix_keys["\x0c"]
    end
  end

  def test_reserved_keys_and_unknown_actions_are_refused
    with_config("keys" => { "normal" => { "i" => "detach", "3" => "detach", "x" => "self_destruct", "ab" => "detach" } }) do |config|
      assert_empty config.normal_keys
      assert_equal 4, config.errors.length
    end
  end

  class RecordingApp
    attr_reader :calls

    def initialize
      @calls = []
    end

    def method_missing(name, *args)
      @calls << [name, *args]
    end

    def respond_to_missing?(*) = true
  end

  def test_the_input_handler_honours_a_remap_and_a_new_prefix
    with_config("prefix" => "C-b", "keys" => { "normal" => { "Z" => "toggle_zoom", "q" => nil },
                                               "prefix" => { "Z" => "set_layout:grid" } }) do |config|
      app = RecordingApp.new
      input = Muxr::InputHandler.new(app)
      input.configure(config)
      input.feed("Zq")
      assert_equal [[:toggle_zoom]], app.calls
      input.enter_passthrough_mode
      app.calls.clear
      input.feed("ab\x01\x02Z\x02\x02")
      assert_equal [[:send_to_focused, "ab\x01"], [:set_layout, :grid], [:send_to_focused, "\x02"]], app.calls
    end
  end

  class FakeRenderer
    def reset_frame!; end
  end

  def test_the_app_applies_window_defaults_and_thresholds
    with_config("layout" => "wide", "master_ratio" => 0.7, "auto_spiral_min" => { "cols" => 90 }) do |config|
      app = Muxr::Application.new([])
      app.instance_variable_set(:@session, Muxr::Session.new(name: "spec"))
      app.instance_variable_set(:@input, Muxr::InputHandler.new(app))
      app.send(:apply_config, config)
      app.send(:apply_window_defaults)
      assert_equal :wide, app.session.window.layout
      assert_equal 0.7, app.session.window.master_ratio
      assert_equal 90, Muxr::LayoutManager.auto_spiral_min_cols
      assert_equal Muxr::LayoutManager::AUTO_SPIRAL_MIN_ROWS, Muxr::LayoutManager.auto_spiral_min_rows
    ensure
      Muxr::LayoutManager.auto_spiral_min_cols = nil
    end
  end

  def test_reload_reads_the_file_again
    with_config("layout" => "tall") do |_, path|
      app = Muxr::Application.new([])
      app.instance_variable_set(:@session, Muxr::Session.new(name: "spec"))
      input = Muxr::InputHandler.new(app)
      app.instance_variable_set(:@input, input)
      File.write(path, JSON.generate("prefix" => "C-b"))
      previous = ENV["MUXR_CONFIG"]
      ENV["MUXR_CONFIG"] = path
      begin
        app.reload_config
      ensure
        ENV["MUXR_CONFIG"] = previous
      end
      assert_equal "\x02", input.prefix
    end
  end
end
