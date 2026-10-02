# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require_relative 'mock_sketchup'
%w[generators/cabinet_generator scene/attributes scene/registry scene/settings_store ui/controller].each do |f|
  require File.join(CabinetCraft::PLUGIN_ROOT, f)
end

class TestScene < Minitest::Test
  def setup
    Sketchup.reset_model!
    @c = CabinetCraft::Interface::Controller.new
    @model = Sketchup.active_model
  end

  def mm(inches)
    inches * 25.4
  end

  def cabinet_groups
    @model.entities.grep(Sketchup::Group)
  end

  def test_create_builds_cabinet_group_with_exact_panel_geometry
    res = @c.create('base_cabinet', 'width' => 600, 'height' => 757, 'depth' => 562, 'shelf_count' => 1, 'door_count' => 0)
    assert res['created'], res.inspect
    group = cabinet_groups.first
    assert_equal res['panels'].size, group.entities.grep(Sketchup::Group).size

    b = group.bounds
    assert_in_delta 600, mm(b.max.x - b.min.x), 1e-6
    assert_in_delta 562, mm(b.max.y - b.min.y), 1e-6
    assert_in_delta 757, mm(b.max.z - b.min.z), 1e-6

    side = group.entities.grep(Sketchup::Group).find { |g| g.name == 'B01-SIDE_LEFT' }
    sb = side.bounds
    assert_in_delta 18, mm(sb.max.x - sb.min.x), 1e-6
    assert_in_delta 739, mm(sb.max.z - sb.min.z), 1e-6
    assert_equal 'B01', side.get_attribute('CabinetCraft_Part', 'cabinet_label')
    assert_equal [:start, 'CabinetCraft: Create cabinet'], @model.ops.first
    assert_equal [:commit], @model.ops.last
    assert_equal group, @model.selection.first
  end

  def test_cabinet_attributes_cover_required_metadata
    @c.create('base_cabinet', {})
    group = cabinet_groups.first
    dict = group.attribute_dictionary('CabinetCraft')
    %w[cabinet_id cabinet_type width height depth material material_thickness back_thickness construction_type
       shelf_count created_date modified_date version].each do |k|
      refute_nil dict[k], "missing #{k}"
    end
  end

  def test_update_changes_width_in_place_and_preserves_identity_and_position
    first = @c.create('base_cabinet', 'width' => 600)['cabinet']
    second = @c.create('base_cabinet', 'width' => 600)['cabinet']
    refute_equal first['id'], second['id']
    assert_equal %w[B01 B02], [first['label'], second['label']]

    g1, g2 = cabinet_groups
    assert_in_delta 600, mm(g2.transformation.origin.x), 1e-6 # placed right of the first

    res = @c.update(first['id'], first['params'].merge('width' => 800))
    assert res['updated']
    assert_equal first['id'], res['cabinet']['id']
    assert_equal 2, res['cabinet']['version']
    assert_in_delta 800, mm(g1.bounds.max.x - g1.bounds.min.x), 1e-6
    # untouched cabinet was not rebuilt
    assert_equal 0, g2.made_unique
    assert_equal 1, g1.made_unique
    assert_equal 0, mm(g1.transformation.origin.x)
  end

  def test_update_with_no_change_does_not_touch_model
    cab = @c.create('base_cabinet', {})['cabinet']
    ops = @model.ops.size
    res = @c.update(cab['id'], cab['params'])
    refute res['updated']
    assert_equal ops, @model.ops.size
  end

  def test_invalid_parameters_do_not_modify_model
    res = @c.create('base_cabinet', 'width' => 10)
    refute res['created']
    assert_empty cabinet_groups
    cab = @c.create('base_cabinet', {})['cabinet']
    res = @c.update(cab['id'], cab['params'].merge('height' => 300, 'shelf_count' => 10))
    refute res['updated']
    assert(res['issues'].any? { |i| i['severity'] == 'error' })
  end

  def test_rebuild_removes_old_geometry
    cab = @c.create('base_cabinet', 'shelf_count' => 4)['cabinet']
    g = cabinet_groups.first
    n4 = g.entities.grep(Sketchup::Group).size
    @c.update(cab['id'], cab['params'].merge('shelf_count' => 0))
    assert_equal n4 - 4, g.entities.grep(Sketchup::Group).size
  end

  def test_preview_has_no_side_effects_and_matches_created_parts
    ops = @model.ops.size
    prev = @c.preview('base_cabinet', 'width' => 800)
    assert_equal ops, @model.ops.size
    assert_empty cabinet_groups
    created = @c.create('base_cabinet', 'width' => 800)
    assert_equal prev['panels'].map { |p| p.values_at('part_id', 'length', 'width') },
                 created['panels'].map { |p| p.values_at('part_id', 'length', 'width') }
  end

  def test_duplicate_ids_get_reidentified
    cab = @c.create('base_cabinet', {})['cabinet']
    original = cabinet_groups.first
    copy = original.deep_copy # same cabinet_id, as after a move+copy
    @model.entities.instance_variable_get(:@items) << copy
    assert_equal 1, CabinetCraft::Scene::Registry.duplicates(@model).size

    @c.create('base_cabinet', {}) # any operation repairs duplicates
    ids = CabinetCraft::Scene::Registry.cabinets(@model).map { |_, c| c.id }
    assert_equal ids.uniq, ids
    assert_includes ids, cab['id']
  end

  def test_selected_summary
    assert_nil @c.selected_summary
    cab = @c.create('base_cabinet', {})['cabinet']
    assert_equal cab['id'], @c.selected_summary['id']
  end

  def test_bootstrap_is_json_safe
    boot = @c.bootstrap
    JSON.parse(JSON.generate(boot))
    assert_equal 'base_cabinet', boot['library'].first['type']
  end

  def test_operation_aborted_on_failure
    CabinetCraft::Generators::CabinetGenerator.stub(:create, ->(*) { raise 'boom' }) do
      assert_raises(RuntimeError) { @c.create('base_cabinet', {}) }
    end
    assert_equal [:abort], @model.ops.last
  end

  def test_phase2_preset_geometry_and_front_to_drawer_switch
    res = @c.create('base_door_drawer', {})
    assert res['created'], res.inspect
    group = cabinet_groups.first
    b = group.bounds
    assert_in_delta 800, mm(b.max.x - b.min.x), 1e-6
    assert_in_delta 820, mm(b.max.z - b.min.z), 1e-6
    assert_in_delta 562 + 18, mm(b.max.y - b.min.y), 1e-6 # doors sit in front of the carcass depth
    names = group.entities.grep(Sketchup::Group).map(&:name)
    %w[B01-DOOR_1 B01-DOOR_2 B01-DRAWER_1_FRONT B01-DRAWER_1_BOTTOM B01-ZONE_SHELF B01-TOE_KICK].each { |n| assert_includes names, n }

    cab = res['cabinet']
    up = @c.update(cab['id'], cab['params'].merge('door_count' => 0, 'drawer_count' => 4, 'shelf_count' => 0))
    assert up['updated'], up.inspect
    names = group.entities.grep(Sketchup::Group).map(&:name)
    assert_equal 4, names.count { |n| n.match?(/DRAWER_\d_FRONT\z/) }
    refute(names.any? { |n| n.include?('DOOR') })
    refute_includes names, 'B01-ZONE_SHELF'
    assert_equal 1, group.made_unique
    ids = names.dup
    assert_equal ids.uniq, ids
  end
