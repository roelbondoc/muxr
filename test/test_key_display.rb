require "test_helper"
require "stringio"
require "muxr"
require_relative "support/pane_fakes"

class TestKeyDisplay < Minitest::Test
  include PaneFakes

  def setup
    @now = 0.0
    @keys = Muxr::KeyDisplay.new(prefix: "\x01", clock: -> { @now })
  end

  def test_normal_mode_keys_are_named
    @keys.note("c", :normal)
    @keys.note("\r", :normal)
    @keys.note("\e[A", :normal)
    @keys.note("\t", :normal)
    @keys.note("\x04", :normal)
    @keys.note(" ", :normal)
    assert_equal %w[c Enter Up Tab C-d Space], @keys.labels
  end

  def test_passthrough_shows_only_the_prefix_chord
    @keys.note("ls -la\r", :passthrough)
    assert_empty @keys.labels
    @keys.note("x\x01", :passthrough)
    @keys.note("\e", :prefix)
    assert_equal %w[C-a Esc], @keys.labels
  end

  def test_text_typed_into_a_prompt_is_left_to_the_prompt
    @keys.note(":", :normal)
    @keys.note("layout grid", :command)
    @keys.note("\t", :command)
    @keys.note("\r", :command)
    assert_equal %w[: Tab Enter], @keys.labels
  end

  def test_keys_fade_and_the_list_is_bounded
    15.times { @keys.note("j", :normal) }
    assert_equal Muxr::KeyDisplay::MAX_KEYS, @keys.labels.length
    @now = Muxr::KeyDisplay::TTL + 1
    @keys.note("k", :normal)
    assert @keys.expire!
    assert_equal %w[k], @keys.labels
    refute @keys.expire!
  end

  def test_showkeys_toggles_and_rejects_nonsense
    app = Muxr::Application.new([])
    win = Muxr::Window.new
    win.add_pane(Muxr::Pane.new(id: "aaaaaa", process: ScriptedProcess.new))
    app.instance_variable_set(:@session, FakeSession.new(win, false, nil))
    app.instance_variable_set(:@input, Muxr::InputHandler.new(app))
    assert_nil app.key_labels
    app.set_show_keys(nil)
    assert_equal [], app.key_labels
    app.set_show_keys("off")
    assert_nil app.key_labels
    app.set_show_keys("maybe")
    assert_nil app.key_labels
  end

  def test_show_keys_is_a_config_setting
    assert_equal true, Muxr::Config.new({ "show_keys" => true }).show_keys
    config = Muxr::Config.new({ "show_keys" => "yes" })
    assert_nil config.show_keys
    assert_equal ["show_keys: expected true or false"], config.errors
  end

  def test_the_status_bar_carries_the_keys
    session = Muxr::Session.new(name: "spec", width: 120, height: 20)
    out = StringIO.new
    Muxr::Renderer.new(out: out).render(session, keys: %w[c c t Enter])
    assert_includes out.string, " c  c  t  Enter "
  end
end
