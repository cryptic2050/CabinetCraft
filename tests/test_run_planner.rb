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

  # --- fillers -----------------------------------------------------------------------------------------------------------------
  def filler(over = {})
    { 'filler' => true }.merge(over)
  end

  def test_a_filler_takes_its_target_width_when_the_others_can_share_the_rest
    r = P.plan(2400, [flex, flex, flex, filler])
    assert_equal 2400, r['widths'].sum
    assert_equal 50, r['widths'].last
    assert_equal [783, 783, 784], r['widths'].first(3).sort # 2350 shared by three
    assert_equal [true, 0.0, 0.0], [r['ok'], r['leftover'], r['shortfall']]
  end

  def test_with_fixed_cabinets_the_filler_closes_the_gap_exactly
    r = P.plan(1900, [fixed(600), fixed(600), fixed(600), filler])
    assert_equal [600, 600, 600, 100], r['widths']
    assert r['ok']
    assert_equal [600, 600, 600, 20], P.plan(1820, [fixed(600), fixed(600), fixed(600), filler])['widths']
  end

  def test_a_gap_larger_than_the_filler_maximum_is_reported
    r = P.plan(2000, [fixed(600), fixed(600), fixed(600), filler])
    assert_equal 150, r['widths'].last
    assert_equal 50.0, r['leftover']
    assert_match(/maximum.*50.0 mm of the wall stays empty/, r['issues'].join)
  end

  def test_a_gap_smaller_than_the_filler_minimum_does_not_fit
    r = P.plan(1810, [fixed(600), fixed(600), fixed(600), filler])
    assert_equal false, r['ok']
    assert_equal 10.0, r['shortfall']
  end

  def test_saturated_cabinets_pass_the_remainder_to_the_filler
    r = P.plan(2000, [flex(300, 900), flex(300, 900), filler])
    assert_equal [900, 900], r['widths'].first(2) # at their maximum
    assert_equal 150, r['widths'].last # the filler is limited too
    assert_equal 50.0, r['leftover']
    r2 = P.plan(1900, [flex(300, 900), flex(300, 900), filler('max' => 400)])
    assert_equal [900, 900, 100], r2['widths']
  end

  def test_several_fillers_share_equally_and_may_sit_anywhere_in_the_row
    r = P.plan(1900, [filler, fixed(900), fixed(800), filler])
    assert_equal [100, 900, 800, 100].sum, r['widths'].sum
    assert_equal r['widths'].first, r['widths'].last
    assert_equal 100, r['widths'].first
  end

  def test_filler_limits_are_validated
    [filler('min' => 0), filler('min' => 100, 'max' => 50), filler('width' => 10), filler('width' => 500)].each do |f|
      assert_raises(ArgumentError, f.inspect) { P.plan(2000, [flex, f]) }
    end
    assert_equal [20.0, 150.0, 50.0], [P::FILLER_MIN, P::FILLER_MAX, P::FILLER_TARGET]
  end

  def test_property_fillers_stay_in_range_and_the_total_is_exact_when_feasible
    rng = Random.new(21)
    300.times do
      items = Array.new(rng.rand(1..5)) { rng.rand < 0.4 ? fixed(rng.rand(300..900)) : flex(rng.rand(250..400), rng.rand(500..900)) }
      items.insert(rng.rand(0..items.size), filler('min' => 20, 'max' => rng.rand(60..200), 'width' => rng.rand(20..60)))
      length = rng.rand(800..5000)
      r = P.plan(length, items)
      items.each_with_index do |it, i|
        w = r['widths'][i]
        if it['filler'] then assert w >= 20 - 1e-6 && w <= it['max'] + 1e-6, "filler #{w}"
        elsif it['fixed'] then assert_equal it['width'], w
        else assert w >= it['min'] - 1e-6 && w <= it['max'] + 1e-6
        end
      end
      assert_in_delta length, r['widths'].sum + r['leftover'] - r['shortfall'], 1e-6
      assert r['leftover'].zero? || r['shortfall'].zero?
    end
  end
end
