require "test_helper"
require "muxr"

class TestMasterShape < Minitest::Test
  LM = Muxr::LayoutManager
  AREA = LM::Rect.new(0, 0, 100, 40)

  def test_defaults_match_the_even_split
    assert_equal LM.tall(3, AREA).map(&:to_a), LM.compute(:tall, 3, AREA).map(&:to_a)
    assert_equal [0, 0, 50, 40], LM.compute(:tall, 3, AREA)[0].to_a
  end

  def test_ratio_widens_the_tall_master
    rects = LM.compute(:tall, 3, AREA, ratio: 0.7)
    assert_equal [0, 0, 70, 40], rects[0].to_a
    assert_equal [70, 0, 30, 20], rects[1].to_a
  end

  def test_ratio_deepens_the_wide_master
    rects = LM.compute(:wide, 3, AREA, ratio: 0.25)
    assert_equal [0, 0, 100, 10], rects[0].to_a
    assert_equal [0, 10, 50, 30], rects[1].to_a
  end

  def test_ratio_is_clamped
    assert_equal 90, LM.compute(:tall, 2, AREA, ratio: 5)[0].w
    assert_equal 10, LM.compute(:tall, 2, AREA, ratio: 0)[0].w
  end

  def test_two_masters_share_the_master_column
    rects = LM.compute(:tall, 4, AREA, nmaster: 2)
    assert_equal [0, 0, 50, 20], rects[0].to_a
    assert_equal [0, 20, 50, 20], rects[1].to_a
    assert_equal 50, rects[2].x
    assert_equal 50, rects[3].x
  end

  def test_masters_follow_the_master_index
    rects = LM.compute(:tall, 3, AREA, master_index: 2, nmaster: 2)
    assert_equal 0, rects[2].x
    assert_equal 0, rects[0].x
    assert_equal 50, rects[1].x
  end

  def test_every_pane_a_master_fills_the_area
    rects = LM.compute(:tall, 2, AREA, nmaster: 5)
    assert_equal [0, 0, 100, 20], rects[0].to_a
    assert_equal [0, 20, 100, 20], rects[1].to_a
    wide = LM.compute(:wide, 2, AREA, nmaster: 2)
    assert_equal [0, 0, 50, 40], wide[0].to_a
  end

  def test_centered_masters_stack_in_the_middle_column
    rects = LM.compute(:centered, 5, AREA, ratio: 0.6, nmaster: 2)
    assert_equal [20, 0, 60, 20], rects[0].to_a
    assert_equal [20, 20, 60, 20], rects[1].to_a
    assert_equal 0, rects[2].x
    assert_equal 80, rects[3].x
  end

  def test_every_rect_stays_inside_the_area
    %i[tall wide centered].each do |layout|
      (1..6).each do |count|
        (1..4).each do |nmaster|
          [0.1, 0.35, 0.9].each do |ratio|
            rects = LM.compute(layout, count, AREA, ratio: ratio, nmaster: nmaster)
            assert_equal count, rects.compact.length
            covered = rects.sum { |r| r.w * r.h }
            assert_equal AREA.w * AREA.h, covered, "#{layout} #{count}/#{nmaster}/#{ratio}"
          end
        end
      end
    end
  end

  def test_window_steps_and_clamps
    win = Muxr::Window.new
    3.times { win.add_pane(Object.new) }
    win.adjust_master_ratio(0.05)
    assert_equal 0.55, win.master_ratio
    20.times { win.adjust_master_ratio(0.05) }
    assert_equal 0.9, win.master_ratio
    5.times { win.adjust_master_count(1) }
    assert_equal 3, win.master_count
    5.times { win.adjust_master_count(-1) }
    assert_equal 1, win.master_count
  end

  def test_shape_is_saved_with_the_session
    session = Muxr::Session.new(name: "spec")
    session.window.master_ratio = 0.65
    session.window.master_count = 2
    data = session.serialize
    assert_equal 0.65, data["master_ratio"]
    assert_equal 2, data["master_count"]
  end

  def app_with_window
    app = Muxr::Application.new([])
    session = Muxr::Session.new(name: "spec")
    3.times { session.window.add_pane(Object.new) }
    app.instance_variable_set(:@session, session)
    [app, session.window]
  end

  def test_commands_take_a_percentage_or_a_fraction
    app, win = app_with_window
    dispatcher = Muxr::CommandDispatcher.new(app)
    dispatcher.dispatch("ratio 60")
    assert_equal 0.6, win.master_ratio
    dispatcher.dispatch("ratio 0.3")
    assert_equal 0.3, win.master_ratio
    dispatcher.dispatch("masters 2")
    assert_equal 2, win.master_count
    dispatcher.dispatch("ratio wide")
    assert_equal 0.3, win.master_ratio
  end

  def test_keys_reshape_the_master_area
    app, win = app_with_window
    input = Muxr::InputHandler.new(app)
    input.feed(">>.")
    assert_equal 0.6, win.master_ratio
    assert_equal 2, win.master_count
    input.feed("<,")
    assert_equal 0.55, win.master_ratio
    assert_equal 1, win.master_count
  end
end
