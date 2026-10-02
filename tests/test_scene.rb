# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'
require 'open3'
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
      assert_equal 'Part ID,Cabinet,Part name,Length,Width,Thickness,Qty,Material,Grain,Edge banding,Hardware,Status', lines[0].chomp
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
    b.transform!(Geom::Transformation.new(Geom::Point3d.new(Units_mm(100) - b.transformation.origin.x, 0, 0))) # slide B onto A (transform! composes)
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
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
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
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
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
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
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

class TestSceneOverrides < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
    @c = CabinetCraft::Interface::Controller.new
    @model = Sketchup.active_model
    @cab = @c.create('base_cabinet', 'door_count' => 0)['cabinet']
  end

  def groups
    @model.entities.grep(Sketchup::Group)
  end

  def part_group(name)
    groups.first.entities.grep(Sketchup::Group).find { |g| g.name == name }
  end

  def extent_mm(group)
    b = group.bounds
    [b.max.x - b.min.x, b.max.y - b.min.y, b.max.z - b.min.z].map { |v| (v * 25.4).round(3) }
  end

  def rows
    @c.parts_list['rows']
  end

  def test_set_override_regenerates_the_geometry_and_marks_the_part
    assert_equal [18.0, 562.0, 739.0], extent_mm(part_group('B01-SIDE_LEFT'))
    state = @c.set_override(@cab['id'], 'side_left', 'length' => 700, 'width' => 500)
    assert_equal [18.0, 500.0, 700.0], extent_mm(part_group('B01-SIDE_LEFT'))
    assert_equal [18.0, 562.0, 739.0], extent_mm(part_group('B01-SIDE_RIGHT'))
    part = state['parts'].find { |p| p['key'] == 'side_left' }
    assert_equal 'MANUAL OVERRIDE', part['status']
    assert_equal({ 'auto' => 739.0, 'value' => 700.0, 'effective' => 700.0 }, part['fields']['length'])
    assert_equal 'AUTO', state['parts'].find { |p| p['key'] == 'side_right' }['status']
    assert_equal 'MANUAL OVERRIDE', rows.find { |r| r['key'] == 'side_left' }['status']
    JSON.generate(state)
  end

  def test_overrides_are_stored_in_the_model_and_survive_reload
    @c.set_override(@cab['id'], 'shelf_1', 'offset_z' => 20)
    fresh = CabinetCraft::Interface::Controller.new
    assert_equal({ 'shelf_1' => { 'offset_z' => 20.0 } }, fresh.list['cabinets'].first['overrides'])
    assert_equal 'MANUAL OVERRIDE', fresh.parts_list['rows'].find { |r| r['key'] == 'shelf_1' }['status']
  end

  def test_blank_value_and_reset_return_to_auto
    @c.set_override(@cab['id'], 'side_left', 'length' => 700, 'offset_x' => 3)
    @c.set_override(@cab['id'], 'side_left', 'length' => '')
    assert_equal({ 'side_left' => { 'offset_x' => 3.0 } }, @c.list['cabinets'].first['overrides'])
    ops = @model.ops.size
    @c.set_override(@cab['id'], 'side_left', 'length' => '') # no change: no model operation
    assert_equal ops, @model.ops.size
    @c.set_override(@cab['id'], 'bottom', 'thickness' => 20)
    st = @c.reset_overrides(@cab['id'], 'side_left')
    assert_equal ['bottom'], st['parts'].select { |p| p['status'] != 'AUTO' }.map { |p| p['key'] }
    assert_empty @c.reset_overrides(@cab['id'])['parts'].select { |p| p['status'] != 'AUTO' }
    assert_equal [18.0, 562.0, 739.0], extent_mm(part_group('B01-SIDE_LEFT'))
  end

  def test_invalid_overrides_are_rejected_and_change_nothing
    ops = @model.ops.size
    assert_raises(ArgumentError) { @c.set_override(@cab['id'], 'side_left', 'length' => -5) }
    assert_raises(ArgumentError) { @c.set_override(@cab['id'], 'nope', 'length' => 5) }
    assert_raises(ArgumentError) { @c.set_override(@cab['id'], 'side_left', 'edges' => { 'left' => 1 }) }
    assert_raises(ArgumentError) { @c.set_override('missing', 'side_left', 'length' => 5) }
    assert_equal ops, @model.ops.size
    assert_empty @c.list['cabinets'].first['overrides']
  end

  def test_editing_a_cabinet_that_would_change_an_override_asks_first
    @c.set_override(@cab['id'], 'side_left', 'length' => 700)
    ops = @model.ops.size
    res = @c.update(@cab['id'], @cab['params'].merge('height' => 900))
    refute res['updated']
    assert res['needs_confirmation']
    assert_equal [['side_left', 'length', 700.0, 739.0, 882.0]], res['affected'].map { |a| a.values_at('part_key', 'field', 'override', 'auto_old', 'auto_new') }
    assert_equal 'B01-SIDE_LEFT', res['affected'].first['part_id']
    assert_equal ops, @model.ops.size, 'nothing was changed while waiting for the decision'
    assert_equal 757.0, @c.list['cabinets'].first['params']['height']
  end

  def test_keep_applies_the_change_and_keeps_the_override
    @c.set_override(@cab['id'], 'side_left', 'length' => 700)
    res = @c.update(@cab['id'], @cab['params'].merge('height' => 900), 'keep')
    assert res['updated']
    assert_equal({ 'side_left' => { 'length' => 700.0 } }, res['cabinet']['overrides'])
    assert_equal [18.0, 562.0, 700.0], extent_mm(part_group('B01-SIDE_LEFT')) # still the manual value
    assert_equal [18.0, 562.0, 882.0], extent_mm(part_group('B01-SIDE_RIGHT')) # others follow the new height
  end

  def test_reset_applies_the_change_and_returns_affected_parts_to_auto
    @c.set_override(@cab['id'], 'side_left', 'length' => 700)
    @c.set_override(@cab['id'], 'shelf_1', 'offset_z' => 10)
    res = @c.update(@cab['id'], @cab['params'].merge('height' => 900), 'reset')
    assert res['updated']
    assert_equal({ 'shelf_1' => { 'offset_z' => 10.0 } }, res['cabinet']['overrides']) # unaffected override stays
    assert_equal [18.0, 562.0, 882.0], extent_mm(part_group('B01-SIDE_LEFT'))
  end

  def test_changes_that_do_not_touch_overridden_sizes_need_no_confirmation
    @c.set_override(@cab['id'], 'side_left', 'length' => 700)
    res = @c.update(@cab['id'], @cab['params'].merge('width' => 700, 'shelf_count' => 2)) # side length depends only on height
    assert res['updated']
    refute res['needs_confirmation']
    assert_equal [18.0, 562.0, 700.0], extent_mm(part_group('B01-SIDE_LEFT'))
  end

  def test_removing_an_overridden_part_asks_and_orphans_are_reported
    c2 = @c.create('base_cabinet', 'width' => 800, 'door_count' => 2)['cabinet']
    @c.set_override(c2['id'], 'door_2', 'length' => 600)
    res = @c.update(c2['id'], c2['params'].merge('door_count' => 1))
    assert res['needs_confirmation']
    assert_equal [true], res['affected'].map { |a| a['orphaned'] }
    kept = @c.update(c2['id'], c2['params'].merge('door_count' => 1), 'keep')
    assert kept['updated']
    assert_equal ['door_2'], @c.advanced_parts(c2['id'])['orphans']
    assert(@c.validate['issues'].any? { |i| i['code'] == 'override_orphan' })
  end

  def test_overridden_geometry_is_not_flagged_as_hand_edited
    @c.set_override(@cab['id'], 'side_left', 'length' => 700)
    v = @c.validate
    refute(v['issues'].any? { |i| i['code'] == 'geometry_modified' }, v['issues'].inspect)
  end

  def test_other_cabinets_are_untouched_by_overrides
    other = @c.create('base_cabinet', 'door_count' => 0)['cabinet']
    g2 = groups.last
    @c.set_override(@cab['id'], 'side_left', 'length' => 700)
    assert_equal 0, g2.made_unique
    assert_empty @c.list['cabinets'].find { |c| c['id'] == other['id'] }['overrides']
  end

  def test_an_override_that_makes_drilling_impossible_blocks_gcode
    @c.nest('kerf' => 8)
    @model_before = @c.cnc_check['exportable']
    assert @model_before, 'baseline is exportable'
    # shorten the left side so the rail joint (near the top) now lies beyond the end of the part
    @c.set_override(@cab['id'], 'side_left', 'length' => 650)
    v = @c.validate
    drill = v['issues'].select { |i| i['code'] == 'impossible_drilling' && i['severity'] == 'error' }
    refute_empty drill
    assert(drill.all? { |i| i['part_key'] == 'side_left' && i['cabinet_id'] == @cab['id'] })
    refute @c.cnc_check['exportable']
    Dir.mktmpdir do |dir|
      err = assert_raises(ArgumentError) { @c.export('gcode', 'nc', File.join(dir, 'x.nc')) }
      assert_match(/falls outside/, err.message)
      assert_empty Dir.children(dir)
    end
    @c.reset_overrides(@cab['id'], 'side_left') # back to AUTO: exportable again
    assert @c.cnc_check['exportable']
  end

  def test_advanced_parts_shape
    st = @c.advanced_parts(@cab['id'])
    side = st['parts'].find { |p| p['key'] == 'side_left' }
    assert_equal %w[bottom front top back].sort, side['edge_faces'].sort # a side's edges are not on its left/right faces
    assert_equal %w[length width thickness material edges offset_x offset_y offset_z].sort, side['fields'].keys.sort
    refute @c.advanced_parts('nope')['ok']
  end
