require "test_helper"
require "muxr"
require_relative "support/pane_fakes"

class TestSilence < Minitest::Test
  include PaneFakes

  def pane(id = "aaaaaa")
    Muxr::Pane.new(id: id, process: ScriptedProcess.new).tap { |p| p.instance_variable_set(:@quiet_until, 0) }
  end

  def build_app(panes, client: FakeClient.new)
    app = Muxr::Application.new([])
    win = Muxr::Window.new
    panes.each { |p| win.add_pane(p) }
    app.instance_variable_set(:@session, FakeSession.new(win, false, nil))
    app.instance_variable_set(:@current_client, client)
    app
  end

  def test_an_unwatched_pane_is_never_due
    refute pane.silence_due?(Muxr::Pane.now + 3600)
  end

  def test_due_once_the_threshold_passes_without_output
    p = pane
    p.watch_silence(30, 100.0)
    refute p.silence_due?(129.0)
    assert p.silence_due?(130.0)
  end

  def test_output_restarts_the_countdown_and_clears_the_marker
    p = pane
    p.watch_silence(30, 100.0)
    p.note_silence!
    assert p.silent?
    p.note_output(120.0)
    refute p.silent?
    refute p.silence_due?(149.0)
    assert p.silence_due?(150.0)
  end

  def test_reported_once_per_quiet_spell
    p = pane
    p.watch_silence(30, 100.0)
    p.note_silence!
    refute p.silence_due?(500.0)
  end

  def test_the_app_flashes_marks_and_rings_when_a_pane_goes_quiet
    client = FakeClient.new
    quiet = pane("bbbbbb")
    app = build_app([pane, quiet], client: client)
    quiet.watch_silence(5, Muxr::Pane.now - 10)
    app.send(:report_silent_panes)
    assert quiet.silent?
    assert_includes client.bytes, "\a"
    assert_equal "pane #2 silent for 5s", app.instance_variable_get(:@message)
  end

  def test_command_arms_and_disarms_the_focused_pane
    p = pane
    app = build_app([p])
    Muxr::CommandDispatcher.new(app).dispatch("silence 2m")
    assert_equal 120, p.silence_after
    Muxr::CommandDispatcher.new(app).dispatch("silence 45")
    assert_equal 45, p.silence_after
    Muxr::CommandDispatcher.new(app).dispatch("silence off")
    assert_nil p.silence_after
    Muxr::CommandDispatcher.new(app).dispatch("silence soon")
    assert_nil p.silence_after
    assert_match(/expected seconds/, app.instance_variable_get(:@message))
  end

  def test_the_threshold_survives_a_save
    session = Muxr::Session.new(name: "spec")
    p = pane
    p.watch_silence(90)
    session.window.add_pane(p)
    assert_equal 90, session.serialize["panes"][0]["silence"]
  end
end
