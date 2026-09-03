require "test_helper"
require "tmpdir"
require "muxr/pane"
require "muxr/control_server"
require "muxr/remote_pane"

# End-to-end exercise of a borrowed pane: a real ControlServer on a real Unix
# socket, a real RemotePane talking to it, and a real Pane/Terminal on each
# side. Only the PTY is faked — everything the mirror depends on (framing,
# base64 relay, geometry negotiation, teardown) is the production code.
class TestRemotePane < Minitest::Test
  class FakeProcess
    attr_reader :writes

    def initialize
      @writes = +"".b
      @queued = []
      @rows = 24
      @cols = 80
    end

    def queue_output(bytes); @queued << bytes.b; end
    def io; nil; end
    def writer_io; nil; end
    def pending_write?; false; end
    def drain; end
    def write(data); @writes << data.b; end
    def read_nonblock(_ = 8192); @queued.shift; end
    def resize(rows, cols); @rows = rows; @cols = cols; end
    def nudge_redraw; @nudged = true; end
    def nudged?; !!@nudged; end
    def alive?; true; end
    def cwd; "/tmp/owner"; end
    def close; end
  end

  class FakeApp
    attr_accessor :session
    def invalidate; end
  end

  def setup
    @dir = Dir.mktmpdir("muxr-mirror")
    @socket_path = File.join(@dir, "owner.ctrl.sock")
    @app = FakeApp.new
    @app.session = Muxr::Session.new(name: "owner", width: 100, height: 30)
    @process = FakeProcess.new
    @pane = Muxr::Pane.new(rows: 24, cols: 80, process: @process)
    @app.session.window.add_pane(@pane)
    @server = Muxr::ControlServer.new(@app, @socket_path)
    @server.start
    @remotes = []
    start_pump
  end

  def teardown
    stop_pump
    @remotes.each { |r| r.close rescue nil }
    @server.stop
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  # The owner's event loop, minus everything a mirror doesn't touch. Runs on
  # its own thread so RemotePane's blocking handshake has someone to answer it.
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

  def mirror(rows: 24, cols: 80)
    remote = Muxr::RemotePane.connect(
      socket_path: @socket_path, pane_id: @pane.id, rows: rows, cols: cols
    )
    @remotes << remote
    pane = Muxr::Pane.new(rows: remote.rows, cols: remote.cols, process: remote)
    remote.bind(pane.terminal)
    [remote, pane]
  end

  # Owner-side equivalent of Application#consume_pane_io for a mirrored pane.
  def relay_output(bytes)
    @process.queue_output(bytes)
    @pane.read_from_pty { |chunk| @server.on_pane_raw(@pane.id, chunk) }
  end

  # Pull whatever the mirror has received into its replica, giving the pump a
  # few chances to deliver before concluding there's nothing coming.
  def drain_into(remote, pane, attempts: 60)
    attempts.times do
      pane.read_from_pty
      break if yield
      sleep 0.01
    end
    pane
  end

  def test_handshake_reports_owner_geometry_and_identity
    @pane.terminal.feed("hello from the owner")
    remote, = mirror
    assert_equal "owner", remote.session
    assert_equal @pane.id, remote.pane_id
    assert_equal 24, remote.rows
    assert_equal 80, remote.cols
    assert_equal "/tmp/owner", remote.cwd
    assert remote.mirror?
  end

  def test_snapshot_reproduces_the_owner_screen
    @pane.terminal.feed("line one\r\nline two\r\n\e[31mred\e[0m")
    _remote, pane = mirror
    pane.read_from_pty
    assert_equal @pane.terminal.dump_text, pane.terminal.dump_text
    assert_equal "red", pane.terminal.dump_text.lines[2].strip
  end

  def test_live_output_reaches_the_mirror
    remote, pane = mirror
    pane.read_from_pty # consume the snapshot
    relay_output("fresh output\r\n")
    drain_into(remote, pane) { pane.terminal.dump_text.include?("fresh output") }
    assert_includes pane.terminal.dump_text, "fresh output"
  end

  def test_mirror_keeps_attributes_not_just_text
    @pane.terminal.feed("\e[1;32mgreen bold\e[0m")
    _remote, pane = mirror
    pane.read_from_pty
    cell = pane.terminal.cell(0, 0)
    assert_equal "g", cell.char
    assert_equal 2, cell.fg
    assert_equal Muxr::Terminal::BOLD, cell.attrs & Muxr::Terminal::BOLD
  end

  def test_input_typed_at_the_mirror_reaches_the_owner_pty
    remote, = mirror
    remote.write("ls -la\r")
    wait_until { @process.writes.include?("ls -la\r") }
    assert_includes @process.writes, "ls -la\r"
  end

  def test_input_survives_bytes_that_are_not_valid_utf8
    remote, = mirror
    remote.write("\e[A".b + "\xC3".b)
    wait_until { @process.writes.bytesize >= 4 }
    assert_equal "\e[A\xC3".b, @process.writes
  end

  def test_owner_shrinks_the_pty_to_fit_the_smallest_mirror
    mirror(rows: 10, cols: 40)
    wait_until { @pane.mirror_size == [10, 40] }
    @pane.resize(30, 100)
    assert_equal 10, @pane.terminal.rows
    assert_equal 40, @pane.terminal.cols
  end

  def test_pane_returns_to_full_size_when_the_mirror_goes_away
    remote, = mirror(rows: 10, cols: 40)
    wait_until { @pane.mirror_size == [10, 40] }
    remote.close
    wait_until { @pane.mirror_size.nil? }
    @pane.resize(30, 100)
    assert_equal 30, @pane.terminal.rows
    assert_equal 100, @pane.terminal.cols
  end

  def test_geometry_change_resizes_the_replica_and_resyncs_it
    remote, pane = mirror
    pane.read_from_pty
    @pane.resize(12, 40)
    @pane.terminal.feed("after resize")
    drain_into(remote, pane) { pane.terminal.rows == 12 }
    assert_equal 12, pane.terminal.rows
    assert_equal 40, pane.terminal.cols
    assert_includes pane.terminal.dump_text, "after resize"
  end

  def test_owner_shrinks_immediately_even_with_nobody_attached
    # No client is attached in this test, so no render ever runs — the pane
    # still has to reach a size the mirror can display in full.
    mirror(rows: 9, cols: 30)
    wait_until { @pane.terminal.rows == 9 && @pane.terminal.cols == 30 }
    assert_equal [9, 30], [@pane.terminal.rows, @pane.terminal.cols]
  end

  def test_a_mirror_leaving_never_grows_the_pane_on_its_own
    remote, = mirror(rows: 9, cols: 30)
    wait_until { @pane.terminal.rows == 9 }
    remote.close
    wait_until { @pane.mirror_size.nil? }
    assert_equal [9, 30], [@pane.terminal.rows, @pane.terminal.cols]
  end

  def test_mirror_does_not_resize_its_replica_locally
    _remote, pane = mirror
    pane.resize(8, 20)
    assert_equal 24, pane.terminal.rows
    assert_equal 80, pane.terminal.cols
  end

  # The owner answers DSR once. If the replica answered too, its reply would
  # travel back as pane.send_input and the inner program would read a second,
  # unsolicited cursor report as keystrokes.
  def test_only_the_owner_answers_the_inner_programs_cursor_query
    remote, pane = mirror
    pane.read_from_pty
    relay_output("\e[6n")
    drain_into(remote, pane) { false }
    assert_equal 1, @process.writes.scan("\e[1;1R").length
  end

  def test_mirror_dies_when_the_owner_loses_the_pane
    remote, pane = mirror
    pane.read_from_pty
    @app.session.window.remove_pane(@pane)
    drain_into(remote, pane) { !remote.alive? }
    refute remote.alive?
  end

  def test_mirror_dies_when_the_owning_server_stops
    remote, pane = mirror
    pane.read_from_pty
    stop_pump
    @server.stop
    drain_into(remote, pane) { !remote.alive? }
    refute remote.alive?
  end

  def test_refresh_asks_the_owner_to_repaint
    remote, = mirror
    remote.nudge_redraw
    wait_until { @process.nudged? }
    assert @process.nudged?
  end

  def test_refusing_to_mirror_a_private_pane
    @pane.mark_private!
    err = assert_raises(Muxr::RemotePane::Error) { mirror }
    assert_match(/private/, err.message)
  end

  def test_unknown_pane_id_fails_the_handshake
    err = assert_raises(Muxr::RemotePane::Error) do
      @remotes << Muxr::RemotePane.connect(
        socket_path: @socket_path, pane_id: "nosuch", rows: 24, cols: 80
      )
    end
    assert_match(/no pane with id/, err.message)
  end

  def test_unreachable_socket_fails_the_handshake
    assert_raises(Muxr::RemotePane::Error) do
      Muxr::RemotePane.connect(
        socket_path: File.join(@dir, "missing.sock"), pane_id: "x", rows: 24, cols: 80
      )
    end
  end

  def wait_until(attempts: 200)
    attempts.times do
      return true if yield
      sleep 0.01
    end
    false
  end
end
