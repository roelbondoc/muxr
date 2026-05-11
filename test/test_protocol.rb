require "test_helper"
require "socket"
require "stringio"

class TestProtocol < Minitest::Test
  def test_round_trip_input_payload
    a, b = UNIXSocket.pair
    Rux::Protocol.write(a, Rux::Protocol::INPUT, "hello\x01\x02world")
    a.close
    type, payload = Rux::Protocol.read(b)
    assert_equal "I", type
    assert_equal "hello\x01\x02world".b, payload.b
  end

  def test_zero_length_payload
    a, b = UNIXSocket.pair
    Rux::Protocol.write(a, Rux::Protocol::BYE)
    a.close
    type, payload = Rux::Protocol.read(b)
    assert_equal "B", type
    assert_equal "", payload
  end

  def test_eof_returns_nil
    a, b = UNIXSocket.pair
    a.close
    assert_nil Rux::Protocol.read(b)
  end

  def test_truncated_header_returns_nil
    a, b = UNIXSocket.pair
    a.write("I\x00") # 2 bytes of a 5-byte header
    a.close
    assert_nil Rux::Protocol.read(b)
  end

  def test_truncated_payload_returns_nil
    a, b = UNIXSocket.pair
    # Header claims 10 bytes of payload, then only 3 arrive before EOF.
    a.write("I" + [10].pack("N") + "abc")
    a.close
    assert_nil Rux::Protocol.read(b)
  end

  def test_multiple_back_to_back_messages
    a, b = UNIXSocket.pair
    Rux::Protocol.write(a, Rux::Protocol::INPUT, "one")
    Rux::Protocol.write(a, Rux::Protocol::OUTPUT, "two")
    Rux::Protocol.write(a, Rux::Protocol::RESIZE, "30 100")
    a.close

    assert_equal ["I", "one"],     Rux::Protocol.read(b)
    assert_equal ["O", "two"],     Rux::Protocol.read(b)
    assert_equal ["R", "30 100"],  Rux::Protocol.read(b)
    assert_nil Rux::Protocol.read(b)
  end

  def test_binary_payload_survives_round_trip
    a, b = UNIXSocket.pair
    payload = (0..255).map(&:chr).join.b
    Rux::Protocol.write(a, Rux::Protocol::OUTPUT, payload)
    a.close
    type, got = Rux::Protocol.read(b)
    assert_equal "O", type
    assert_equal payload, got.b
  end

  def test_write_rejects_bad_type
    a, _b = UNIXSocket.pair
    assert_raises(ArgumentError) { Rux::Protocol.write(a, "II", "x") }
    assert_raises(ArgumentError) { Rux::Protocol.write(a, "", "x") }
  end

  def test_encode_and_decode_size
    encoded = Rux::Protocol.encode_size(30, 120)
    assert_equal "30 120", encoded
    assert_equal [30, 120], Rux::Protocol.decode_size(encoded)
  end

  def test_decode_size_rejects_malformed
    assert_nil Rux::Protocol.decode_size("garbage")
    assert_nil Rux::Protocol.decode_size("30")
    assert_nil Rux::Protocol.decode_size("30 abc")
    assert_nil Rux::Protocol.decode_size("")
  end
end