end

class TestSceneReports < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new(CabinetCraft::Scene::SettingsStore.new)
    @c = CabinetCraft::Interface::Controller.new
  end

  def test_parts_list_and_cutting_list_cover_every_cabinet
    @c.create('base_single_door', {})
    @c.create('base_drawer_3', {})
    parts = @c.parts_list
    assert_equal 2, parts['cabinet_count']
    assert_equal %w[B01 B02], parts['rows'].map { |r| r['cabinet_label'] }.uniq
    cl = @c.cutting_list
    assert_equal parts['rows'].size, cl['part_count']
    assert_equal parts['rows'].size, cl['materials'].sum { |m| m['groups'].sum { |g| g['qty'] } }
  end

  def test_parts_list_follows_model_edits
    cab = @c.create('base_single_door', {})['cabinet']
    door = -> { @c.parts_list['rows'].find { |r| r['key'] == 'door_1' } }
    assert_equal [717, 597], door.call.values_at('length', 'width')
    @c.update(cab['id'], cab['params'].merge('width' => 800))
    assert_equal [797, 717], door.call.values_at('length', 'width') # one source of truth: no stale data
  end

  def test_part_attributes_hold_scalars_only
    @c.create('base_single_door', {})
    group = Sketchup.active_model.entities.grep(Sketchup::Group).first
    door = group.entities.grep(Sketchup::Group).find { |g| g.name == 'B01-DOOR_1' }
    dict = door.attribute_dictionary('CabinetCraft_Part')
    assert_equal 'L1 2.0mm, L2 2.0mm, W1 2.0mm, W2 2.0mm', dict['edge_text']
    refute dict.key?('hardware')
    refute dict.key?('edge_codes')
    dict.each_pair { |_, v| assert(v.is_a?(String) || v.is_a?(Numeric)) }
  end

  def test_export_formats_write_files
    @c.create('base_double_door', {})
    Dir.mktmpdir do |dir|
      csv = File.join(dir, 'p.csv')
      assert @c.export('parts', 'csv', csv)['ok']
      lines = File.read(csv).lines
      assert_equal 'Part ID,Cabinet,Part name,Length,Width,Thickness,Qty,Material,Grain,Edge banding,Hardware', lines[0].chomp
      assert_equal @c.parts_list['rows'].size + 1, lines.size
      xl = File.join(dir, 'p_excel.csv')
      @c.export('cutting_list', 'excel_csv', xl)
      assert File.binread(xl).start_with?("\xEF\xBB\xBFsep=,\r\n".b)
      js = File.join(dir, 'proj.json')
      @c.export('project', 'json', js)
      assert_equal 1, JSON.parse(File.read(js))['cabinets'].size
      hw = File.join(dir, 'hw.csv')
      @c.export('hardware', 'csv', hw)
      assert_includes File.read(hw), 'Standard concealed hinge'
    end
  end

  def test_export_rejects_bad_requests
    assert_raises(ArgumentError) { @c.export('nope', 'csv', '/tmp/x') }
    assert_raises(ArgumentError) { @c.export('project', 'csv', '/tmp/x') }
    assert_raises(ArgumentError) { @c.export('parts', 'csv', '') }
    assert_raises(ArgumentError) { @c.export('parts', 'csv', '/no/such/dir/x.csv') }
  end

  def test_hardware_management_persists_and_protects_used_items
    state = @c.add_hardware('Soft hinge X', 'hinge', '3.2', 'ACME')
    custom = state['library'].find { |h| h['custom'] }
    assert_equal 'Soft hinge X', custom['name']
    assert_includes state['schema'].find { |f| f['key'] == 'hinge_type' }['options'].map { |o| o['value'] }, custom['id']

    reloaded = CabinetCraft::Hardware::Config.new(CabinetCraft::Scene::SettingsStore.new) # new "session"
    assert_equal ['Soft hinge X'], reloaded.custom_items.map(&:name)

    @c.create('base_single_door', 'hinge_type' => custom['id'])
    err = assert_raises(ArgumentError) { @c.delete_hardware(custom['id']) }
    assert_match(/B01/, err.message)
    assert_raises(ArgumentError) { @c.delete_hardware('hinge_standard') }
  end

  def test_changing_hinge_rule_updates_existing_cabinets
    @c.create('base_single_door', {}) # door 717 -> 2 hinges by default
    hinges = -> { @c.cutting_list['hardware'].find { |h| h['hardware_id'] == 'hinge_standard' }['qty'] }
    assert_equal 2, hinges.call
    @c.set_hinge_rules([{ 'min_height' => 0, 'count' => 3 }])
    assert_equal 3, hinges.call
    assert_raises(ArgumentError) { @c.set_hinge_rules([]) }
  end

  def test_preview_includes_hardware_and_json_safe
    prev = @c.preview('base_double_door', {})
    refute_empty prev['hardware']
    JSON.generate(prev)
  end
end
