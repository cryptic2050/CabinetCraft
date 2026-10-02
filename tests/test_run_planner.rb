# frozen_string_literal: true

require_relative 'test_helper'

class TestRunPlanner < Minitest::Test
  P = CabinetCraft::RunPlanner

  def flex(min = 300, max = 900)
    { 'min' => min, 'max' => max }
  end

  def fixed(w)
    { 'fixed' => true, 'width' => w }
  end

  def test_equal_split_fills_the_wall_exactly
    r = P.plan(2400, [flex, flex, flex, flex])
    assert_equal [600, 600, 600, 600], r['widths']
    assert_equal [true, 0.0, 0.0], [r['ok'], r['leftover'], r['shortfall']]
    assert_empty r['issues']
  end

  def test_rounding_remainder_is_handed_out_so_the_total_is_exact
    r = P.plan(2000, [flex, flex, flex])
    assert_equal 2000, r['widths'].sum
    assert_equal [667, 667, 666], r['widths']
    assert_equal [1000.5, 1000.5], P.plan(2001, [flex(300, 1200), flex(300, 1200)], step: 0.5)['widths']
  end

  def test_fixed_items_keep_their_width
    r = P.plan(2000, [fixed(450), flex, fixed(300), flex])
    assert_equal [450, 625, 300, 625], r['widths']
  end

  def test_clamped_cabinets_pass_their_share_on
    # a 300-wide-max cabinet cannot take its 500 share: the others absorb the difference
    r = P.plan(2000, [flex(300, 300), flex, flex])
    assert_equal [300, 850, 850], r['widths']
    r2 = P.plan(2000, [flex(700, 900), flex(300, 400), flex])
    assert_equal [800, 400, 800], r2['widths'] # the 400-capped cabinet leaves 1600 for the other two
    r3 = P.plan(2000, [flex(850, 900), flex(300, 400), flex(300, 900)])
    assert_equal [850, 400, 750], r3['widths'] # a minimum can push the others lower than an equal share
  end

  def test_leftover_is_reported_not_hidden
    r = P.plan(3000, [flex, flex])
    assert_equal [900, 900], r['widths']
    assert_equal [true, 1200.0, 0.0], [r['ok'], r['leftover'], r['shortfall']]
    assert_match(/filler strip/, r['issues'].join)
  end

  def test_too_long_row_is_not_ok_and_reports_the_shortfall
    r = P.plan(1000, [flex, flex, flex, flex])
    assert_equal [false, 200.0], [r['ok'], r['shortfall']]
    assert_equal [300, 300, 300, 300], r['widths']
    over = P.plan(500, [fixed(600), flex])
    assert_equal false, over['ok']
    assert_operator over['shortfall'], :>, 0
  end

  def test_all_fixed_rows
    assert_equal [true, 0.0], P.plan(900, [fixed(450), fixed(450)]).values_at('ok', 'leftover')
    r = P.plan(1000, [fixed(450), fixed(450)])
    assert_equal 100.0, r['leftover']
  end

  def test_invalid_input_raises
    [[0, [flex]], [-5, [flex]], ['abc', [flex]], [1000, []], [1000, [{ 'fixed' => true }]], [1000, [fixed(-1)]], [1000, [flex(500, 400)]], [1000, [flex(0, 400)]]].each do |len, items|
      assert_raises(ArgumentError, "#{len.inspect} #{items.inspect}") { P.plan(len, items) }
    end
    assert_raises(ArgumentError) { P.plan(1000, [flex], step: 0) }
  end

  def test_property_total_is_exact_and_limits_hold
    rng = Random.new(42)
    300.times do
      n = rng.rand(1..7)
      items = Array.new(n) do
        if rng.rand < 0.3 then fixed(rng.rand(200..900))
        else
          lo = rng.rand(150..500)
          flex(lo, lo + rng.rand(0..600))
        end
      end
      length = rng.rand(500..6000)
      r = P.plan(length, items)
      items.each_with_index do |it, i|
        w = r['widths'][i]
        if it['fixed'] then assert_equal it['width'], w
        else assert w >= it['min'] - 1e-6 && w <= it['max'] + 1e-6, "#{w} outside #{it.inspect}"
        end
      end
      assert_in_delta length, r['widths'].sum + r['leftover'] - r['shortfall'], 1e-6, items.inspect
      assert r['leftover'].zero? || r['shortfall'].zero?
    end
  end

  def test_unclamped_cabinets_differ_by_at_most_one_step
    rng = Random.new(7)
    200.times do
      items = Array.new(rng.rand(2..6)) { flex(100, 3000) }
      r = P.plan(rng.rand(1000..6000), items)
      assert_operator r['widths'].max - r['widths'].min, :<=, 1.0 + 1e-9
    end
  end
end
