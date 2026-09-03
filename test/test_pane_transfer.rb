require "test_helper"
require "tmpdir"
require "muxr/pty_process"
require "muxr/pane"
require "muxr/control_server"
require "muxr/pane_transfer"

# A move is only real if the *process* survives it, so these tests use a real
# pty running `cat` rather than a fake: the assertions that matter are that the
# pid is unchanged, that the fd still works from the new owner, and that the
# old owner let go without signalling anything.
class TestPaneTransfer < Minitest::Test
  class FakeApp
    attr_accessor :session, :renderer
    def invalidate; end
  end

  class FakeRenderer
    def reset_frame!; end
  end

  def setup
    @dir = Dir.mktmpdir("muxr-move")
    @socket_path = File.join(@dir, "owner.ctrl.sock")
    @app = FakeApp.new
    @app.session = Muxr::Session.new(name: "owner", width: 100, height: 30)
    @app.renderer = FakeRenderer.new
    @pane = real_pane
    @keeper = real_pane
    @app.session.window.add_pane(@pane)
    @app.session.window.add_pane(@keeper)
    @server = Muxr::ControlServer.new(@app, @socket_path)
    @server.start
    @claimed = []
    start_pump
  end

  def teardown
    stop_pump
    @claimed.each { |p| p.close rescue nil }
    @app.session.window.panes.each { |p| p.close rescue nil }
    @server.stop
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # `cat` is a cheap stand-in for a shell: it holds the pty open and echoes,
  # which is enough to prove the fd still works on the far side of a move.
  def real_pane
    Muxr::Pane.new(rows: 10, cols: 40, process: Muxr::PTYProcess.new(command: "/bin/cat"))
  end

  def start_pump
    @pumping = true
    @pump = Thread.new do
      while @pumping
        r, w = IO.select(@server.read_ios, @server.write_ios, nil, 0.01)
        r&.each { |io| @server.handle_read(io) }
        w&.each { |io| @server.handle_write(io) }
        @server.tick
      end
    end
  end

  def stop_pump
    @pumping = false
    @pump&.join(2)
    @pump = nil
  end

  def claim(pane_id = @pane.id)
    result = Muxr::PaneTransfer.claim(socket_path: @socket_path, pane_id: pane_id)
    @claimed << result.pane
    result
  end

  def wait_until(attempts: 300)
    attempts.times do
      return true if yield
      sleep 0.01
    end
    false
  end

  def read_until(pane, attempts: 300)
    attempts.times do
      pane.read_from_pty
      return true if yield
      sleep 0.01
    end
    false
  end

  def test_the_moved_pane_is_the_same_process
    pid = @pane.pid
    result = claim
    assert_equal pid, result.pane.pid
    assert_equal "owner", result.session
  end

  def test_the_pane_leaves_the_session_it_came_from
    claim
    refute_includes @app.session.window.panes, @pane
    assert_equal [@keeper], @app.session.window.panes
  end

  def test_the_old_owner_lets_go_without_killing_the_shell
    pid = @pane.pid
    claim
    refute @pane.alive?, "the source pane should look gone to the session that gave it up"
    assert_equal 1, Process.kill(0, pid), "the process itself must still be running"
  end

  def test_the_pty_still_works_from_its_new_home
    moved = claim.pane
    moved.write("still-connected\r")
    assert read_until(moved) { moved.terminal.dump_text.include?("still-connected") },
           "writing to the moved pane should still reach the process"
  end

  def test_the_pane_keeps_its_id_and_cwd
    moved = claim.pane
    assert_equal @pane.id, moved.id
    refute_nil moved.cwd
  end

  def test_the_screen_travels_with_the_pane
    @pane.terminal.feed("\e[1;31mon the screen\e[0m\r\nsecond row")
    expected = @pane.terminal.dump_text
    moved = claim.pane
    assert_equal expected, moved.terminal.dump_text
    assert_equal 1, moved.terminal.cell(0, 0).fg
    assert_equal Muxr::Terminal::BOLD, moved.terminal.cell(0, 0).attrs & Muxr::Terminal::BOLD
  end

  def test_scrollback_travels_with_the_pane
    40.times { |i| @pane.terminal.feed("history-#{i}\r\n") }
    depth = @pane.terminal.scrollback_size
    assert_operator depth, :>, 0
    moved = claim.pane
    assert_equal depth, moved.terminal.scrollback_size
    moved.terminal.scroll_back(depth)
    assert_includes moved.terminal.dump_text, "history-0"
  end

  # The picker already filters private panes, but the move has to refuse too:
  # otherwise anything that can reach the control socket could take a pane the
  # user deliberately hid.
  def test_a_private_pane_is_never_handed_over
    @pane.mark_private!
    err = assert_raises(Muxr::PaneTransfer::Error) { claim }
    assert_match(/private/, err.message)
    assert_includes @app.session.window.panes, @pane
  end

  def test_moving_the_last_pane_out_of_a_session_is_refused
    @app.session.window.remove_pane(@keeper)
    err = assert_raises(Muxr::PaneTransfer::Error) { claim }
    assert_match(/last pane/, err.message)
    assert_includes @app.session.window.panes, @pane
  end

  def test_a_borrowed_pane_cannot_be_moved_on
    mirror_process = Object.new
    def mirror_process.mirror?; true; end
    def mirror_process.io; nil; end
    def mirror_process.writer_io; nil; end
    def mirror_process.pending_write?; false; end
    def mirror_process.drain; end
    def mirror_process.write(_); end
    def mirror_process.read_nonblock(_ = 8192); nil; end
    def mirror_process.resize(_, _); end
    def mirror_process.alive?; true; end
    def mirror_process.cwd; "/tmp"; end
    def mirror_process.close; end
    borrowed = Muxr::Pane.new(process: mirror_process)
    borrowed.origin = "elsewhere:abc123"
    @app.session.window.add_pane(borrowed)
    err = assert_raises(Muxr::PaneTransfer::Error) { claim(borrowed.id) }
    assert_match(/borrowed from elsewhere:abc123/, err.message)
  end

  def test_an_unknown_pane_is_refused
    err = assert_raises(Muxr::PaneTransfer::Error) { claim("nosuch") }
    assert_match(/no pane with id/, err.message)
  end

  def test_an_unreachable_owner_is_refused
    err = assert_raises(Muxr::PaneTransfer::Error) do
      Muxr::PaneTransfer.claim(socket_path: File.join(@dir, "missing.sock"), pane_id: "x")
    end
    assert_match(/cannot reach/, err.message)
  end

  # Until the receiver commits, the pane is still the owner's. Dropping the
  # connection mid-move has to put it straight back to work rather than
  # stranding a live shell between two servers.
  def test_a_move_abandoned_before_commit_leaves_the_pane_where_it_was
    socket = UNIXSocket.new(@socket_path)
    socket.write(JSON.generate("id" => 1, "method" => "pane.move", "params" => { "pane" => @pane.id }) + "\n")
    assert wait_until { @server.handing_off?(@pane) }
    socket.close
    assert wait_until { !@server.handing_off?(@pane) }
    assert_includes @app.session.window.panes, @pane
    assert @pane.alive?
  end

  def test_a_half_finished_move_times_out_instead_of_pausing_the_pane_forever
    socket = UNIXSocket.new(@socket_path)
    socket.write(JSON.generate("id" => 1, "method" => "pane.move", "params" => { "pane" => @pane.id }) + "\n")
    assert wait_until { @server.handing_off?(@pane) }
    stop_pump
    @server.instance_variable_get(:@handoffs).each_value { |h| h[:deadline_at] = 0 }
    @server.tick
    refute @server.handing_off?(@pane)
    assert_includes @app.session.window.panes, @pane
    socket.close
  end
end