end

class TestScenePdf < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
    @c = CabinetCraft::Interface::Controller.new
    @c.create('base_double_door', 'handle_type' => 'handle_bar')
    @c.create('base_drawer_3', {})
    @c.set_project_name('VALENTINA KITCHEN')
  end

  def test_pdf_exports_write_valid_files_for_every_report
    Dir.mktmpdir do |dir|
      %w[parts cutting_list labels nesting].each do |kind|
        path = File.join(dir, "#{kind}.pdf")
        res = @c.export(kind, 'pdf', path)
        assert res['ok'], kind
        bytes = File.binread(path)
        assert bytes.start_with?('%PDF-1.4'.b), kind
        assert bytes.end_with?("%%EOF\n".b), kind
        assert_equal res['bytes'], bytes.bytesize
        assert_includes bytes, 'VALENTINA'.b if kind == 'labels'
      end
    end
  end

  def test_pdf_needs_cabinets_and_known_kinds
    Sketchup.reset_model!
    empty = CabinetCraft::Interface::Controller.new
    Dir.mktmpdir do |dir|
      assert_raises(ArgumentError) { empty.export('parts', 'pdf', File.join(dir, 'x.pdf')) }
      assert_raises(ArgumentError) { @c.export('hardware', 'pdf', File.join(dir, 'x.pdf')) }
      assert_raises(ArgumentError) { @c.export('project', 'pdf', File.join(dir, 'x.pdf')) }
      assert_empty Dir.children(dir)
    end
  end

  def test_pdf_reflects_overrides
    cab = @c.list['cabinets'].first
    @c.set_override(cab['id'], 'side_left', 'length' => 650)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'p.pdf')
      @c.export('parts', 'pdf', path)
      assert_includes File.binread(path), 'MANUAL OVERRIDE'.b
    end
  end
end

class TestLoader < Minitest::Test
  def test_extension_loads_in_main_rb_order_and_runs_a_full_workflow
    out, st = Open3.capture2e('ruby', File.join(__dir__, 'tools', 'load_main.rb'))
    assert st.success?, out
    assert_match(/LOAD OK: \d+ files/, out)
  end
end

class TestSceneTemplates < Minitest::Test
  Ex = CabinetCraft::Templates::Examples

  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
    @c = CabinetCraft::Interface::Controller.new
    @model = Sketchup.active_model
  end

  def groups
    @model.entities.grep(Sketchup::Group)
  end

  def shelf_id
    @shelf_id ||= @c.install_example('open_shelf_unit')['saved_id']
  end

  # --- library -----------------------------------------------------------------------------------------------------
  def test_installed_template_appears_in_the_library_with_its_own_schema
    id = shelf_id
    lib = @c.library_state
    entry = lib['library'].find { |e| e['type'] == id }
    assert_equal ['Open shelf unit', 'CUSTOM', 'template'], entry.values_at('name', 'category', 'user')
    assert_equal %w[width height depth board back shelves edge], lib['schemas'][id].map { |f| f['key'] }
    assert_includes @c.bootstrap['library'].map { |e| e['type'] }, id
    assert_equal 'tpl_1', id
  end

  def test_create_edit_and_report_a_custom_cabinet
    id = shelf_id
    res = @c.create(id, 'width' => 900, 'shelves' => 2)
    assert res['created'], res.inspect
    cab = res['cabinet']
    group = groups.first
    assert_equal %w[B01-BACK B01-BOTTOM B01-SHELF_1 B01-SHELF_2 B01-SIDE_LEFT B01-SIDE_RIGHT B01-TOP], group.entities.grep(Sketchup::Group).map(&:name).sort
    b = group.bounds
    assert_in_delta 900, (b.max.x - b.min.x) * 25.4, 1e-6
    up = @c.update(cab['id'], cab['params'].merge('shelves' => 4, 'height' => 2000))
    assert up['updated']
    assert_equal 4 + 4 + 1, groups.first.entities.grep(Sketchup::Group).size
    rows = @c.parts_list['rows']
    assert_equal 9, rows.size
    assert(rows.all? { |r| r['cabinet_label'] == 'B01' })
    assert_equal 'Shelf 3', rows.find { |r| r['key'] == 'shelf_3' }['name']
    JSON.generate(@c.preview(id, {}))
  end

  def test_custom_cabinets_flow_into_cutting_list_nesting_labels_and_pdfs
    @c.create(shelf_id, {})
    @c.create('base_single_door', {}) # mixed with a built-in cabinet
    assert_equal 2, @c.cutting_list['cabinet_count']
    nest = @c.nest('kerf' => 8)
    placed = nest['materials'].sum { |m| m['sheets'].sum { |s| s['placements'].size } }
    assert_equal @c.parts_list['rows'].size, placed
    assert_equal @c.parts_list['rows'].size, @c.labels['labels'].size
    Dir.mktmpdir do |dir|
      %w[parts cutting_list labels nesting].each { |k| assert @c.export(k, 'pdf', File.join(dir, "#{k}.pdf"))['ok'] }
    end
    v = @c.validate
    assert_equal [], v['issues'].select { |i| i['severity'] == 'error' }.map { |i| i['message'] }
  end

  def test_custom_cabinets_get_a_machining_notice_and_no_drilling
    @c.create(shelf_id, {})
    assert_equal 0, @c.machining_state['summary']['total']
    note = @c.validate['issues'].find { |i| i['code'] == 'machining_unsupported' }
    assert_match(/custom template/, note['message'])
    assert_equal 'warning', note['severity']
  end

  def test_overrides_work_on_custom_cabinets
    cab = @c.create(shelf_id, {})['cabinet']
    @c.set_override(cab['id'], 'shelf_1', 'offset_z' => 20, 'length' => 700)
    row = @c.parts_list['rows'].find { |r| r['key'] == 'shelf_1' }
    assert_equal ['MANUAL OVERRIDE', 700.0], row.values_at('status', 'length')
    res = @c.update(cab['id'], cab['params'].merge('width' => 1000))
    assert res['needs_confirmation'], 'shelf length is affected by width'
  end

  def test_constraint_failures_block_creation_with_the_templates_message
    res = @c.create(shelf_id, 'height' => 400, 'shelves' => 8)
    refute res['created']
    assert_match(/less than 100 mm apart/, res['issues'].first['message'])
    assert_empty groups
  end

  # --- editing, validating, deleting -------------------------------------------------------------------------------------
  def test_validate_template_previews_or_explains
    ok = @c.validate_template(JSON.generate(Ex::FLOATING_TV_UNIT))
    assert ok['ok']
    assert_equal 7, ok['panels'].size
    assert_equal %w[bay inner_w], ok['derived'].map { |d| d['name'] }.sort
    bad = @c.validate_template(JSON.generate(Ex::OPEN_SHELF_UNIT.merge('panels' => [Ex::OPEN_SHELF_UNIT['panels'][0].merge('size' => ['board_t', 'depth', 'oops'])])))
    refute bad['ok']
    assert(bad['errors'].any? { |e| e.include?('panels[1].size[z]') && e.include?('oops') })
    refute @c.validate_template('{nope')['ok']
    assert_empty @c.templates_state['templates'], 'validating never saves'
  end

  def test_editing_a_template_regenerates_only_its_cabinets
    id = shelf_id
    @c.create(id, {})
    @c.create('base_single_door', {})
    other = groups.last
    edited = JSON.parse(JSON.generate(Ex::OPEN_SHELF_UNIT))
    edited['panels'].find { |p| p['key'] == 'back' }['name'] = 'Rear panel'
    res = @c.save_template(JSON.generate(edited), id)
    assert_equal id, res['saved_id']
    assert_equal 'Rear panel', @c.parts_list['rows'].find { |r| r['key'] == 'back' }['name']
    assert_equal 0, other.made_unique
  end

  def test_template_in_use_cannot_be_deleted
    id = shelf_id
    @c.create(id, {})
    err = assert_raises(ArgumentError) { @c.delete_template(id) }
    assert_match(/B01/, err.message)
    @c.update(@c.list['cabinets'].first['id'], @c.list['cabinets'].first['params']) # no-op
    groups.first.erase!
    refute_includes @c.delete_template(id)['library'].map { |e| e['type'] }, id
  end

  def test_duplicate_names_and_bad_json_are_refused
    shelf_id
    assert_raises(ArgumentError) { @c.save_template(JSON.generate(Ex::OPEN_SHELF_UNIT)) } # same name as the installed one
    bad = @c.save_template('{nope')
    refute bad['ok']
    assert_match(/Not valid JSON/, bad['errors'].first)
    assert_raises(ArgumentError) { @c.install_example('nope') }
  end

  # --- presets ("save as template") ----------------------------------------------------------------------------------------
  def test_save_preset_appears_in_the_library_and_creates_matching_cabinets
    st = @c.save_preset('Sink base 900', 'BASE CABINETS', 'Two doors, no shelf', 'base_cabinet',
                        { 'width' => 900, 'height' => 820, 'toe_kick_height' => 100, 'door_count' => 2, 'shelf_count' => 0 })
    entry = st['library'].find { |e| e['name'] == 'Sink base 900' }
    assert_equal ['preset_1', 'preset'], entry.values_at('type', 'user')
    res = @c.create('preset_1', {})
    assert res['created']
    assert_equal [900.0, 2, 0], res['cabinet']['params'].values_at('width', 'door_count', 'shelf_count')
    assert_equal 'preset_1', res['cabinet']['type']
    assert_equal 2, @c.parts_list['rows'].count { |r| r['key'].start_with?('door_') }
    assert_raises(ArgumentError) { @c.save_preset('Sink base 900', 'X', '', 'base_cabinet', {}) } # name taken
    assert_raises(ArgumentError) { @c.save_preset('From template', 'X', '', shelf_id, {}) } # templates are not preset bases
    assert_raises(ArgumentError) { @c.save_preset('Bad', 'X', '', 'base_cabinet', { 'width' => 5 }) }
    assert_raises(ArgumentError) { @c.delete_preset('preset_1') } # in use
  end

  # --- portability --------------------------------------------------------------------------------------------------------------
  def test_model_carries_its_templates_and_presets_to_another_machine
    @c.save_preset('Sink base 900', 'BASE CABINETS', '', 'base_cabinet', { 'width' => 900 })
    @c.create(shelf_id, {})
    @c.create('preset_1', {})
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new # a fresh machine
    assert_nil CabinetCraft::Templates.find('tpl_1')
    rows = @c.parts_list['rows'] # any report restores what the model needs
    refute_nil CabinetCraft::Templates.find('tpl_1')
    assert_equal 2, rows.map { |r| r['cabinet_label'] }.uniq.size
    assert_includes @c.library_state['library'].map { |e| e['type'] }, 'preset_1'
    assert_equal 'valid', @c.validate['summary']['status'].then { |s| s == 'warning' ? 'valid' : s }, @c.validate['issues'].inspect
  end

  def test_missing_template_without_snapshot_is_reported_not_a_crash
    @c.create(shelf_id, {})
    @model.set_attribute('CabinetCraft_Project', 'templates_snapshot', '{}')
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
    assert_equal 1, @c.list['cabinets'].size, 'the cabinet is still readable'
    assert_empty @c.parts_list['rows']
    assert_match(/not available on this machine/, @c.validate['issues'].first['message'])
    # an inert cabinet must not cascade into "missing part" errors
    refute(@c.validate['issues'].any? { |i| i['code'] == 'missing_in_model' || i['code'] == 'unexpected_geometry' })
  end

  def test_untrusted_snapshots_are_validated
    evil = { 'templates' => [{ 'id' => 'tpl_9', 'name' => 'x', 'panels' => [{ 'key' => 'p', 'role' => 'side', 'material' => 'mdf_18', 'size' => ['`ls`', '1', '1'], 'origin' => %w[0 0 0], 'thickness_axis' => 'x' }] },
                             { 'id' => 'not_an_id', 'name' => 'y' }], 'presets' => [{ 'id' => 'preset_9', 'name' => 'z', 'base_type' => 'base_cabinet', 'defaults' => { 'width' => 5 } }] }
    @model.set_attribute('CabinetCraft_Project', 'templates_snapshot', JSON.generate(evil))
    @c.library_state
    assert_empty CabinetCraft::Templates.config.templates
    assert_empty CabinetCraft::Templates.config.presets
  end
