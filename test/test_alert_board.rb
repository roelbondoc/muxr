require "test_helper"
require "tmpdir"
require "muxr/alert_board"

class TestAlertBoard < Minitest::Test
  def test_written_alerts_read_back_sorted_by_key
    Dir.mktmpdir do |dir|
      Muxr::AlertBoard.write("zeta", "z", dir: dir)
      Muxr::AlertBoard.write("alpha", "a", url: "https://example.com", urgent: true, dir: dir)
      alerts = Muxr::AlertBoard.read_all(dir: dir)
      assert_equal %w[alpha zeta], alerts.map(&:key)
      assert alerts.first.urgent
      assert_equal "https://example.com", alerts.first.url
      refute alerts.last.urgent
    end
  end

  def test_expired_and_malformed_alerts_are_skipped
    Dir.mktmpdir do |dir|
      Muxr::AlertBoard.write("stale", "old", ttl: 10, dir: dir)
      File.write(File.join(dir, "broken.json"), "{")
      assert_empty Muxr::AlertBoard.read_all(dir: dir, now: Time.now.to_f + 60)
    end
  end

  def test_control_characters_are_scrubbed_and_text_is_capped
    Dir.mktmpdir do |dir|
      Muxr::AlertBoard.write("noisy", "a\e[31mb\n" + "c" * 80, dir: dir)
      text = Muxr::AlertBoard.read_all(dir: dir).first.text
      refute_match(/[[:cntrl:]]/, text)
      assert_equal Muxr::AlertBoard::TEXT_MAX, text.length
    end
  end

  def test_clear_removes_the_alert
    Dir.mktmpdir do |dir|
      Muxr::AlertBoard.write("gone", "x", dir: dir)
      assert Muxr::AlertBoard.clear("gone", dir: dir)
      refute Muxr::AlertBoard.clear("gone", dir: dir)
      assert_empty Muxr::AlertBoard.read_all(dir: dir)
    end
  end

  def test_keys_cannot_escape_the_directory
    Dir.mktmpdir do |dir|
      assert_raises(ArgumentError) { Muxr::AlertBoard.write("../evil", "x", dir: dir) }
    end
  end

  def test_refresh_reports_a_change_once_and_is_rate_limited
    Dir.mktmpdir do |dir|
      board = Muxr::AlertBoard.new(dir: dir)
      refute board.refresh(0.0)
      Muxr::AlertBoard.write("new", "hi", dir: dir)
      refute board.refresh(0.5)
      assert board.refresh(1.5)
      assert_equal %w[hi], board.alerts.map(&:text)
      refute board.refresh(3.0)
    end
  end
end
