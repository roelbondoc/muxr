require "test_helper"
require "muxr/pane"
require "muxr/control_server"

class TestPaneStatus < Minitest::Test
  class FakeProcess
    attr_accessor :pid

    def initialize(pid: 4242)
      @pid = pid
    end

    def io; nil; end
    def writer_io; nil; end
    def pending_write?; false; end
    def write(_); end
    def resize(_, _); end
    def alive?; true; end
    def cwd; "/tmp/status"; end
    def close; end
  end

  CLAUDE_TURN_START = "\e]0;✳ Claude Code\a\e]9;4;0;\a\e]0;◐ Claude Code\a\e]9;4;3;\a\e]0;◐ Reply with ok\a".b
  CLAUDE_TURN_END = "\e]0;✳ Reply with ok\a\e]9;4;0;\a".b
  CLAUDE_WAITING = "\e]777;notify;Claude Code;Claude is waiting for your input\a".b

  def terminal
    Muxr::Terminal.new(rows: 5, cols: 20)
  end

  def test_the_window_title_is_kept_but_never_queued_for_the_outer_terminal
    term = terminal
    term.feed("\e]2;build: 3/10\e\\".b)
    assert_equal "build: 3/10", term.title
    assert_nil term.take_pending_notifications!
  end

  def test_a_title_has_control_bytes_stripped_and_is_capped
    term = terminal
    term.feed("\e]0;a\x01b#{"x" * 500}\a".b)
    assert term.title.start_with?("ab")
    assert_equal Muxr::Terminal::STATUS_TEXT_MAX, term.title.length
  end

  def test_progress_follows_a_claude_turn
    term = terminal
    term.feed(CLAUDE_TURN_START)
    assert_equal [3, nil], term.progress
    assert_equal "◐ Reply with ok", term.title
    term.feed(CLAUDE_TURN_END)
    assert_nil term.progress
    assert_equal "✳ Reply with ok", term.title
  end

  def test_progress_with_a_percentage
    term = terminal
    term.feed("\e]9;4;1;40\a".b)
    assert_equal [1, 40], term.progress
  end

  def test_progress_is_still_forwarded_but_is_not_an_alert
    term = terminal
    term.feed("\e]9;4;3;\a".b)
    assert_equal "\e]9;4;3;\a".b, term.take_pending_notifications!
    refute term.take_alert!
  end

  def test_a_notification_is_recorded_and_alerts
    term = terminal
    term.feed(CLAUDE_WAITING)
    assert_equal "Claude Code: Claude is waiting for your input", term.notice
    assert term.notice_at
    assert term.take_alert!
    refute term.take_alert!
  end

  def test_an_osc_9_message_is_a_notice
    term = terminal
    term.feed("\e]9;tests finished\a".b)
    assert_equal "tests finished", term.notice
  end

  def test_a_bare_bell_alerts
    term = terminal
    term.feed("\a".b)
    assert term.take_alert!
  end

  def test_pane_state_is_busy_while_progress_is_up_and_the_program_is_foreground
    pane = Muxr::Pane.new(process: FakeProcess.new)
    pane.foreground_command = "claude"
    pane.terminal.feed(CLAUDE_TURN_START)
    assert_equal "busy", pane.state(Muxr::Pane.now + 60)
    pane.terminal.feed(CLAUDE_TURN_END)
    assert_equal "idle", pane.state(Muxr::Pane.now + 60)
  end

  def test_progress_left_behind_by_an_exited_program_is_ignored
    pane = Muxr::Pane.new(process: FakeProcess.new)
    pane.terminal.feed(CLAUDE_TURN_START)
    pane.foreground_command = nil
    assert_equal "idle", pane.state(Muxr::Pane.now + 60)
  end

  def test_progress_counts_on_a_mirror_which_has_no_pid
    pane = Muxr::Pane.new(process: FakeProcess.new(pid: nil))
    pane.terminal.feed("\e]9;4;2;\a".b)
    assert_equal "error", pane.state(Muxr::Pane.now + 60)
  end

  def test_recent_output_is_active_and_old_output_is_idle
    pane = Muxr::Pane.new(process: FakeProcess.new)
    now = Muxr::Pane.now + 10
    pane.note_output(now)
    assert_equal "active", pane.state(now + 1)
    assert_equal "idle", pane.state(now + Muxr::Pane::ACTIVE_WINDOW + 1)
    assert_in_delta 5.0, pane.idle_seconds(now + 5), 0.01
  end

  def test_panes_list_carries_status_but_not_for_a_private_pane
    session = Muxr::Session.new(name: "status", width: 80, height: 24)
    shown = Muxr::Pane.new(process: FakeProcess.new)
    shown.foreground_command = "claude"
    shown.terminal.feed(CLAUDE_TURN_START + CLAUDE_WAITING)
    hidden = Muxr::Pane.new(process: FakeProcess.new)
    hidden.terminal.feed("\e]0;secret\a".b)
    hidden.mark_private!
    session.window.add_pane(shown)
    session.window.add_pane(hidden)
    app = Struct.new(:session).new(session)
    server = Muxr::ControlServer.new(app, "/nonexistent.sock")

    listed = server.local_call("panes.list")["panes"]

    assert_equal "claude", listed[0]["command"]
    assert_equal "◐ Reply with ok", listed[0]["title"]
    assert_equal "busy", listed[0]["state"]
    assert_equal "Claude Code: Claude is waiting for your input", listed[0]["notice"]
    assert_kind_of Float, listed[0]["idle"]
    refute listed[1].key?("title")
    refute listed[1].key?("state")
  end
end