end

class TestSceneStandards < Minitest::Test
  def setup
    Sketchup.reset_model!
    @c = CabinetCraft::Interface::Controller.new
  end

  def test_library_defaults_are_resolved_on_the_server
    lib = @c.bootstrap['library']
    door = lib.find { |e| e['type'] == 'base_single_door' }
    assert_equal [100.0, 820.0, 'mdf_18'], door['resolved'].values_at('toe_kick_height', 'height', 'material')
    st = @c.save_standards('Acme Joinery', 'material' => 'ply_18', 'toe_kick_height' => 120, 'door_reveal' => 2)
    assert_equal 'Acme Joinery', st['standards']['name']
    door = st['library'].find { |e| e['type'] == 'base_single_door' }
    assert_equal [120.0, 840.0, 'ply_18', 2.0], door['resolved'].values_at('toe_kick_height', 'height', 'material', 'door_reveal')
    assert_equal({ 'material' => 'ply_18', 'toe_kick_height' => 120.0, 'door_reveal' => 2.0 }, @c.bootstrap['standards']['values'])
  end

  def test_new_cabinets_use_standards_and_existing_ones_do_not_change
    old = @c.create('base_single_door', {})['cabinet']
    @c.save_standards('Acme', 'front_material' => 'ply_18', 'edge_front' => 0.4)
    fresh = @c.create('base_single_door', @c.bootstrap['library'].find { |e| e['type'] == 'base_single_door' }['resolved'])['cabinet']
    assert_equal ['mdf_18', 2.0], old['params'].values_at('front_material', 'edge_front')
    assert_equal ['ply_18', 0.4], fresh['params'].values_at('front_material', 'edge_front')
    assert_equal 'mdf_18', @c.list['cabinets'].find { |c| c['id'] == old['id'] }['params']['front_material']
  end

  def test_invalid_standards_raise_and_reset_restores_factory
    assert_raises(ArgumentError) { @c.save_standards('x', 'door_reveal' => 99) }
    assert_empty @c.standards_state['standards']['values']
    @c.save_standards('Acme', 'door_gap' => 5)
    assert_equal 5.0, @c.standards_state['standards']['values']['door_gap']
    assert_empty @c.reset_standards['standards']['values']
    fields = @c.standards_state['fields'].map { |f| f['key'] }
    refute_includes fields, 'width'
    JSON.generate(@c.standards_state)
  end

  def test_standards_state_exposes_hardware_placement_settings
    assert_equal 100.0, @c.standards_state['hardware_settings']['hinge_inset']
  end
end

