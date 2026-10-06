require "test_helper"
require "muxr/session_directory"
require "muxr/pane_filter"
require "muxr/pane_switcher"

class TestPaneFilter < Minitest::Test
  def entry(**fields)
    Muxr::SessionDirectory::Entry.new(
      session: "proj", pane_id: "abc123", slot: 1, cwd: "/src/proj", focused: false,
      state: "idle", bell: false, activity: false, silent: false, private: false, here: false,
      **fields
    )
  end

  def matches?(query, entry)
    Muxr::PaneFilter.new(query).match?(entry)
  end

  def test_an_empty_query_matches_everything
    assert matches?("", entry)
    assert matches?("   ", entry)
  end

  def test_a_bare_word_matches_any_text_field_case_insensitively
    claude = entry(command: "claude", title: "✳ Fix the Login bug")
    assert matches?("login", claude)
    assert matches?("CLAUDE", claude)
    assert matches?("proj", claude)
    refute matches?("vim", claude)
  end

  def test_field_terms_only_look_at_their_field
    pane = entry(command: "claude", title: "talking about vim")
    assert matches?("cmd:claude", pane)
    refute matches?("cmd:vim", pane)
    assert matches?("t:vim", pane)
    assert matches?("s:pro", pane)
    refute matches?("s:other", pane)
  end

  def test_every_term_must_match
    pane = entry(command: "claude", session: "phoenix")
    assert matches?("cmd:claude s:phoe", pane)
    refute matches?("cmd:claude s:toolbox", pane)
  end

  def test_is_terms_test_state_and_attention
    busy = entry(state: "busy")
    belled = entry(bell: true)
    assert matches?("is:busy", busy)
    refute matches?("is:idle", busy)
    assert matches?("is:bell", belled)
    assert matches?("is:attention", belled)
    refute matches?("is:attention", busy)
    refute matches?("is:nonsense", busy)
  end

  def test_a_leading_dash_excludes
    assert matches?("-is:idle", entry(state: "busy"))
    refute matches?("-is:idle", entry(state: "idle"))
    refute matches?("-cmd:claude", entry(command: "claude"))
  end

  def test_an_unknown_key_falls_back_to_a_plain_text_match
    assert matches?("http://x", entry(title: "open http://x now"))
  end

  def test_a_missing_field_never_matches_a_field_term
    refute matches?("cmd:claude", entry(command: nil))
  end
end

class TestPaneSwitcher < Minitest::Test
  def entry(session, id, command = nil)
    Muxr::SessionDirectory::Entry.new(session: session, pane_id: id, slot: 1, command: command, state: "idle")
  end

  def setup
    @entries = [entry("a", "111111", "claude"), entry("a", "222222"), entry("b", "333333", "claude")]
  end

  def test_typing_narrows_the_rows_and_resets_the_selection
    switcher = Muxr::PaneSwitcher.new(@entries)
    switcher.move(1)
    "cmd:cl".each_char { |ch| switcher.type(ch) }
    assert_equal %w[111111 333333], switcher.rows.map(&:pane_id)
    assert_equal 0, switcher.index
  end

  def test_an_initial_query_is_applied
    switcher = Muxr::PaneSwitcher.new(@entries, query: "s:b")
    assert_equal ["333333"], switcher.rows.map(&:pane_id)
  end

  def test_backspace_and_clear_widen_the_rows_again
    switcher = Muxr::PaneSwitcher.new(@entries, query: "s:bx")
    assert switcher.empty?
    switcher.backspace
    assert_equal 1, switcher.rows.length
    switcher.clear_query
    assert_equal 3, switcher.rows.length
  end

  def test_moving_wraps_around
    switcher = Muxr::PaneSwitcher.new(@entries)
    switcher.move(-1)
    assert_equal "333333", switcher.selected.pane_id
    switcher.move(1)
    assert_equal "111111", switcher.selected.pane_id
  end

  def test_moving_an_empty_list_is_a_no_op
    switcher = Muxr::PaneSwitcher.new([])
    switcher.move(1)
    assert_nil switcher.selected
  end

  def test_refreshing_keeps_the_selected_pane_selected
    switcher = Muxr::PaneSwitcher.new(@entries)
    switcher.move(2)
    switcher.replace_entries([entry("b", "333333"), entry("a", "111111")])
    assert_equal "333333", switcher.selected.pane_id
  end
end

class TestSessionDirectoryOrder < Minitest::Test
  def entry(id, idle)
    Muxr::SessionDirectory::Entry.new(session: "s", pane_id: id, idle: idle)
  end

  def test_the_most_recently_updated_pane_comes_first_and_unknowns_last
    entries = [entry("old", 300.0), entry("unknown", nil), entry("fresh", 0.5), entry("tie-a", 10.0), entry("tie-b", 10.0)]
    sorted = Muxr::SessionDirectory.most_recently_updated_first(entries)
    assert_equal %w[fresh tie-a tie-b old unknown], sorted.map(&:pane_id)
  end
end

class TestPaneSwitcherDefault < Minitest::Test
  def entry(id, here: false, focused: false, command: nil)
    Muxr::SessionDirectory::Entry.new(session: "s", pane_id: id, here: here, focused: focused, command: command)
  end

  def test_the_selection_starts_on_the_last_other_pane
    switcher = Muxr::PaneSwitcher.new([entry("mine", here: true, focused: true), entry("other"), entry("older")])
    assert_equal "other", switcher.selected.pane_id
  end

  def test_the_focused_pane_of_another_session_is_not_skipped
    switcher = Muxr::PaneSwitcher.new([entry("theirs", focused: true), entry("other")])
    assert_equal "theirs", switcher.selected.pane_id
  end

  def test_filtering_skips_the_current_pane_too
    switcher = Muxr::PaneSwitcher.new([entry("mine", here: true, focused: true, command: "vim"), entry("other", command: "vim"), entry("x")])
    "cmd:vim".each_char { |ch| switcher.type(ch) }
    assert_equal "other", switcher.selected.pane_id
  end

  def test_the_current_pane_is_selected_when_it_is_the_only_match
    switcher = Muxr::PaneSwitcher.new([entry("mine", here: true, focused: true)])
    assert_equal "mine", switcher.selected.pane_id
  end
end
