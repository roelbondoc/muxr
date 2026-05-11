require_relative "test_helper"
require "muxr/application"

class TestApplicationListActive < Minitest::Test
  def with_isolated_sockets_dir
    Dir.mktmpdir("muxr-sockets") do |dir|
      original = Muxr::Application::SOCKETS_DIR
      Muxr::Application.send(:remove_const, :SOCKETS_DIR)
      Muxr::Application.const_set(:SOCKETS_DIR, dir)
      begin
        yield dir
      ensure
        Muxr::Application.send(:remove_const, :SOCKETS_DIR)
        Muxr::Application.const_set(:SOCKETS_DIR, original)
      end
    end
  end

  def test_list_active_returns_empty_when_dir_missing
    Dir.mktmpdir("muxr-sockets") do |tmp|
      missing = File.join(tmp, "does-not-exist")
      original = Muxr::Application::SOCKETS_DIR
      Muxr::Application.send(:remove_const, :SOCKETS_DIR)
      Muxr::Application.const_set(:SOCKETS_DIR, missing)
      begin
        assert_equal [], Muxr::Application.list_active
      ensure
        Muxr::Application.send(:remove_const, :SOCKETS_DIR)
        Muxr::Application.const_set(:SOCKETS_DIR, original)
      end
    end
  end

  def test_list_active_returns_empty_when_no_sockets
    with_isolated_sockets_dir do
      assert_equal [], Muxr::Application.list_active
    end
  end

  def test_list_active_returns_names_of_alive_sockets
    with_isolated_sockets_dir do |dir|
      alive_a = UNIXServer.new(File.join(dir, "work.sock"))
      alive_b = UNIXServer.new(File.join(dir, "play.sock"))
      begin
        assert_equal %w[play work], Muxr::Application.list_active
      ensure
        alive_a.close
        alive_b.close
      end
    end
  end

  def test_list_active_skips_stale_sockets_and_non_sock_files
    with_isolated_sockets_dir do |dir|
      alive = UNIXServer.new(File.join(dir, "alive.sock"))
      # A regular file with .sock extension — connect() will fail with ECONNREFUSED.
      File.write(File.join(dir, "stale.sock"), "")
      # Something unrelated in the same directory.
      File.write(File.join(dir, "notes.txt"), "ignore me")
      begin
        assert_equal %w[alive], Muxr::Application.list_active
      ensure
        alive.close
      end
    end
  end
end