class TestCostingScene < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    @c = CabinetCraft::Interface::Controller.new
    @c.create('base_double_door', {})
    @c.create('base_drawer_3', {})
    @c.set_project_name('VALENTINA KITCHEN')
  end

  def test_cost_state_defaults_and_warnings_for_unpriced_items
    s = @c.cost_state
    assert_equal 2, s['cabinet_count']
    assert_equal true, s['settings']['enabled']
    assert_equal 2, s['estimate']['per_cabinet'].size
    assert_match(/No price set/, s['estimate']['warnings'].join)
    assert_equal 0.0, s['estimate']['total_cost']
  end

  def test_settings_persist_in_the_model_and_drive_the_estimate
    @c.set_hardware_price('hinge_standard', 4)
    @c.save_cost_settings('labour_rate' => 30, 'labour_hours_per_cabinet' => 1, 'margin_pct' => 40, 'transport' => 50)
    again = CabinetCraft::Interface::Controller.new # same model, new controller
    st = again.cost_state
    assert_equal 40.0, st['settings']['margin_pct']
    e = st['estimate']
    assert_operator e['labour']['cost'], :>=, 60.0
    assert_in_delta e['total_cost'], e['per_cabinet'].sum { |x| x['cost'] }, 0.0001
    assert_in_delta e['total_cost'] / 0.6, e['selling_price'], 0.011
  end

  def test_invalid_settings_are_rejected_and_nothing_is_saved
    assert_raises(ArgumentError) { @c.save_cost_settings('margin_pct' => 120) }
    assert_equal 25.0, @c.cost_state['settings']['margin_pct']
  end

  def test_hardware_prices_show_in_hardware_state
    st = @c.set_hardware_price('hinge_standard', 3.25)
    assert_equal 3.25, st['library'].find { |h| h['id'] == 'hinge_standard' }['price']
    assert_raises(ArgumentError) { @c.set_hardware_price('hinge_standard', -3) }
  end

  def test_disabled_costing_blocks_cost_exports
    @c.save_cost_settings('enabled' => false)
    assert_equal({ 'enabled' => false }, @c.cost_state['estimate'])
    Dir.mktmpdir do |dir|
      %w[costing quote].each do |k|
        err = assert_raises(ArgumentError) { @c.export(k, 'pdf', File.join(dir, "#{k}.pdf")) }
        assert_match(/switched off/, err.message)
      end
      assert_empty Dir.children(dir)
    end
  end

  def test_cost_exports_and_quote_never_leak_cost_or_margin
    @c.set_hardware_price('hinge_standard', 3)
    @c.save_cost_settings('margin_pct' => 33, 'edge_prices' => { 'default' => 1.0 })
    Dir.mktmpdir do |dir|
      %w[csv excel_csv json pdf].each do |fmt|
        res = @c.export('costing', fmt, File.join(dir, "costing.#{fmt}"))
        assert res['ok'], fmt
      end
      assert_in_delta @c.cost_estimate['selling_price'], JSON.parse(File.read(File.join(dir, 'costing.json')))['rows']['selling_price'], 0.0001
      path = File.join(dir, 'quote.pdf')
      assert @c.export('quote', 'pdf', path)['ok']
      bytes = File.binread(path)
      assert bytes.start_with?('%PDF-1.4'.b)
      assert_includes bytes, 'VALENTINA'.b
      %w[margin Margin profit Profit Total\ cost].each { |w| refute_includes bytes, w.b, w }
      assert File.size(File.join(dir, 'costing.pdf')) > 500
    end
  end
end

class TestAssemblyScene < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    @c = CabinetCraft::Interface::Controller.new
    @c.create('base_double_door', {})
    @c.create('base_drawer_3', {})
    @model = Sketchup.active_model
  end

  def groups
    @model.entities.grep(Sketchup::Group)
  end

  def part_boxes(group)
    group.entities.grep(Sketchup::Group).to_h { |p| [p.name, p.bounds.min.to_a + p.bounds.max.to_a] }
  end

  def id(i = 0)
    @c.list['cabinets'][i]['id']
  end

  def test_assembly_state_has_steps_parts_and_both_drawings
    s = @c.assembly_state(id)
    assert s['ok']
    assert_equal s['parts'].size, s['svg_exploded'].scan('<g data-part=').size
    assert_equal s['parts'].size, s['svg_assembled'].scan('<g data-part=').size
    assert_equal false, s['exploded_in_model']
    assert_operator s['steps'].size, :>=, 5
  end

  def test_explode_moves_parts_and_assemble_restores_them_exactly
    g = groups.first
    before = part_boxes(g)
    res = @c.explode_cabinet(id, 120)
    assert res['exploded_in_model']
    during = part_boxes(g)
    assert_operator (during['B01-SIDE_LEFT'][0] - before['B01-SIDE_LEFT'][0]).abs, :>, 1 # inches
    assert_in_delta(-120, (during['B01-SIDE_LEFT'][0] - before['B01-SIDE_LEFT'][0]) * 25.4, 1e-6)
    assert_in_delta 120, (during['B01-SIDE_RIGHT'][0] - before['B01-SIDE_RIGHT'][0]) * 25.4, 1e-6
    assert_equal false, @c.assemble_cabinet(id)['exploded_in_model']
    part_boxes(g).each { |k, v| v.zip(before[k]).each { |a, b| assert_in_delta b, a, 1e-9, k } }
  end

  def test_changing_the_distance_does_not_accumulate_and_assemble_is_idempotent
    g = groups.first
    before = part_boxes(g)
    @c.explode_cabinet(id, 100)
    @c.explode_cabinet(id, 100) # same again: nothing moves further
    @c.explode_cabinet(id, 50)
    assert_in_delta(-50, (part_boxes(g)['B01-SIDE_LEFT'][0] - before['B01-SIDE_LEFT'][0]) * 25.4, 1e-6)
    @c.assemble_cabinet(id)
    @c.assemble_cabinet(id)
    part_boxes(g).each { |k, v| v.zip(before[k]).each { |a, b| assert_in_delta b, a, 1e-9, k } }
  end

  def test_only_the_chosen_cabinet_moves
    other = part_boxes(groups.last)
    @c.explode_cabinet(id(0), 100)
    assert_equal other, part_boxes(groups.last)
  end

  def test_exploding_is_one_undo_step_and_can_be_aborted_by_errors
    starts = -> { @model.instance_variable_get(:@ops).count { |o| o.first == :start } }
    n = starts.call
    @c.explode_cabinet(id, 80)
    assert_equal n + 1, starts.call
    assert_equal :commit, @model.instance_variable_get(:@ops).last.first
    assert_raises(ArgumentError) { @c.explode_cabinet(id, 99_999) }
    assert_raises(ArgumentError) { @c.explode_cabinet(id, 'abc') }
    assert_raises(ArgumentError) { @c.explode_cabinet(id, -5) }
    assert_raises(ArgumentError) { @c.explode_cabinet('nope', 50) }
  end

  def test_model_check_warns_about_exploded_cabinets_and_skips_their_overlap_test
    @c.explode_cabinet(id, 400)
    issues = @c.validate['issues']
    assert(issues.any? { |i| i['code'] == 'cabinet_exploded' })
    refute(issues.any? { |i| i['code'] == 'cabinets_overlap' })
    refute(issues.any? { |i| i['code'] == 'geometry_modified' })
    @c.assemble_cabinet(id)
    refute(@c.validate['issues'].any? { |i| i['code'] == 'cabinet_exploded' })
  end

  def test_editing_an_exploded_cabinet_rebuilds_it_assembled
    @c.explode_cabinet(id, 200)
    cab = @c.list['cabinets'].first
    @c.update(cab['id'], cab['params'].merge('width' => 700))
    assert_equal false, @c.assembly_state(id)['exploded_in_model']
    refute(@c.validate['issues'].any? { |i| i['code'] == 'cabinet_exploded' })
  end

  def test_assembly_pdf_covers_every_cabinet
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'a.pdf')
      assert @c.export('assembly', 'pdf', path)['ok']
      bytes = File.binread(path)
      assert_includes bytes, 'Assembly instructions'.b
      %w[B01 B02].each { |l| assert_includes bytes, l.b }
    end
    empty = Sketchup.reset_model!
    assert_raises(ArgumentError) { CabinetCraft::Interface::Controller.new.export('assembly', 'pdf', File.join(Dir.tmpdir, 'x.pdf')) }
  end

  def test_assembly_for_missing_cabinet_is_a_clean_failure
    r = @c.assembly_state('nope')
    assert_equal false, r['ok']
  end
end

