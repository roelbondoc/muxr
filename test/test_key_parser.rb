require "test_helper"
require "muxr/control_server"
require "muxr/key_parser"

class TestKeyParser < Minitest::Test
  KP = Muxr::KeyParser

  def kinds(entries)
    KP.translate(entries).map(&:first)
  end

  def bytes_for(entries)
    KP.translate(entries).map(&:last).join
  end

  def test_pure_text_is_literal
    segs = KP.translate(["hello world"])
    assert_equal [[:literal, "hello world".b]], segs
  end

  def test_esc_translates_to_escape_byte
    segs = KP.translate(["<esc>"])
    assert_equal [[:special, "\e".b]], segs
  end

  def test_esc_case_insensitive
    assert_equal "\e".b, bytes_for(["<Esc>"])
    assert_equal "\e".b, bytes_for(["<ESC>"])
  end

  def test_enter_and_cr_aliases
    assert_equal "\r".b, bytes_for(["<enter>"])
    assert_equal "\r".b, bytes_for(["<cr>"])
    assert_equal "\r".b, bytes_for(["<return>"])
  end

  def test_ctrl_c_and_ctrl_d
    assert_equal "\x03".b, bytes_for(["<c-c>"])
    assert_equal "\x04".b, bytes_for(["<c-d>"])
    assert_equal "\x01".b, bytes_for(["<c-a>"])
    assert_equal "\x1a".b, bytes_for(["<c-z>"])
  end

  def test_arrow_keys
    assert_equal "\e[A".b, bytes_for(["<up>"])
    assert_equal "\e[B".b, bytes_for(["<down>"])
    assert_equal "\e[C".b, bytes_for(["<right>"])
    assert_equal "\e[D".b, bytes_for(["<left>"])
  end

  def test_arrow_sequence_then_enter
    segs = KP.translate(["<down>", "<down>", "<enter>"])
    assert_equal [:special, :special, :special], segs.map(&:first)
    assert_equal "\e[B\e[B\r".b, segs.map(&:last).join
  end

  def test_function_keys
    assert_equal "\eOP".b,    bytes_for(["<f1>"])
    assert_equal "\eOS".b,    bytes_for(["<f4>"])
    assert_equal "\e[15~".b,  bytes_for(["<f5>"])
    assert_equal "\e[24~".b,  bytes_for(["<f12>"])
  end

  def test_shift_tab
    assert_equal "\e[Z".b, bytes_for(["<s-tab>"])
  end

  def test_misc_keys
    assert_equal "\t".b,     bytes_for(["<tab>"])
    assert_equal "\x7f".b,   bytes_for(["<bs>"])
    assert_equal " ".b,      bytes_for(["<space>"])
    assert_equal "\e[H".b,   bytes_for(["<home>"])
    assert_equal "\e[F".b,   bytes_for(["<end>"])
    assert_equal "\e[5~".b,  bytes_for(["<pageup>"])
    assert_equal "\e[6~".b,  bytes_for(["<pagedown>"])
  end

  def test_mixing_literal_text_with_named_keys
    segs = KP.translate(["G", "o", "hello world", "<esc>", ":w", "<enter>"])
    assert_equal [:literal, :literal, :literal, :special, :literal, :special], segs.map(&:first)
    assert_equal "Gohello world\e:w\r".b, segs.map(&:last).join
  end

  def test_partial_angle_bracket_text_is_literal
    # "if x < 5" doesn't match the whole-string <name> pattern, so it passes
    # through verbatim.
    segs = KP.translate(["if x < 5"])
    assert_equal [[:literal, "if x < 5".b]], segs
  end

  def test_unknown_named_key_raises
    err = assert_raises(Muxr::Dispatcher::Error) { KP.translate(["<nope>"]) }
    assert_match(/unknown named key/, err.message)
  end

  def test_non_array_raises
    assert_raises(Muxr::Dispatcher::Error) { KP.translate("just a string") }
  end

  def test_non_string_entries_raise
    assert_raises(Muxr::Dispatcher::Error) { KP.translate(["ok", 123]) }
  end
end
