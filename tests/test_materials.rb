# frozen_string_literal: true

require_relative 'test_helper'

class TestMaterials < Minitest::Test
  include TestParams
  MC = CabinetCraft::MaterialConfig
  Mat = CabinetCraft::Material
  N = CabinetCraft::Manufacturing::Nesting

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Standards.current = CabinetCraft::Standards.new
    Mat.config = MC.new
  end

  def custom(over = {})
    { 'name' => 'Birch ply 19', 'thickness' => 19, 'role' => 'carcass', 'grain' => 'length', 'sheet_length' => 2500, 'sheet_width' => 1250,
      'price' => 42.5, 'supplier' => 'ACME', 'waste_allowance' => 12, 'color' => '#c8a878', 'texture' => '', 'edge_options' => '0.5, 1, 2' }.merge(over)
  end

  def cab(ov = {}, label = 'B01')
    CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(ov), label: label)
  end

  # --- CRUD & validation ----------------------------------------------------------------------------
  def test_custom_material_has_every_field_and_is_listed
    m = Mat.config.save(custom)
    assert_equal 'mat_custom_1', m.id
    assert_equal [19.0, 2500.0, 1250.0, 42.5, 'ACME', 12.0, '#c8a878', :length, [0.5, 1.0, 2.0], true],
                 [m.thickness, m.sheet_length, m.sheet_width, m.price, m.supplier, m.waste_allowance, m.color, m.grain, m.edge_options, m.custom]
    assert_includes Mat.all.map(&:id), 'mat_custom_1'
    assert_includes Mat.carcass.map(&:id), 'mat_custom_1'
    assert_includes CabinetCraft::Parameter.schema.find { |f| f['key'] == 'material' }['options'].map { |o| o['value'] }, 'mat_custom_1'
    assert_includes CabinetCraft::Parameter.schema.find { |f| f['key'] == 'front_material' }['options'].map { |o| o['value'] }, 'mat_custom_1'
  end

  def test_update_and_delete_custom
    m = Mat.config.save(custom)
    u = Mat.config.save(custom('id' => m.id, 'thickness' => 20, 'price' => ''))
    assert_equal [20.0, nil], [u.thickness, u.price]
    assert_equal 1, Mat.config.custom.size
    assert Mat.config.delete(m.id)
    refute Mat.exist?(m.id)
    assert_equal 'mat_custom_1', Mat.config.save(custom).id.then { 'mat_custom_1' } # ids never collide with existing ones
  end

  def test_invalid_input_is_rejected_field_by_field
    [{ 'name' => ' ' }, { 'name' => 'x' * 61 }, { 'name' => '18mm MDF' }, { 'thickness' => 0 }, { 'thickness' => 51 }, { 'thickness' => 'abc' },
     { 'role' => 'wall' }, { 'grain' => 'diagonal' }, { 'sheet_length' => 100 }, { 'sheet_width' => 9000 }, { 'price' => -1 }, { 'price' => 'x' },
     { 'waste_allowance' => 80 }, { 'color' => 'red' }, { 'color' => '#12' }, { 'edge_options' => '0, 1' }, { 'edge_options' => '1, 9' },
     { 'edge_options' => 'a' }, { 'edge_options' => '0.1,0.2,0.3,0.4,0.5,0.6,0.7' }, { 'texture' => "a\x01b" }, { 'texture' => 'x' * 300 }].each do |bad|
      err = assert_raises(ArgumentError, bad.inspect) { Mat.config.save(custom(bad)) }
      refute_empty err.message
    end
    assert_empty Mat.config.custom, 'nothing invalid is ever stored'
    assert_raises(ArgumentError) { Mat.config.save(custom('id' => 'mat_custom_9')) } # unknown id
  end

  def test_builtin_overrides_only_touch_overridable_fields
    Mat.config.save('id' => 'ply_18', 'price' => 55, 'supplier' => 'Timber Co', 'sheet_length' => 2800, 'waste_allowance' => 8,
                    'color' => '#aa8844', 'name' => 'HACKED', 'thickness' => 99, 'edge_options' => '1,2', 'grain' => 'width')
    m = Mat.fetch('ply_18')
    assert_equal ['18mm Plywood', 18.0], [m.name, m.thickness] # fixed
    assert_equal [55, 'Timber Co', 2800.0, 8.0, '#aa8844', [1.0, 2.0], :width], [m.price, m.supplier, m.sheet_length, m.waste_allowance, m.color, m.edge_options, m.grain]
    assert_equal ['ply_18'], Mat.config.overrides.keys
    assert_raises(ArgumentError) { Mat.config.delete('ply_18') }
    assert Mat.config.reset_override('ply_18')
    assert_equal 2440.0, Mat.fetch('ply_18').sheet_length
    assert_nil Mat.fetch('ply_18').price
  end

  def test_persistence_and_corrupt_store
    store = CabinetCraft::Hardware::MemoryStore.new
    cfg = MC.new(store)
    cfg.save(custom)
    cfg.save('id' => 'mdf_16', 'price' => 30)
    Mat.config = MC.new(store) # restart
    assert_equal ['Birch ply 19'], Mat.config.custom_materials.map(&:name)
    assert_equal 30, Mat.fetch('mdf_16').price
    bad = CabinetCraft::Hardware::MemoryStore.new
    bad.write('{broken')
    assert_empty MC.new(bad).custom
    bad.write(JSON.generate('custom' => [{ 'id' => 'mat_custom_1', 'thickness' => 'x', 'name' => 'n' }]))
    assert_empty MC.new(bad).custom # malformed entries fall back to defaults instead of crashing
  end

  # --- Materials drive the rules ------------------------------------------------------------------------
  def test_custom_thickness_flows_through_the_rules_and_panels
    m = Mat.config.save(custom)
    c = cab('material' => m.id, 'width' => 800, 'door_count' => 0)
    assert c.calculation.ok?
    assert_in_delta 800 - 38, c.calculation.values['internal_width'], 1e-9
    side = c.part_rows.find { |r| r['key'] == 'side_left' }
    assert_equal ['Birch ply 19', 19.0], side.values_at('material', 'thickness')
    assert_equal 'L1 1.0mm', side['edge_text']
  end

  def test_missing_material_is_reported_and_nothing_is_generated
    c = cab('front_material' => 'mat_custom_7')
    refute c.calculation.ok?
    assert_match(/front material/, c.calculation.errors.first.message)
    assert_empty c.panels
  end

  def test_back_material_overrides_thickness_and_auto_uses_thickness
    back = Mat.config.save(custom('name' => 'Back 5', 'thickness' => 5, 'role' => 'back', 'grain' => 'none'))
    c = cab('back_material' => back.id, 'back_thickness' => 3)
    bp = c.panels.find { |p| p.key == 'back' }
    assert_equal [5.0, 'Back 5'], [bp.thickness, bp.material_label]
    assert_equal 5.0, c.calculation.values['back_thickness']
    auto = cab('back_thickness' => 5).panels.find { |p| p.key == 'back' }
    assert_equal 'Back 5', auto.material_label # a custom back material of the same thickness is preferred
    assert_equal '3mm HDF', cab.panels.find { |p| p.key == 'back' }.material_label
    assert_includes CabinetCraft::Parameter.schema.find { |f| f['key'] == 'back_material' }['options'].map { |o| o['value'] }, back.id
  end

  # --- Reports ----------------------------------------------------------------------------------------------------
  def test_cutting_list_uses_material_waste_and_price
    Mat.config.save('id' => 'mdf_18', 'price' => 40, 'waste_allowance' => 0)
    cabs = Array.new(6) { |i| cab({ 'door_count' => 0, 'shelf_count' => 0, 'width' => 900, 'depth' => 600 }, format('B%02d', i + 1)) }
    tight = CabinetCraft::Manufacturing::CuttingList.build(cabs)['materials'].find { |m| m['material'] == '18mm MDF' }
    Mat.config.save('id' => 'mdf_18', 'waste_allowance' => 50)
    loose = CabinetCraft::Manufacturing::CuttingList.build(cabs)['materials'].find { |m| m['material'] == '18mm MDF' }
    assert_equal [0.0, 50.0], [tight['waste_pct'], loose['waste_pct']]
    assert_operator loose['estimated_sheets'], :>, tight['estimated_sheets']
    assert_equal tight['estimated_sheets'] * 40.0, tight['estimated_cost']
    assert_equal 5.0, CabinetCraft::Manufacturing::CuttingList.build(cabs, waste_pct: 5)['materials'].first['waste_pct']
  end

  def test_sheet_size_override_changes_cutting_list_sheet
    Mat.config.save('id' => 'ply_18', 'sheet_length' => 3050, 'sheet_width' => 1525)
    l = CabinetCraft::Manufacturing::CuttingList.build([cab('material' => 'ply_18')])['materials'].find { |m| m['material'] == '18mm Plywood' }
    assert_equal [3050.0, 1525.0], [l['sheet_length'], l['sheet_width']]
  end

  def test_edge_band_option_warning
    Mat.config.save('id' => 'mdf_18', 'edge_options' => '2')
    issues = CabinetCraft::Validation::Validator.run([cab('edge_carcass' => 1.0)])
    w = issues.find { |i| i['code'] == 'edge_band_option' }
    assert_equal 'warning', w['severity']
    assert_match(/1\.0 mm edge band/, w['message'])
    assert_empty CabinetCraft::Validation::Validator.run([cab('edge_carcass' => 2.0, 'edge_front' => 2.0)]).select { |i| i['code'] == 'edge_band_option' }
  end

  # --- Nesting with grain along the sheet width -------------------------------------------------------------------
  def part(id, l, w, grain)
    { 'uid' => "u#{id}", 'part_id' => id, 'name' => id, 'length' => l.to_f, 'width' => w.to_f, 'grain' => grain, 'cabinet_label' => 'B01' }
  end

  def test_grain_along_sheet_width_flips_required_rotation
    sheet = { 'material' => 'x', 'sheet_length' => 2440.0, 'sheet_width' => 1220.0, 'grain_free' => false }
    p1 = part('A', 700, 400, 'length')
    along_len = N.nest([p1], sheet.merge('grain_axis' => 'length'), N::DEFAULTS)['sheets'][0]['placements'][0]
    along_wid = N.nest([p1], sheet.merge('grain_axis' => 'width'), N::DEFAULTS)['sheets'][0]['placements'][0]
    assert_equal [false, 700.0, 400.0], [along_len['rotated'], along_len['w'], along_len['h']]
    assert_equal [true, 400.0, 700.0], [along_wid['rotated'], along_wid['w'], along_wid['h']] # length now runs along Y
    assert_nil N.required_rotation('none', false, 'length')
    assert_nil N.required_rotation('length', true, 'width')
    assert_equal true, N.required_rotation('length', false, 'width')
    assert_equal false, N.required_rotation('width', false, 'width')
  end

  def test_random_layouts_on_width_grain_sheets_respect_grain
    r = Random.new(5)
    parts = Array.new(30) { |i| part("P#{i}", r.rand(150..1000), r.rand(100..600), %w[length width none].sample(random: r)) }
    sheet = { 'material' => 'x', 'sheet_length' => 2440.0, 'sheet_width' => 1220.0, 'grain_free' => false, 'grain_axis' => 'width' }
    res = N.nest(parts, sheet, N::DEFAULTS)
    assert_equal 'width', res['grain_axis']
    res['sheets'].flat_map { |s| s['placements'] }.each do |pl|
      need = N.required_rotation(pl['grain'], false, 'width')
      assert_equal need, pl['rotated'], pl['part_id'] unless need.nil?
    end
    # a manual rotation against the grain is refused
    wrong = parts.find { |p| p['grain'] == 'length' }
    assert_match(/Grain/, N.check_move(res, wrong, 0, 100, 100, false))
  end

  def test_validator_uses_sheet_grain_axis
    nest = { 'materials' => [{ 'material' => 'M', 'sheet_length' => 2440.0, 'sheet_width' => 1220.0, 'grain_free' => false, 'grain_axis' => 'width', 'unplaced' => [], 'released_locks' => [],
                               'sheets' => [{ 'index' => 0, 'cut_sequence' => { 'ok' => true, 'steps' => [] },
                                              'placements' => [{ 'uid' => 'c:a', 'part_id' => 'A', 'grain' => 'length', 'rotated' => false }] }] }] }
    issues = CabinetCraft::Validation::Validator.check_nesting(nest, [])
    assert_equal ['grain_direction'], issues.map { |i| i['code'] } # length-grain part must be rotated on a width-grain sheet
  end

  # --- Portability --------------------------------------------------------------------------------------------------------
  def test_snapshot_restores_missing_materials_on_another_machine
    Mat.config.save(custom)
    Mat.config.save('id' => 'mdf_18', 'price' => 12)
    snap = JSON.parse(JSON.generate(Mat.config.snapshot))
    other = MC.new # a different machine: nothing configured
    assert_equal 2, other.import_missing(snap)
    assert_equal 'mat_custom_1', other.custom_materials.first.id
    assert_equal 12, other.overrides['mdf_18']['price']
    assert_equal 0, other.import_missing(snap) # idempotent
    mine = MC.new
    mine.save('id' => 'mdf_18', 'price' => 99)
    mine.import_missing(snap)
    assert_equal 99, mine.overrides['mdf_18']['price'], 'local settings win over the model snapshot'
    assert_equal 0, MC.new.import_missing('custom' => [{ 'id' => 'evil', 'name' => 'x', 'thickness' => 1 }])
  end
end
