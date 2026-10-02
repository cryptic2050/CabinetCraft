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

class TestScenePhase4 < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    @c = CabinetCraft::Interface::Controller.new
    @model = Sketchup.active_model
  end

  def groups
    @model.entities.grep(Sketchup::Group)
  end

  def codes(v)
    v['issues'].map { |i| i['code'] }
  end

  # --- Nesting through the controller ------------------------------------------------------
  def test_nest_covers_all_parts_and_is_valid
    @c.create('base_double_door', {})
    @c.create('base_drawer_3', {})
    res = @c.nest
    placed = res['materials'].sum { |m| m['sheets'].sum { |s| s['placements'].size } }
    assert_equal @c.parts_list['rows'].size, placed
    assert_equal 0, res['totals']['unplaced']
    assert_operator res['totals']['utilization'], :>, 0
    JSON.generate(res)
    assert(res['materials'].all? { |m| m['sheets'].all? { |s| s['cut_sequence']['ok'] } })
  end

  def test_nest_settings_are_validated_and_persisted_in_model
    @c.create('base_single_door', {})
    assert_raises(ArgumentError) { @c.nest('kerf' => -2) }
    res = @c.nest('kerf' => 3.2, 'trim' => 5, 'spacing' => 1)
    assert_equal [3.2, 5.0, 1.0], res['settings'].values_at('kerf', 'trim', 'spacing')
    assert_equal 3.2, @c.project_state['nest_settings']['kerf'] # stored in the model, survives a new controller
    assert_equal 3.2, CabinetCraft::Interface::Controller.new.nest['settings']['kerf']
  end

  def test_manual_move_locks_and_survives_renest_and_unlock
    @c.create('base_single_door', {})
    res = @c.nest
    mat = res['materials'].first
    pl = mat['sheets'][0]['placements'].first
    free_x = 2440 - 10 - pl['w'] - 1 # bottom-right corner region of an otherwise empty sheet area is not guaranteed free; use a far corner check
    bad = @c.nest_lock(mat['material'], pl['uid'], 0, 0, 0, false)
    refute bad['ok']
    assert_match(/Outside/, bad['error'])
    # lock the part exactly where it is, then move another part elsewhere
    locked = @c.nest_lock_current(pl['uid'])
    assert locked['ok']
    again = @c.nest['materials'].first['sheets'][0]['placements'].find { |p| p['uid'] == pl['uid'] }
    assert_equal [pl['x'], pl['y'], true], again.values_at('x', 'y', 'locked')
    assert @c.nest_unlock(pl['uid'])['ok']
    refute @c.nest['materials'].first['sheets'][0]['placements'].find { |p| p['uid'] == pl['uid'] }['locked']
    _ = free_x
  end

  def test_lock_is_released_when_the_part_changes
    cab = @c.create('base_single_door', {})['cabinet']
    row = @c.parts_list['rows'].find { |r| r['key'] == 'bottom' }
    @c.nest_lock_current(row['part_uid'])
    @c.update(cab['id'], cab['params'].merge('width' => 800)) # bottom changes size
    res = @c.nest
    assert_equal ['part size changed'], res['materials'].flat_map { |m| m['released_locks'] }.map { |l| l['reason'] }
    assert(@c.validate['issues'].any? { |i| i['code'] == 'lock_released' })
  end

  # --- Labels and lookup ---------------------------------------------------------------------
  def test_labels_and_scan_lookup
    @c.create('base_single_door', {})
    @c.set_project_name('VALENTINA KITCHEN')
    labels = @c.labels
    assert_equal 'VALENTINA KITCHEN', labels['project']
    code = labels['labels'].find { |l| l['part_id'] == 'B01-DOOR_1' }['qr_payload']
    found = @c.lookup_part(code)
    assert found['ok']
    assert_equal 'Door 1', found['part']['name']
    assert_equal 'B01', found['cabinet']['label']
    refute_empty found['hardware']
    refute @c.lookup_part('hello')['ok']
    refute @c.lookup_part("CC1|#{SecureRandom.uuid}|door_1")['ok']
    stale = code.sub('door_1', 'door_9')
    assert_match(/no part/, @c.lookup_part(stale)['error'])
  end

  def test_label_and_nesting_exports
    @c.create('base_single_door', {})
    Dir.mktmpdir do |dir|
      html = File.join(dir, 'l.html')
      assert @c.export('labels', 'html', html)['ok']
      assert_includes File.read(html), 'Untitled project'
      csv = File.join(dir, 'l.csv')
      @c.export('labels', 'csv', csv)
      assert_match(/^Project,Cabinet,Part,Part ID,Dimensions/, File.read(csv))
      nest = File.join(dir, 'n.csv')
      @c.export('nesting', 'csv', nest)
      assert_match(/^Material,Sheet,Part ID/, File.read(nest))
      assert_equal @c.parts_list['rows'].size + 1, File.read(nest).lines.size
    end
  end

  # --- Validation against the real model ----------------------------------------------------------
  def test_clean_model_is_valid
    @c.create('base_double_door', {})
    @c.create('base_drawer_3', {})
    v = @c.validate
    assert_equal 'valid', v['summary']['status'], v['issues'].inspect
    assert_equal 2, v['cabinet_count']
  end

  def test_deleted_part_is_detected_and_selectable
    cab = @c.create('base_single_door', {})['cabinet']
    group = groups.first
    group.entities.grep(Sketchup::Group).find { |g| g.name == 'B01-SHELF_1' }.erase!
    v = @c.validate
    issue = v['issues'].find { |i| i['code'] == 'missing_in_model' }
    assert_equal 'error', issue['severity']
    assert_equal 'shelf_1', issue['part_key']
    assert_equal 'error', v['summary']['status']
    # editing the cabinet regenerates it
    @c.update(cab['id'], cab['params'].merge('width' => 700))
    refute_includes codes(@c.validate), 'missing_in_model'
  end

  def test_manually_edited_part_geometry_is_flagged
    @c.create('base_single_door', {})
    side = groups.first.entities.grep(Sketchup::Group).find { |g| g.name == 'B01-SIDE_LEFT' }
    side.entities.clear!
    big = CabinetCraft::Panel.new(key: 'x', name: 'x', role: :side, origin: [0, 0, 0], size: [18, 562, 900], thickness_axis: :x, material_id: 'mdf_18', material_label: 'm')
    CabinetCraft::Generators::CabinetGenerator.build_box(side.entities, big)
    issue = @c.validate['issues'].find { |i| i['code'] == 'geometry_modified' }
    assert_equal 'warning', issue['severity']
    assert_equal 'side_left', issue['part_key']
  end

  def test_scaled_cabinet_and_overlapping_cabinets_flagged
    @c.create('base_single_door', {})
    @c.create('base_single_door', {})
    a, b = groups
    b.transform!(Geom::Transformation.new(Geom::Point3d.new(Units_mm(100), 0, 0))) # slide B onto A
    a.transformation.xscale = 1.5
    assert_includes codes(@c.validate), 'cabinets_overlap'
    assert_includes codes(@c.validate), 'cabinet_scaled'
  end

  def Units_mm(mm)
    mm / 25.4
  end

  def test_unreadable_cabinet_data_is_reported_with_entity_id
    @c.create('base_single_door', {})
    group = groups.first
    group.set_attribute('CabinetCraft', 'params_json', '{broken')
    issue = @c.validate['issues'].find { |i| i['code'] == 'unreadable_cabinet' }
    assert issue['entity_id']
    assert @c.select_target(nil, nil, issue['entity_id'])['ok']
    assert_equal group, @model.selection.first
  end

  def test_nesting_failure_for_oversized_cabinet_is_selectable
    cab = @c.create('base_cabinet', 'width' => 3000, 'door_count' => 0, 'shelf_count' => 0)['cabinet']
    issue = @c.validate['issues'].find { |i| i['code'] == 'nesting_failure' }
    assert_equal cab['id'], issue['cabinet_id']
    r = @c.select_target(issue['cabinet_id'], issue['part_key'])
    assert r['ok']
    assert_equal 'part', r['selected']
    assert_equal "#{cab['label']}-#{issue['part_key'].upcase}", @model.selection.first.name
    assert_equal [groups.first], @model.active_path
  end

  def test_select_target_cabinet_level_and_unknown
    cab = @c.create('base_single_door', {})['cabinet']
    @model.active_path = [groups.first]
    assert @c.select_target(cab['id'])['ok']
    assert_nil @model.active_path
    refute @c.select_target('nope')['ok']
    refute @c.select_target(nil)['ok']
  end
