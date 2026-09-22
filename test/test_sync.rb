require "test_helper"
require "stringio"
require "muxr"
require_relative "support/pane_fakes"

class TestSync < Minitest::Test
  include PaneFakes

  class Drawer
    attr_reader :pane

    def initialize(pane)
      @pane = pane
    end

    def visible?; true; end
  end

  def pane(id)
    Muxr::Pane.new(id: id, process: ScriptedProcess.new)
  end

  def build_app(panes)
    app = Muxr::Application.new([])
    win = Muxr::Window.new
    panes.each { |p| win.add_pane(p) }
    app.instance_variable_set(:@session, FakeSession.new(win, false, nil))
    [app, win]
  end

  def written(p)
    p.process.written
  end

  def test_input_reaches_only_the_focused_pane_by_default
    a, b = pane("aaaaaa"), pane("bbbbbb")
    app, = build_app([a, b])
    app.send_to_focused("ls\r")
    assert_equal "ls\r", written(a)
    assert_equal "", written(b)
  end

  def test_sync_sends_keystrokes_and_pastes_to_every_pane
    a, b, c = pane("aaaaaa"), pane("bbbbbb"), pane("cccccc")
    app, = build_app([a, b, c])
    app.set_sync("on")
    app.send_to_focused("uptime\r")
    app.instance_variable_set(:@paste_buffer, +"echo hi")
    app.paste_from_buffer
    [a, b, c].each { |p| assert_equal "uptime\recho hi", written(p) }
  end

  def test_sync_toggles_and_rejects_nonsense
    app, win = build_app([pane("aaaaaa")])
    app.set_sync(nil)
    assert win.synchronized
    app.set_sync(nil)
    refute win.synchronized
    app.set_sync("maybe")
    refute win.synchronized
    assert_match(/expected on or off/, app.instance_variable_get(:@message))
  end

  def test_the_drawer_is_never_broadcast_to_or_from
    a, b, drawer = pane("aaaaaa"), pane("bbbbbb"), pane(:drawer)
    app, win = build_app([a, b])
    win.synchronized = true
    app.instance_variable_set(:@session, FakeSession.new(win, true, Drawer.new(drawer)))
    app.send_to_focused("x")
    assert_equal "x", written(drawer)
    assert_equal "", written(a)
    assert_equal "", written(b)
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

  def test_status_bar_warns_while_synced
    session = Muxr::Session.new(name: "spec", width: 120, height: 20)
    2.times { session.window.add_pane(FakePane.new) }
    session.window.synchronized = true
    out = StringIO.new
    Muxr::Renderer.new(out: out).render(session)
    assert_includes out.string, "[SYNC]"
  end
end
