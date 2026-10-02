# frozen_string_literal: true

require_relative 'test_helper'

class TestVisualization < Minitest::Test
  include TestParams
  V = CabinetCraft::Manufacturing::Visualization

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
  end

  def cab(label = 'B01', ov = {})
    CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(ov), label: label)
  end

  def cabs
    [cab('B01', 'door_count' => 2, 'drawer_count' => 1, 'height' => 820, 'shelf_count' => 1), cab('B02', 'material' => 'ply_18')]
  end

  def test_every_mode_classifies_every_part_and_the_legend_counts_add_up
    all = cabs
    n = all.sum { |c| c.panels.size }
    V::MODES.each_key do |mode|
      r = V.assign(mode, all)
      assert_equal n, r['parts'].size, mode
      assert_equal n, r['legend'].sum { |l| l['count'] }, mode
      r['parts'].each_value { |p| assert_match(/\A#[0-9a-f]{6}\z/, p['color'], mode) }
      assert_equal r['legend'].map { |l| l['label'] }.uniq, r['legend'].map { |l| l['label'] }, "#{mode}: one legend entry per category"
    end
  end

  def test_the_role_mode_groups_parts_and_orders_the_legend_the_same_way_every_time
    r = V.assign('role', cabs)
    assert_equal 'Structure (sides, bottom, top, rails, dividers)', r['legend'].first['label']
    assert_equal V::PALETTE[0], r['legend'].first['color']
    only_fronts = V.assign('role', [cab('B09', 'door_count' => 1)])
    structure = only_fronts['legend'].find { |l| l['label'].start_with?('Structure') }
    assert_equal V::PALETTE[0], structure['color'] # a legend entry keeps its colour whatever else is present
    fronts = V.assign('role', [cab('B09', 'door_count' => 1)])['legend'].find { |l| l['label'].start_with?('Fronts') }
    assert_equal V::PALETTE[3], fronts['color']
    no_shelves = V.assign('role', [cab('B10', 'door_count' => 1, 'shelf_count' => 0)])
    refute(no_shelves['legend'].any? { |l| l['label'] == 'Shelves' })
    assert_equal V::PALETTE[3], no_shelves['legend'].find { |l| l['label'].start_with?('Fronts') }['color'] # not shifted by the missing shelves category
  end

  def test_grain_and_override_modes
    g = V.assign('grain', [cab('B01', 'material' => 'ply_18')])
    assert_includes g['legend'].map { |l| l['label'] }, 'Grain along the length'
    c = cab.with_overrides('bottom' => { 'length' => 590.0 })
    o = V.assign('overrides', [c])
    manual = o['legend'].find { |l| l['label'] == 'Manually overridden' }
    assert_equal [1, V::PALETTE[1]], [manual['count'], manual['color']]
    assert_equal V::NEUTRAL, o['legend'].find { |l| l['label'] == 'Automatic' }['color']
  end

  def test_edge_banding_colours_follow_the_thickness
    c = cab('B01', 'door_count' => 1)
    r = V.assign('edges', [c])
    labels = r['legend'].map { |l| l['label'] }
    assert_includes labels, 'No edge banding'
    assert(labels.any? { |l| l =~ /mm band/ })
    one = r['legend'].find { |l| l['label'] == '1 mm band' }
    refute_nil one
    assert_equal V::PALETTE[2], one['color'] # 1 mm is always slot 2, whatever other bands exist
    assert_equal V::NEUTRAL, r['legend'].find { |l| l['label'] == 'No edge banding' }['color']
  end

  def test_status_mode_follows_production_progress
    c = cab
    rows = CabinetCraft::Manufacturing::PartsList.build([c])
    ops = CabinetCraft::Manufacturing::Machining.for_project([c])['ops'].group_by { |o| o['part_uid'] }
    todo = V.assign('status', [c], production: {}, ops_by_uid: ops)
    assert_equal ['Not started'], todo['legend'].map { |l| l['label'] }
    state = CabinetCraft::Manufacturing::Production.mark({}, rows.first, 'cut', true)
    part = V.assign('status', [c], production: state, ops_by_uid: ops)
    assert_equal({ 'Not started' => V::NEUTRAL, 'In progress' => V::WARN }, part['legend'].to_h { |l| [l['label'], l['color']] })
    full = {}
    rows.each { |r| CabinetCraft::Manufacturing::Production.applicable(r, ops).each { |st| full = CabinetCraft::Manufacturing::Production.mark(full, r, st, true) } }
    done = V.assign('status', [c], production: full, ops_by_uid: ops)
    assert_equal [['All steps done', V::GOOD]], done['legend'].map { |l| [l['label'], l['color']] }
  end

  def test_cabinet_mode_gives_each_cabinet_its_own_colour
    r = V.assign('cabinet', cabs)
    assert_equal %w[B01 B02], r['legend'].map { |l| l['label'] }
    assert_equal [V::PALETTE[0], V::PALETTE[1]], r['legend'].map { |l| l['color'] }
  end

  def test_presentation_keeps_the_fronts_real_and_makes_the_carcass_see_through
    r = V.assign('presentation', cabs)
    front = r['parts'].values.find { |p| p['key'] == 'front' }
    carcass = r['parts'].values.find { |p| p['key'] == 'carcass' }
    assert_equal true, front['real']
    assert_nil front['alpha']
    assert_equal V::CARCASS_ALPHA, carcass['alpha']
    assert_operator carcass['alpha'], :<, 0.5
    legend = r['legend'].to_h { |l| [l['label'], l] }
    assert legend['Fronts (real material)']['real']
    assert_equal V::CARCASS_ALPHA, legend['Carcass (see-through)']['alpha']
  end

  def test_material_mode_uses_the_library_colours_and_marks_parts_as_real
    r = V.assign('material', cabs)
    assert(r['parts'].values.all? { |p| p['real'] })
    mdf = r['legend'].find { |l| l['label'] == '18mm MDF' }
    assert_equal CabinetCraft::Material.find('mdf_18').color, mdf['color']
  end

  def test_an_unknown_mode_is_refused_and_an_empty_project_is_fine
    assert_raises(ArgumentError) { V.assign('sparkly', cabs) }
    r = V.assign('role', [])
    assert_equal [{}, []], [r['parts'], r['legend']]
  end
end
