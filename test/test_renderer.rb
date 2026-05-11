require "test_helper"
require "stringio"
require "muxr/renderer"

class TestRenderer < Minitest::Test
  # Renderer duck-types panes on rect/terminal/resize, so a small struct
  # backed by a real Terminal is enough to exercise compose_panes without
  # spawning PTYs.
  class FakePane
    attr_accessor :rect
    attr_reader :terminal, :label

    def initialize(label:, rows: 9, cols: 38)
      @label = label
      @terminal = Muxr::Terminal.new(rows: rows, cols: cols)
      @terminal.feed(label)
      @rect = nil
    end

    def resize(rows, cols)
      @terminal.resize(rows, cols)
    end
  end

  def build_session(layout:, focused_index:, pane_labels: %w[AAA BBB CCC])
    session = Muxr::Session.new(name: "spec", width: 40, height: 12)
    pane_labels.each { |l| session.window.add_pane(FakePane.new(label: l)) }
    session.window.set_layout(layout)
    session.window.focused_index = focused_index
    session
  end

  def render(session)
    out = StringIO.new
    renderer = Muxr::Renderer.new(out: out)
    renderer.render(session)
    out.string
  end

  def test_monocle_renders_focused_pane_not_last_pane
    session = build_session(layout: :monocle, focused_index: 0)
    output = render(session)
    assert_includes output, "AAA"
    refute_includes output, "BBB"
    refute_includes output, "CCC"
  end

  def test_monocle_switches_visible_pane_when_focus_changes
    session = build_session(layout: :monocle, focused_index: 0)
    render(session)
    session.window.focused_index = 2
    output = render(session)
    assert_includes output, "CCC"
    refute_includes output, "AAA"
    refute_includes output, "BBB"
  end

  def test_monocle_title_shows_position_and_layout_hint
    session = build_session(layout: :monocle, focused_index: 1)
    output = render(session)
    assert_includes output, "#2/3"
    assert_includes output, "(monocle)"
  end

  def test_non_focused_panes_still_get_resized_in_monocle
    # Important: even though we skip drawing, the off-screen panes need to be
    # sized to the full area so their PTYs are ready when focus moves.
    session = build_session(layout: :monocle, focused_index: 0)
    render(session)
    other = session.window.panes[2]
    # Full area minus the surrounding border: 40 cols - 2, 11 rows - 2
    # (height is session.height - 1 for the status bar).
    assert_equal 38, other.terminal.cols
    assert_equal 9, other.terminal.rows
  end
end
