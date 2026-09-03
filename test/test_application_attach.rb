require "test_helper"
require "tmpdir"
require "muxr/application"
require "muxr/input_handler"
require "muxr/pane"
require "muxr/pane_picker"
require "muxr/session_directory"

class TestApplicationAttach < Minitest::Test
  class FakeProcess
    def io; nil; end
    def writer_io; nil; end
    def pending_write?; false; end
    def drain; end
    def write(_); end
    def read_nonblock(_ = 8192); nil; end
    def resize(_, _); end
    def alive?; true; end
    def cwd; "/tmp/local"; end
    def close; end
  end

  class FakeMirrorProcess < FakeProcess
    def mirror?; true; end
  end

  def setup
    @dir = Dir.mktmpdir("muxr-attach")
    @original = Muxr::Application::SOCKETS_DIR
    Muxr::Application.send(:remove_const, :SOCKETS_DIR)
    Muxr::Application.const_set(:SOCKETS_DIR, @dir)
    @app = Muxr::Application.new(["-s", "here"])
    @app.instance_variable_set(:@session, Muxr::Session.new(name: "here", width: 80, height: 24))
    @app.instance_variable_set(:@renderer, Object.new.tap { |r| def r.reset_frame!; end })
    @app.instance_variable_set(:@input, Muxr::InputHandler.new(@app))
    @app.session.window.add_pane(Muxr::Pane.new(process: FakeProcess.new))
  end

  def teardown
    Muxr::Application.send(:remove_const, :SOCKETS_DIR)
    Muxr::Application.const_set(:SOCKETS_DIR, @original)
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def flashed
    @app.instance_variable_get(:@message)
  end

  def test_opening_the_picker_with_nothing_to_attach_says_so_instead_of_opening
    @app.open_pane_picker
    assert_nil @app.pane_picker
    assert_equal :normal, @app.input.state
    assert_match(/no panes to attach/, flashed)
  end

  def test_cancelling_clears_the_overlay
    @app.instance_variable_set(:@pane_picker, Muxr::PanePicker.new([]))
    @app.cancel_pane_picker
    assert_nil @app.pane_picker
  end

  def test_confirming_an_empty_selection_is_a_no_op
    @app.instance_variable_set(:@pane_picker, Muxr::PanePicker.new([]))
    @app.confirm_pane_picker
    assert_nil @app.pane_picker
    assert_equal 1, @app.session.window.panes.length
  end

  def test_an_unreachable_owner_is_reported_rather_than_raised
    entry = Muxr::SessionDirectory::Entry.new(
      session: "gone", socket_path: File.join(@dir, "nope.ctrl.sock"),
      pane_id: "abc123", slot: 1, cwd: "/tmp", rows: 24, cols: 80, focused: false
    )
    assert_nil @app.attach_remote_pane(entry)
    assert_equal 1, @app.session.window.panes.length
    assert_match(/attach failed/, flashed)
  end

  def test_a_borrowed_pane_is_not_written_into_the_session_snapshot
    mirror = Muxr::Pane.new(process: FakeMirrorProcess.new)
    mirror.origin = "work:abc123"
    @app.session.window.add_pane(mirror)
    ids = @app.session.serialize["panes"].map { |p| p["id"] }
    assert_equal 2, @app.session.window.panes.length
    assert_equal [@app.session.window.panes.first.id], ids
  end

  def test_the_viewport_offered_to_the_owner_fits_the_layout_the_pane_will_land_in
    rows, cols = @app.mirror_viewport
    assert_operator rows, :>, 0
    assert_operator cols, :>, 0
    assert_operator rows, :<=, @app.session.height
    assert_operator cols, :<=, @app.session.width
  end
end
