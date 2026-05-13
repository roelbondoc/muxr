require "test_helper"

class TestDrawer < Minitest::Test
  class FakePane
    attr_accessor :cwd
    attr_reader :closed

    def initialize(cwd)
      @cwd = cwd
      @closed = false
    end

    def close
      @closed = true
    end
  end

  def test_defaults_to_hidden
    drawer = Muxr::Drawer.new(pane: FakePane.new("/tmp"))
    refute drawer.visible?
  end

  def test_toggle_flips_visibility
    drawer = Muxr::Drawer.new(pane: FakePane.new("/tmp"))
    drawer.toggle!
    assert drawer.visible?
    drawer.toggle!
    refute drawer.visible?
  end

  def test_show_and_hide_are_idempotent
    drawer = Muxr::Drawer.new(pane: FakePane.new("/tmp"))
    drawer.show!
    drawer.show!
    assert drawer.visible?
    drawer.hide!
    drawer.hide!
    refute drawer.visible?
  end

  def test_cwd_prefers_pane
    drawer = Muxr::Drawer.new(pane: FakePane.new("/tmp/foo"), origin_cwd: "/tmp")
    assert_equal "/tmp/foo", drawer.cwd
  end

  def test_cwd_falls_back_to_origin_when_pane_missing
    drawer = Muxr::Drawer.new(pane: nil, origin_cwd: "/srv/x")
    assert_equal "/srv/x", drawer.cwd
  end

  def test_close_closes_pane_and_clears_state
    pane = FakePane.new("/tmp")
    drawer = Muxr::Drawer.new(pane: pane)
    drawer.show!
    drawer.close
    assert pane.closed
    refute drawer.visible?
    assert_nil drawer.pane
  end

  def test_command_attribute_defaults_to_nil
    drawer = Muxr::Drawer.new(pane: FakePane.new("/tmp"))
    assert_nil drawer.command
  end

  def test_command_attribute_captures_constructor_value
    drawer = Muxr::Drawer.new(pane: FakePane.new("/tmp"), command: "claude")
    assert_equal "claude", drawer.command
  end
end
