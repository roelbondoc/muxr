require "test_helper"
require "muxr/foreground_command"

class TestForegroundCommand < Minitest::Test
  # Linux /proc/<pid>/stat: comm field is parenthesized and may contain
  # spaces, so the parser slices from the last ')'.
  def test_parse_linux_stat_extracts_tpgid_and_pgid
    raw = "1234 (bash) S 1 1234 1234 34816 5678 4194304 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0\n"
    tpgid, pgid = Muxr::ForegroundCommand.parse_linux_stat(raw)
    assert_equal 5678, tpgid
    assert_equal 1234, pgid
  end

  def test_parse_linux_stat_handles_comm_with_spaces_and_parens
    # Process comm "weird (name)" — the rindex(')') trick is what saves us.
    raw = "42 (weird (name)) R 1 99 99 0 88 0 0 0 0 0 0 0 0 0 20 0 1 0 0\n"
    tpgid, pgid = Muxr::ForegroundCommand.parse_linux_stat(raw)
    assert_equal 88, tpgid
    assert_equal 99, pgid
  end

  def test_parse_linux_stat_returns_nil_pair_for_garbage
    tpgid, pgid = Muxr::ForegroundCommand.parse_linux_stat("not a real stat line")
    assert_nil tpgid
    assert_nil pgid
  end

  # normalize() strips path/leading-dash, then filters known shells.
  def test_normalize_returns_command_name
    assert_equal "vim", Muxr::ForegroundCommand.normalize("vim")
    assert_equal "npm", Muxr::ForegroundCommand.normalize("npm\n")
    assert_equal "ls", Muxr::ForegroundCommand.normalize("/bin/ls")
  end

  def test_normalize_strips_login_shell_dash
    # Login shells appear as "-bash"; we strip the dash and then filter.
    assert_nil Muxr::ForegroundCommand.normalize("-bash")
    assert_nil Muxr::ForegroundCommand.normalize("-zsh")
  end

  def test_normalize_filters_shells
    %w[bash zsh fish sh dash ksh tcsh csh].each do |shell|
      assert_nil Muxr::ForegroundCommand.normalize(shell), "expected nil for #{shell}"
    end
  end

  def test_normalize_handles_empty_and_nil
    assert_nil Muxr::ForegroundCommand.normalize(nil)
    assert_nil Muxr::ForegroundCommand.normalize("")
    assert_nil Muxr::ForegroundCommand.normalize("   ")
  end

  # lookup() guards against bogus pids — important because Application's
  # poller iterates a snapshot that may include a pane whose process died
  # between dup and lookup.
  def test_lookup_with_invalid_pid_returns_nil
    assert_nil Muxr::ForegroundCommand.lookup(nil)
    assert_nil Muxr::ForegroundCommand.lookup(0)
    assert_nil Muxr::ForegroundCommand.lookup(-1)
    assert_nil Muxr::ForegroundCommand.lookup("123")
  end

  def test_lookup_for_unknown_pid_returns_nil
    # 2**30 is virtually guaranteed not to exist on the host.
    assert_nil Muxr::ForegroundCommand.lookup(2**30)
  end
end
