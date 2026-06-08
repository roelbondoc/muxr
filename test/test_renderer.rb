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

  def test_monocle_title_shows_position_and_mode_chip
    session = build_session(layout: :monocle, focused_index: 1)
    output = render(session)
    assert_includes output, "#2/3"
    # The mode chip lives in the top-right corner of the focused pane,
    # not in the title. After stripping ANSI escapes, the visual layout
    # of the top border should put #2/3 on the left and [NORMAL] on the
    # right (with the mode chip closer to the closing corner).
    plain = output.gsub(/\e\[[?0-9;]*[a-zA-Z]/, "")
    top = plain.lines.first
    pane_idx = top.index("#2/3")
    chip_idx = top.index("[NORMAL]")
    refute_nil pane_idx
    refute_nil chip_idx
    assert chip_idx > pane_idx, "mode chip should be to the right of the pane label"
  end

  # The Renderer treats foreground_command as optional (FakePane doesn't
  # define it); when it IS present, the value should appear after the mode
  # chip, separated by " · ".
  class FakePaneWithCommand < FakePane
    attr_accessor :foreground_command
    def initialize(label:, command: nil)
      super(label: label)
      @foreground_command = command
    end
  end

  def test_title_shows_foreground_command_after_mode
    session = Muxr::Session.new(name: "spec", width: 60, height: 12)
    session.window.add_pane(FakePaneWithCommand.new(label: "X", command: "npm test"))
    session.window.set_layout(:monocle)
    session.window.focused_index = 0
    output = render(session)
    assert_includes output, "· npm test"
  end

  def test_title_omits_separator_when_no_foreground_command
    session = Muxr::Session.new(name: "spec", width: 60, height: 12)
    session.window.add_pane(FakePaneWithCommand.new(label: "X", command: nil))
    session.window.set_layout(:monocle)
    session.window.focused_index = 0
    output = render(session)
    refute_includes output, " · "
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

  # Tiny pane that feeds a wrapping OSC 8 link into its terminal — the
  # canonical "long URL spans multiple rows" case the passthrough exists for.
  class WrappedLinkPane < FakePane
    def initialize
      super(label: "")
      @terminal.feed("\e]8;;https://example.com/longpath\e\\AAAAAAAAA\e]8;;\e\\")
    end
  end

  def test_osc_8_hyperlink_passthrough_wraps_run_with_one_open_and_close
    session = Muxr::Session.new(name: "spec", width: 40, height: 12)
    session.window.add_pane(WrappedLinkPane.new)
    session.window.set_layout(:monocle)
    session.window.focused_index = 0
    output = render(session)
    # One open with the original payload, exactly one close. Both Ghostty and
    # kitty merge a wrapped run into a single clickable URL when the
    # hyperlink stays open across the cursor-positioning emits between cells.
    assert_includes output, "\e]8;;https://example.com/longpath\e\\"
    assert_equal 1, output.scan("\e]8;;https://example.com/longpath\e\\").length
    assert_equal 1, output.scan("\e]8;;\e\\").length
  end

  def test_wide_char_emitted_once_with_following_glyph_contiguous
    session = Muxr::Session.new(name: "spec", width: 40, height: 12)
    session.window.add_pane(FakePane.new(label: "中x"))
    session.window.set_layout(:monocle)
    session.window.focused_index = 0
    output = render(session)
    # The wide glyph is emitted exactly once — its continuation half is never
    # written, so we don't double-draw it or shove the trailing 'x' over.
    assert_equal 1, output.scan("中").length
    # With width-aware cursor tracking the 'x' lands one column past the wide
    # glyph's two columns, so it follows contiguously with no cursor-position
    # escape wedged between them.
    assert_includes output, "中x"
  end
end
