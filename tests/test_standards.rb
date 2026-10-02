# frozen_string_literal: true

require_relative 'test_helper'

class TestStandards < Minitest::Test
  include TestParams
  S = CabinetCraft::Standards

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
    S.current = S.new
  end

  def defaults(type = 'base_cabinet')
    CabinetCraft::Library.defaults_for(type)
  end

  # --- saving and validation --------------------------------------------------------------------------------
  def test_standards_cover_manufacturing_choices_only
    refute_includes S::ALLOWED, 'width'
    refute_includes S::ALLOWED, 'door_count'
    refute_includes S::ALLOWED, 'shelf_count'
    assert_equal S::ALLOWED.sort, S.fields.map { |f| f['key'] }.sort
    %w[material front_material door_reveal door_gap toe_kick_height edge_carcass edge_front construction connector_type hinge_type runner_type].each { |k| assert_includes S::ALLOWED, k }
  end

  def test_save_stores_only_the_chosen_keys_and_coerces
    S.current.save(name: ' Acme Joinery ', values: { 'material' => 'ply_18', 'door_reveal' => '2', 'edge_carcass' => 0.4, 'hinge_type' => 'hinge_soft_close' })
    assert_equal 'Acme Joinery', S.current.name
    assert_equal({ 'material' => 'ply_18', 'door_reveal' => 2.0, 'edge_carcass' => 0.4, 'hinge_type' => 'hinge_soft_close' }, S.current.values)
  end

  def test_invalid_standards_are_rejected_with_every_problem_and_nothing_is_saved
    err = assert_raises(ArgumentError) { S.current.save(name: 'x', values: { 'door_reveal' => 99, 'edge_front' => 'abc', 'construction' => 'nope' }) }
    assert_match(/Outer reveal/, err.message)
    assert_match(/Door \/ drawer front band/, err.message)
    assert_match(/Construction/, err.message)
    assert_empty S.current.values
    assert_raises(ArgumentError) { S.current.save(name: 'x', values: { 'width' => 800 }) } # a design choice, not a standard
    assert_raises(ArgumentError) { S.current.save(name: 'x' * 61, values: {}) }
    err = assert_raises(ArgumentError) { S.current.save(name: 'x', values: { 'brace_depth' => 300 }) } # rails would be deeper than the cabinet
    assert_match(/invalid default cabinet/, err.message)
  end

  def test_unknown_materials_and_hardware_are_rejected_by_the_rules_not_stored
    assert_raises(ArgumentError) { S.current.save(name: 'x', values: { 'material' => 'unobtainium' }) }
    assert_empty S.current.values
  end

  # --- precedence ---------------------------------------------------------------------------------------------------
  def test_new_cabinets_start_from_the_standards
    S.current.save(name: 'Acme', values: { 'material' => 'ply_18', 'front_material' => 'ply_18', 'door_reveal' => 2.0, 'door_gap' => 4.0, 'edge_front' => 0.4,
                                           'connector_type' => 'confirmat', 'hinge_type' => 'hinge_soft_close', 'runner_type' => 'runner_soft_close', 'back_thickness' => 6.0 })
    d = defaults
    assert_equal ['ply_18', 'ply_18', 2.0, 4.0, 0.4, 'confirmat', 'hinge_soft_close', 'runner_soft_close', 6.0],
                 d.values_at('material', 'front_material', 'door_reveal', 'door_gap', 'edge_front', 'connector_type', 'hinge_type', 'runner_type', 'back_thickness')
    cab = CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(d), label: 'B01')
    assert cab.calculation.ok?
    assert_equal ['18mm Plywood', 'L1 1.0mm'], cab.part_rows.find { |r| r['key'] == 'side_left' }.values_at('material', 'edge_text')
    assert_equal '6mm MDF', cab.part_rows.find { |r| r['key'] == 'back' }['material']
  end

  def test_standards_never_touch_design_choices_of_presets
    S.current.save(name: 'Acme', values: { 'door_reveal' => 2.0 })
    d = defaults('base_drawer_3')
    assert_equal [0, 3], d.values_at('door_count', 'drawer_count') # preset structure is unchanged
    assert_equal 600.0, d['width']
  end

  def test_toe_kick_standard_adjusts_preset_overall_height
    assert_equal [100.0, 820.0], defaults('base_single_door').values_at('toe_kick_height', 'height') # factory: 720 + 100
    S.current.save(name: 'Acme', values: { 'toe_kick_height' => 150.0 })
    d = defaults('base_single_door')
    assert_equal [150.0, 870.0], d.values_at('toe_kick_height', 'height') # carcass stays 720
    assert_equal 720.0, CabinetCraft::Cabinet.build(type: 'base_single_door', params: params(d), label: 'B01').calculation.values['carcass_height']
    assert_equal 757.0, defaults('base_cabinet')['height'] # the general cabinet keeps its explicit size
  end

  def test_a_saved_preset_keeps_exactly_what_was_saved
    preset = CabinetCraft::Templates.config.save_preset(name: 'My base', category: 'X', description: '', base_type: 'base_cabinet',
                                                        params: params('door_reveal' => 3.0, 'edge_front' => 1.0, 'toe_kick_height' => 80.0, 'height' => 800))
    S.current.save(name: 'Acme', values: { 'door_reveal' => 2.0, 'edge_front' => 0.4, 'toe_kick_height' => 150.0 })
    d = defaults(preset['id'])
    assert_equal [3.0, 1.0, 80.0, 800.0], d.values_at('door_reveal', 'edge_front', 'toe_kick_height', 'height') # explicit user choice wins
  end

  def test_templates_are_unaffected
    id = CabinetCraft::Templates.config.save_template(CabinetCraft::Templates::Examples::OPEN_SHELF_UNIT).id
    before = CabinetCraft::Library.defaults_for(id)
    S.current.save(name: 'Acme', values: { 'material' => 'ply_18' })
    assert_equal before, CabinetCraft::Library.defaults_for(id)
  end

  def test_existing_cabinets_are_not_changed
    cab = CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(defaults), label: 'B01')
    before = cab.params.dup
    S.current.save(name: 'Acme', values: { 'material' => 'ply_18' })
    assert_equal before, cab.params
    assert_equal 'mdf_18', CabinetCraft::Cabinet.from_attributes(cab.to_attributes).params['material']
  end

  # --- persistence ----------------------------------------------------------------------------------------------------------
  def test_persistence_reset_and_corrupt_store
    store = CabinetCraft::Hardware::MemoryStore.new
    s = S.new(store)
    s.save(name: 'Acme', values: { 'door_gap' => 4.0 })
    again = S.new(store)
    assert_equal ['Acme', { 'door_gap' => 4.0 }], [again.name, again.values]
    again.reset
    assert_empty S.new(store).values
    store.write('{broken')
    assert_empty S.new(store).values
    store.write(JSON.generate('name' => 'x', 'values' => { 'door_gap' => 99, 'width' => 5 })) # out-of-range or disallowed: ignored entirely
    assert_empty S.new(store).values
  end
end
