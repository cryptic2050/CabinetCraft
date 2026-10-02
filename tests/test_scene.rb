# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'mock_sketchup'
%w[generators/cabinet_generator scene/attributes scene/registry ui/controller].each do |f|
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
    res = @c.create('base_cabinet', 'width' => 600, 'height' => 757, 'depth' => 562, 'shelf_count' => 1)
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
end
