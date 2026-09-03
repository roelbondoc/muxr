require "test_helper"
require "json"
require "socket"
require "tmpdir"
require "muxr/application"
require "muxr/session_directory"

# SessionDirectory is the only place muxr looks outside its own process, so
# these tests stand up real listening sockets in a temp SOCKETS_DIR rather than
# stubbing the discovery.
class TestSessionDirectory < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("muxr-directory")
    @original = Muxr::Application::SOCKETS_DIR
    Muxr::Application.send(:remove_const, :SOCKETS_DIR)
    Muxr::Application.const_set(:SOCKETS_DIR, @dir)
    @servers = []
    @responders = []
  end

  def teardown
    @responders.each { |t| t.kill }
    @servers.each { |s| s.close rescue nil }
    Muxr::Application.send(:remove_const, :SOCKETS_DIR)
    Muxr::Application.const_set(:SOCKETS_DIR, @original)
    FileUtils.remove_entry(@dir) if File.directory?(@dir)
  end

  def listen(name)
    server = UNIXServer.new(File.join(@dir, name))
    @servers << server
    server
  end

  # A stand-in muxr server that answers exactly one method with a canned result.
  def serve(name, panes)
    listen("#{name}.sock")
    control = listen("#{name}.ctrl.sock")
    @responders << Thread.new do
      loop do
        client = control.accept
        Thread.new do
          while (line = client.gets)
            msg = JSON.parse(line) rescue next
            next unless msg["method"] == "panes.list"
            client.write(JSON.generate("id" => msg["id"], "result" => { "panes" => panes }) + "\n")
          end
        rescue IOError, SystemCallError
        end
      end
    rescue IOError, SystemCallError
    end
  end

  def pane(id:, slot:, private: false, alive: true, cwd: "/tmp/#{id}")
    { "id" => id, "slot" => slot, "private" => private, "alive" => alive,
      "cwd" => cwd, "rows" => 24, "cols" => 80, "focused" => slot == 1 }
  end

  def test_live_sessions_pairs_a_session_with_its_control_socket
    serve("work", [])
    assert_equal({ "work" => File.join(@dir, "work.ctrl.sock") }, Muxr::SessionDirectory.live_sessions)
  end

  def test_a_control_socket_is_not_itself_a_session
    serve("work", [])
    refute_includes Muxr::SessionDirectory.live_sessions.keys, "work.ctrl"
    refute_includes Muxr::Application.list_active, "work.ctrl"
    assert_equal ["work"], Muxr::Application.list_active
  end

  def test_a_session_without_a_live_control_socket_is_skipped
    listen("half.sock")
    assert_empty Muxr::SessionDirectory.live_sessions
  end

  def test_a_stale_socket_file_is_skipped
    File.write(File.join(@dir, "dead.sock"), "")
    File.write(File.join(@dir, "dead.ctrl.sock"), "")
    assert_empty Muxr::SessionDirectory.live_sessions
    assert_empty Muxr::Application.list_active
  end

  def test_panes_are_collected_across_sessions
    serve("work", [pane(id: "aaa111", slot: 1), pane(id: "bbb222", slot: 2)])
    serve("notes", [pane(id: "ccc333", slot: 1)])
    entries = Muxr::SessionDirectory.panes
    assert_equal %w[aaa111 bbb222 ccc333], entries.map(&:pane_id).sort
    assert_equal "notes:ccc333", entries.find { |e| e.pane_id == "ccc333" }.label
  end

  def test_the_asking_session_is_left_out
    serve("work", [pane(id: "aaa111", slot: 1)])
    serve("notes", [pane(id: "ccc333", slot: 1)])
    entries = Muxr::SessionDirectory.panes(exclude: "work")
    assert_equal ["ccc333"], entries.map(&:pane_id)
  end

  def test_private_and_dead_panes_are_not_offered
    serve("work", [
      pane(id: "aaa111", slot: 1),
      pane(id: "secret", slot: 2, private: true),
      pane(id: "zombie", slot: 3, alive: false)
    ])
    assert_equal ["aaa111"], Muxr::SessionDirectory.panes.map(&:pane_id)
  end

  def test_a_server_that_never_answers_does_not_hang_the_caller
    listen("mute.sock")
    listen("mute.ctrl.sock")
    serve("work", [pane(id: "aaa111", slot: 1)])
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    entries = Muxr::SessionDirectory.panes
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal ["aaa111"], entries.map(&:pane_id)
    assert_operator elapsed, :<, Muxr::SessionDirectory::QUERY_TIMEOUT * 3
  end
end
