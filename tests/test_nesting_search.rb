# frozen_string_literal: true

require_relative 'test_helper'

class TestNestingSearch < Minitest::Test
  N = CabinetCraft::Manufacturing::Nesting
  SHEET = { 'material' => 'M', 'sheet_length' => 2440.0, 'sheet_width' => 1220.0, 'grain_free' => true }.freeze
  CFG = { 'kerf' => 4.0, 'trim' => 10.0, 'spacing' => 0.0 }.freeze

  def parts(seed, n, grain: 'none')
    r = Random.new(seed)
    Array.new(n) do |i|
      l = r.rand(80..1200).to_f
      { 'uid' => "u#{i}", 'part_id' => "P#{i}", 'name' => 'p', 'length' => l, 'width' => r.rand(60..[l.to_i, 600].min).to_f,
        'grain' => grain == 'mixed' ? %w[length width none].sample(random: r) : grain, 'cabinet_label' => 'B' }
    end
  end

  # The previous search: the four sort orders with the area fit and the short-axis split.
  def baseline(ps, sheet = SHEET, cfg = CFG)
    s = N::DEFAULTS.merge(cfg)
    ctx = { sheet: sheet, uw: sheet['sheet_length'] - 2 * s['trim'], uh: sheet['sheet_width'] - 2 * s['trim'], gap: s['kerf'] + s['spacing'], trim: s['trim'], settings: s }
    runs = N.sort_orders.map { |o| N.run(ps.sort_by(&o), [], ctx) }
    runs.min_by { |r| [r[:unplaced].size, r[:sheets].size, -r[:offcut]] }
  end

  def test_never_worse_than_the_old_four_ordering_search
    strictly = 0
    60.times do |k|
      ps = parts(500 + k, [12, 30, 70, 160][k % 4])
      old = baseline(ps)
      new = N.nest(ps, SHEET, CFG)
      assert_operator new['unplaced'].size, :<=, old[:unplaced].size
      assert_operator new['total_sheets'], :<=, old[:sheets].size, "problem #{k}"
      strictly += 1 if new['total_sheets'] < old[:sheets].size
    end
    assert_operator strictly, :>, 0, 'the wider search should help on at least some problems'
  end

  def test_the_result_is_deterministic
    ps = parts(9, 40)
    assert_equal JSON.generate(N.nest(ps, SHEET, CFG)), JSON.generate(N.nest(ps, SHEET, CFG))
  end

  def assert_valid_layout(res, ps, cfg = CFG)
    gap = cfg['kerf'] + (cfg['spacing'] || 0)
    placed = res['sheets'].flat_map { |s| s['placements'] }
    assert_equal ps.map { |p| p['uid'] }.sort, (placed.map { |p| p['uid'] } + res['unplaced'].map { |p| p['uid'] }).sort
    res['sheets'].each do |s|
      s['placements'].each do |p|
        assert_operator p['x'], :>=, cfg['trim'] - 1e-6
        assert_operator p['y'], :>=, cfg['trim'] - 1e-6
        assert_operator p['x'] + p['w'], :<=, res['sheet_length'] - cfg['trim'] + 1e-6
        assert_operator p['y'] + p['h'], :<=, res['sheet_width'] - cfg['trim'] + 1e-6
      end
      s['placements'].combination(2).each do |a, b|
        sep_x = b['x'] - (a['x'] + a['w']) >= gap - 0.011 || a['x'] - (b['x'] + b['w']) >= gap - 0.011
        sep_y = b['y'] - (a['y'] + a['h']) >= gap - 0.011 || a['y'] - (b['y'] + b['h']) >= gap - 0.011
        assert sep_x || sep_y, "#{a['part_id']} and #{b['part_id']} are closer than the cutting gap"
      end
    end
  end

  def test_layouts_stay_valid_with_grain_and_rotation
    [parts(1, 50), parts(2, 50, grain: 'mixed'), parts(3, 120, grain: 'length')].each do |ps|
      sheet = SHEET.merge('grain_free' => false, 'grain_axis' => 'length')
      res = N.nest(ps, sheet, CFG)
      assert_valid_layout(res, ps)
      res['sheets'].flat_map { |s| s['placements'] }.each do |pl|
        part = ps.find { |p| p['uid'] == pl['uid'] }
        # a part with grain along its length must lie with its length along the sheet length (not rotated); width grain the opposite
        assert_equal false, pl['rotated'] if part['grain'] == 'length'
        assert_equal true, pl['rotated'] if part['grain'] == 'width'
      end
    end
  end

  def test_locked_parts_are_kept_with_the_wider_search
    ps = parts(4, 30)
    first = N.nest(ps, SHEET, CFG)
    pl = first['sheets'][0]['placements'][3]
    locked = { pl['uid'] => { 'sheet' => 0, 'x' => pl['x'], 'y' => pl['y'], 'rotated' => pl['rotated'], 'sig' => "#{ps.find { |p| p['uid'] == pl['uid'] }['length'].round(1)}x#{ps.find { |p| p['uid'] == pl['uid'] }['width'].round(1)}" } }
    again = N.nest(ps, SHEET, CFG, locked)
    kept = again['sheets'][0]['placements'].find { |p| p['uid'] == pl['uid'] }
    assert_equal [pl['x'], pl['y'], true], [kept['x'], kept['y'], kept['locked']]
    assert_valid_layout(again, ps)
  end

  def test_tiny_inputs
    assert_equal 0, N.nest([], SHEET, CFG)['total_sheets']
    one = N.nest(parts(5, 1), SHEET, CFG)
    assert_equal 1, one['total_sheets']
  end

  # --- offcuts ----------------------------------------------------------------------------------------------------------
  def test_offcuts_account_for_all_free_area_when_the_gap_is_zero
    ps = [{ 'uid' => 'a', 'part_id' => 'A', 'name' => 'a', 'length' => 600.0, 'width' => 600.0, 'grain' => 'none', 'cabinet_label' => 'B' }]
    res = N.nest(ps, SHEET, { 'kerf' => 0.0, 'trim' => 0.0, 'spacing' => 0.0, 'min_offcut' => 20.0 })
    sheet = res['sheets'][0]
    assert_in_delta 2440.0 * 1220 - 600 * 600, sheet['offcuts'].sum { |o| o['w'] * o['h'] }, 1.0
    assert_operator sheet['offcuts'].size, :<=, 2
    assert_equal res['offcut_count'], sheet['offcuts'].size
  end

  def test_offcuts_never_overlap_parts_or_each_other_and_respect_the_minimum
    20.times do |k|
      ps = parts(700 + k, [10, 25, 60][k % 3])
      cfg = CFG.merge('min_offcut' => [100.0, 200.0, 300.0][k % 3])
      res = N.nest(ps, SHEET, cfg)
      res['sheets'].each do |s|
        s['offcuts'].each do |o|
          assert_operator o['w'], :>=, cfg['min_offcut'] - 1e-6
          assert_operator o['h'], :>=, cfg['min_offcut'] - 1e-6
          assert_operator o['x'] + o['w'], :<=, res['sheet_length'] - cfg['trim'] + 1e-6
          assert_operator o['y'] + o['h'], :<=, res['sheet_width'] - cfg['trim'] + 1e-6
          s['placements'].each do |p|
            disjoint = o['x'] + o['w'] <= p['x'] + 1e-6 || p['x'] + p['w'] <= o['x'] + 1e-6 || o['y'] + o['h'] <= p['y'] + 1e-6 || p['y'] + p['h'] <= o['y'] + 1e-6
            assert disjoint, "offcut overlaps #{p['part_id']}"
          end
        end
        s['offcuts'].combination(2).each do |a, b|
          disjoint = a['x'] + a['w'] <= b['x'] + 1e-6 || b['x'] + b['w'] <= a['x'] + 1e-6 || a['y'] + a['h'] <= b['y'] + 1e-6 || b['y'] + b['h'] <= a['y'] + 1e-6
          assert disjoint
        end
        assert_equal s['offcuts'].map { |o| -o['w'] * o['h'] }, s['offcuts'].map { |o| -o['w'] * o['h'] }.sort # biggest first
      end
    end
  end

  def test_a_bigger_minimum_gives_fewer_offcuts_and_the_setting_is_validated
    ps = parts(11, 25)
    small = N.nest(ps, SHEET, CFG.merge('min_offcut' => 50.0))['offcut_count']
    big = N.nest(ps, SHEET, CFG.merge('min_offcut' => 500.0))['offcut_count']
    assert_operator small, :>=, big
    assert_equal 150.0, N.normalize_settings({})['min_offcut']
    assert_equal 200.0, N.normalize_settings('min_offcut' => '200')['min_offcut']
    assert_raises(ArgumentError) { N.normalize_settings('min_offcut' => 5) }
    assert_raises(ArgumentError) { N.normalize_settings('min_offcut' => 5000) }
  end
end
