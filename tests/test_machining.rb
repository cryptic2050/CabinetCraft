# frozen_string_literal: true

require_relative 'test_helper'

class TestMachining < Minitest::Test
  include TestParams
  M = CabinetCraft::Manufacturing::Machining
  MC = CabinetCraft::MachiningConfig
  Chk = CabinetCraft::Validation::MachiningChecker

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Standards.current = CabinetCraft::Standards.new
    CabinetCraft::MachiningConfig.current = MC.new
  end

  def cab(ov = {}, label = 'B01')
    CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(ov), label: label)
  end

  def ops(c, kind = nil)
    all = M.operations(c)['ops']
    kind ? all.select { |o| o['kind'] == kind } : all
  end

  # --- hinges ----------------------------------------------------------------------------------
  def test_hinge_cups_on_door_inner_face_at_rule_positions
    c = cab('height' => 720, 'door_count' => 1, 'hinge_side' => 'left')
    cups = ops(c, 'hinge_cup')
    assert_equal 2, cups.size
    assert_equal [100.0, 617.0], cups.map { |o| o['x'] }.sort # along the 717 mm door length, from its bottom
    assert(cups.all? { |o| o['y'] == 22.5 && o['dia'] == 35.0 && o['depth'] == 12.5 && o['side'] == 'a' && o['part_key'] == 'door_1' })
  end

  def test_right_hinge_cup_is_measured_from_the_hinge_edge
    c = cab('height' => 720, 'hinge_side' => 'right')
    # door width 597: cup centre is 22.5 from the RIGHT edge -> 574.5 from the left edge (door width axis, local y)
    assert_equal [574.5], ops(c, 'hinge_cup').map { |o| o['y'] }.uniq
  end

  def test_hinge_plate_holes_on_the_matching_side_panel
    c = cab('height' => 720, 'hinge_side' => 'left')
    plates = ops(c, 'hinge_plate')
    assert_equal 4, plates.size # 2 hinges x 2 holes
    assert(plates.all? { |o| o['part_key'] == 'side_left' && o['side'] == 'a' && o['y'] == 37.0 })
    # hinge at door z 1.5 + 100 = 101.5 -> plate holes 16 mm either side; side local x = z - 18 (side starts above the bottom)
    assert_equal [67.5, 99.5, 584.5, 616.5], plates.map { |o| o['x'] }.sort
    assert_equal 'side_right', ops(cab('hinge_side' => 'right'), 'hinge_plate').first['part_key']
    assert_equal 'b', ops(cab('hinge_side' => 'right'), 'hinge_plate').first['side']
  end

  def test_inner_doors_without_a_divider_warn_and_skip_plate_holes
    c = cab('width' => 1200, 'door_count' => 4)
    res = M.operations(c)
    assert(res['issues'].any? { |i| i['code'] == 'machining_no_mount' })
    assert_operator ops(c, 'hinge_cup').size, :>, ops(c, 'hinge_plate').size / 2
  end

  def test_hinge_count_follows_rules
    tall = cab('height' => 2100, 'depth' => 600, 'shelf_count' => 3)
    assert_equal 4, ops(tall, 'hinge_cup').size
    CabinetCraft::Hardware.config.hinge_rules = [{ 'min_height' => 0, 'count' => 3 }]
    assert_equal 3, ops(cab, 'hinge_cup').size
  end

  # --- shelf pins / handles / runners -----------------------------------------------------------------
  def test_shelf_pins_four_per_shelf_on_inner_faces
    c = cab('shelf_count' => 2, 'door_count' => 0)
    pins = ops(c, 'shelf_pin')
    assert_equal 8, pins.size
    assert_equal({ 'side_left' => 4, 'side_right' => 4 }, pins.group_by { |o| o['part_key'] }.transform_values(&:size))
    assert_equal %w[a b], pins.group_by { |o| o['part_key'] }.sort.map { |_, v| v.first['side'] }
    # each pin sits 3 mm below the shelf, 17 mm in from the shelf's front/back edges
    shelf = c.panels.find { |p| p.key == 'shelf_1' }
    left = pins.select { |o| o['part_key'] == 'side_left' }.map { |o| [o['y'], o['x']] }
    assert_includes left.map(&:first), shelf.origin[1] + 17
    assert_includes left.map(&:first), shelf.max_corner[1] - 17
    assert_in_delta shelf.origin[2] - 3 - 18, left.map(&:last).min, 1e-6 # side local x runs from z = 18
  end

  def test_pins_in_both_compartments_use_divider_faces
    c = cab('width' => 900, 'divider_count' => 1, 'shelf_count' => 1, 'door_count' => 0)
    pins = ops(c, 'shelf_pin')
    assert_equal 8, pins.size
    assert_equal 4, pins.count { |o| o['part_key'] == 'divider_1' }
    assert_equal %w[a b], pins.select { |o| o['part_key'] == 'divider_1' }.map { |o| o['side'] }.uniq.sort
  end

  def test_handles_are_through_holes_from_the_front_face
    c = cab('handle_type' => 'handle_bar', 'door_count' => 1, 'drawer_count' => 1, 'height' => 820, 'toe_kick_height' => 100)
    h = ops(c, 'handle')
    assert_equal 4, h.size
    assert(h.all? { |o| o['through'] && o['side'] == 'b' && o['dia'] == 5.0 })
    drawer = h.select { |o| o['part_key'] == 'drawer_1_front' }
    assert_in_delta 128.0, (drawer[0]['x'] - drawer[1]['x']).abs.abs.then { |v| v.zero? ? (drawer[0]['y'] - drawer[1]['y']).abs : v }, 1e-6
    assert_empty ops(cab, 'handle') # handle_type none
  end

  def test_runner_holes_per_drawer_per_side
    c = cab('door_count' => 0, 'drawer_count' => 3, 'shelf_count' => 0)
    r = ops(c, 'runner')
    assert_equal 3 * 2 * 3, r.size
    assert_equal [37.0, 69.0, 101.0], r.select { |o| o['part_key'] == 'side_left' }.map { |o| o['y'] }.uniq.sort
  end

  # --- connectors: machining must agree with the hardware list ----------------------------------------
  def test_connector_ops_match_hardware_counts_for_every_type
    shapes = [{}, { 'width' => 900, 'divider_count' => 1, 'shelf_count' => 0 }, { 'height' => 820, 'toe_kick_height' => 100, 'door_count' => 1, 'drawer_count' => 1 },
              { 'depth' => 700, 'door_count' => 0 }]
    shapes.each do |shape|
      c = cab(shape.merge('connector_type' => 'cam_lock'))
      hw = ->(id, cabinet) { cabinet.hardware.select { |h| h['hardware_id'] == id }.sum { |h| h['qty'] } }
      assert_equal hw.call('cam_lock', c), ops(c, 'connector_cam').size, shape.inspect
      assert_equal hw.call('cam_lock', c), ops(c, 'connector_bore').size
      assert_equal hw.call('cam_bolt', c), ops(c, 'connector_bolt').size
      d = cab(shape.merge('connector_type' => 'dowel'))
      assert_equal hw.call('dowel', d), ops(d, 'connector_dowel').size / 2, shape.inspect # edge + face hole per dowel
      k = cab(shape.merge('connector_type' => 'confirmat'))
      assert_equal hw.call('confirmat', k), ops(k, 'connector_confirmat').size / 2
    end
  end

  def test_cam_joint_geometry_on_side_and_bottom
    c = cab('connector_type' => 'cam_lock', 'shelf_count' => 0, 'door_count' => 0)
    cams = ops(c, 'connector_cam').select { |o| o['part_key'] == 'side_left' }
    assert(cams.all? { |o| o['dia'] == 15.0 && o['depth'] == 12.5 && o['side'] == 'a' })
    assert(cams.all? { |o| (o['x'] - 34.0).abs < 1e-6 }) # 34 mm up the side from the joint (side local x = height above bottom top)
    bores = ops(c, 'connector_bore').select { |o| o['part_key'] == 'side_left' }
    assert(bores.all? { |o| o['edge'] == 'W1' && o['dia'] == 8.0 && o['depth'] == 34.0 && o['z'] == 9.0 })
    assert_equal cams.map { |o| o['y'] }, bores.map { |o| o['along'] } # bore lines up with its cam housing
    bolts = ops(c, 'connector_bolt').select { |o| o['part_key'] == 'bottom' && o['x'] == 9.0 }
    assert_equal cams.size, bolts.size
  end

  def test_confirmat_clearance_hole_goes_through_the_outer_face
    k = ops(cab('connector_type' => 'confirmat', 'shelf_count' => 0, 'door_count' => 0), 'connector_confirmat')
    thru = k.select { |o| o['target'] == 'face' }
    assert(thru.all? { |o| o['through'] && o['dia'] == 7.0 && o['side'] == 'b' || o['part_key'] != 'bottom' })
    assert(k.any? { |o| o['target'] == 'edge' && o['depth'] == 50.0 && o['dia'] == 5.0 })
  end

  def test_unsupported_hardware_is_reported_not_silently_skipped
    c = cab('connector_type' => 'lamello', 'door_count' => 0, 'drawer_count' => 1, 'runner_type' => 'runner_undermount', 'shelf_count' => 0)
    res = M.operations(c)
    assert_equal 2, res['issues'].count { |i| i['code'] == 'machining_unsupported' }
    assert_empty res['ops'].select { |o| o['kind'] =~ /connector|runner/ }
  end

  # --- custom patterns -----------------------------------------------------------------------------------
  def test_custom_pattern_applies_to_every_matching_part
    MC.current.add_pattern(name: 'Cable hole', role: 'shelf', side: 'a', holes: [{ 'x' => 100, 'y' => 60, 'dia' => 60, 'depth' => 18 }])
    c = cab('shelf_count' => 2)
    custom = ops(c, 'custom')
    assert_equal 2, custom.size
    assert(custom.all? { |o| o['note'] == 'Cable hole' && o['through'] && o['x'] == 100.0 })
  end

  def test_custom_pattern_validation_and_persistence
    store = CabinetCraft::Hardware::MemoryStore.new
    cfg = MC.new(store)
    assert_raises(ArgumentError) { cfg.add_pattern(name: '', role: 'shelf', side: 'a', holes: [{ 'x' => 1, 'y' => 1, 'dia' => 5, 'depth' => 5 }]) }
    assert_raises(ArgumentError) { cfg.add_pattern(name: 'x', role: 'wall', side: 'a', holes: [{ 'x' => 1, 'y' => 1, 'dia' => 5, 'depth' => 5 }]) }
    assert_raises(ArgumentError) { cfg.add_pattern(name: 'x', role: 'shelf', side: 'c', holes: [{ 'x' => 1, 'y' => 1, 'dia' => 5, 'depth' => 5 }]) }
    assert_raises(ArgumentError) { cfg.add_pattern(name: 'x', role: 'shelf', side: 'a', holes: []) }
    assert_raises(ArgumentError) { cfg.add_pattern(name: 'x', role: 'shelf', side: 'a', holes: [{ 'x' => 1, 'y' => 1, 'dia' => 0, 'depth' => 5 }]) }
    cfg.add_pattern(name: 'ok', role: 'shelf', side: 'b', holes: [{ 'x' => 1, 'y' => 2, 'dia' => 5, 'depth' => 5 }])
    assert_equal ['ok'], MC.new(store).patterns.map { |p| p['name'] }
    assert cfg.delete_pattern('pattern_1')
  end

  def test_settings_change_the_machining
    MC.current.set_setting('hinge_cup_edge', 21.5)
    assert_equal [21.5], ops(cab('height' => 720), 'hinge_cup').map { |o| o['y'] }.uniq
    assert_raises(ArgumentError) { MC.current.set_setting('hinge_cup_edge', 0) }
    assert_raises(ArgumentError) { MC.current.set_setting('bogus', 1) }
  end

  def test_corrupt_store_falls_back
    s = CabinetCraft::Hardware::MemoryStore.new
    s.write('{nope')
    assert_equal 35.0, MC.new(s).settings['hinge_cup_dia']
  end

  # --- feasibility checker ----------------------------------------------------------------------------------
  def test_standard_presets_have_no_drilling_errors
    CabinetCraft::Library::ENTRIES.each_with_index do |e, i|
      %w[cam_lock dowel confirmat].each do |conn|
        c = CabinetCraft::Cabinet.build(type: e['type'], params: params(CabinetCraft::Library.defaults_for(e['type']).merge('connector_type' => conn, 'handle_type' => 'handle_bar')), label: format('B%02d', i + 1))
        errs = Chk.check(M.operations(c)['ops']).select { |x| x['severity'] == 'error' }
        assert_empty errs.map { |x| x['message'] }, "#{e['type']} / #{conn}"
      end
    end
  end

  def test_all_ops_lie_inside_their_parts
    shapes = [{ 'width' => 900, 'divider_count' => 1, 'shelf_count' => 2, 'door_count' => 2 }, { 'door_count' => 0, 'drawer_count' => 4, 'height' => 820, 'toe_kick_height' => 100, 'shelf_count' => 0 }]
    shapes.each do |s|
      M.operations(cab(s.merge('handle_type' => 'handle_bar')))['ops'].each do |o|
        next unless o['target'] == 'face'

        r = o['dia'] / 2.0
        assert_operator o['x'] - r, :>=, -1e-6, o.inspect
        assert_operator o['x'] + r, :<=, o['part_length'] + 1e-6, o.inspect
        assert_operator o['y'] - r, :>=, -1e-6, o.inspect
        assert_operator o['y'] + r, :<=, o['part_width'] + 1e-6, o.inspect
      end
    end
  end

  def test_thin_panels_make_cam_housings_impossible
    errs = Chk.check(M.operations(cab('material' => 'ply_12', 'connector_type' => 'cam_lock'))['ops']).select { |x| x['severity'] == 'error' }
    assert(errs.any? { |e| e['message'] =~ /deep in a 12|leaves under/ }, 'a 12.5 mm deep housing cannot fit in 12 mm board')
    assert(errs.all? { |e| e['code'] == 'impossible_drilling' && e['cabinet_id'] && e['part_key'] })
  end

  def test_edge_bore_too_large_for_thin_board
    errs = Chk.check(M.operations(cab('material' => 'ply_12', 'connector_type' => 'dowel'))['ops'])
    assert(errs.any? { |e| e['message'].include?('leaves under') }, 'a 12 mm deep dowel hole in 12 mm board must not break through')
  end

  def test_overlapping_holes_and_outside_holes_detected
    MC.current.add_pattern(name: 'bad', role: 'shelf', side: 'a', holes: [{ 'x' => 100, 'y' => 100, 'dia' => 20, 'depth' => 5 }, { 'x' => 110, 'y' => 100, 'dia' => 20, 'depth' => 5 },
                                                                         { 'x' => 2, 'y' => 100, 'dia' => 20, 'depth' => 5 }])
    msgs = Chk.check(M.operations(cab('shelf_count' => 1))['ops']).map { |e| e['message'] }
    assert(msgs.any? { |m| m.include?('overlaps') })
    assert(msgs.any? { |m| m.include?('falls outside') })
  end

  def test_validator_includes_machining_issues
    issues = CabinetCraft::Validation::Validator.run([cab('material' => 'ply_12', 'connector_type' => 'cam_lock')])
    assert(issues.any? { |i| i['code'] == 'impossible_drilling' && i['severity'] == 'error' })
    clean = CabinetCraft::Validation::Validator.run([cab('door_count' => 1)])
    assert_empty clean.map { |i| i['message'] }
  end
end
