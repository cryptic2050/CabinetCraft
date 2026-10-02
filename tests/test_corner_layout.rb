# frozen_string_literal: true

require_relative 'test_helper'

class TestCornerLayout < Minitest::Test
  C = CabinetCraft::CornerLayout

  # world position of a point given in a cabinet's own frame (x width, y depth front -> back)
  def world(frame, lx, ly)
    ox, oy = frame['origin']
    [ox + lx * frame['x_axis'][0] + ly * frame['y_axis'][0], oy + lx * frame['x_axis'][1] + ly * frame['y_axis'][1]]
  end

  def footprint(frame, w, d)
    pts = [world(frame, 0, 0), world(frame, w, 0), world(frame, w, d), world(frame, 0, d)]
    xs = pts.map(&:first)
    ys = pts.map(&:last)
    [xs.min, ys.min, xs.max, ys.max].map { |v| v.round(6) }
  end

  def test_none_corner_run_a_starts_in_the_corner_and_run_b_clears_its_depth
    p = C.plan(3000, 2400, kind: 'none', depth: 560, clearance: 20)
    assert p['ok']
    assert_equal [0.0, 3000.0], [p['a']['start'], p['a']['length']]
    assert_equal [580.0, 1820.0], [p['b']['start'], p['b']['length']]
    assert_nil p['corner']
  end

  def test_blind_corner_cabinet_opens_run_a_and_run_b_clears_the_depth
    p = C.plan(3000, 2400, kind: 'blind', corner: { 'width' => 900 })
    assert_equal [900.0, 2100.0], [p['a']['start'], p['a']['length']]
    assert_equal [580.0, 1820.0], [p['b']['start'], p['b']['length']]
    assert_equal [0.0, 0.0, 900.0, 560.0], footprint(p['corner']['frame'], 900, 560) # the blind cabinet fills x 0..900 against wall A
  end

  def test_l_shaped_corner_runs_start_after_the_arms
    p = C.plan(3000, 2400, kind: 'l_shaped', corner: { 'width_a' => 900, 'width_b' => 1000 })
    assert_equal [900.0, 2100.0], [p['a']['start'], p['a']['length']]
    assert_equal [1000.0, 1400.0], [p['b']['start'], p['b']['length']]
    assert_equal [0.0, 0.0], p['corner']['frame']['origin']
  end

  def test_frames_put_the_front_into_the_room_and_the_back_on_the_wall
    fa = C.frame_a(900, 600, 560)
    assert_equal [900.0, 0.0, 1500.0, 560.0], footprint(fa, 600, 560)
    assert_equal [1500.0, 560.0], world(fa, 0, 0).map(&:to_f) # local front-left corner: front is at y = depth, left is the far end
    assert_equal 0.0, world(fa, 0, 560)[1]               # the back is on the wall y = 0
    fb = C.frame_b(1000, 600, 560)
    assert_equal [0.0, 1000.0, 560.0, 1600.0], footprint(fb, 600, 560)
    assert_equal 560.0, world(fb, 0, 0)[0]               # the front is at x = depth
    assert_equal 0.0, world(fb, 0, 560)[0]               # the back is on the wall x = 0
    # both frames are proper rotations (right-handed): x cross y points up
    [fa, fb].each { |f| assert_equal 1, f['x_axis'][0] * f['y_axis'][1] - f['x_axis'][1] * f['y_axis'][0] }
  end

  def test_pieces_never_overlap_for_every_kind
    rng = Random.new(3)
    300.times do
      kind = C::KINDS.sample(random: rng)
      d = rng.rand(300..700)
      corner = { 'width' => rng.rand(600..1200), 'width_a' => rng.rand((d + 100)..1300), 'width_b' => rng.rand((d + 100)..1300) }
      p = C.plan(rng.rand(2500..5000), rng.rand(2500..5000), kind: kind, depth: d, clearance: rng.rand(0..60), corner: corner)
      next unless p['ok']

      wa = Array.new(rng.rand(1..4)) { 300.0 }
      wb = Array.new(rng.rand(1..4)) { 300.0 }
      assert_empty C.overlapping(C.rectangles(p, wa, wb)), "#{kind} #{p.inspect}"
    end
  end

  def test_overlap_detection_itself_works
    assert_equal [%w[a b]], C.overlapping([['a', 0, 0, 10, 10], ['b', 5, 5, 15, 15], ['c', 10, 0, 20, 5]])
    assert_empty C.overlapping([['a', 0, 0, 10, 10], ['b', 10, 0, 20, 10]]) # touching is fine
  end

  def test_walls_that_are_too_short_are_reported
    p = C.plan(800, 2400, kind: 'blind', corner: { 'width' => 900 })
    assert_equal false, p['ok']
    assert_match(/Wall A/, p['issues'].join)
    q = C.plan(3000, 500, kind: 'none', depth: 560)
    assert_equal false, q['ok']
    assert_match(/Wall B/, q['issues'].join)
  end

  def test_invalid_input_raises
    [[0, 2000, {}], [2000, -1, {}], ['x', 2000, {}], [2000, 2000, { kind: 'zig' }], [2000, 2000, { depth: 0 }], [2000, 2000, { clearance: -5 }],
     [2000, 2000, { kind: 'blind' }], [2000, 2000, { kind: 'l_shaped', corner: { 'width_a' => 500, 'width_b' => 900 } }],
     [2000, 2000, { kind: 'l_shaped', corner: { 'width_a' => 900 } }]].each do |a, b, opts|
      assert_raises(ArgumentError, [a, b, opts].inspect) { C.plan(a, b, **opts) }
    end
  end
end
