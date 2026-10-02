# frozen_string_literal: true

require_relative 'test_helper'

class TestPhase2 < Minitest::Test
  include TestParams
  R = CabinetCraft::Rules

  def by_key(ov)
    panels_for(ov).to_h { |p| [p.key, p] }
  end

  def dims(p)
    [p.length, p.width, p.thickness]
  end

  # --- Doors -------------------------------------------------------------------
  def test_door_height_717_for_720_cabinet_matches_brief
    ps = by_key('height' => 720, 'door_count' => 1)
    assert_equal [717, 597, 18], dims(ps['door_1'])
    assert_in_delta 1.5, ps['door_1'].origin[2], 1e-9
    assert_in_delta(-18, ps['door_1'].origin[1], 1e-9) # sits in front of the carcass
  end

  def test_two_doors_are_adjacent_with_gap_and_symmetric_reveals
    ps = by_key('width' => 800, 'door_count' => 2)
    a = ps['door_1']
    b = ps['door_2']
    assert_in_delta 1.5, a.origin[0], 1e-9
    assert_in_delta 3.0, b.origin[0] - a.max_corner[0], 1e-9
    assert_in_delta 1.5, 800 - b.max_corner[0], 1e-9
  end

  def test_door_follows_height_and_toe_kick
    ps = by_key('height' => 820, 'toe_kick_height' => 100, 'door_count' => 1)
    assert_equal [717, 597, 18], dims(ps['door_1'])
    assert_in_delta 101.5, ps['door_1'].origin[2], 1e-9
    assert_in_delta 818.5, ps['door_1'].max_corner[2], 1e-9
  end

  # --- Toe kick ----------------------------------------------------------------
  def test_toe_kick_raises_carcass_and_total_height_stays_h
    r = calc('height' => 820, 'toe_kick_height' => 100)
    assert r.ok?
    assert_empty r.warnings
    assert_in_delta 720, r.values['carcass_height'], 1e-9
    assert_in_delta 702, r.values['side_height'], 1e-9
    ps = by_key('height' => 820, 'toe_kick_height' => 100)
    assert_in_delta 100, ps['bottom'].origin[2], 1e-9
    assert_equal [600, 100, 18], dims(ps['toe_kick']) # length x width x thickness
    assert_in_delta 50, ps['toe_kick'].origin[1], 1e-9
    assert_in_delta 820, panels_for('height' => 820, 'toe_kick_height' => 100, 'door_count' => 0).map { |p| p.max_corner[2] }.max, 1e-9
  end

  def test_no_toe_kick_panel_when_zero
    refute by_key({}).key?('toe_kick')
  end

  def test_toe_kick_setback_too_deep_is_error
    refute calc('toe_kick_height' => 100, 'toe_kick_depth' => 150, 'depth' => 160).ok?
  end

  # --- Dividers ------------------------------------------------------------------
  def test_divider_compartment_width_formula
    r = calc('width' => 900, 'divider_count' => 1, 'door_count' => 0)
    assert_in_delta((864 - 18) / 2.0, r.values['compartment_width'], 1e-9) # 423
    r = calc('width' => 1200, 'divider_count' => 2, 'door_count' => 0)
    assert_in_delta((1164 - 36) / 3.0, r.values['compartment_width'], 1e-9)
  end

  def test_dividers_and_shelves_per_compartment
    ps = panels_for('width' => 900, 'divider_count' => 2, 'shelf_count' => 2, 'door_count' => 0)
    assert_equal 2, ps.count { |p| p.role == :divider }
    assert_equal 6, ps.count { |p| p.role == :shelf }
    shelf = ps.find { |p| p.role == :shelf }
    assert_in_delta((864 - 36) / 3.0, shelf.width, 1e-6)
    div = ps.find { |p| p.role == :divider }
    assert_in_delta 721, div.length, 1e-6 # 739 side - 18 (under the rails)
  end

  def test_too_many_dividers_is_error
    refute calc('width' => 300, 'divider_count' => 4, 'door_count' => 0).ok?
  end

  # --- Drawers -------------------------------------------------------------------
  def test_three_drawers_fill_height_equally
    r = calc('height' => 820, 'toe_kick_height' => 100, 'door_count' => 0, 'drawer_count' => 3, 'shelf_count' => 0)
    assert r.ok?, r.errors.map(&:message).join
    fronts = r.values['drawer_fronts']
    assert_equal 3, fronts.size
    fronts.each { |f| assert_in_delta 237, f['height'], 1e-9 } # (720 - 3 - 2*3) / 3
    assert_in_delta 3, fronts[0]['z'] - (fronts[1]['z'] + fronts[1]['height']), 1e-9 # 3mm gap
    assert_in_delta 818.5, fronts[0]['z'] + fronts[0]['height'], 1e-9
    assert_in_delta 101.5, fronts[2]['z'], 1e-9
  end

  def test_drawer_box_rules
    ps = by_key('depth' => 562, 'width' => 600, 'height' => 820, 'toe_kick_height' => 100, 'door_count' => 0,
                'drawer_count' => 3, 'shelf_count' => 0)
    # box width = internal 564 - 2*13 runner clearance; depth = floor((549-10)/50)*50 = 500
    assert_equal [538, 500, 3], dims(ps['drawer_1_bottom'])
    assert_equal 16, ps['drawer_1_side_left'].thickness
    assert_equal 500, ps['drawer_1_side_left'].length
    assert_equal 538 - 32, ps['drawer_1_box_front'].length
    assert_equal :length, ps['drawer_1_side_left'].grain
  end

  def test_drawer_over_door_layout
    r = calc('width' => 800, 'height' => 820, 'toe_kick_height' => 100, 'door_count' => 2, 'drawer_count' => 1,
             'drawer_front_height' => 180)
    assert r.ok?, r.errors.map(&:message).join
    # carcass 720: 1.5 + door + 3 + 180 + 1.5 = 720
    assert_in_delta 720 - 3 - 3 - 180, r.values['door_height'], 1e-9
    ps = by_key('width' => 800, 'height' => 820, 'toe_kick_height' => 100, 'door_count' => 2, 'drawer_count' => 1)
    assert ps.key?('zone_shelf')
    assert_in_delta 11.5, ps['drawer_1_bottom'].origin[2] - ps['zone_shelf'].max_corner[2], 1e-9 # half gap + box lift
  end

  def test_shelves_ignored_with_warning_when_drawers_fill_cabinet
    r = calc('door_count' => 0, 'drawer_count' => 2, 'shelf_count' => 2, 'divider_count' => 1)
    assert r.ok?
    assert_equal 0, r.values['shelf_count']
    assert_equal 2, r.warnings.count { |w| w.message.include?('ignored') }
    assert(panels_for('door_count' => 0, 'drawer_count' => 2, 'shelf_count' => 2).none? { |p| p.role == :shelf })
  end

  def test_lowest_drawer_box_clears_bottom_panel
    r = calc('door_count' => 0, 'drawer_count' => 1, 'shelf_count' => 0)
    assert_operator r.values['drawer_boxes'][0]['z'], :>=, 18 + 10
  end

  def test_shallow_cabinet_cannot_have_drawers
    refute calc('depth' => 250, 'door_count' => 0, 'drawer_count' => 1, 'shelf_count' => 0).ok?
  end

  def test_front_material_thickness_drives_doors
    ps = by_key('front_material' => 'mdf_16')
    assert_equal 16, ps['door_1'].thickness
    assert_in_delta(-16, ps['door_1'].origin[1], 1e-9)
  end

  # --- Whole-matrix invariants -----------------------------------------------------
  def test_every_valid_combination_is_collision_free_unique_and_in_bounds
    checked = 0
    [600, 800, 1200].each do |w|
      [0, 100].each do |toe|
        [0, 1, 2].each do |dividers|
          [0, 1, 2, 3].each do |doors|
            [0, 1, 3].each do |drawers|
              [0, 2].each do |shelves|
                %w[standard spec_example].each do |profile|
                  ov = { 'width' => w, 'height' => 720 + toe, 'toe_kick_height' => toe, 'divider_count' => dividers,
                         'door_count' => doors, 'drawer_count' => drawers, 'shelf_count' => shelves, 'construction' => profile }
                  pr = params(ov)
                  r = R.compute(pr)
                  next unless r.ok?

                  checked += 1
                  panels = CabinetCraft::Generators::PanelGenerator.generate(pr, r.values)
                  keys = panels.map(&:key)
                  assert_equal keys.uniq, keys, "duplicate keys #{ov}"
                  panels.combination(2).each do |a, b|
                    next if a.grooved_into.include?(b.key) || b.grooved_into.include?(a.key)

                    refute a.overlaps?(b, 0.01), "#{a.key} overlaps #{b.key} for #{ov}" # values are rounded to 0.001 mm
                  end
                  panels.each do |p|
                    p.size.each { |s| assert_operator s, :>, 0, "#{p.key} has non-positive size #{ov}" }
                    assert_operator p.min_corner[0], :>=, -1e-6 unless p.key == 'back'
                    assert_operator p.max_corner[0], :<=, w + 1e-6
                    assert_operator p.min_corner[2], :>=, -1e-6
                    assert_operator p.max_corner[2], :<=, 720 + toe + 3 + 1e-6 # spec_example stack is 3mm taller
                  end
                end
              end
            end
          end
        end
      end
    end
    assert_operator checked, :>, 200
  end

  def test_part_ids_unique_across_complex_cabinet
    pr = params('width' => 900, 'divider_count' => 2, 'shelf_count' => 2, 'door_count' => 2, 'drawer_count' => 2,
                'height' => 820, 'toe_kick_height' => 100)
    cab = CabinetCraft::Cabinet.build(type: 'base_cabinet', params: pr, label: 'B07')
    ids = cab.part_rows.map { |r| r['part_id'] }
    assert_equal ids.uniq, ids
    assert_operator ids.size, :>, 20
  end

  def test_library_presets_are_valid
    CabinetCraft::Library::ENTRIES.each do |e|
      pr, errs = CabinetCraft::Parameter.coerce(CabinetCraft::Library.defaults_for(e['type']))
      assert_empty errs, e['type']
      r = R.compute(pr)
      assert r.ok?, "#{e['type']}: #{r.errors.map(&:message)}"
      assert_empty r.warnings, "#{e['type']}: #{r.warnings.map(&:message)}"
    end
  end
end