class TestRunScene < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    @c = CabinetCraft::Interface::Controller.new
    @model = Sketchup.active_model
  end

  def groups
    @model.entities.grep(Sketchup::Group)
  end

  def starts
    @model.instance_variable_get(:@ops).count { |o| o.first == :start }
  end

  def test_plan_is_pure_and_returns_widths_per_item
    r = @c.plan_run(2400, [{ 'type' => 'base_single_door' }, { 'type' => 'base_drawer_3' }, { 'type' => 'base_double_door', 'fixed' => true, 'width' => 800 }])
    assert r['ok']
    assert_equal [800, 800, 800], r['widths']
    assert_equal %w[base_single_door base_drawer_3 base_double_door], r['items'].map { |i| i['type'] }
    assert_empty groups
  end

  def test_create_run_places_cabinets_edge_to_edge_with_exact_widths
    res = @c.create_run(2400, [{ 'type' => 'base_single_door' }, { 'type' => 'base_drawer_3' }, { 'type' => 'base_double_door', 'fixed' => true, 'width' => 900 }])
    assert res['ok']
    assert_equal [750, 750, 900], res['created'].map { |c| c['params']['width'] }
    assert_equal %w[B01 B02 B03], res['created'].map { |c| c['label'] }
    boxes = groups.map { |g| [g.bounds.min.x * 25.4, g.bounds.max.x * 25.4] }.sort
    assert_in_delta 0, boxes.first[0], 1e-6
    boxes.each_cons(2) { |a, b| assert_in_delta a[1], b[0], 1e-6 } # no gaps, no overlap
    assert_in_delta 2400, boxes.last[1], 1e-6
    assert_empty(@c.validate['issues'].select { |i| i['code'] == 'cabinets_overlap' })
  end

  def test_run_starts_after_existing_cabinets_and_is_one_undo_step
    @c.create('base_cabinet', 'width' => 500)
    n = starts
    @c.create_run(1200, [{ 'type' => 'base_cabinet' }, { 'type' => 'base_cabinet' }])
    assert_equal n + 1, starts
    xs = groups.map { |g| g.bounds.min.x * 25.4 }.sort
    assert_in_delta 500, xs[1], 1e-6
    assert_in_delta 1100, xs[2], 1e-6
  end

  def test_nothing_is_created_when_the_row_does_not_fit_or_a_cabinet_is_invalid
    assert_raises(ArgumentError) { @c.create_run(500, [{ 'type' => 'base_cabinet' }, { 'type' => 'base_cabinet' }]) } # needs >= 600
    assert_raises(ArgumentError) { @c.create_run(1200, [{ 'type' => 'nope' }]) }
    assert_raises(ArgumentError) { @c.create_run(1200, [{ 'type' => 'base_cabinet', 'params' => { 'material' => 'missing' } }]) }
    assert_raises(ArgumentError) { @c.create_run(1200, []) }
    assert_empty groups
  end

  def test_leftover_wall_is_reported_but_the_run_is_still_created
    res = @c.create_run(2000, [{ 'type' => 'base_cabinet', 'max' => 600 }, { 'type' => 'base_cabinet', 'max' => 600 }])
    assert res['ok']
    assert_equal 800.0, res['plan']['leftover']
    assert_equal 2, groups.size
  end

  def test_per_item_params_are_kept_and_widths_win
    res = @c.create_run(1500, [{ 'type' => 'base_cabinet', 'params' => { 'width' => 111, 'shelf_count' => 3, 'door_count' => 0 } }, { 'type' => 'base_cabinet' }])
    first = res['created'].first['params']
    assert_equal [750, 3], first.values_at('width', 'shelf_count')
  end

  def test_invalid_plan_input_is_a_clean_failure_for_the_preview
    r = @c.plan_run('abc', [{ 'type' => 'base_cabinet' }])
    assert_equal false, r['ok']
    assert_equal false, @c.plan_run(1000, [{ 'type' => 'zzz' }])['ok']
  end
end

class TestLinkedRuns < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    @c = CabinetCraft::Interface::Controller.new
    @model = Sketchup.active_model
    @res = @c.create_run(2400, [{ 'type' => 'base_single_door' }, { 'type' => 'base_drawer_3' }, { 'type' => 'base_double_door' }])
    @run = @res['runs'].first
  end

  def Units_mm(mm)
    mm / 25.4
  end

  def groups
    @model.entities.grep(Sketchup::Group)
  end

  def spans
    groups.map { |g| [(g.bounds.min.x * 25.4).round(6), (g.bounds.max.x * 25.4).round(6)] }.sort
  end

  def test_run_is_stored_with_members_and_in_sync
    assert_equal 'R01', @run['name']
    assert_equal 2400, @run['length']
    assert_equal 3, @run['members'].size
    assert @run['in_sync']
    assert_equal [800, 800, 800], @run['members'].map { |m| m['width'] }
    assert_equal ['R01'], CabinetCraft::Interface::Controller.new.runs_state['runs'].map { |r| r['name'] } # persisted in the model
    assert_equal 'R02', @c.create_run(1200, [{ 'type' => 'base_cabinet' }, { 'type' => 'base_cabinet' }])['runs'].last['name']
  end

  def test_quick_stretch_resizes_all_members_and_keeps_them_edge_to_edge
    r = @c.restretch_run(@run['id'], 2700)
    assert r['updated']
    assert_equal [900, 900, 900], r['runs'].first['members'].map { |m| m['width'] }
    s = spans
    assert_in_delta 0, s.first[0], 1e-6
    s.each_cons(2) { |a, b| assert_in_delta a[1], b[0], 1e-6 }
    assert_in_delta 2700, s.last[1], 1e-6
    assert r['runs'].first['in_sync']
    assert_equal 2700, @c.runs_state['runs'].first['length']
  end

  def test_stretch_down_and_back_restores_the_original_sizes
    @c.restretch_run(@run['id'], 1800)
    assert_equal [600, 600, 600], @c.runs_state['runs'].first['members'].map { |m| m['width'] }
    @c.restretch_run(@run['id'], 2400)
    assert_equal [800, 800, 800], @c.runs_state['runs'].first['members'].map { |m| m['width'] }
    assert_in_delta 2400, spans.last[1], 1e-6
  end

  def test_rules_can_pin_one_cabinet_and_the_others_compensate
    r = @c.restretch_run(@run['id'], 2400, [nil, { 'fixed' => true, 'width' => 600 }, nil])
    assert_equal [900, 600, 900], r['runs'].first['members'].map { |m| m['width'] }
    assert_equal [false, true, false], r['runs'].first['members'].map { |m| m['fixed'] }
    again = @c.restretch_run(@run['id'], 2000) # the pin persists
    assert_equal [700, 600, 700], again['runs'].first['members'].map { |m| m['width'] }
  end

  def test_pinning_without_a_width_uses_the_current_width
    r = @c.restretch_run(@run['id'], 2400, [{ 'fixed' => true }, nil, nil])
    assert_equal 800, r['runs'].first['members'].first['width']
    assert_equal true, r['runs'].first['members'].first['fixed']
  end

  def test_a_row_that_does_not_fit_changes_nothing
    before = spans
    assert_raises(ArgumentError) { @c.restretch_run(@run['id'], 700) } # 3 x 300 minimum = 900
    assert_equal before, spans
    assert_equal [800, 800, 800], @c.runs_state['runs'].first['members'].map { |m| m['width'] }
    assert_equal 2400, @c.runs_state['runs'].first['length']
  end

  def test_status_flags_resized_moved_and_missing_cabinets
    ids = @run['members'].map { |m| m['cabinet_id'] }
    cab = @c.list['cabinets'].find { |c| c['id'] == ids[1] }
    @c.update(cab['id'], cab['params'].merge('width' => 700))
    st = @c.runs_state['runs'].first
    assert_equal %w[ok resized], st['members'].first(2).map { |m| m['status'] }
    assert_equal false, st['in_sync']
    @c.restretch_run(@run['id'], 2400) # re-plan puts everything right again
    assert @c.runs_state['runs'].first['in_sync']
    third = groups.find { |g| g.get_attribute('CabinetCraft', 'cabinet_id') == ids[2] }
    third.transform!(Geom::Transformation.new(Geom::Point3d.new(Units_mm(50), 0, 0)))
    assert_equal 'moved', @c.runs_state['runs'].first['members'].last['status']
    third.erase!
    assert_equal 'missing', @c.runs_state['runs'].first['members'].last['status']
    err = assert_raises(ArgumentError) { @c.restretch_run(@run['id'], 2400) }
    assert_match(/no longer in the model/, err.message)
  end

  def test_the_run_follows_the_first_cabinet_when_it_was_moved
    ids = @run['members'].map { |m| m['cabinet_id'] }
    groups.each { |g| g.transform!(Geom::Transformation.new(Geom::Point3d.new(Units_mm(1000), 0, 0))) } # user moved the whole row
    assert @c.runs_state['runs'].first['in_sync']
    @c.restretch_run(@run['id'], 2700)
    s = spans
    assert_in_delta 1000, s.first[0], 1e-6
    assert_in_delta 3700, s.last[1], 1e-6
    assert_equal ids, @c.runs_state['runs'].first['members'].map { |m| m['cabinet_id'] }
  end

  def test_manual_overrides_ask_before_a_stretch_changes_them
    id = @run['members'][0]['cabinet_id']
    @c.set_override(id, 'bottom', 'length' => 790) # the bottom's length follows the cabinet width (800 -> 900)
    r = @c.restretch_run(@run['id'], 2700)
    assert_equal [false, true], [r['updated'], r['needs_confirmation']]
    assert_equal ['B01-BOTTOM'], r['affected'].map { |a| a['part_id'] }
    assert_equal [800, 800, 800], @c.runs_state['runs'].first['members'].map { |m| m['width'] } # nothing changed yet
    assert @c.restretch_run(@run['id'], 2700, nil, 'keep')['updated']
    assert_equal [900, 900, 900], @c.runs_state['runs'].first['members'].map { |m| m['width'] }
    assert_equal({ 'length' => 790.0 }, @c.list['cabinets'].find { |c| c['id'] == id }['overrides']['bottom']) # the override was kept
  end

  def test_resetting_overrides_when_a_stretch_changes_them
    id = @run['members'][0]['cabinet_id']
    @c.set_override(id, 'bottom', 'length' => 790)
    assert @c.restretch_run(@run['id'], 2700, nil, 'reset')['updated']
    refute @c.list['cabinets'].find { |c| c['id'] == id }['overrides'].key?('bottom')
  end

  def test_one_undo_step_and_unlink_keeps_the_cabinets
    n = @model.instance_variable_get(:@ops).count { |o| o.first == :start }
    @c.restretch_run(@run['id'], 2700)
    assert_equal n + 1, @model.instance_variable_get(:@ops).count { |o| o.first == :start }
    assert_equal [], @c.unlink_run(@run['id'])['runs']
    assert_equal 3, groups.size
    assert_raises(ArgumentError) { @c.unlink_run(@run['id']) }
    assert_raises(ArgumentError) { @c.restretch_run(@run['id'], 2400) }
  end

  def test_corrupt_stored_runs_are_ignored
    @model.set_attribute('CabinetCraft_Project', 'runs', '{"x":{"id":5},"y":"junk","z":{"id":"a","items":[]}}')
    assert_equal [], @c.runs_state['runs']
    @model.set_attribute('CabinetCraft_Project', 'runs', 'not json')
    assert_equal [], @c.runs_state['runs']
  end
