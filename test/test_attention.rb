require "test_helper"
require "stringio"
require "muxr"
require_relative "support/pane_fakes"

class TestAttention < Minitest::Test
  include PaneFakes

  def pane(id)
    Muxr::Pane.new(id: id, process: ScriptedProcess.new)
  end

  def build_app(panes, client: FakeClient.new)
    app = Muxr::Application.new([])
    win = Muxr::Window.new
    panes.each { |p| win.add_pane(p) }
    app.instance_variable_set(:@session, FakeSession.new(win, false, nil))
    app.instance_variable_set(:@current_client, client)
    app
  end

  def deliver(app, pane, *chunks)
    pane.process.feed(*chunks)
    app.send(:consume_pane_io, pane.io)
  end

  def test_output_is_ignored_during_the_grace_after_a_resize
    p = pane("aaaaaa")
    now = Muxr::Pane.now
    p.hush!(now)
    p.note_output(now + 0.1)
    refute p.activity?
    p.note_output(now + Muxr::Pane::ATTENTION_GRACE)
    assert p.activity?
  end

  def test_clear_attention_drops_both_markers
    p = pane("aaaaaa")
    p.note_output(Muxr::Pane.now + 60)
    p.note_bell
    p.clear_attention!
    refute p.activity?
    refute p.bell?
  end

  def test_a_background_pane_is_marked_but_the_focused_one_is_not
    focused = pane("aaaaaa")
    background = pane("bbbbbb")
    app = build_app([focused, background])
    [focused, background].each { |p| p.instance_variable_set(:@quiet_until, 0) }
    deliver(app, focused, "hello")
    deliver(app, background, "hello")
    refute focused.activity?
    assert background.activity?
  end

  def test_a_bell_marks_the_pane_and_still_reaches_the_outer_terminal
    client = FakeClient.new
    background = pane("bbbbbb")
    app = build_app([pane("aaaaaa"), background], client: client)
    deliver(app, background, "\a")
    assert background.bell?
    assert_includes client.bytes, "\a"
  end

  def test_the_focused_pane_is_marked_while_nobody_is_attached
    focused = pane("aaaaaa")
    app = build_app([focused], client: nil)
    deliver(app, focused, "\a")
    assert focused.bell?
  end

  def test_rendering_clears_the_focused_pane
    focused = pane("aaaaaa")
    focused.note_bell
    app = build_app([focused])
    app.send(:clear_focused_attention)
    refute focused.bell?
  end

  class MarkedPane
    attr_accessor :rect
    attr_reader :terminal

    def initialize(bell: false, activity: false)
      @terminal = Muxr::Terminal.new(rows: 5, cols: 20)
      @bell = bell
      @activity = activity
    end

    def bell?; @bell; end
    def activity?; @activity; end
    def resize(rows, cols); @terminal.resize(rows, cols); end
  end

  def test_titles_and_status_bar_show_which_panes_want_attention
    session = Muxr::Session.new(name: "spec", width: 120, height: 20)
    session.window.add_pane(MarkedPane.new)
    session.window.add_pane(MarkedPane.new(bell: true))
    session.window.add_pane(MarkedPane.new(activity: true))
    session.window.set_layout(:tall)
    out = StringIO.new
    Muxr::Renderer.new(out: out).render(session)
    screen = Muxr::Terminal.new(rows: 20, cols: 120)
    screen.feed(out.string)
    text = screen.dump_text
    assert_includes text, "#2!"
    assert_includes text, "#3•"
    assert_includes text, "alerts:2!,3•"
  end
end
