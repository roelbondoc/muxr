require "test_helper"

class TestSession < Minitest::Test
  class FakePane
    attr_accessor :cwd

    def initialize(cwd)
      @cwd = cwd
    end

    def close
      # no-op
    end
  end

  class FakeDrawerPane < FakePane
  end

  def with_isolated_sessions_dir
    Dir.mktmpdir("rux-sessions") do |dir|
      original = Rux::Session::SESSIONS_DIR
      Rux::Session.send(:remove_const, :SESSIONS_DIR)
      Rux::Session.const_set(:SESSIONS_DIR, dir)
      begin
        yield dir
      ensure
        Rux::Session.send(:remove_const, :SESSIONS_DIR)
        Rux::Session.const_set(:SESSIONS_DIR, original)
      end
    end
  end

  def build_session
    session = Rux::Session.new(name: "spec", width: 100, height: 30)
    session.window.add_pane(FakePane.new("/tmp/one"))
    session.window.add_pane(FakePane.new("/tmp/two"))
    session.window.set_layout(:grid)
    session.window.focused_index = 1
    session.window.master_index = 0
    drawer_pane = FakeDrawerPane.new("/tmp/drawer")
    drawer = Rux::Drawer.new(pane: drawer_pane, origin_cwd: "/tmp/drawer")
    drawer.show!
    session.drawer = drawer
    session.focus_drawer = true
    session
  end

  def test_serialize_round_trip
    session = build_session
    data = session.serialize
    json = JSON.pretty_generate(data)
    parsed = JSON.parse(json)

    assert_equal "spec", parsed["name"]
    assert_equal 100, parsed["width"]
    assert_equal 30, parsed["height"]
    assert_equal "grid", parsed["layout"]
    assert_equal 1, parsed["focused_index"]
    assert_equal 0, parsed["master_index"]
    assert_equal true, parsed["focus_drawer"]
    assert_equal 2, parsed["panes"].length
    assert_equal "/tmp/one", parsed["panes"][0]["cwd"]
    assert_equal "/tmp/two", parsed["panes"][1]["cwd"]
    assert_equal true, parsed["drawer"]["visible"]
    assert_equal "/tmp/drawer", parsed["drawer"]["cwd"]
  end

  def test_save_writes_file_and_load_reads_it
    with_isolated_sessions_dir do
      session = build_session
      session.save

      loaded = Rux::Session.load("spec")
      refute_nil loaded
      assert_equal "spec", loaded["name"]
      assert_equal 2, loaded["panes"].length
    end
  end

  def test_load_returns_nil_for_missing
    with_isolated_sessions_dir do
      assert_nil Rux::Session.load("nonexistent")
    end
  end

  def test_serialize_handles_missing_drawer
    session = Rux::Session.new(name: "spec", width: 80, height: 24)
    session.window.add_pane(FakePane.new("/tmp"))
    data = session.serialize
    assert_nil data["drawer"]
  end

  def test_exists_check
    with_isolated_sessions_dir do
      refute Rux::Session.exists?("missing")
      session = build_session
      session.save
      assert Rux::Session.exists?("spec")
    end
  end
end
