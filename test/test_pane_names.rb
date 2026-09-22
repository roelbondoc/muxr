require "test_helper"
require "stringio"
require "muxr"
require_relative "support/pane_fakes"

class TestPaneNames < Minitest::Test
  include PaneFakes

  def pane(id = "aaaaaa")
    Muxr::Pane.new(id: id, process: ScriptedProcess.new)
  end

  def test_names_are_trimmed_capped_and_blank_means_none
    p = pane
    p.name = "  api server  "
    assert_equal "api server", p.name
    p.name = "x" * 40
    assert_equal Muxr::Pane::NAME_MAX, p.name.length
    p.name = "\e[31mred"
    assert_equal "[31mred", p.name
    p.name = "   "
    assert_nil p.name
    assert_equal "aaaaaa", p.label
  end

  def test_rename_command_labels_and_clears_the_focused_pane
    p = pane
    app = Muxr::Application.new([])
    win = Muxr::Window.new
    win.add_pane(p)
    app.instance_variable_set(:@session, FakeSession.new(win, false, nil))
    dispatcher = Muxr::CommandDispatcher.new(app)
    dispatcher.dispatch("rename web tests")
    assert_equal "web tests", p.name
    dispatcher.dispatch("rename")
    assert_nil p.name
  end

  def test_the_title_shows_the_name_in_place_of_the_id
    session = Muxr::Session.new(name: "spec", width: 100, height: 20)
    p = pane
    p.name = "api"
    session.window.add_pane(p)
    out = StringIO.new
    Muxr::Renderer.new(out: out).render(session)
    assert_includes out.string, "#1 api"
    refute_includes out.string, "aaaaaa"
  end

  def test_the_name_is_saved_with_the_session
    session = Muxr::Session.new(name: "spec")
    p = pane
    p.name = "db"
    session.window.add_pane(p)
    assert_equal "db", session.serialize["panes"][0]["name"]
  end

  class ControlApp
    attr_accessor :session
    def invalidate; end
  end

  def control_server(panes)
    app = ControlApp.new
    app.session = Muxr::Session.new(name: "spec")
    panes.each { |p| app.session.window.add_pane(p) }
    Muxr::Dispatcher.new(app, nil)
  end

  def test_control_surface_lists_and_resolves_names
    a, b = pane("aaaaaa"), pane("bbbbbb")
    b.name = "logs"
    server = control_server([a, b])
    listed = server.send(:panes_list)["panes"]
    assert_nil listed[0]["name"]
    assert_equal "logs", listed[1]["name"]
    assert_same b, server.send(:find_pane, { "pane" => "logs" })
    assert_same a, server.send(:find_pane, { "pane" => "aaaaaa" })
  end

  def test_an_id_wins_over_a_name_and_duplicates_are_refused
    a, b, c = pane("aaaaaa"), pane("bbbbbb"), pane("cccccc")
    b.name = "aaaaaa"
    c.name = "twin"
    d = pane("dddddd")
    d.name = "twin"
    server = control_server([a, b, c, d])
    assert_same a, server.send(:find_pane, { "pane" => "aaaaaa" })
    error = assert_raises(Muxr::Dispatcher::Error) { server.send(:find_pane, { "pane" => "twin" }) }
    assert_match(/2 panes are named/, error.message)
  end

  def test_a_private_pane_keeps_its_name_to_itself
    p = pane
    p.name = "secrets"
    p.mark_private!
    listed = control_server([p]).send(:panes_list)["panes"]
    assert_nil listed[0]["name"]
  end
end