end

class TestCornerLayoutScene < Minitest::Test
  D = 560.0

  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
    @c = CabinetCraft::Interface::Controller.new
    @model = Sketchup.active_model
    @c.install_example('l_shaped_corner_base')
    @c.install_example('blind_corner_base')
    @l_type = type_named('L-shaped corner base')
    @blind_type = type_named('Blind corner base')
  end

  def type_named(name)
    @c.bootstrap['library'].find { |e| e['name'] == name }['type']
  end

  def groups
    @model.entities.grep(Sketchup::Group)
  end

  def rect(g)
    b = g.bounds
    %i[x y].flat_map { |a| [b.min.send(a) * 25.4, b.max.send(a) * 25.4] }.then { |x0, x1, y0, y1| [x0.round(4), y0.round(4), x1.round(4), y1.round(4)] }
  end

  def group_for(label)
    groups.find { |g| g.name.start_with?(label + ' ') }
  end

  # World-space box [x0, y0, x1, y1] (mm) of a part: the cabinet group's transformation applied to the part's own bounds.
  def part(label, key)
    g = group_for(label)
    b = g.entities.grep(Sketchup::Group).find { |p| p.name == "#{label}-#{key}" }.bounds
    pts = [b.min.x, b.max.x].product([b.min.y, b.max.y], [b.min.z, b.max.z]).map { |x, y, z| g.transformation.apply(Geom::Point3d.new(x, y, z)) }
    [pts.map(&:x).min, pts.map(&:y).min, pts.map(&:x).max, pts.map(&:y).max].map { |v| (v * 25.4).round(4) }
  end

  def spec(kind, over = {})
    base = { 'wall_a' => 3000, 'wall_b' => 2400, 'kind' => kind, 'depth' => 560, 'clearance' => 20, 'origin' => [0, 0],
             'run_a' => [{ 'type' => 'base_single_door' }, { 'type' => 'base_drawer_3' }, { 'type' => 'base_double_door' }],
             'run_b' => [{ 'type' => 'base_single_door' }, { 'type' => 'base_double_door' }] }
    corner = case kind
             when 'blind' then { 'type' => @blind_type, 'width' => 900 }
             when 'l_shaped' then { 'type' => @l_type, 'width_a' => 900, 'width_b' => 1000 }
             else {}
             end
    base.merge('corner' => corner).merge(over)
  end

  def no_overlaps
    rects = groups.map { |g| [g.name, *rect(g)] }
    assert_empty CabinetCraft::CornerLayout.overlapping(rects), rects.inspect
  end

  def test_plan_is_pure_and_reports_each_run
    r = @c.plan_corner(spec('l_shaped'))
    assert r['ok'], r['issues'].inspect
    assert_equal [900.0, 2100.0], [r['layout']['a']['start'], r['layout']['a']['length']]
    assert_equal 3, r['run_a']['widths'].size
    assert_equal 2100.0, r['run_a']['widths'].sum
    assert_equal 1400.0, r['run_b']['widths'].sum
    assert_empty r['overlaps']
    assert_empty groups
  end

  def test_none_corner_run_a_faces_the_room_and_run_b_clears_it
    res = @c.create_corner_layout(spec('none'))
    assert res['ok']
    a = res['created']['a'].map { |c| rect(group_for(c['label'])) }
    b = res['created']['b'].map { |c| rect(group_for(c['label'])) }
    a.each { |r| assert_equal [0.0, D + 18], [r[1], r[3]] } # run A stands in front of wall A (y = 0); the 18 mm door adds to the depth
    assert_equal 0.0, a.map(&:first).min
    a.sort.each_cons(2) { |p, q| assert_in_delta p[2], q[0], 1e-3 }
    b.each { |r| assert_equal [0.0, D + 18], [r[0], r[2]] } # run B stands in front of wall B (x = 0)
    assert_equal 580.0, b.map { |r| r[1] }.min               # depth + clearance
    b.sort_by { |r| r[1] }.each_cons(2) { |p, q| assert_in_delta p[3], q[1], 1e-3 }
    no_overlaps
    assert_empty(@c.validate['issues'].select { |i| i['code'] == 'cabinets_overlap' })
  end

  def test_fronts_face_into_the_room
    res = @c.create_corner_layout(spec('none'))
    la = res['created']['a'].first['label']
    lb = res['created']['b'].first['label']
    door_a = part(la, 'DOOR_1')
    door_b = part(lb, 'DOOR_1')
    assert_in_delta D, door_a[1], 1e-3 # door in front of run A: it starts at y = depth
    assert_in_delta D, door_b[0], 1e-3 # door in front of run B: it starts at x = depth
    assert_operator part(la, 'BACK')[3], :<=, 20 # back panel against the wall (y near 0, set back a little)
    assert_operator part(lb, 'BACK')[2], :<=, 20 # back panel against the wall (x near 0)
  end

  def test_l_shaped_corner_fills_the_corner_and_runs_start_after_its_arms
    res = @c.create_corner_layout(spec('l_shaped'))
    corner = rect(group_for(res['created']['corner']['label']))
    assert_equal [0.0, 0.0, 900.0, 1000.0], corner
    a = res['created']['a'].map { |c| rect(group_for(c['label'])) }
    b = res['created']['b'].map { |c| rect(group_for(c['label'])) }
    assert_equal 900.0, a.map(&:first).min
    assert_equal 1000.0, b.map { |r| r[1] }.min
    assert_in_delta 3000, a.map { |r| r[2] }.max, 1e-3
    assert_in_delta 2400, b.map { |r| r[3] }.max, 1e-3
    no_overlaps
  end

  def test_blind_corner_turns_its_blind_panel_towards_the_corner
    res = @c.create_corner_layout(spec('blind'))
    label = res['created']['corner']['label']
    assert_equal [0.0, 0.0, 900.0, D + 18], rect(group_for(label))
    blind = part(label, 'BLIND_PANEL')
    door = part(label, 'DOOR')
    assert_in_delta 350, blind[2], 1e-3 # the blind panel is at the wall-B end (x from 0 to 350)
    assert_in_delta 0, blind[0], 1e-3
    assert_operator door[0], :>=, 350 - 1e-3
    assert_equal 900.0, rect(group_for(res['created']['a'].first['label']))[0]
    assert_equal 580.0, res['created']['b'].map { |c| rect(group_for(c['label']))[1] }.min # clear of the blind cabinet's 578 mm front
    no_overlaps
  end

  def test_layout_is_one_undo_step_and_remembered
    n = @model.instance_variable_get(:@ops).count { |o| o.first == :start }
    res = @c.create_corner_layout(spec('l_shaped'))
    assert_equal n + 1, @model.instance_variable_get(:@ops).count { |o| o.first == :start }
    lay = @c.layouts_state['layouts'].first
    assert_equal ['L01', 'l_shaped', 3000.0, 2400.0, true], [lay['name'], lay['kind'], lay['wall_a'], lay['wall_b'], lay['in_sync']]
    assert_equal %w[R01 R02], @c.runs_state['runs'].map { |r| r['name'] }
    assert_equal %w[x y], @c.runs_state['runs'].map { |r| r['axis'] }
    assert_equal 6, groups.size
    assert_equal res['layout']['id'], lay['id']
    assert_equal lay['id'], CabinetCraft::Interface::Controller.new.layouts_state['layouts'].first['id']
  end

  def test_restretch_layout_resizes_both_runs_and_keeps_everything_edge_to_edge
    res = @c.create_corner_layout(spec('l_shaped'))
    id = res['layout']['id']
    r = @c.restretch_layout(id, 3600, 2700)
    assert r['updated']
    assert_equal [3600.0, 2700.0], [r['layout']['wall_a'], r['layout']['wall_b']]
    a = res['created']['a'].map { |c| rect(group_for(c['label'])) }.sort
    b = res['created']['b'].map { |c| rect(group_for(c['label'])) }.sort_by { |q| q[1] }
    assert_equal 900.0, a.first[0]
    a.each_cons(2) { |p, q| assert_in_delta p[2], q[0], 1e-3 }
    assert_in_delta 3600, a.last[2], 1e-3
    assert_equal 1000.0, b.first[1]
    b.each_cons(2) { |p, q| assert_in_delta p[3], q[1], 1e-3 }
    assert_in_delta 2700, b.last[3], 1e-3
    assert_equal [0.0, 0.0, 900.0, 1000.0], rect(group_for(res['created']['corner']['label'])) # the corner cabinet did not move
    no_overlaps
    assert @c.layouts_state['layouts'].first['in_sync']
  end

  def test_restretch_is_one_undo_step_and_a_blank_wall_keeps_the_current_length
    id = @c.create_corner_layout(spec('none'))['layout']['id']
    n = @model.instance_variable_get(:@ops).count { |o| o.first == :start }
    r = @c.restretch_layout(id, 2700, '')
    assert_equal n + 1, @model.instance_variable_get(:@ops).count { |o| o.first == :start }
    assert_equal [2700.0, 2400.0], [r['layout']['wall_a'], r['layout']['wall_b']]
  end

  def test_blind_corner_stays_against_the_wall_after_resizing_it
    res = @c.create_corner_layout(spec('blind'))
    id = res['layout']['id']
    cab = @c.list['cabinets'].find { |c| c['id'] == res['created']['corner']['id'] }
    @c.update(cab['id'], cab['params'].merge('width' => 1000))
    r = @c.restretch_layout(id)
    assert r['updated'], r.inspect
    assert_equal [0.0, 0.0, 1000.0, D + 18], rect(group_for(res['created']['corner']['label']))
    assert_equal 1000.0, res['created']['a'].map { |c| rect(group_for(c['label']))[0] }.min
    no_overlaps
  end

  def test_nothing_is_created_when_the_layout_is_invalid
    assert_raises(ArgumentError) { @c.create_corner_layout(spec('l_shaped', 'wall_a' => 800)) }             # wall shorter than the arm
    assert_raises(ArgumentError) { @c.create_corner_layout(spec('l_shaped', 'corner' => { 'type' => 'base_cabinet', 'width_a' => 900, 'width_b' => 900 })) } # no arm parameters
    assert_raises(ArgumentError) { @c.create_corner_layout(spec('blind', 'corner' => { 'width' => 900 })) }  # no corner type
    assert_raises(ArgumentError) { @c.create_corner_layout(spec('none', 'run_a' => [{ 'type' => 'nope' }])) }
    assert_raises(ArgumentError) { @c.create_corner_layout(spec('none', 'wall_b' => 500)) }                  # run B has no room
    assert_raises(ArgumentError) { @c.create_corner_layout(spec('none', 'run_a' => [{ 'type' => 'base_cabinet', 'params' => { 'material' => 'missing' } }])) }
    assert_empty groups
    assert_empty @c.layouts_state['layouts']
    assert_empty @c.runs_state['runs']
  end

  def test_a_row_that_cannot_fit_is_refused
    err = assert_raises(ArgumentError) { @c.create_corner_layout(spec('none', 'wall_a' => 800)) }
    assert_match(/too long/, err.message)
    assert_empty groups
  end

  def test_missing_corner_cabinet_blocks_the_restretch_and_unlink_keeps_the_cabinets
    res = @c.create_corner_layout(spec('l_shaped'))
    id = res['layout']['id']
    group_for(res['created']['corner']['label']).erase!
    assert_equal false, @c.layouts_state['layouts'].first['in_sync']
    assert_match(/no longer in the model/, assert_raises(ArgumentError) { @c.restretch_layout(id, 3200) }.message)
    count = groups.size
    assert_empty @c.unlink_layout(id)['layouts']
    assert_equal count, groups.size
    assert_equal 2, @c.runs_state['runs'].size
    assert_raises(ArgumentError) { @c.unlink_layout(id) }
  end

  def test_layouts_one_side_only_and_origin_default_after_existing_cabinets
    @c.create('base_cabinet', 'width' => 500)
    res = @c.create_corner_layout(spec('none', 'origin' => nil, 'run_b' => []))
    assert res['ok']
    assert_nil @c.layouts_state['layouts'].first['run_b']
    first = res['created']['a'].map { |c| rect(group_for(c['label']))[0] }.min
    assert_in_delta 500, first, 1e-3
  end

  def test_corrupt_stored_layouts_are_ignored
    @model.set_attribute('CabinetCraft_Project', 'layouts', '{"a":{"id":"x","kind":"zig"},"b":5,"c":{"id":"y","kind":"none","wall_a":"abc"}}')
    assert_equal [], @c.layouts_state['layouts']
    @model.set_attribute('CabinetCraft_Project', 'layouts', 'garbage')
    assert_equal [], @c.layouts_state['layouts']
  end

  def test_manual_overrides_ask_before_a_layout_resize_changes_them
    res = @c.create_corner_layout(spec('none', 'wall_a' => 2400)) # three cabinets of 800
    first = res['created']['a'].first['id']
    @c.set_override(first, 'bottom', 'length' => 790)
    r = @c.restretch_layout(res['layout']['id'], 2700) # 900 each: the override would change
    assert_equal [false, true], [r['updated'], r['needs_confirmation']]
    assert_operator r['affected'].size, :>=, 1
    assert_equal 2400.0, @c.layouts_state['layouts'].first['wall_a'] # nothing was changed
    assert @c.restretch_layout(res['layout']['id'], 2700, nil, 'keep')['updated']
  end
