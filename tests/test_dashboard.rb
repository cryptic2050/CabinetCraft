# frozen_string_literal: true

require_relative 'test_helper'

class TestDashboard < Minitest::Test
  include TestParams
  D = CabinetCraft::Manufacturing::Dashboard

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
  end

  def cab(label, ov = {})
    CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(ov), label: label)
  end

  def nesting(unplaced: 0)
    { 'totals' => { 'total_sheets' => 3, 'utilization' => 61.5, 'unplaced' => unplaced },
      'materials' => [{ 'material' => '18mm MDF', 'total_sheets' => 2, 'utilization' => 70.0, 'unplaced' => Array.new(unplaced) { {} } },
                      { 'material' => '3mm HDF', 'total_sheets' => 1, 'utilization' => 40.0, 'unplaced' => [] }] }
  end

  def cost(over = {})
    { 'enabled' => true, 'currency' => '$', 'materials_total' => 100.0, 'edge_total' => 10.0, 'hardware_total' => 20.0, 'cnc' => { 'cost' => 5.0 }, 'labour' => { 'cost' => 50.0 },
      'installation' => 30.0, 'transport' => 5.0, 'total_cost' => 220.0, 'selling_price' => 293.33, 'profit' => 73.33, 'warnings' => [] }.merge(over)
  end

  def build(over = {})
    cabs = over.delete(:cabinets) || [cab('B01'), cab('B02', 'door_count' => 2)]
    D.build(**{ project: 'P', cabinets: cabs, type_names: { 'base_cabinet' => 'Base cabinet' }, nesting: nesting, cost: cost, issues: [], cnc: { 'errors' => 0, 'warnings' => 0 },
              runs: [], layouts: [], materials: CabinetCraft::Material.all }.merge(over))
  end

  def status(d, id)
    d['checks'].find { |c| c['id'] == id }['status']
  end

  def test_project_block_counts_cabinets_parts_and_types
    d = build
    assert_equal 2, d['project']['cabinets']
    assert_equal 'Base cabinet', d['project']['types'].first['name']
    assert_equal 2, d['project']['types'].first['count']
    assert_equal d['project']['parts'], [cab('B01'), cab('B02', 'door_count' => 2)].sum { |c| c.part_rows.size }
  end

  def test_sheets_block_mirrors_the_nesting_result
    s = build['sheets']
    assert_equal [3, 61.5, 0], [s['total'], s['utilization'], s['unplaced']]
    assert_equal [['18mm MDF', 2, 70.0], ['3mm HDF', 1, 40.0]], s['materials'].map { |m| [m['material'], m['sheets'], m['utilization']] }
  end

  def test_cost_segments_add_up_to_the_total_cost
    c = build['cost']
    assert_equal %w[materials edge hardware cnc labour], c['segments'].map { |s| s['key'] }
    assert_equal [100.0, 10.0, 20.0, 5.0, 85.0], c['segments'].map { |s| s['value'] }
    assert_in_delta cost['total_cost'], c['segments'].sum { |s| s['value'] }, 0.001
  end

  def test_disabled_cost_has_no_segments
    assert_equal({ 'enabled' => false }, build(cost: { 'enabled' => false })['cost'])
  end

  def test_hardware_block_is_sorted_by_quantity_and_limited
    h = build['hardware']
    assert_operator h.size, :<=, 8
    assert_equal h.map { |x| -x['qty'] }, h.map { |x| -x['qty'] }.sort
    assert_equal build(cabinets: [cab('B01')])['hardware'].sum { |x| x['qty'] }, cab('B01').hardware.sum { |x| x['qty'] }
  end

  def price_materials
    %w[mdf_18 hdf_3].each { |id| CabinetCraft::Material.config.save('id' => id, 'price' => 40) }
  end

  def test_all_good_project_is_ready
    price_materials
    d = build
    assert d['ready']
    assert_equal %w[ok], d['checks'].map { |c| c['status'] }.reject { |s| %w[na].include?(s) }.uniq
  end

  def test_errors_block_readiness_and_say_how_many
    issue = ->(sev) { { 'severity' => sev, 'code' => 'x', 'message' => 'm' } }
    d = build(issues: [issue.call('error'), issue.call('error'), issue.call('warning')])
    refute d['ready']
    assert_equal 'error', status(d, 'model')
    assert_equal '2 errors, 1 warning', d['checks'].find { |c| c['id'] == 'model' }['detail']
    assert_equal [2, 1], d['issues'].values_at('errors', 'warnings')
    w = build(issues: [issue.call('warning')])
    assert w['ready'] # warnings do not block
    assert_equal 'warn', status(w, 'model')
  end

  def test_unplaced_parts_and_cnc_errors_are_errors
    assert_equal 'error', status(build(nesting: nesting(unplaced: 2)), 'nesting')
    refute build(nesting: nesting(unplaced: 1))['ready']
    d = build(cnc: { 'errors' => 3, 'warnings' => 0 })
    assert_equal 'error', status(d, 'cnc')
    assert_equal 'warn', status(build(cnc: { 'errors' => 0, 'warnings' => 2 }), 'cnc')
    assert_equal 'na', status(build(cnc: nil), 'cnc')
  end

  def test_unpriced_materials_and_cost_warnings_warn
    d = build(cost: cost('warnings' => ['No price set for x']))
    assert_equal 'warn', status(d, 'prices')
    assert d['ready']
    assert_match(/no price for 18mm MDF/, build['checks'].find { |c| c['id'] == 'prices' }['detail']) # the default library has no prices
    price_materials
    assert_equal 'ok', status(build, 'prices')
    assert_equal 'na', status(build(cost: { 'enabled' => false }), 'prices')
  end

  def test_runs_and_layouts_out_of_sync_warn
    assert_equal 'na', status(build, 'layouts')
    assert_equal 'ok', status(build(runs: [{ 'in_sync' => true }]), 'layouts')
    d = build(runs: [{ 'in_sync' => false }, { 'in_sync' => true }], layouts: [{ 'in_sync' => false }])
    assert_equal 'warn', status(d, 'layouts')
    assert_equal({ 'runs' => 2, 'layouts' => 1, 'out_of_sync' => 2 }, d['layouts'])
  end

  def test_empty_project_is_not_ready
    d = build(cabinets: [], nesting: nil, cnc: nil)
    refute d['ready']
    assert_equal ['empty'], d['checks'].map { |c| c['id'] }
    assert_equal 0, d['project']['cabinets']
    assert_equal [], d['sheets']['materials']
  end

  def test_production_progress_is_information_and_untracked_is_not_applicable
    assert_equal 'na', status(build, 'production')
    prod = { 'stages' => { 'cut' => { 'done' => 3, 'total' => 10 }, 'banded' => { 'done' => 0, 'total' => 2 } }, 'progress' => 12.5, 'complete_parts' => 1, 'parts' => 10 }
    d = build(production: prod)
    assert_equal 'info', status(d, 'production')
    assert_match(/12.5% .* 1 of 10 parts/, d['checks'].find { |c| c['id'] == 'production' }['detail'])
    assert d['ready'] # progress never blocks readiness
    assert_equal prod, d['production']
    zero = build(production: { 'stages' => { 'cut' => { 'done' => 0, 'total' => 5 } }, 'progress' => 0.0, 'complete_parts' => 0, 'parts' => 5 })
    assert_equal 'na', status(zero, 'production')
  end

  def test_overrides_are_information_not_a_problem
    c = cab('B01').with_overrides('bottom' => { 'length' => 590.0 })
    d = build(cabinets: [c])
    assert_equal 'info', status(d, 'overrides')
    assert d['ready']
    assert_equal 1, d['project']['overridden_parts']
  end
end