end

class TestSceneCnc < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new(CabinetCraft::Scene::SettingsStore.new('hardware_config'))
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::MachiningConfig.current = CabinetCraft::MachiningConfig.new(CabinetCraft::Scene::SettingsStore.new('machining_config'))
    @c = CabinetCraft::Interface::Controller.new
    @c.create('base_double_door', 'handle_type' => 'handle_bar')
    @c.create('base_drawer_3', {})
    @c.nest('kerf' => 8) # router is 8 mm
  end

  def test_machining_state_summarises_operations
    st = @c.machining_state
    assert_operator st['summary']['face'], :>, 20
    assert_operator st['summary']['edge'], :>, 0
    assert_equal %w[B01 B02], st['summary']['by_cabinet'].keys
    assert_equal 'default_router', st['active']
    JSON.generate(st)
  end

  def test_cnc_check_blocks_export_when_kerf_is_below_tool_diameter
    @c.nest('kerf' => 4)
    chk = @c.cnc_check
    refute chk['exportable']
    assert(chk['issues'].any? { |i| i['code'] == 'cnc_kerf_too_small' })
    Dir.mktmpdir do |dir|
      err = assert_raises(ArgumentError) { @c.export('gcode', 'nc', File.join(dir, 'job.nc')) }
      assert_match(/not written/, err.message)
      assert_empty Dir.children(dir)
    end
  end

  def test_multi_file_exports_write_one_file_per_sheet
    Dir.mktmpdir do |dir|
      %w[dxf svg gcode].each do |kind|
        ext = kind == 'gcode' ? 'nc' : kind
        r = @c.export(kind, ext, File.join(dir, "job.#{ext}"))
        assert r['ok'], kind
        assert_operator r['count'], :>=, 1
        assert(r['paths'].all? { |f| File.exist?(f) && f.end_with?(".#{ext}") && File.basename(f).start_with?('job_') })
      end
      nc = Dir.glob(File.join(dir, '*.nc')).sort
      assert(nc.all? { |f| File.read(f).include?('NOT verified') })
      assert(nc.any? { |f| File.read(f).include?('G81') })
      under = @c.export('gcode_b', 'nc', File.join(dir, 'job.nc'))
      assert(under['paths'].all? { |f| f.include?('_underside') })
      csv = File.join(dir, 'm.csv')
      @c.export('machining', 'csv', csv)
      assert_match(/^Cabinet,Part ID,Kind,Target/, File.read(csv))
    end
  end

  def test_machine_and_post_management_through_the_controller
    st = @c.save_machine(CabinetCraft::MachiningConfig::DEFAULT_MACHINE.merge('id' => '', 'name' => 'Shop', 'post' => 'grbl', 'origin' => 'top_left'))
    assert_equal 'machine_1', st['active']
    Dir.mktmpdir do |dir|
      r = @c.export('gcode', 'nc', File.join(dir, 'g.nc'))
      assert(r['paths'].all? { |f| File.read(f).include?('M0') && !File.read(f).include?('M6') })
    end
    assert_raises(ArgumentError) { @c.save_machine(CabinetCraft::MachiningConfig::DEFAULT_MACHINE.merge('id' => 'default_router')) }
    st = @c.save_post('', 'Mine', CabinetCraft::Manufacturing::CncPosts::DEFAULT_TEMPLATES, 'tap')
    assert_equal ['post_1'], st['custom_posts'].map { |p| p['id'] }
    assert_equal 'machine_1', @c.select_machine('machine_1')['active']
    assert_equal 'default_router', @c.delete_machine('machine_1')['active']
  end

  def test_preview_and_patterns
    prev = @c.cnc_preview('18mm MDF', 0)
    assert prev['ok']
    assert_match(/\A<svg/, prev['svg'])
    assert_equal prev['holes'], prev['svg'].scan('<circle').size
    st = @c.add_pattern('Cable hole', 'shelf', 'a', [{ 'x' => 100, 'y' => 60, 'dia' => 60, 'depth' => 18 }])
    assert_equal ['Cable hole'], st['patterns'].map { |p| p['name'] }
    assert_operator st['summary']['by_kind']['custom'], :>=, 1
    assert_empty @c.delete_pattern('pattern_1')['patterns']
    assert_raises(ArgumentError) { @c.delete_pattern('pattern_9') }
  end

  def test_settings_persist_across_new_config_instances
    @c.set_machining_setting('hinge_cup_edge', 21.5)
    again = CabinetCraft::MachiningConfig.new(CabinetCraft::Scene::SettingsStore.new('machining_config'))
    assert_equal 21.5, again.settings['hinge_cup_edge']
    assert_equal 22.5, CabinetCraft::MachiningConfig.new(CabinetCraft::Scene::SettingsStore.new('hardware_config')).settings['hinge_cup_edge'] # separate key
  end

  def test_validation_includes_drilling_through_the_scene
    @c.create('base_cabinet', 'material' => 'ply_12', 'connector_type' => 'cam_lock')
    assert(@c.validate['issues'].any? { |i| i['code'] == 'impossible_drilling' })
  end
