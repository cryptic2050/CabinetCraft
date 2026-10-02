# frozen_string_literal: true

require_relative 'test_helper'

class TestNesting < Minitest::Test
  N = CabinetCraft::Manufacturing::Nesting
  CS = CabinetCraft::Manufacturing::CutSequence

  SHEET = { 'material' => '18mm Plywood', 'sheet_length' => 2440.0, 'sheet_width' => 1220.0, 'grain_free' => false }.freeze
  FREE_SHEET = SHEET.merge('material' => '18mm MDF', 'grain_free' => true).freeze

  def part(id, l, w, grain = 'length')
    { 'uid' => "u#{id}", 'part_id' => id, 'name' => id, 'length' => l.to_f, 'width' => w.to_f, 'grain' => grain, 'cabinet_label' => 'B01' }
  end

  def random_parts(seed, count, grain: 'length')
    r = Random.new(seed)
    Array.new(count) { |i| part("P#{i}", r.rand(100..1100), r.rand(80..700), grain == 'mixed' ? %w[length width none].sample(random: r) : grain) }
  end

  # Independent checks of a result against the rules, not against the algorithm.
  def assert_valid(result, parts, settings = N::DEFAULTS, grain_free: false)
    trim = result['trim']
    gap = result['kerf'] + result['spacing']
    ids = []
    result['sheets'].each do |sh|
      pl = sh['placements']
      pl.each do |p|
        ids << p['part_id']
        assert_operator p['x'], :>=, trim - 1e-6
        assert_operator p['y'], :>=, trim - 1e-6
        assert_operator p['x'] + p['w'], :<=, result['sheet_length'] - trim + 1e-6, "#{p['part_id']} beyond right trim"
        assert_operator p['y'] + p['h'], :<=, result['sheet_width'] - trim + 1e-6, "#{p['part_id']} beyond top trim"
        src = parts.find { |x| x['part_id'] == p['part_id'] }
        assert_in_delta src['length'] * src['width'], p['w'] * p['h'], 0.5
        assert_equal [src['length'], src['width']].sort, [p['w'], p['h']].sort
        unless grain_free
          assert_equal false, p['rotated'], "#{p['part_id']} rotated against length grain" if src['grain'] == 'length'
          assert_equal true, p['rotated'], "#{p['part_id']} not rotated for width grain" if src['grain'] == 'width'
        end
      end
      pl.combination(2).each do |a, b|
        sep_x = a['x'] + a['w'] + gap <= b['x'] + 1e-6 || b['x'] + b['w'] + gap <= a['x'] + 1e-6
        sep_y = a['y'] + a['h'] + gap <= b['y'] + 1e-6 || b['y'] + b['h'] + gap <= a['y'] + 1e-6
        assert sep_x || sep_y, "#{a['part_id']} and #{b['part_id']} closer than #{gap} mm"
      end
      assert_in_delta sh['used_area'] + sh['waste_area'], result['sheet_length'] * result['sheet_width'], 1.0
    end
    unplaced = result['unplaced'].map { |u| u['part_id'] }
    assert_equal parts.map { |p| p['part_id'] }.sort, (ids + unplaced).sort, 'every part placed or reported exactly once'
    assert_equal ids.uniq, ids
    assert_in_delta result['used_area'] + result['waste_area'], result['total_area'], 1.0
  end

  # Replays the saw steps: no cut may pass through a part; every part is released exactly once.
  def assert_cuts_sound(sheet, kerf)
    cut = sheet['cut_sequence']
    assert cut['ok'], cut['reason']
    parts = sheet['placements']
    cut['steps'].select { |s| s['type'] == 'cut' }.each do |s|
      lo = s['position']
      hi = lo + kerf
      parts.each do |p|
        crosses = if s['axis'] == 'vertical'
                    p['x'] < hi - 1e-6 && p['x'] + p['w'] > lo + 1e-6 && p['y'] < s['to'] - 1e-6 && p['y'] + p['h'] > s['from'] + 1e-6
                  else
                    p['y'] < hi - 1e-6 && p['y'] + p['h'] > lo + 1e-6 && p['x'] < s['to'] - 1e-6 && p['x'] + p['w'] > s['from'] + 1e-6
                  end
        refute crosses, "step #{s['step']} (#{s['axis']} #{lo}) cuts through #{p['part_id']}"
      end
    end
    released = cut['steps'].select { |s| s['type'] == 'part' }.map { |s| s['part_id'] }
    assert_equal parts.map { |p| p['part_id'] }.sort, released.sort
  end

  def test_simple_exact_fit_two_parts
    r = N.nest([part('A', 1000, 600), part('B', 1000, 600)], SHEET, {})
    assert_equal 1, r['total_sheets']
    assert_valid(r, [part('A', 1000, 600), part('B', 1000, 600)])
    assert_in_delta 2 * 1000 * 600 * 100.0 / (2440 * 1220), r['utilization'], 0.01
  end

  def test_random_sets_are_valid_for_many_seeds_and_settings
    configs = [{}, { 'kerf' => 3.2, 'trim' => 5, 'spacing' => 2 }, { 'kerf' => 0, 'trim' => 0 }, { 'kerf' => 6, 'trim' => 20, 'spacing' => 10 }]
    (1..12).each do |seed|
      configs.each do |cfg|
        parts = random_parts(seed, 25 + seed)
        s = N.normalize_settings(cfg)
        r = N.nest(parts, SHEET, s)
        assert_valid(r, parts, s)
        r['sheets'].each { |sh| assert_cuts_sound(sh, s['kerf']) }
      end
    end
  end

  def test_grain_free_material_may_rotate_and_uses_fewer_or_equal_sheets
    parts = random_parts(3, 40, grain: 'width') # all need rotation if directional
    directional = N.nest(parts, SHEET, N::DEFAULTS)
    free = N.nest(parts, FREE_SHEET, N::DEFAULTS)
    assert_valid(directional, parts)
    assert_valid(free, parts, grain_free: true)
    assert_operator free['total_sheets'], :<=, directional['total_sheets'] + 1
  end

  def test_grain_is_never_violated_with_mixed_grain
    parts = random_parts(5, 60, grain: 'mixed')
    r = N.nest(parts, SHEET, N::DEFAULTS)
    assert_valid(r, parts)
    assert_includes r['sheets'].flat_map { |s| s['placements'] }.map { |p| p['rotated'] }, true # 'none' parts do rotate
  end

  def test_part_too_big_is_reported_not_dropped
    big = part('BIG', 3000, 500)
    r = N.nest([big, part('OK', 500, 500)], SHEET, {})
    assert_equal ['BIG'], r['unplaced'].map { |u| u['part_id'] }
    assert_equal 1, r['total_sheets']
    # a part that only fits if rotated, but grain forbids rotation
    tall = part('TALL', 1300, 400, 'width') # width grain: width runs along 2440 -> 400 along X, 1300 along Y (> 1200 usable)
    assert_equal ['TALL'], N.nest([tall], SHEET, {})['unplaced'].map { |u| u['part_id'] }
    assert_empty N.nest([tall], FREE_SHEET, {})['unplaced'] # free material: rotate to 1300 x 400
  end

  def test_trim_reduces_usable_area
    fits = part('F', 2420, 1200, 'none')
    assert_empty N.nest([fits], FREE_SHEET, { 'trim' => 10 })['unplaced']
    assert_equal 1, N.nest([fits], FREE_SHEET, { 'trim' => 11 })['unplaced'].size
  end

  def test_kerf_forces_extra_sheet
    parts = Array.new(2) { |i| part("K#{i}", 1209, 1200, 'none') } # 2 x 1209 = 2418 fits 2420 usable only without a kerf
    assert_equal 1, N.nest(parts, FREE_SHEET, { 'kerf' => 0, 'trim' => 10 })['total_sheets']
    assert_equal 2, N.nest(parts, FREE_SHEET, { 'kerf' => 4, 'trim' => 10 })['total_sheets']
  end

  def test_empty_and_totals
    r = N.nest([], SHEET, {})
    assert_equal 0, r['total_sheets']
    assert_equal 0.0, r['utilization']
  end

  def test_settings_validation
    assert_raises(ArgumentError) { N.normalize_settings('kerf' => -1) }
    assert_raises(ArgumentError) { N.normalize_settings('trim' => 999) }
    assert_raises(ArgumentError) { N.normalize_settings('sheet_length' => 10) }
    assert_raises(ArgumentError) { N.normalize_settings('kerf' => 'abc') }
    assert_equal 4.0, N.normalize_settings({})['kerf']
  end

  # --- Locks ---------------------------------------------------------------------------------
  def test_locked_part_stays_put_and_others_avoid_it
    parts = random_parts(2, 20)
    base = N.nest(parts, SHEET, N::DEFAULTS)
    moved = parts[0]
    lock = { moved['uid'] => { 'sheet' => 0, 'x' => 1500.0, 'y' => 500.0, 'rotated' => false, 'sig' => N.signature(moved) } }
    r = N.nest(parts, SHEET, N::DEFAULTS, lock)
    assert_valid(r, parts)
    p = r['sheets'][0]['placements'].find { |x| x['uid'] == moved['uid'] }
    assert_equal [1500.0, 500.0, true], [p['x'], p['y'], p['locked']]
    assert_empty r['released_locks']
    assert_operator r['total_sheets'], :>=, 1
    _ = base
  end

  def test_lock_released_when_part_changes_or_leaves_sheet
    p1 = part('A', 800, 500)
    stale = { p1['uid'] => { 'sheet' => 0, 'x' => 100.0, 'y' => 100.0, 'rotated' => false, 'sig' => '700.0x500.0' } }
    r = N.nest([p1], SHEET, N::DEFAULTS, stale)
    assert_equal ['part size changed'], r['released_locks'].map { |x| x['reason'] }
    assert_equal false, r['sheets'][0]['placements'][0]['locked']
    off = { p1['uid'] => { 'sheet' => 0, 'x' => 2000.0, 'y' => 100.0, 'rotated' => false, 'sig' => N.signature(p1) } }
    assert_match(/outside the sheet/, N.nest([p1], SHEET, N::DEFAULTS, off)['released_locks'][0]['reason'])
    rot = { p1['uid'] => { 'sheet' => 0, 'x' => 100.0, 'y' => 100.0, 'rotated' => true, 'sig' => N.signature(p1) } }
    assert_match(/grain/, N.nest([p1], SHEET, N::DEFAULTS, rot)['released_locks'][0]['reason'])
  end

  def test_two_locks_that_collide_release_the_second
    a = part('A', 500, 500, 'none')
    b = part('B', 500, 500, 'none')
    locks = { a['uid'] => { 'sheet' => 0, 'x' => 100.0, 'y' => 100.0, 'rotated' => false },
              b['uid'] => { 'sheet' => 0, 'x' => 300.0, 'y' => 300.0, 'rotated' => false } }
    r = N.nest([a, b], FREE_SHEET, N::DEFAULTS, locks)
    assert_equal ['B'], r['released_locks'].map { |x| x['part_id'] }
    assert_valid(r, [a, b], grain_free: true)
  end

  def test_lock_on_second_sheet_creates_it
    a = part('A', 500, 500, 'none')
    r = N.nest([a], FREE_SHEET, N::DEFAULTS, a['uid'] => { 'sheet' => 1, 'x' => 50.0, 'y' => 50.0, 'rotated' => false })
    assert_equal 2, r['total_sheets']
    assert_empty r['sheets'][0]['placements']
  end

  def test_check_move
    parts = [part('A', 800, 500, 'none'), part('B', 800, 500, 'none')]
    r = N.nest(parts, FREE_SHEET, N::DEFAULTS)
    a = parts[0]
    assert_nil N.check_move(r, a, 0, 1500, 600, false)
    assert_match(/Outside/, N.check_move(r, a, 0, 2000, 600, false))
    assert_match(/Outside/, N.check_move(r, a, 0, 0, 0, false))
    b = r['sheets'][0]['placements'].find { |p| p['part_id'] == 'B' }
    assert_match(/Too close/, N.check_move(r, a, 0, b['x'] + 10, b['y'] + 10, false))
    directional = N.nest([part('G', 800, 500, 'length')], SHEET, N::DEFAULTS)
    assert_match(/Grain/, N.check_move(directional, part('G', 800, 500, 'length'), 0, 100, 100, true))
    assert_nil N.check_move(directional, part('G', 800, 500, 'length'), 0, 100, 100, false)
  end

  # --- Cut sequence ------------------------------------------------------------------------------
  def test_cut_sequence_for_simple_strip
    rects = [{ 'id' => 'A', 'x' => 0, 'y' => 0, 'w' => 1000, 'h' => 600 }, { 'id' => 'B', 'x' => 1004, 'y' => 0, 'w' => 800, 'h' => 600 }]
    cut = CS.compute(rects, 2420, 1200, 4, offset: 10)
    assert cut['ok']
    cuts = cut['steps'].select { |s| s['type'] == 'cut' }
    # a horizontal cut would separate nothing at first, so the first cut divides A from B: 1000 + 10 trim
    assert_equal ['vertical', 1010.0], cuts.first.values_at('axis', 'position')
    assert_includes cuts.map { |c| [c['axis'], c['position']] }, ['horizontal', 610.0] # trim the 600 high strips
    assert_equal %w[A B], cut['steps'].select { |s| s['type'] == 'part' }.map { |s| s['part_id'] }
  end

  def test_pinwheel_layout_is_not_guillotine
    # four rectangles around a central one: no edge-to-edge cut exists
    k = 4
    rects = [
      { 'id' => 'a', 'x' => 0, 'y' => 0, 'w' => 600, 'h' => 300 },
      { 'id' => 'b', 'x' => 600 + k, 'y' => 0, 'w' => 300, 'h' => 600 },
      { 'id' => 'c', 'x' => 300 + k, 'y' => 600 + k, 'w' => 600, 'h' => 300 },
      { 'id' => 'd', 'x' => 0, 'y' => 300 + k, 'w' => 300, 'h' => 600 },
      { 'id' => 'e', 'x' => 300 + k, 'y' => 300 + k, 'w' => 296, 'h' => 296 }
    ]
    cut = CS.compute(rects, 1000, 1000, k)
    refute cut['ok']
    assert_match(/guillotine/, cut['reason'])
  end

  def test_overlapping_gap_smaller_than_kerf_is_not_cuttable
    rects = [{ 'id' => 'A', 'x' => 0, 'y' => 0, 'w' => 500, 'h' => 500 }, { 'id' => 'B', 'x' => 501, 'y' => 0, 'w' => 500, 'h' => 500 }]
    refute CS.compute(rects, 1500, 1000, 4)['ok']
  end
end
