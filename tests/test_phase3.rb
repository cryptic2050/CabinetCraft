# frozen_string_literal: true

require_relative 'test_helper'

class TestPhase3 < Minitest::Test
  include TestParams
  H = CabinetCraft::Hardware
  HR = CabinetCraft::HardwareRules

  def setup
    H.config = H::Config.new # fresh defaults per test
  end

  def cab(ov = {}, label = 'B01')
    CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(ov), label: label)
  end

  def part(c, key)
    c.panels.find { |p| p.key == key }
  end

  # --- Edge banding ------------------------------------------------------------------
  def test_carcass_side_has_front_edge_only
    s = part(cab, 'side_left')
    assert_equal({ front: 1.0 }, s.edges)
    # side: length axis z (vertical), width axis y (depth): front is the min of the width axis -> L1
    assert_equal({ 'L1' => 1.0 }, s.edge_codes)
  end

  def test_door_has_all_four_edges_2mm
    d = part(cab('door_count' => 1, 'height' => 720), 'door_1')
    assert_equal %i[bottom left right top], d.edges.keys.sort
    assert_equal [2.0], d.edges.values.uniq
    assert_equal({ 'L1' => 2.0, 'L2' => 2.0, 'W1' => 2.0, 'W2' => 2.0 }, d.edge_codes)
    # 597 x 717 door: 2 * 717 + 2 * 597 = 2628 mm of 2mm band
    assert_in_delta 2628, d.edge_lengths[2.0], 1e-6
  end

  def test_edge_params_change_and_zero_disables
    c = cab('edge_carcass' => 0.4, 'edge_front' => 0)
    assert_equal({ front: 0.4 }, part(c, 'side_left').edges)
    assert_empty part(c, 'door_1').edges
    assert_equal '-', part(c, 'door_1').edge_text
  end

  def test_hidden_parts_are_not_banded
    c = cab('shelf_count' => 1)
    %w[back brace_front brace_rear].each { |k| assert_empty part(c, k).edges, k }
    assert_equal({ front: 1.0 }, part(c, 'shelf_1').edges)
  end

  def test_edge_on_thickness_face_is_rejected
    p = part(cab, 'bottom')
    assert_raises(ArgumentError) { p.with_edges(top: 1.0) } # bottom's thickness axis is z
  end

  # --- Hinge rules ---------------------------------------------------------------------
  def test_default_hinge_count_by_door_height
    cfg = H.config
    assert_equal 2, cfg.hinge_count(600)
    assert_equal 3, cfg.hinge_count(900)
    assert_equal 4, cfg.hinge_count(1200)
    assert_equal 2, cfg.hinge_count(899.9)
    assert_equal 4, cfg.hinge_count(2000)
  end

  def test_hinge_quantity_updates_when_door_height_changes
    low = cab('height' => 720, 'door_count' => 1)
    tall = cab('height' => 2100, 'door_count' => 1, 'depth' => 600, 'shelf_count' => 3)
    assert_equal 2, low.hardware.find { |h| h['hardware_id'] == 'hinge_standard' }['qty']
    assert_equal 4, tall.hardware.find { |h| h['hardware_id'] == 'hinge_standard' }['qty'] # door 2097
  end

  def test_hinge_positions
    assert_equal [100.0, 617.0], HR.hinge_positions(717, 2, 100)
    assert_equal [100.0, 500.0, 900.0], HR.hinge_positions(1000, 3, 100)
    assert_equal [50.0], HR.hinge_positions(100, 1, 100).then { |x| [x.first / 1.0] }
    assert_equal [25.0, 75.0], HR.hinge_positions(100, 2, 100) # inset capped at height/4
  end

  def test_custom_hinge_rules_are_used
    H.config.hinge_rules = [{ 'min_height' => 0, 'count' => 3 }, { 'min_height' => 700, 'count' => 5 }]
    assert_equal 5, cab('door_count' => 1, 'height' => 757).hardware.find { |h| h['hardware_id'] == 'hinge_standard' }['qty']
  end

  def test_invalid_hinge_rules_rejected
    [[], [{ 'min_height' => 100, 'count' => 2 }],
     [{ 'min_height' => 0, 'count' => 2 }, { 'min_height' => 0, 'count' => 3 }],
     [{ 'min_height' => 0, 'count' => 0 }]].each do |rows|
      assert_raises(ArgumentError, rows.inspect) { H.config.hinge_rules = rows }
    end
    assert_equal 2, H.config.hinge_count(600) # unchanged
  end

  def test_hinge_sides
    assert_equal %w[left right], 2.times.map { |i| HR.hinge_side(i, 2, 'left') }
    assert_equal 'right', HR.hinge_side(0, 1, 'right')
  end

  # --- Other hardware -------------------------------------------------------------------
  def test_handles_follow_doors_and_drawers
    c = cab('door_count' => 2, 'drawer_count' => 1, 'handle_type' => 'handle_bar', 'width' => 800)
    assert_equal 3, c.hardware.select { |h| h['hardware_id'] == 'handle_bar' }.sum { |h| h['qty'] }
    assert_empty cab('door_count' => 2).hardware.select { |h| h['hardware_id'] == 'handle_bar' }
  end

  def test_runner_per_drawer_with_box_depth
    c = cab('door_count' => 0, 'drawer_count' => 3, 'shelf_count' => 0, 'runner_type' => 'runner_soft_close')
    r = c.hardware.select { |h| h['hardware_id'] == 'runner_soft_close' }
    assert_equal 3, r.size
    assert(r.all? { |h| h['detail'].include?('500') })
  end

  def test_connectors_scale_with_joint_length_and_cam_needs_a_bolt
    c = cab('shelf_count' => 0, 'door_count' => 0)
    cams = c.hardware.select { |h| h['hardware_id'] == 'cam_lock' }.sum { |h| h['qty'] }
    bolts = c.hardware.select { |h| h['hardware_id'] == 'cam_bolt' }.sum { |h| h['qty'] }
    assert_operator cams, :>=, 10
    assert_equal cams, bolts
    deep = cab('depth' => 800, 'shelf_count' => 0, 'door_count' => 0)
    assert_operator deep.hardware.select { |h| h['hardware_id'] == 'cam_lock' }.sum { |h| h['qty'] }, :>, cams
    conf = cab('connector_type' => 'confirmat').hardware
    assert(conf.none? { |h| %w[dowel cam_bolt].include?(h['hardware_id']) })
    refute_includes CabinetCraft::Parameter.schema.find { |f| f['key'] == 'connector_type' }['options'].map { |o| o['value'] }, 'cam_bolt'
  end

  def test_shelf_pins_four_per_shelf
    c = cab('shelf_count' => 2)
    assert_equal 8, c.hardware.select { |h| h['hardware_id'] == 'shelf_pin' }.sum { |h| h['qty'] }
    assert_empty cab('shelf_count' => 0).hardware.select { |h| h['hardware_id'] == 'shelf_pin' }
  end

  def test_feet_only_with_toe_kick
    assert_empty cab('foot_type' => 'adjustable_foot').hardware.select { |h| h['hardware_id'] == 'adjustable_foot' }
    f = cab('foot_type' => 'adjustable_foot', 'toe_kick_height' => 100, 'height' => 820).hardware
    assert_equal 4, f.find { |h| h['hardware_id'] == 'adjustable_foot' }['qty']
    wide = cab('foot_type' => 'adjustable_foot', 'toe_kick_height' => 100, 'height' => 820, 'width' => 1200).hardware
    assert_equal 6, wide.find { |h| h['hardware_id'] == 'adjustable_foot' }['qty']
  end

  def test_part_rows_carry_hardware_and_edges
    rows = cab('door_count' => 1).part_rows
    door = rows.find { |r| r['key'] == 'door_1' }
    assert_includes door['hardware'], '2 x Standard concealed hinge'
    assert_includes door['edge_text'], 'L1 2.0mm'
    assert_equal '-', rows.find { |r| r['key'] == 'back' }['hardware']
  end

  # --- Custom hardware & config ------------------------------------------------------------
  def test_custom_hardware_lifecycle_and_persistence
    store = H::MemoryStore.new
    cfg = H::Config.new(store)
    it = cfg.add_custom(name: 'Blum clip-top', category: 'hinge', price: '4.5', supplier: 'Blum')
    assert_equal 'custom_1', it.id
    assert_equal 4.5, it.price
    H.config = cfg
    assert_includes H.all.map(&:id), 'custom_1'
    assert_includes CabinetCraft::Parameter.schema.find { |f| f['key'] == 'hinge_type' }['options'].map { |o| o['value'] }, 'custom_1'

    again = H::Config.new(store) # simulates restarting SketchUp
    assert_equal ['Blum clip-top'], again.custom_items.map(&:name)
    assert_equal 'custom_2', again.add_custom(name: 'X', category: 'handle').id
    assert again.delete_custom('custom_1')
    refute again.delete_custom('nope')
  end

  def test_custom_hardware_validation
    assert_raises(ArgumentError) { H.config.add_custom(name: ' ', category: 'hinge') }
    assert_raises(ArgumentError) { H.config.add_custom(name: 'a', category: 'bogus') }
    assert_raises(ArgumentError) { H.config.add_custom(name: 'a', category: 'hinge', price: '-1') }
    assert_raises(ArgumentError) { H.config.add_custom(name: 'a', category: 'hinge', price: 'abc') }
  end

  def test_corrupt_store_falls_back_to_defaults
    store = H::MemoryStore.new
    store.write('{not json')
    cfg = H::Config.new(store)
    assert_equal 2, cfg.hinge_count(600)
    assert_empty cfg.custom_items
  end

  def test_missing_custom_hardware_does_not_break_cabinet
    c = cab('hinge_type' => 'custom_99', 'door_count' => 1) # coerce accepts unknown open ids
    assert_includes c.hardware.map { |h| h['name'] }, 'Unknown hardware (custom_99)'
    assert(c.hardware_issues.any? { |i| i['message'].include?('custom_99') })
    back = CabinetCraft::Cabinet.from_attributes(c.to_attributes)
    refute_nil back
  end

  def test_settings_validation
    H.config.set_setting('hinge_inset', 80)
    assert_equal 80.0, H.config.settings['hinge_inset']
    assert_raises(ArgumentError) { H.config.set_setting('hinge_inset', 0) }
    assert_raises(ArgumentError) { H.config.set_setting('nope', 1) }
  end

  # --- Cutting list ----------------------------------------------------------------------------
  def test_identical_parts_are_grouped_across_cabinets
    cabs = [cab({ 'door_count' => 1 }, 'B01'), cab({ 'door_count' => 1 }, 'B02'), cab({ 'width' => 800, 'door_count' => 1 }, 'B03')]
    list = CabinetCraft::Manufacturing::CuttingList.build(cabs)
    mdf = list['materials'].find { |m| m['material'] == '18mm MDF' }
    side = mdf['groups'].find { |g| g['name'] == 'Side panel' }
    assert_equal 6, side['qty'] # 2 per cabinet x 3 cabinets, all 739 x 562
    assert_equal [739, 562], [side['length'], side['width']]
    assert_equal 'B01, B02, B03', side['cabinets']
    door = mdf['groups'].select { |g| g['name'] == 'Door' }
    assert_equal [2, 1], door.map { |g| g['qty'] }.sort_by { -_1 } # 597 wide x2, 797 wide x1
    total_qty = list['materials'].sum { |m| m['groups'].sum { |g| g['qty'] } }
    assert_equal list['part_count'], total_qty
  end

  def test_material_area_and_sheet_estimate
    list = CabinetCraft::Manufacturing::CuttingList.build([cab('door_count' => 0, 'shelf_count' => 0)])
    mdf = list['materials'].find { |m| m['material'] == '18mm MDF' }
    expected = (600 * 562 + 2 * 739 * 562 + 2 * 564 * 100) / 1e6
    assert_in_delta expected, mdf['area_m2'], 0.001
    assert_equal 1, mdf['estimated_sheets']
    assert_match(/not a nesting result/, list['estimate_note'])
  end

  def test_edge_banding_and_hardware_totals
    list = CabinetCraft::Manufacturing::CuttingList.build([cab('door_count' => 1, 'height' => 720, 'shelf_count' => 0)])
    bands = list['edge_banding'].to_h { |b| [b['thickness'], b['length_m']] }
    # 720 high: sides 702, door 717. 1mm: 2 side fronts (702) + bottom front (600); 2mm: door 2628
    assert_in_delta((702 * 2 + 600) / 1000.0, bands[1.0], 1e-6)
    assert_in_delta 2.628, bands[2.0], 1e-6
    hinge = list['hardware'].find { |h| h['hardware_id'] == 'hinge_standard' }
    assert_equal 2, hinge['qty']
  end

  # --- Exporters --------------------------------------------------------------------------------
  def test_csv_escaping_and_formula_neutralisation
    csv = CabinetCraft::Exporters::CsvExporter.render(
      [{ 'a' => 'x,y', 'b' => '=1+1', 'c' => 5, 'd' => 'say "hi"', 'e' => -3 }],
      [%w[a A], %w[b B], %w[c C], %w[d D], %w[e E]]
    )
    assert_equal "A,B,C,D,E\n\"x,y\",'=1+1,5,\"say \"\"hi\"\"\",-3\n", csv
  end

  def test_excel_csv_has_bom_sep_hint_and_crlf
    csv = CabinetCraft::Exporters::CsvExporter.render([{ 'a' => 1 }], [%w[a A]], excel: true)
    assert csv.start_with?("﻿sep=,\r\nA\r\n1\r\n"), csv.inspect
  end

  def test_project_json_round_trips
    list = CabinetCraft::Manufacturing::CuttingList.build([cab])
    json = CabinetCraft::Exporters::JsonExporter.project([cab], list)
    data = JSON.parse(json)
    assert_equal 'cabinetcraft-project', data['format']
    assert_equal 1, data['cabinets'].size
    assert_equal cab.params.keys.sort, data['cabinets'][0]['params'].keys.sort
    assert_operator data['cabinets'][0]['parts'].size, :>, 5
  end

  def test_hardware_does_not_break_geometry_invariants
    # All presets still produce collision-free panels with edges/hardware attached.
    CabinetCraft::Library::ENTRIES.each do |e|
      c = CabinetCraft::Cabinet.build(type: e['type'], params: params(CabinetCraft::Library.defaults_for(e['type'])), label: 'B09')
      assert c.calculation.ok?
      refute_empty c.hardware, e['type']
      assert_equal c.part_rows.map { |r| r['part_id'] }.uniq.size, c.part_rows.size
    end
  end
end