end

class TestDashboardScene < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    @c = CabinetCraft::Interface::Controller.new
    @model = Sketchup.active_model
  end

  def test_empty_model_is_not_ready_and_does_not_crash
    d = @c.dashboard_state
    assert_equal [false, 0], [d['ready'], d['project']['cabinets']]
    assert_equal ['empty'], d['checks'].map { |c| c['id'] }
  end

  def test_dashboard_figures_equal_the_figures_of_the_other_tabs
    @c.create('base_double_door', {})
    @c.create('base_drawer_3', {})
    @c.set_hardware_price('hinge_standard', 3)
    @c.save_cost_settings('margin_pct' => 30, 'labour_rate' => 25, 'labour_hours_per_cabinet' => 2)
    d = @c.dashboard_state
    nest = @c.nest
    assert_equal nest['totals']['total_sheets'], d['sheets']['total']
    assert_equal nest['totals']['utilization'], d['sheets']['utilization']
    est = @c.cost_estimate
    assert_equal est['total_cost'], d['cost']['total_cost']
    assert_equal est['selling_price'], d['cost']['selling_price']
    assert_in_delta est['total_cost'], d['cost']['segments'].sum { |s| s['value'] }, 0.02
    assert_equal @c.parts_list['rows'].size, d['project']['parts']
    assert_equal @c.validate['summary']['errors'], d['issues']['errors']
    assert_equal @c.validate['summary']['warnings'], d['issues']['warnings']
    assert_equal @c.cnc_check['errors'], d['checks'].find { |c| c['id'] == 'cnc' }['detail'].to_s[/\A(\d+) error/, 1].to_i
  end

  def test_dashboard_nests_only_once
    @c.create('base_cabinet', {}) # two materials: carcass and back
    calls = 0
    counter = Module.new { define_method(:nest) { |*a| calls += 1; super(*a) } }
    CabinetCraft::Manufacturing::Nesting.singleton_class.prepend(counter)
    @c.dashboard_state
    assert_equal 2, calls # one nesting run = one call per material
    @c.nest # outside the dashboard the memo is gone
    assert_equal 4, calls
  end

  def test_dashboard_reports_runs_and_layout_state_and_a_deleted_cabinet
    res = @c.create_run(2400, [{ 'type' => 'base_cabinet' }, { 'type' => 'base_cabinet' }, { 'type' => 'base_cabinet' }])
    d = @c.dashboard_state
    assert_equal({ 'runs' => 1, 'layouts' => 0, 'out_of_sync' => 0 }, d['layouts'])
    @model.entities.grep(Sketchup::Group).last.erase!
    d2 = @c.dashboard_state
    assert_equal 1, d2['layouts']['out_of_sync']
    assert_equal 'warn', d2['checks'].find { |c| c['id'] == 'layouts' }['status']
    assert_equal res['runs'].first['id'], @c.runs_state['runs'].first['id']
  end

  def test_a_model_error_blocks_readiness
    @c.create('base_cabinet', {})
    g = @model.entities.grep(Sketchup::Group).first
    g.entities.grep(Sketchup::Group).first.erase! # a part deleted from the model
    d = @c.dashboard_state
    assert_equal 'error', d['checks'].find { |c| c['id'] == 'model' }['status']
    refute d['ready']
    assert_operator d['issues']['errors'], :>=, 1
  end
