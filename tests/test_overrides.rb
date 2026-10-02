# frozen_string_literal: true

require_relative 'test_helper'

class TestOverrides < Minitest::Test
  include TestParams
  O = CabinetCraft::Overrides

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::MachiningConfig.current = CabinetCraft::MachiningConfig.new
  end

  def cab(ov = {}, overrides = {}, label = 'B01')
    c = CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(ov), label: label)
    overrides.empty? ? c : c.with_overrides(overrides)
  end

  def row(c, key)
    c.part_rows.find { |r| r['key'] == key }
  end

  def panel(c, key)
    c.panels.find { |p| p.key == key }
  end

  # --- applying ---------------------------------------------------------------------------------------
  def test_no_overrides_means_auto_everywhere
    c = cab
    assert(c.part_rows.all? { |r| r['status'] == 'AUTO' })
    assert_equal c.auto_panels.map { |p| [p.key, p.size, p.origin] }, c.panels.map { |p| [p.key, p.size, p.origin] }
  end

  def test_size_overrides_follow_the_parts_own_axes
    c = cab({}, 'side_left' => { 'length' => 700.0, 'width' => 500.0 }, 'bottom' => { 'thickness' => 20.0 })
    side = row(c, 'side_left')
    assert_equal [700.0, 500.0, 18.0, 'MANUAL OVERRIDE'], side.values_at('length', 'width', 'thickness', 'status')
    assert_equal [739.0, 562.0, 18.0, 'AUTO'], row(c, 'side_right').values_at('length', 'width', 'thickness', 'status')
    assert_equal 20.0, row(c, 'bottom')['thickness']
    assert_equal %w[length width], panel(c, 'side_left').overridden
  end

  def test_offsets_move_the_part_relative_to_its_automatic_position
    auto = panel(cab, 'shelf_1').origin
    moved = panel(cab({}, 'shelf_1' => { 'offset_x' => 5.0, 'offset_y' => -3.0, 'offset_z' => 12.5 }), 'shelf_1').origin
    assert_equal [auto[0] + 5, auto[1] - 3, auto[2] + 12.5], moved
    c = cab({ 'width' => 700 }, 'shelf_1' => { 'offset_z' => 12.5 }) # still relative after a parametric change
    assert_in_delta panel(cab('width' => 700), 'shelf_1').origin[2] + 12.5, panel(c, 'shelf_1').origin[2], 1e-9
  end

  def test_material_override
    c = cab({}, 'door_1' => { 'material' => 'ply_18' })
    assert_equal ['18mm Plywood', 'ply_18'], row(c, 'door_1').values_at('material', 'material_id')
    assert_equal '18mm MDF', row(c, 'side_left')['material']
  end

  def test_edge_override_replaces_the_automatic_banding_entirely
    c = cab({ 'height' => 720 }, 'door_1' => { 'edges' => { 'top' => 2, 'bottom' => 2, 'left' => 0.4, 'right' => 0 } })
    # a door's top/bottom are its width edges (W2/W1), left/right its length edges (L1/L2); right = 0 means no band
    assert_equal({ 'L1' => 0.4, 'W1' => 2.0, 'W2' => 2.0 }, row(c, 'door_1')['edge_codes'])
    assert_equal '-', row(cab({}, 'side_left' => { 'edges' => { 'front' => 0 } }), 'side_left')['edge_text'] # explicit "no banding"
    assert_equal({ front: 1.0 }, panel(cab, 'side_left').edges) # untouched part keeps its automatic edge
  end

  def test_edges_validate_faces_and_values
    side = panel(cab, 'side_left') # thickness axis x: left/right are not edges
    assert_raises(ArgumentError) { O.clean_part(side, 'edges' => { 'left' => 1 }) }
    assert_raises(ArgumentError) { O.clean_part(side, 'edges' => { 'sideways' => 1 }) }
    assert_raises(ArgumentError) { O.clean_part(side, 'edges' => { 'front' => 9 }) }
    assert_raises(ArgumentError) { O.clean_part(side, 'edges' => { 'front' => 'x' }) }
    assert_equal({ 'edges' => { 'front' => 2.0, 'top' => 1.0 } }, O.clean_part(side, 'edges' => { 'front' => 2, 'top' => 1, 'back' => 0 }))
  end

  def test_clean_part_validation_and_blank_resets
    side = panel(cab, 'side_left')
    ex = { 'length' => 700.0, 'offset_x' => 3.0 }
    assert_equal({ 'offset_x' => 3.0 }, O.clean_part(side, { 'length' => '' }, ex)) # blank -> back to AUTO
    assert_equal({ 'length' => 700.0 }, O.clean_part(side, { 'offset_x' => nil }, ex))
    [{ 'length' => 0 }, { 'length' => 99_999 }, { 'length' => 'abc' }, { 'thickness' => 500 }, { 'offset_x' => 5000 }, { 'material' => 'gold' }].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { O.clean_part(side, bad) }
    end
    assert_equal({}, O.clean_part(side, { 'bogus' => 5 })) # unknown fields are ignored
  end

  # --- persistence ----------------------------------------------------------------------------------------
  def test_overrides_round_trip_through_attributes_and_survive_with_params
    c = cab({}, 'side_left' => { 'length' => 700.0 }, 'door_1' => { 'edges' => { 'top' => 1.0 } })
    back = CabinetCraft::Cabinet.from_attributes(c.to_attributes)
    assert_equal c.overrides, back.overrides
    again = c.with_params(params('width' => 700))
    assert_equal c.overrides, again.overrides
    assert_equal c.version + 1, c.with_overrides({}).version
    assert_equal({}, CabinetCraft::Cabinet.from_attributes(cab.to_attributes.reject { |k, _| k == 'overrides_json' }).overrides) # older models
  end

  def test_sanitize_drops_malformed_stored_overrides
    raw = { 'side_left' => { 'length' => 700, 'evil' => 1, 'material' => 5, 'edges' => 'x', 'offset_x' => 'a' }, 'door_1' => 'x', 5 => {}, 'back' => {} }
    assert_equal({ 'side_left' => { 'length' => 700 } }, O.sanitize(raw))
    assert_equal({}, O.sanitize(nil))
    assert_equal({}, O.sanitize([1]))
  end

  # --- "do not silently overwrite" ------------------------------------------------------------------------------
  def test_affected_lists_only_overridden_sizes_that_would_change
    c = cab({}, 'side_left' => { 'length' => 700.0 }, 'bottom' => { 'width' => 500.0 }, 'shelf_1' => { 'offset_z' => 5.0 })
    taller = c.with_params(params('height' => 900))
    aff = O.affected(c.auto_panels, taller.auto_panels, c.overrides)
    assert_equal [['side_left', 'length', 739.0, 882.0]], aff.map { |a| a.values_at('part_key', 'field', 'auto_old', 'auto_new') }
  end

  def test_bottom_width_override_is_affected_by_depth_not_width
    c = cab({}, 'bottom' => { 'width' => 500.0 }) # the bottom's width axis is the cabinet depth
    assert_empty O.affected(c.auto_panels, c.with_params(params('width' => 900)).auto_panels, c.overrides)
    assert_equal ['width'], O.affected(c.auto_panels, c.with_params(params('depth' => 600)).auto_panels, c.overrides).map { |a| a['field'] }
  end

  def test_removed_parts_are_reported_as_orphaned
    c = cab({ 'width' => 800, 'door_count' => 2 }, 'door_2' => { 'length' => 600.0 })
    fewer = c.with_params(params('width' => 800, 'door_count' => 1))
    aff = O.affected(c.auto_panels, fewer.auto_panels, c.overrides)
    assert_equal [['door_2', true]], aff.map { |a| a.values_at('part_key', 'orphaned') }
    assert_equal({}, O.reset_affected(c.overrides, aff))
    assert_equal ['door_2'], fewer.orphan_overrides
    assert_equal ['door_2'], CabinetCraft::Validation::Validator.run([fewer]).select { |i| i['code'] == 'override_orphan' }.map { |i| i['part_key'] }
  end

  def test_reset_affected_removes_only_those_fields
    ov = { 'side_left' => { 'length' => 700.0, 'offset_x' => 2.0 }, 'bottom' => { 'thickness' => 20.0 } }
    out = O.reset_affected(ov, [{ 'part_key' => 'side_left', 'field' => 'length', 'orphaned' => false }])
    assert_equal({ 'side_left' => { 'offset_x' => 2.0 }, 'bottom' => { 'thickness' => 20.0 } }, out)
    assert_equal ov['side_left'], { 'length' => 700.0, 'offset_x' => 2.0 }, 'input is not mutated'
  end

  # --- everything downstream follows the overridden panels -------------------------------------------------------------
  def test_parts_list_cutting_list_and_labels_use_overridden_sizes
    c = cab({ 'door_count' => 0 }, 'side_left' => { 'length' => 700.0 })
    list = CabinetCraft::Manufacturing::CuttingList.build([c])
    mdf = list['materials'].find { |m| m['material'] == '18mm MDF' }
    sides = mdf['groups'].select { |g| g['name'] == 'Side panel' }.map { |g| [g['length'], g['qty']] }.sort
    assert_equal [[700.0, 1], [739.0, 1]], sides # the two sides are no longer identical
    label = CabinetCraft::Manufacturing::Labels.build([c], project_name: 'P').find { |l| l['part_id'] == 'B01-SIDE_LEFT' }
    assert_equal ['700 x 562 x 18', 'MANUAL OVERRIDE'], label.values_at('dimensions', 'override')
    html = CabinetCraft::Exporters::LabelHtml.render([label])
    assert_includes html, 'MANUAL OVERRIDE'
  end

  def test_hinge_count_follows_an_overridden_door_height
    assert_equal 2, cab('height' => 720, 'door_count' => 1).hardware.find { |h| h['hardware_id'] == 'hinge_standard' }['qty']
    tall = cab({ 'height' => 720, 'door_count' => 1 }, 'door_1' => { 'length' => 1300.0 })
    assert_equal 4, tall.hardware.find { |h| h['hardware_id'] == 'hinge_standard' }['qty'] # rule: >= 1200 -> 4
    cups = CabinetCraft::Manufacturing::Machining.operations(tall)['ops'].select { |o| o['kind'] == 'hinge_cup' }
    assert_equal 4, cups.size
  end

  def test_connector_counts_stay_consistent_between_hardware_and_machining_with_overrides
    c = cab({ 'connector_type' => 'cam_lock', 'door_count' => 0, 'shelf_count' => 0, 'depth' => 600 },
            'side_left' => { 'width' => 300.0 }, 'brace_front' => { 'width' => 260.0 })
    ops = CabinetCraft::Manufacturing::Machining.operations(c)['ops']
    cams = c.hardware.select { |h| h['hardware_id'] == 'cam_lock' }.sum { |h| h['qty'] }
    assert_equal cams, ops.count { |o| o['kind'] == 'connector_cam' }
    assert_equal cams, ops.count { |o| o['kind'] == 'connector_bolt' }
    plain = cab({ 'connector_type' => 'cam_lock', 'door_count' => 0, 'shelf_count' => 0, 'depth' => 600 })
    assert_operator cams, :<, plain.hardware.select { |h| h['hardware_id'] == 'cam_lock' }.sum { |h| h['qty'] } # a shallower side needs fewer fixings
  end

  def test_nesting_uses_the_overridden_dimensions
    c = cab({ 'door_count' => 0 }, 'bottom' => { 'length' => 2000.0, 'width' => 500.0 })
    rows = CabinetCraft::Manufacturing::PartsList.build([c]).select { |r| r['material'] == '18mm MDF' }
    parts = rows.map { |r| { 'uid' => r['part_uid'], 'part_id' => r['part_id'], 'name' => r['name'], 'length' => r['length'], 'width' => r['width'], 'grain' => r['grain'], 'cabinet_label' => 'B01' } }
    res = CabinetCraft::Manufacturing::Nesting.nest(parts, { 'material' => 'x', 'sheet_length' => 2440.0, 'sheet_width' => 1220.0, 'grain_free' => true }, {})
    placed = res['sheets'].flat_map { |s| s['placements'] }.find { |p| p['part_id'] == 'B01-BOTTOM' }
    assert_equal [2000.0, 500.0], [placed['length'], placed['width']]
  end

  # --- validation of the result ---------------------------------------------------------------------------------------------
  def test_overrides_that_collide_are_reported
    c = cab({ 'door_count' => 0 }, 'shelf_1' => { 'length' => 700.0 }) # wider than the 564 mm opening: runs through both sides
    issues = CabinetCraft::Validation::Validator.run([c])
    assert(issues.any? { |i| i['code'] == 'overlapping_parts' && i['severity'] == 'error' })
  end

  def test_thickness_or_material_mismatch_is_a_warning
    w = CabinetCraft::Validation::Validator.run([cab({}, 'door_1' => { 'thickness' => 22.0 })]).select { |i| i['code'] == 'override_thickness' }
    assert_equal ['door_1'], w.map { |i| i['part_key'] }
    assert_equal 'warning', w.first['severity']
    assert_empty CabinetCraft::Validation::Validator.run([cab({}, 'door_1' => { 'thickness' => 18.0 })]).select { |i| i['code'] == 'override_thickness' }
    mm = CabinetCraft::Validation::Validator.run([cab({}, 'door_1' => { 'material' => 'ply_15' })]).select { |i| i['code'] == 'override_thickness' }
    assert_equal 1, mm.size # 15 mm board but the part is still 18 mm
  end
end
