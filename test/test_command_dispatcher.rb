require "test_helper"
require "muxr/command_dispatcher"

# Exercises the pure Tab-completion logic. Dispatch itself is covered
# indirectly via the Application; here we only care about #complete, which
# needs no app instance.
class TestCommandDispatcher < Minitest::Test
  CD = Muxr::CommandDispatcher

  def complete(line)
    CD.complete(line)
  end

  def test_completes_unique_command_with_trailing_space
    line, cands = complete("lay")
    assert_equal "layout ", line
    assert_equal %w[layout], cands
  end

  def test_ambiguous_command_extends_to_common_prefix
    line, cands = complete("s")
    assert_equal "s", line # save / sessions share only "s"
    assert_equal %w[save sessions], cands
  end

  def test_empty_line_offers_all_commands_unchanged
    line, cands = complete("")
    assert_equal "", line
    assert_includes cands, "layout"
    assert_includes cands, "quit"
  end

  def test_completes_layout_argument
    line, cands = complete("layout gr")
    assert_equal "layout grid ", line
    assert_equal %w[grid], cands
  end

  def test_ambiguous_layout_argument_lists_candidates
    line, cands = complete("layout s")
    assert_equal "layout s", line
    assert_equal %w[spiral stack], cands
  end

  def test_bare_layout_with_space_lists_all_layouts
    line, cands = complete("layout ")
    assert_equal "layout ", line
    assert_equal Muxr::Window::LAYOUTS.map(&:to_s).sort, cands
  end

  def test_completes_drawer_argument
    line, cands = complete("drawer h")
    assert_equal "drawer hide ", line
    assert_equal %w[hide], cands
  end

  def test_no_match_leaves_line_unchanged
    line, cands = complete("zzz")
    assert_equal "zzz", line
    assert_empty cands
  end

  def test_unknown_command_has_no_argument_completions
    line, cands = complete("save foo")
    assert_equal "save foo", line
    assert_empty cands
  end

  def test_tolerates_leading_whitespace
    line, cands = complete("  layout co")
    assert_equal "layout columns ", line
    assert_equal %w[columns], cands
  end
end