end

class TestSceneMaterials < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    @c = CabinetCraft::Interface::Controller.new
    @model = Sketchup.active_model
  end

  def groups
    @model.entities.grep(Sketchup::Group)
  end

  def custom(over = {})
    { 'name' => 'Birch 19', 'thickness' => 19, 'role' => 'carcass', 'grain' => 'length', 'sheet_length' => 2500, 'sheet_width' => 1250,
      'color' => '#c8a878' }.merge(over)
  end

  def side_thickness_mm(group)
    s = group.entities.grep(Sketchup::Group).find { |g| g.name.end_with?('SIDE_LEFT') }
    (s.bounds.max.x - s.bounds.min.x) * 25.4
  end

  def test_editing_a_material_regenerates_only_the_cabinets_that_use_it
    mat = @c.save_material(custom)['saved_id']
    @c.create('base_cabinet', 'material' => mat, 'door_count' => 0)
    @c.create('base_cabinet', 'door_count' => 0)
    a, b = groups
    assert_in_delta 19, side_thickness_mm(a), 1e-6
    assert_in_delta 18, side_thickness_mm(b), 1e-6
    ops_before = @model.ops.size
    res = @c.save_material(custom('id' => mat, 'thickness' => 21))
    assert_equal 1, res['regenerated']
    assert_in_delta 21, side_thickness_mm(a), 1e-6 # follows the material
    assert_in_delta 18, side_thickness_mm(b), 1e-6 # untouched
    assert_equal 0, b.made_unique
    assert_equal ops_before + 2, @model.ops.size # one start+commit for the single regeneration
    assert_equal ['B01'], res['materials'].find { |m| m['id'] == mat }['used_by']
  end

  def test_delete_is_refused_while_in_use_and_allowed_after
    mat = @c.save_material(custom)['saved_id']
    cab = @c.create('base_cabinet', 'material' => mat)['cabinet']
    err = assert_raises(ArgumentError) { @c.delete_material(mat) }
    assert_match(/B01/, err.message)
    @c.update(cab['id'], cab['params'].merge('material' => 'mdf_18'))
    refute_includes @c.delete_material(mat)['materials'].map { |m| m['id'] }, mat
    assert_raises(ArgumentError) { @c.delete_material('mdf_18') }
  end

  def test_builtin_override_and_reset_through_the_controller
    res = @c.save_material('id' => 'mdf_18', 'price' => 33, 'color' => '#112233')
    assert_equal 33, res['materials'].find { |m| m['id'] == 'mdf_18' }['price']
    assert_equal ['mdf_18'], res['overridden']
    assert_equal 0, @c.reset_material('mdf_18')['regenerated']
    assert_empty @c.materials_state['overridden']
  end

  def test_model_carries_its_custom_materials_to_another_machine
    mat = @c.save_material(custom('name' => 'Portable board', 'price' => 20))['saved_id']
    @c.create('base_cabinet', 'material' => mat)
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new # a fresh machine: nothing configured
    refute CabinetCraft::Material.exist?(mat)
    rows = @c.parts_list['rows'] # any report call restores what the model needs
    assert CabinetCraft::Material.exist?(mat)
    assert_equal 'Portable board', rows.find { |r| r['key'] == 'side_left' }['material']
    assert_equal 'valid', @c.validate['summary']['status'], @c.validate['issues'].inspect
  end

  def test_missing_material_without_snapshot_is_an_error_not_a_crash
    mat = @c.save_material(custom)['saved_id']
    @c.create('base_cabinet', 'material' => mat)
    @model.set_attribute('CabinetCraft_Project', 'materials_snapshot', '{}')
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    v = @c.validate
    assert_equal ['missing_material'], v['issues'].map { |i| i['code'] }
    assert_empty @c.parts_list['rows']
    assert_equal 1, @c.list['cabinets'].size # the cabinet is still there and editable
  end

  def test_nesting_uses_the_materials_sheet_size_and_grain
    mat = @c.save_material(custom('grain' => 'width', 'sheet_length' => 3000, 'sheet_width' => 1500))['saved_id']
    @c.create('base_cabinet', 'material' => mat, 'door_count' => 0)
    m = @c.nest['materials'].find { |r| r['material'] == 'Birch 19' }
    assert_equal [3000.0, 1500.0, 'width', false], [m['sheet_length'], m['sheet_width'], m['grain_axis'], m['grain_free']]
    side = m['sheets'].flat_map { |s| s['placements'] }.find { |p| p['part_id'] == 'B01-SIDE_LEFT' }
    assert_equal true, side['rotated'] # vertical-grain side: its length must run along the sheet's width (Y)
    assert_equal 'valid', @c.validate['summary']['status'], @c.validate['issues'].inspect
  end

  def test_invalid_material_input_changes_nothing
    assert_raises(ArgumentError) { @c.save_material(custom('thickness' => 0)) }
    assert_empty CabinetCraft::Material.config.custom
  end
end
