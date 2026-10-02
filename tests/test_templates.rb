# frozen_string_literal: true

require_relative 'test_helper'

class TestTemplates < Minitest::Test
  T = CabinetCraft::Templates::Template
  Ex = CabinetCraft::Templates::Examples

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
  end

  def deep(h)
    JSON.parse(JSON.generate(h))
  end

  def shelf_unit
    @shelf_unit ||= T.from_h(deep(Ex::OPEN_SHELF_UNIT), id: 'tpl_1')
  end

  def tv_unit
    @tv_unit ||= T.from_h(deep(Ex::FLOATING_TV_UNIT), id: 'tpl_2')
  end

  def params_for(t, over = {})
    p, errors = CabinetCraft::Parameter.coerce(t.defaults.merge(over), t.schema)
    raise "bad params #{errors}" unless errors.empty?

    p
  end

  def build(t, over = {})
    t.build(params_for(t, over))
  end

  def invalid(mutator)
    raw = deep(Ex::OPEN_SHELF_UNIT)
    mutator.call(raw)
    assert_raises(T::Invalid) { T.from_h(raw) }.errors
  end

  # --- building --------------------------------------------------------------------------------------------
  def test_open_shelf_unit_default_geometry
    b = build(shelf_unit)
    assert b.result.ok?, b.result.errors.map(&:message).inspect
    keys = b.panels.map(&:key)
    assert_equal %w[side_left side_right bottom top shelf_1 shelf_2 shelf_3 back], keys
    side = b.panels.find { |p| p.key == 'side_left' }
    assert_equal [1800.0, 300.0, 18.0], [side.length, side.width, side.thickness]
    assert_in_delta 764, b.result.values['inner_w'], 1e-9
    assert_in_delta (1800 - 18 * 5) / 4.0, b.result.values['gap'], 1e-9 # 427.5
    shelf = b.panels.find { |p| p.key == 'shelf_2' }
    assert_equal 'Shelf 2', shelf.name
    assert_in_delta 18 + 427.5 * 2 + 18, shelf.origin[2], 1e-9
    assert_equal ['3mm HDF', 3.0], b.panels.find { |p| p.key == 'back' }.then { |p| [p.material_label, p.thickness] }
    assert_equal({ front: 1.0 }, side.edges)
  end

  def test_panels_never_overlap_over_a_parameter_matrix
    [600, 800, 1200].each do |w|
      [900, 1800, 2400].each do |h|
        [0, 1, 4, 8].each do |n|
          %w[mdf_18 ply_15 mdf_16].each do |mat|
            b = build(shelf_unit, 'width' => w, 'height' => h, 'shelves' => n, 'board' => mat)
            next unless b.result.ok?

            assert_equal 4 + n + 1, b.panels.size
            b.panels.combination(2).each { |a, c| refute a.overlaps?(c, 0.01), "#{a.key}/#{c.key} #{w}x#{h} n=#{n} #{mat}" }
          end
        end
      end
    end
  end

  def test_material_parameter_drives_thickness_variable
    thin = build(shelf_unit, 'board' => 'ply_12')
    assert_in_delta 800 - 24, thin.result.values['inner_w'], 1e-9
    assert_equal 12.0, thin.panels.find { |p| p.key == 'bottom' }.thickness
  end

  def test_constraints_error_and_warning
    err = build(shelf_unit, 'height' => 400, 'shelves' => 8)
    refute err.result.ok?
    assert_match(/less than 100 mm/, err.result.errors.first.message)
    assert_empty err.panels
    warn = build(shelf_unit, 'width' => 2000, 'depth' => 200)
    assert warn.result.ok?
    assert_equal ['Very wide for its depth; consider a centre support'], warn.result.warnings.map(&:message)
    assert_equal 8, warn.panels.size
  end

  def test_toggle_if_and_hardware_parameter
    on = build(tv_unit)
    assert_includes on.panels.map(&:key), 'flap_door'
    assert_equal 3, on.hardware.sum { |h| h['qty'] }
    assert_equal ['hinge_soft_close', 'flap_door'], on.hardware.first.values_at('hardware_id', 'part_key')
    off = build(tv_unit, 'flap' => '0')
    refute_includes off.panels.map(&:key), 'flap_door'
    assert_empty off.hardware
    other = build(tv_unit, 'hinge' => 'hinge_push_open')
    assert_equal 'Push-to-open hinge', other.hardware.first['name']
    assert_equal 7, on.panels.size # top, bottom, 2 sides, 2 dividers, flap door
  end

  def test_repeat_hardware_attaches_to_each_instance
    b = build(shelf_unit)
    dowels = b.hardware.select { |h| h['hardware_id'] == 'dowel' }
    assert_equal %w[shelf_1 shelf_2 shelf_3], dowels.map { |h| h['part_key'] }
    assert_equal [4, 4, 4], dowels.map { |h| h['qty'] }
    assert_equal 'cabinet', b.hardware.find { |h| h['hardware_id'] == 'confirmat' }['part_key']
    assert_empty build(shelf_unit, 'shelves' => 0).hardware.select { |h| h['hardware_id'] == 'dowel' }
  end

  def test_schema_matches_the_ui_format_and_coerces
    s = tv_unit.schema
    assert_equal %w[width height depth board front dividers flap hinge], s.map { |f| f['key'] }
    flap = s.find { |f| f['key'] == 'flap' }
    assert_equal ['enum', '1', %w[1 0]], [flap['type'], flap['default'], flap['options'].map { |o| o['value'] }]
    assert_includes s.find { |f| f['key'] == 'hinge' }['options'].map { |o| o['value'] }, 'hinge_push_open'
    assert_equal %w[hdf_3 mdf_6 mdf_9], shelf_unit.schema.find { |f| f['key'] == 'back' }['options'].map { |o| o['value'] }.sort
    _, errors = CabinetCraft::Parameter.coerce(shelf_unit.defaults.merge('width' => 99_999), shelf_unit.schema)
    refute_empty errors
  end

  def test_missing_material_is_an_issue_not_an_exception
    p = params_for(shelf_unit).merge('board' => 'mat_custom_9')
    b = shelf_unit.build(p)
    refute b.result.ok?
    assert_match(/not in the material library/, b.result.errors.first.message)
  end

  def test_round_trip_through_json_keeps_behaviour
    again = T.from_json(JSON.generate(shelf_unit.to_h))
    a = build(shelf_unit, 'shelves' => 5)
    b = build(again, 'shelves' => 5)
    assert_equal a.panels.map { |p| [p.key, p.size, p.origin, p.edges] }, b.panels.map { |p| [p.key, p.size, p.origin, p.edges] }
    assert_equal a.result.values, b.result.values
    refute_includes JSON.generate(shelf_unit.to_h), '"ast"'
  end

  # --- validation: each mistake is reported where it is ---------------------------------------------------------------
  def test_structure_errors
    assert_includes invalid(->(r) { r['name'] = '' }).join, 'name: is required'
    assert_includes invalid(->(r) { r['parameters'][0]['key'] = 'Width!' }).join, 'must be lower-case'
    assert_includes invalid(->(r) { r['parameters'][1]['key'] = 'width' }).join, "used twice"
    assert_includes invalid(->(r) { r['parameters'][0]['type'] = 'color' }).join, 'type must be one of'
    assert_includes invalid(->(r) { r['parameters'][0]['default'] = 99_999 }).join, 'default must lie between'
    assert_includes invalid(->(r) { r['parameters'][3]['default'] = 'gold' }).join, "not in the library"
    assert_includes invalid(->(r) { r['parameters'][0]['key'] = 'min' }).join, 'reserved'
    assert_includes invalid(->(r) { r['parameters'] = 'x' }).join, 'must be a list'
    assert_includes invalid(->(r) { r['panels'][0]['role'] = 'wall' }).join, 'role must be one of'
    assert_includes invalid(->(r) { r['panels'][0]['size'] = ['1', '2'] }).join, 'list of 3 formulas'
    assert_includes invalid(->(r) { r['panels'][0]['material'] = 'nope' }).join, 'neither a material parameter'
    assert_includes invalid(->(r) { r['panels'][0]['thickness_axis'] = 'w' }).join, 'must be x, y or z'
    assert_includes invalid(->(r) { r['panels'][0]['edges'] = { 'left' => '1' } }).join, 'not an edge'
    assert_includes invalid(->(r) { r['panels'][0]['edges'] = { 'sideways' => '1' } }).join, 'unknown face'
    assert_includes invalid(->(r) { r['hardware'][0]['id'] = 'unobtainium' }).join, 'not in the library'
    assert_includes invalid(->(r) { r['hardware'][0]['part'] = 'ghost' }).join, 'not a panel key'
    assert_includes invalid(->(r) { r['hardware'][0]['id'] = '$board' }).join, 'not a hardware parameter'
    assert_includes invalid(->(r) { r['constraints'][0]['severity'] = 'fatal' }).join, 'severity'
    assert_includes invalid(->(r) { r['derived'][0]['name'] = 'width' }).join, 'already a parameter'
  end

  def test_formula_errors_name_the_place
    e = invalid(->(r) { r['panels'][0]['size'][2] = 'height +' })
    assert(e.any? { |m| m.include?('panels[1].size[z]') && m.include?('ends unexpectedly') }, e.inspect)
    e = invalid(->(r) { r['derived'][1]['expr'] = 'speed * 2' })
    assert(e.any? { |m| m.include?('derived[2].expr') && m.include?('undefined variable speed') }, e.inspect)
    e = invalid(->(r) { r['panels'][5]['size'][0] = 'i + 1' }) # i is only available inside repeat
    assert(e.any? { |m| m.include?('undefined variable i') })
    e = invalid(->(r) { r['panels'][0]['size'][0] = 'system(1)' })
    assert(e.any? { |m| m.include?('Unknown function') })
  end

  def test_derived_values_must_be_defined_before_use
    e = invalid(->(r) { r['derived'][0]['expr'] = 'width - gap' }) # inner_w uses `gap`, which is defined after it
    assert(e.any? { |m| m.include?('derived[1].expr') && m.include?('undefined variable gap') }, e.inspect)
  end

  def test_trial_build_rejects_templates_that_cannot_make_their_defaults
    e = invalid(->(r) { r['panels'][0]['size'][0] = '0 - board_t' }) # negative size at the defaults
    assert(e.any? { |m| m.include?('Default values do not build') }, e.inspect)
    e = invalid(->(r) { r['panels'] = []; r['hardware'] = [] })
    assert(e.any? { |m| m.include?('produces no parts') }, e.inspect)
    e = invalid(->(r) { r['panels'][4]['repeat'] = '1000' })
    assert(e.any? { |m| m.include?('repeat count') })
  end

  def test_json_input_errors
    assert_raises(T::Invalid) { T.from_json('{nope') }
    assert_raises(T::Invalid) { T.from_json('[1]') }
    err = assert_raises(T::Invalid) { T.from_json('{}') }
    assert_includes err.errors.join, 'name: is required'
  end

  def test_limits
    big = deep(Ex::OPEN_SHELF_UNIT)
    big['parameters'] += (1..45).map { |i| { 'key' => "p#{i}", 'type' => 'toggle', 'default' => 0 } }
    assert(assert_raises(T::Invalid) { T.from_h(big) }.errors.any? { |m| m.include?('more than 40') })
  end

  def test_a_hostile_formula_cannot_hang_or_escape
    raw = deep(Ex::OPEN_SHELF_UNIT)
    raw['derived'] << { 'name' => 'x', 'expr' => '`rm -rf /`' }
    assert_raises(T::Invalid) { T.from_h(raw) }
    raw = deep(Ex::OPEN_SHELF_UNIT)
    raw['panels'][4]['repeat'] = '5 / (shelves - shelves)'
    assert_raises(T::Invalid) { T.from_h(raw) } # division by zero at the trial build
  end
end