end

class TestHardwarePortability < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    @c = CabinetCraft::Interface::Controller.new
    @model = Sketchup.active_model
  end

  def other_machine
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new # a fresh machine: no custom items, no prices
    @c2 = CabinetCraft::Interface::Controller.new
  end

  def test_custom_items_and_prices_travel_with_the_model
    h = @c.add_hardware('Brass pull', 'handle', 4.5, 'Acme')['library'].find { |i| i['name'] == 'Brass pull' }
    @c.set_hardware_price('hinge_soft_close', 3.25)
    @c.create('base_single_door', 'handle_type' => h['id'], 'hinge_type' => 'hinge_soft_close')
    other_machine
    assert_nil CabinetCraft::Hardware.find(h['id'])
    @c2.bootstrap # opening the model on the other machine
    st = @c2.hardware_state
    assert_equal 'Brass pull', CabinetCraft::Hardware.find(h['id']).name
    assert_equal 3.25, CabinetCraft::Hardware.price_of('hinge_soft_close')
    est = @c2.cost_estimate
    refute(est['warnings'].any? { |w| w =~ /Unknown hardware/ })
    assert(@c2.list['cabinets'].any?)
    assert_empty @c2.validate['issues'].select { |i| i['code'] == 'hardware_config' }
    refute_nil st
  end

  def test_local_prices_win_over_the_models
    @c.set_hardware_price('hinge_standard', 9)
    @c.create('base_single_door', {})
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Hardware.config.set_price('hinge_standard', 2)
    c2 = CabinetCraft::Interface::Controller.new
    c2.bootstrap
    assert_equal 2.0, CabinetCraft::Hardware.price_of('hinge_standard')
  end

  def test_an_id_that_means_something_else_is_a_warning_not_a_silent_swap
    @c.add_hardware('Brass pull', 'handle')
    @c.create('base_single_door', {})
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Hardware.config.add_custom(name: 'Chrome knob', category: 'handle')
    c2 = CabinetCraft::Interface::Controller.new
    c2.parts_list
    msgs = c2.validate['issues'].select { |i| i['code'] == 'hardware_config' }.map { |i| i['message'] }
    assert_equal 1, msgs.size
    assert_match(/custom_1.*Brass pull.*Chrome knob/, msgs.first)
    assert_equal 'Chrome knob', CabinetCraft::Hardware.find('custom_1').name # the local item is untouched
  end

  def test_different_placement_rules_are_reported
    @c.create('base_single_door', {})
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Hardware.config.set_setting('hinge_inset', 80)
    c2 = CabinetCraft::Interface::Controller.new
    c2.parts_list
    issue = c2.validate['issues'].find { |i| i['code'] == 'hardware_config' }
    assert_match(/placement settings \(hinge_inset\)/, issue['message'])
    c2.set_hardware_setting('hinge_inset', 90) # editing here makes this machine's rules the model's
    assert_empty c2.validate['issues'].select { |i| i['code'] == 'hardware_config' }
  end

  def test_corrupt_snapshots_are_ignored
    @model.set_attribute('CabinetCraft_Project', 'hardware_snapshot', '{"custom":[{"id":"x"},{"id":"custom_1","category":"zzz","name":"n"},5,{"id":"custom_2","category":"handle","name":"ok","price":-3}],"prices":{"hinge_standard":"abc","nope":1,"dowel":-1},"settings":5}')
    @c.bootstrap
    assert_equal ['ok'], CabinetCraft::Hardware.config.custom_items.map(&:name) # only the valid entry, with its bad price dropped
    assert_nil CabinetCraft::Hardware.config.custom_items.first.price
    assert_nil CabinetCraft::Hardware.price_of('dowel')
    @model.set_attribute('CabinetCraft_Project', 'hardware_snapshot', 'garbage')
    assert_equal({ 'cabinets' => [] }, @c.list.slice('cabinets').tap { @c.bootstrap }) # garbage never breaks opening the model
  end
end

class TestNestingRouterMatch < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::MachiningConfig.current = CabinetCraft::MachiningConfig.new
    @c = CabinetCraft::Interface::Controller.new
    @c.create('base_double_door', {})
    @c.create('base_drawer_3', {})
  end

  def kerf_errors
    @c.cnc_check['issues'].select { |i| i['code'] == 'cnc_kerf_too_small' }
  end

  def test_a_new_project_fails_the_router_check_and_one_call_fixes_it
    assert_operator kerf_errors.size, :>, 0
    r = @c.match_nesting_to_router
    assert_equal 8.0, r['matched_router']
    assert_equal [4.0, 4.0, 10.0], r['settings'].values_at('kerf', 'spacing', 'trim') # gap = kerf + spacing = router diameter
    assert_empty kerf_errors
    assert @c.cnc_check['exportable']
    refute(@c.cnc_check['issues'].any? { |i| i['code'] == 'cnc_outside_sheet' })
  end

  def test_it_only_widens_and_is_idempotent
    @c.nest('kerf' => 6, 'spacing' => 5, 'trim' => 20)
    before = @c.nest['settings'].values_at('kerf', 'spacing', 'trim')
    assert_equal before, @c.match_nesting_to_router['settings'].values_at('kerf', 'spacing', 'trim')
    a = @c.match_nesting_to_router['settings']
    assert_equal a, @c.match_nesting_to_router['settings']
  end

  def test_a_trim_smaller_than_the_router_radius_is_raised
    @c.nest('kerf' => 4, 'spacing' => 4, 'trim' => 1)
    assert_equal 4.0, @c.match_nesting_to_router['settings']['trim']
  end

  def test_the_dashboard_readiness_improves_after_matching
    before = @c.dashboard_state['checks'].find { |k| k['id'] == 'cnc' }['status']
    @c.match_nesting_to_router
    after = @c.dashboard_state['checks'].find { |k| k['id'] == 'cnc' }['status']
    assert_equal 'error', before
    refute_equal 'error', after
  end
end

class TestCuttingListUsesNesting < Minitest::Test
  def setup
    Sketchup.reset_model!
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    @c = CabinetCraft::Interface::Controller.new
    4.times { @c.create('base_double_door', {}) }
  end

  def test_sheet_counts_equal_the_nesting
    list = @c.cutting_list
    nest = @c.nest
    list['materials'].each do |m|
      n = nest['materials'].find { |x| x['material'] == m['material'] }
      assert_equal n['total_sheets'], m['estimated_sheets'], m['material']
      assert_equal 'nested', m['sheet_basis']
      assert_operator m['area_estimate_sheets'], :>=, 1
    end
    assert_match(/current nesting/, list['estimate_note'])
  end

  def test_nesting_settings_change_the_cutting_list_count
    before = @c.cutting_list['materials'].find { |m| m['material'] == '18mm MDF' }['estimated_sheets']
    @c.nest('kerf' => 10, 'trim' => 50, 'spacing' => 50)
    after = @c.cutting_list['materials'].find { |m| m['material'] == '18mm MDF' }['estimated_sheets']
    assert_operator after, :>, before
  end

  def test_cost_and_reports_agree_on_sheets
    @c.set_hardware_price('hinge_standard', 1)
    CabinetCraft::Material.config.save('id' => 'mdf_18', 'price' => 50)
    est = @c.cost_estimate
    sheets = @c.cutting_list['materials'].find { |m| m['material'] == '18mm MDF' }
    assert_equal sheets['estimated_sheets'], est['materials'].find { |m| m['material'] == '18mm MDF' }['sheets']
    assert_equal (sheets['estimated_sheets'] * 50.0).round(2), sheets['estimated_cost']
  end

  def test_the_pdf_says_where_the_sheet_count_comes_from
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'c.pdf')
      @c.export('cutting_list', 'pdf', path)
      bytes = File.binread(path)
      assert_includes bytes, 'from the nesting'.b
      refute_includes bytes, 'about 1 sheet'.b
    end
  end

  def test_empty_project_still_works
    Sketchup.reset_model!
    e = CabinetCraft::Interface::Controller.new.cutting_list
    assert_equal 0, e['part_count']
  end
end
