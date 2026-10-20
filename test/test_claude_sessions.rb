require "test_helper"
require "tmpdir"
require "json"
require "muxr"

class TestClaudeSessions < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("muxr-claude")
    Muxr::ClaudeSessions.claude_dir = @dir
    FileUtils.mkdir_p(File.join(@dir, "sessions"))
    FileUtils.mkdir_p(File.join(@dir, "projects", "-work"))
  end

  def teardown
    Muxr::ClaudeSessions.claude_dir = nil
    FileUtils.remove_entry(@dir)
  end

  def transcript(id, records, age: 0)
    path = File.join(@dir, "projects", "-work", "#{id}.jsonl")
    File.write(path, records.map { |r| JSON.generate(r) + "\n" }.join)
    stamp = Time.now - age
    File.utime(stamp, stamp, path)
    path
  end

  def live(pid, id, status: "idle", cwd: "/work")
    File.write(File.join(@dir, "sessions", "#{pid}.json"),
               JSON.generate("pid" => pid, "sessionId" => id, "cwd" => cwd, "status" => status, "kind" => "interactive", "updatedAt" => 0))
  end

  def pane(pid, session: "here", pane_id: "p1", slot: 1)
    Muxr::SessionDirectory::Entry.new(session: session, pane_id: pane_id, slot: slot, pid: pid, here: session == "here", focused: false)
  end

  def test_saved_sessions_carry_title_and_cwd_newest_first
    transcript("old", [{ "type" => "user", "cwd" => "/a" }, { "type" => "ai-title", "aiTitle" => "Old work" }], age: 100)
    transcript("new", [{ "type" => "user", "cwd" => "/b" }, { "type" => "ai-title", "aiTitle" => "New work" }], age: 10)
    entries = Muxr::ClaudeSessions.entries(process_parents: {})
    assert_equal %w[new old], entries.map(&:session_id)
    assert_equal ["New work", "/b", "saved"], [entries[0].title, entries[0].cwd, entries[0].state]
    refute entries[0].running?
  end

  def test_the_last_prompt_titles_a_session_with_no_ai_title
    transcript("s", [{ "type" => "user", "cwd" => "/a" }, { "type" => "last-prompt", "lastPrompt" => "fix the bug\nplease" }])
    assert_equal "fix the bug", Muxr::ClaudeSessions.entries(process_parents: {}).first.title
  end

  def test_an_empty_transcript_is_not_offered
    transcript("s", [{ "type" => "user", "cwd" => "/a" }])
    assert_empty Muxr::ClaudeSessions.entries(process_parents: {})
  end

  def test_a_running_session_is_matched_to_the_pane_its_shell_lives_in
    transcript("s", [{ "type" => "user", "cwd" => "/work" }, { "type" => "ai-title", "aiTitle" => "Live" }])
    live(300, "s", status: "busy")
    entries = Muxr::ClaudeSessions.entries(panes: [pane(100, pane_id: "abc", slot: 2)], process_parents: { 300 => 200, 200 => 100, 100 => 1 })
    assert_equal 1, entries.length
    entry = entries.first
    assert_equal ["busy", "Live", "here", "abc", 2], [entry.state, entry.title, entry.session, entry.pane_id, entry.slot]
    assert entry.in_muxr?
  end

  def test_a_running_session_outside_muxr_has_no_pane
    live(300, "s")
    entry = Muxr::ClaudeSessions.entries(panes: [pane(100)], process_parents: { 300 => 1 }).first
    assert entry.running?
    refute entry.in_muxr?
  end

  def test_a_session_file_whose_process_is_gone_is_treated_as_saved
    transcript("s", [{ "type" => "user", "cwd" => "/work" }, { "type" => "ai-title", "aiTitle" => "Done" }])
    live(300, "s")
    entry = Muxr::ClaudeSessions.entries(process_parents: {}).first
    assert_equal "saved", entry.state
  end

  def test_a_title_beyond_the_tail_is_found_by_scanning_the_whole_file
    filler = { "type" => "assistant", "message" => "x" * 1024 }
    records = [{ "type" => "user", "cwd" => "/a" }, { "type" => "ai-title", "aiTitle" => "Early" }] + Array.new(600) { filler }
    path = transcript("s", records)
    assert_operator File.size(path), :>, Muxr::ClaudeSessions::TAIL_BYTES
    assert_equal "Early", Muxr::ClaudeSessions.transcript(path).title
  end

  def test_the_filter_matches_title_cwd_and_saved_state
    transcript("s", [{ "type" => "user", "cwd" => "/work/muxr" }, { "type" => "ai-title", "aiTitle" => "Resume picker" }])
    entry = Muxr::ClaudeSessions.entries(process_parents: {}).first
    assert Muxr::PaneFilter.new("picker cwd:muxr is:saved").match?(entry)
    refute Muxr::PaneFilter.new("is:busy").match?(entry)
  end
end
