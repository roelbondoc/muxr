require "test_helper"
require "open3"
require "rbconfig"
require "json"

class TestCliHelp < Minitest::Test
  MUXR = File.expand_path("../bin/muxr", __dir__)

  def help_with(config)
    Dir.mktmpdir("muxr-help") do |dir|
      path = File.join(dir, "config.json")
      File.write(path, JSON.generate(config)) if config
      out, status = Open3.capture2({ "MUXR_CONFIG" => path }, RbConfig.ruby, MUXR, "--help")
      assert status.success?
      return [out, path]
    end
  end

  def test_help_names_the_default_prefix
    out, = help_with(nil)
    assert_includes out, "Keybindings (Ctrl-a prefix):"
    assert_includes out, "C-a C-a send literal C-a"
  end

  def test_help_names_the_configured_prefix_and_where_it_came_from
    out, path = help_with("prefix" => "C-b")
    assert_includes out, "Keybindings (Ctrl-b prefix, from #{path.sub(Dir.home, "~")}):"
    assert_includes out, "C-b c   new pane"
    assert_includes out, "C-b C-b send literal C-b"
    refute_includes out, "C-a"
  end
end
