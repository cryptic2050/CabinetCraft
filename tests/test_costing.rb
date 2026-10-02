# frozen_string_literal: true

require_relative 'test_helper'

class TestCosting < Minitest::Test
  include TestParams
  C = CabinetCraft::Manufacturing::Costing

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
  end

  def cab(ov = {}, label = 'B01')
    CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(ov), label: label)
  end

  def settings(over = {})
    C.normalize(over)
  end

  # A tiny fake nesting result: `sheets` placed sheets per material name.
  def nest(sheets_by_material)
    { 'materials' => sheets_by_material.map { |name, n| { 'material' => name, 'total_sheets' => n, 'sheets' => Array.new(n) { { 'placements' => [1] } } } } }
  end

  def estimate(cabs, over = {}, sheets = {}, ops = [])
    C.estimate(cabs, nest(sheets), ops, settings(over))
  end

  # --- settings ---------------------------------------------------------------------------------------------
  def test_defaults_and_validation
    s = settings
    assert_equal [true, 25.0, 'nesting', '$'], s.values_at('enabled', 'margin_pct', 'material_basis', 'currency')
    [{ 'margin_pct' => 99 }, { 'margin_pct' => -1 }, { 'waste_pct' => 150 }, { 'labour_rate' => -5 }, { 'material_basis' => 'guess' }, { 'currency' => '' },
     { 'currency' => 'dollars' }, { 'transport' => 'abc' }, { 'edge_prices' => { '1' => -2 } }, { 'edge_prices' => 'x' }].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { settings(bad) }
    end
    assert_equal 1.5, settings('edge_prices' => { '1' => '1.5' })['edge_prices']['1.0']
    assert_equal false, settings('enabled' => false)['enabled']
  end

  def test_disabled_costing_computes_nothing
    assert_equal({ 'enabled' => false }, estimate([cab], 'enabled' => false))
  end

  # --- hand-computed numbers ------------------------------------------------------------------------------------
  def test_material_cost_uses_nested_sheets_or_area
    CabinetCraft::Material.config.save('id' => 'mdf_18', 'price' => 40)
    CabinetCraft::Material.config.save('id' => 'hdf_3', 'price' => 10)
    c = cab('door_count' => 0, 'shelf_count' => 0)
    e = estimate([c], {}, { '18mm MDF' => 2, '3mm HDF' => 1 })
    mdf = e['materials'].find { |m| m['material'] == '18mm MDF' }
    assert_equal [2, 80.0, 'nested sheets'], [mdf['sheets'], mdf['cost'], mdf['basis']]
    assert_equal 10.0, e['materials'].find { |m| m['material'] == '3mm HDF' }['cost']
    assert_equal 90.0, e['materials_total']
    area = estimate([c], { 'material_basis' => 'area', 'waste_pct' => 0 }, {})
    assert_equal 'area + 0.0% waste', area['materials'].first['basis']
    assert_equal 1, area['materials'].find { |m| m['material'] == '18mm MDF' }['sheets'] # tiny cabinet fits one sheet by area
  end

  def test_edge_banding_cost_per_thickness_with_waste
    # door_count 1 on a 720 cabinet: door 717 x 597 banded 2 mm on all four sides = 2.628 m; sides/bottom/shelf 1 mm
    c = cab({ 'height' => 720, 'door_count' => 1, 'shelf_count' => 0 })
    e = estimate([c], { 'edge_prices' => { '1' => 2.0, '2' => 3.0 }, 'edge_waste_pct' => 10 })
    two = e['edge_banding'].find { |l| l['thickness'] == 2.0 }
    one = e['edge_banding'].find { |l| l['thickness'] == 1.0 }
    assert_in_delta 2.628, two['metres'], 0.006 # reported to 2 decimals
    assert_in_delta 2.628 * 1.1, two['metres_with_waste'], 0.011
    assert_in_delta (2.628 * 1.1 * 3.0).round(2), two['cost'], 0.011
    assert_in_delta ((702 * 2 + 600) / 1000.0), one['metres'], 0.006
    assert_in_delta two['cost'] + one['cost'], e['edge_total'], 0.011
  end

  def test_hardware_cost_uses_unit_prices
    CabinetCraft::Hardware.config.set_price('hinge_standard', 3.5)
    CabinetCraft::Hardware.config.set_price('cam_lock', 0.4)
    CabinetCraft::Hardware.config.set_price('cam_bolt', 0.1)
    c = cab({ 'height' => 720, 'door_count' => 1, 'shelf_count' => 0 })
    e = estimate([c])
    hinge = e['hardware'].find { |h| h['hardware_id'] == 'hinge_standard' }
    assert_equal [2, 3.5, 7.0], [hinge['qty'], hinge['unit_price'], hinge['cost']]
    cams = e['hardware'].find { |h| h['hardware_id'] == 'cam_lock' }
    assert_in_delta cams['qty'] * 0.4, cams['cost'], 0.011
  end

  def test_cnc_and_labour
    ops = Array.new(10) { { 'target' => 'face', 'cabinet_id' => 'x' } } + Array.new(5) { { 'target' => 'edge', 'cabinet_id' => 'x' } }
    c = cab({ 'door_count' => 0 })
    e = estimate([c], { 'cnc_per_sheet' => 20, 'cnc_per_hole' => 0.5, 'labour_rate' => 30, 'labour_hours_per_cabinet' => 2, 'labour_minutes_per_part' => 3 },
                 { '18mm MDF' => 2, '3mm HDF' => 1 }, ops)
    assert_equal [3, 10], e['cnc'].values_at('sheets', 'holes') # only face holes are router work
    assert_equal 3 * 20 + 10 * 0.5, e['cnc']['cost']
    parts = c.part_rows.size
    hours = 2 + parts * 3 / 60.0
    assert_in_delta hours, e['labour']['hours'], 0.01
    assert_in_delta (hours * 30).round(2), e['labour']['cost'], 0.011
  end

  def test_totals_margin_and_selling_price
    CabinetCraft::Material.config.save('id' => 'mdf_18', 'price' => 50)
    c = cab({ 'door_count' => 0, 'shelf_count' => 0 })
    e = estimate([c], { 'margin_pct' => 20, 'transport' => 40, 'installation_per_cabinet' => 60 }, { '18mm MDF' => 1 })
    assert_equal 40.0, e['transport']
    assert_equal 60.0, e['installation']
    assert_in_delta e['manufacturing_cost'] + 100.0, e['total_cost'], 0.011
    assert_in_delta (e['total_cost'] / 0.8).round(2), e['selling_price'], 0.011 # margin is a share of the SELLING price
    assert_in_delta e['selling_price'] * 0.2, e['profit'], 0.02
    assert_in_delta e['selling_price'] - e['total_cost'], e['profit'], 0.011
  end

  def test_unpriced_items_are_warned_about_not_silently_free
    e = estimate([cab({ 'door_count' => 1 })], {}, { '18mm MDF' => 1 })
    msgs = e['warnings'].join("\n")
    assert_match(/No price set for 18mm MDF/, msgs)
    assert_match(/No price set for hardware/, msgs)
    assert_match(/No edge banding price for 1\.0 mm/, msgs)
    priced = estimate([cab({ 'door_count' => 1 })], { 'edge_prices' => { 'default' => 1.0 } }, {})
    refute_match(/edge banding price/, priced['warnings'].join)
  end

  # --- allocation --------------------------------------------------------------------------------------------------------
  def test_per_cabinet_figures_add_up_exactly_to_the_totals
    CabinetCraft::Material.config.save('id' => 'mdf_18', 'price' => 47.35)
    CabinetCraft::Material.config.save('id' => 'ply_18', 'price' => 91.1)
    CabinetCraft::Hardware.config.set_price('hinge_soft_close', 4.37)
    CabinetCraft::Hardware.config.set_price('cam_lock', 0.33)
    cabs = [cab({ 'width' => 600, 'door_count' => 1 }, 'B01'), cab({ 'width' => 800, 'material' => 'ply_18', 'hinge_type' => 'hinge_soft_close', 'door_count' => 2 }, 'B02'),
            cab({ 'width' => 450, 'door_count' => 0, 'drawer_count' => 3, 'height' => 820, 'toe_kick_height' => 100, 'shelf_count' => 0 }, 'B03')]
    over = { 'edge_prices' => { 'default' => 1.37, '1' => 1.1 }, 'cnc_per_sheet' => 17.77, 'cnc_per_hole' => 0.113, 'labour_rate' => 31.3, 'labour_hours_per_cabinet' => 1.7,
             'labour_minutes_per_part' => 2.9, 'transport' => 123.45, 'installation_per_cabinet' => 77.77, 'margin_pct' => 27.5 }
    ops = cabs.flat_map { |c| CabinetCraft::Manufacturing::Machining.operations(c)['ops'] }
    e = estimate(cabs, over, { '18mm MDF' => 3, '18mm Plywood' => 2, '3mm HDF' => 1, '16mm MDF' => 1 }, ops)
    pc = e['per_cabinet']
    assert_equal 3, pc.size
    { 'material' => 'materials_total', 'edge_banding' => 'edge_total', 'hardware' => 'hardware_total' }.each do |k, total|
      assert_in_delta e[total], pc.sum { |x| x[k] }, 0.0001, k
    end
    assert_in_delta e['cnc']['cost'], pc.sum { |x| x['cnc'] }, 0.0001
    assert_in_delta e['labour']['cost'], pc.sum { |x| x['labour'] }, 0.0001
    assert_in_delta e['installation'], pc.sum { |x| x['installation'] }, 0.0001
    assert_in_delta e['transport'], pc.sum { |x| x['transport'] }, 0.0001
    assert_in_delta e['total_cost'], pc.sum { |x| x['cost'] }, 0.0001
    assert_in_delta e['selling_price'], pc.sum { |x| x['price'] }, 0.0001
    pc.each { |x| assert_in_delta x['cost'] / (1 - 0.275), x['price'], 0.02 }
    assert_operator pc[1]['material'], :>, pc[0]['material'] # wider plywood cabinet costs more material
  end

  def test_installation_is_per_cabinet_and_transport_follows_volume
    big = cab({ 'width' => 1200, 'depth' => 600 }, 'B01')
    small = cab({ 'width' => 400, 'depth' => 300 }, 'B02')
    e = estimate([big, small], { 'installation_per_cabinet' => 50, 'transport' => 100 })
    assert_equal [50.0, 50.0], e['per_cabinet'].map { |x| x['installation'] }
    v1 = 1200.0 * 757 * 600
    v2 = 400.0 * 757 * 300
    assert_in_delta 100 * v1 / (v1 + v2), e['per_cabinet'][0]['transport'], 0.011
  end

  def test_empty_project
    e = C.estimate([], nil, [], settings)
    assert_equal [0.0, 0.0, []], [e['total_cost'], e['selling_price'], e['per_cabinet']]
  end

  def test_custom_template_cabinets_are_costed_too
    t = CabinetCraft::Templates.config.save_template(CabinetCraft::Templates::Examples::OPEN_SHELF_UNIT)
    c = CabinetCraft::Cabinet.build(type: t.id, params: params_for(t), label: 'B01')
    CabinetCraft::Hardware.config.set_price('dowel', 0.2)
    e = estimate([c], { 'edge_prices' => { 'default' => 1.0 } }, { '18mm MDF' => 1, '3mm HDF' => 1 })
    assert_operator e['hardware_total'], :>, 0
    assert_equal ['B01'], e['per_cabinet'].map { |x| x['label'] }
    assert_in_delta e['total_cost'], e['per_cabinet'].sum { |x| x['cost'] }, 0.0001
  end

  def params_for(t)
    p, = CabinetCraft::Parameter.coerce(t.defaults, t.schema)
    p
  end

  # --- hardware prices -----------------------------------------------------------------------------------------------------------
  def test_hardware_price_overrides_persist_and_validate
    store = CabinetCraft::Hardware::MemoryStore.new
    cfg = CabinetCraft::Hardware::Config.new(store)
    cfg.set_price('hinge_standard', '2.75')
    cfg.add_custom(name: 'X', category: 'handle', price: 9)
    cfg.set_price('custom_1', 12)
    again = CabinetCraft::Hardware::Config.new(store)
    assert_equal [2.75, 12.0], [again.price_of('hinge_standard'), again.price_of('custom_1')]
    again.set_price('hinge_standard', '')
    assert_nil again.price_of('hinge_standard')
    [-1, 'abc', 2_000_000].each { |bad| assert_raises(ArgumentError) { again.set_price('dowel', bad) } }
    assert_raises(ArgumentError) { again.set_price('nope', 1) }
    assert_equal 9, CabinetCraft::Hardware::Config.new.then { |c| c.add_custom(name: 'Y', category: 'handle', price: 9); c.price_of('custom_1') }
  end
end
