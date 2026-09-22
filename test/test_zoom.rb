require "test_helper"
require "stringio"
require "muxr"

class TestZoom < Minitest::Test
  def window(layout = :tall)
    Muxr::Window.new.tap do |w|
      3.times { w.add_pane(Object.new) }
      w.set_layout(layout)
    end
  end

  def test_zoom_goes_to_monocle_and_back
    win = window(:grid)
    win.toggle_zoom
    assert_equal :monocle, win.layout
    assert win.zoomed?
    win.toggle_zoom
    assert_equal :grid, win.layout
    refute win.zoomed?
  end

  def test_picking_a_layout_while_zoomed_forgets_the_zoom
    win = window(:tall)
    win.toggle_zoom
    win.set_layout(:wide)
    refute win.zoomed?
    win.toggle_zoom
    win.cycle_layout
    refute win.zoomed?
  end

  def test_zoom_in_plain_monocle_does_nothing
    win = window(:monocle)
    win.toggle_zoom
    assert_equal :monocle, win.layout
    refute win.zoomed?
  end

  def test_a_zoomed_session_saves_the_layout_underneath
    session = Muxr::Session.new(name: "spec")
    session.window.set_layout(:spiral)
    session.window.toggle_zoom
    assert_equal "spiral", session.serialize["layout"]
  end

  class FakePane
    attr_accessor :rect
    attr_reader :terminal

    def initialize
      @terminal = Muxr::Terminal.new(rows: 5, cols: 20)
    end

    def resize(rows, cols)
      @terminal.resize(rows, cols)
    end
  end

  def test_status_bar_says_what_zoom_will_restore
    session = Muxr::Session.new(name: "spec", width: 120, height: 20)
    2.times { session.window.add_pane(FakePane.new) }
    session.window.set_layout(:tall)
    session.window.toggle_zoom
    out = StringIO.new
    Muxr::Renderer.new(out: out).render(session)
    assert_includes out.string, "layout:zoom:tall"
  end

  class FakeRenderer
    def reset_frame!; end
  end

  def test_z_toggles_from_normal_mode_and_after_the_prefix
    app = Muxr::Application.new([])
    session = Muxr::Session.new(name: "spec")
    2.times { session.window.add_pane(Object.new) }
    session.window.set_layout(:wide)
    app.instance_variable_set(:@session, session)
    app.instance_variable_set(:@renderer, FakeRenderer.new)
    input = Muxr::InputHandler.new(app)
    input.feed("z")
    assert session.window.zoomed?
    input.enter_passthrough_mode
    input.feed("\x01z")
    assert_equal :wide, session.window.layout
  end
end
