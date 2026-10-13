require "test_helper"
require "muxr/pane"
require "muxr/pane_describer"

class TestPaneDescriber < Minitest::Test
  class FakeProcess
    def pid; 4242; end
    def io; nil; end
    def writer_io; nil; end
    def pending_write?; false; end
    def write(_); end
    def resize(_, _); end
    def alive?; true; end
    def cwd; "/tmp"; end
    def close; end
  end

  def pane(id, text)
    pane = Muxr::Pane.new(id: id, rows: 5, cols: 40, process: FakeProcess.new)
    pane.terminal.feed(text.b)
    pane
  end

  def describer(&block)
    calls = []
    runner = lambda do |context|
      calls << context
      block ? block.call(context) : "described #{calls.length}"
    end
    [Muxr::PaneDescriber.new(interval: 60, runner: runner), calls]
  end

  def sweep_and_wait(describer, panes)
    describer.sweep(panes, Muxr::Pane.now)
    describer.stop
  end

  def test_the_first_sweep_waits_and_then_labels_every_pane
    subject, calls = describer
    panes = [pane("a", "$ rake test\r\n"), pane("b", "$ vim\r\n")]
    subject.tick(panes, 0)
    assert_empty calls
    subject.tick(panes, Muxr::PaneDescriber::FIRST_SWEEP_DELAY)
    subject.stop
    assert_equal 2, calls.length
    assert_includes calls.first, "rake test"
    assert_equal ["described 1", "described 2"], panes.map(&:description)
  end

  def test_private_and_mirrored_panes_are_never_sent
    subject, calls = describer
    secret = pane("s", "password: hunter2\r\n")
    secret.mark_private!
    mirror = pane("m", "mirrored\r\n")
    mirror.define_singleton_method(:mirror?) { true }
    sweep_and_wait(subject, [secret, mirror])
    assert_empty calls
    assert_nil secret.description
  end

  def test_a_pane_without_new_output_is_not_described_again
    subject, calls = describer
    quiet = pane("q", "$ ls\r\n")
    now = Muxr::Pane.now
    subject.sweep([quiet], now)
    subject.sweep([quiet], now + 120)
    subject.stop
    assert_equal 1, calls.length
  end

  def test_output_that_leaves_the_screen_unchanged_is_not_described_again
    subject, calls = describer
    busy = pane("b", "$ top\r\n")
    now = Muxr::Pane.now
    subject.sweep([busy], now)
    busy.note_output(now + 30)
    subject.sweep([busy], now + 60)
    subject.stop
    assert_equal 1, calls.length
  end

  def test_the_reply_is_trimmed_to_one_clean_line
    subject, = describer { "\n  \"vim lib/muxr/pane.rb\"\e\nsecond line\n" }
    target = pane("v", "~\r\n")
    sweep_and_wait(subject, [target])
    assert_equal "vim lib/muxr/pane.rb", target.description
  end

  def test_a_long_reply_is_capped
    subject, = describer { "x" * 200 }
    target = pane("l", "~\r\n")
    sweep_and_wait(subject, [target])
    assert_equal Muxr::PaneDescriber::DESCRIPTION_MAX, target.description.length
  end

  def test_a_failing_run_keeps_the_previous_description
    subject, = describer { raise "boom" }
    target = pane("f", "~\r\n")
    target.description = "earlier"
    _, err = capture_io { sweep_and_wait(subject, [target]) }
    assert_equal "earlier", target.description
    assert_match(/boom/, err)
  end

  def test_without_claude_on_the_path_nothing_runs
    subject = Muxr::PaneDescriber.new(claude: nil)
    refute subject.available?
    subject.tick([pane("a", "x")], 100)
  end
end
