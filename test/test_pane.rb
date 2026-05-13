require "test_helper"
require "muxr/pane"

class TestPane < Minitest::Test
  # Pane normally spawns a real PTY via PTYProcess.new. The `process:` kwarg
  # lets tests bypass that and stay process-free.
  class FakeProcess
    attr_reader :rows, :cols
    def initialize(rows: 24, cols: 80); @rows = rows; @cols = cols; end
    def io; nil; end
    def writer_io; nil; end
    def pending_write?; false; end
    def drain; end
    def write(_); end
    def read_nonblock(_ = 8192); nil; end
    def resize(_, _); end
    def alive?; true; end
    def cwd; "/tmp"; end
    def close; end
  end

  def make_pane(**kw)
    Muxr::Pane.new(process: FakeProcess.new, **kw)
  end

  def test_id_generated_when_not_provided
    p = make_pane
    assert_kind_of String, p.id
    assert_match(/\A[0-9a-f]{6}\z/, p.id)
  end

  def test_provided_id_preserved
    p = make_pane(id: "deadbe")
    assert_equal "deadbe", p.id
  end

  def test_drawer_id_can_be_symbol
    # The drawer slot uses :drawer as a sentinel so the renderer and control
    # surface can distinguish it from regular tiled panes.
    p = make_pane(id: :drawer)
    assert_equal :drawer, p.id
  end

  def test_ids_are_unique_across_instances
    ids = 100.times.map { make_pane.id }
    assert_equal 100, ids.uniq.size
  end

  def test_private_defaults_to_false
    refute make_pane.private?
  end

  def test_mark_private_and_toggle
    p = make_pane
    p.mark_private!
    assert p.private?
    p.toggle_private!
    refute p.private?
    p.toggle_private!
    assert p.private?
    p.mark_public!
    refute p.private?
  end
end
