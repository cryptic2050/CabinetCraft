# frozen_string_literal: true

require_relative 'test_helper'

class TestRules < Minitest::Test
  include TestParams
  R = CabinetCraft::Rules

  def dims(panel)
    [panel.length, panel.width, panel.thickness]
  end

  # --- The exact example from the product brief -------------------------------
  def test_spec_example_600x757x562
    pr = params('width' => 600, 'height' => 757, 'depth' => 562, 'construction' => 'spec_example', 'shelf_count' => 0)
    r = R.compute(pr)
    panels = CabinetCraft::Generators::PanelGenerator.generate(pr, r.values).to_h { |p| [p.key, p] }

    assert_equal [600, 562, 18], dims(panels['bottom'])
    assert_equal [742, 562, 18], dims(panels['side_left'])
    assert_equal [742, 562, 18], dims(panels['side_right'])
    assert_equal [695, 581, 3],  dims(panels['back'])
    assert_equal [564, 100, 18], dims(panels['brace_front'])
    refute panels.key?('brace_rear')
    # The brief's numbers stack to 760mm, not 757mm. The engine must say so.
    assert(r.warnings.any? { |w| w.message.include?('760') })
  end

  def test_standard_profile_is_self_consistent
    r = calc('width' => 600, 'height' => 757, 'depth' => 562)
    assert r.ok?
    assert_empty r.warnings
    assert_in_delta 757, r.values['stack_height'], 1e-9
    assert_in_delta 739, r.values['side_height'], 1e-9
  end

  def test_shelf_example_from_brief
    # 564 x 520 shelf for a 560 deep cabinet with 18mm sides.
    r = calc('width' => 600, 'depth' => 560)
    assert_in_delta 564, r.values['shelf_width'], 1e-9
    assert_in_delta 520, r.values['shelf_depth'], 1e-9
  end

  # --- Matrix: widths x thicknesses ---------------------------------------------
  def test_internal_width_follows_width_and_thickness
    { 'mdf_18' => 18, 'mdf_16' => 16, 'ply_15' => 15 }.each do |mat, t|
      [600, 800, 900, 1200].each do |w|
        r = calc('width' => w, 'material' => mat)
        assert r.ok?, "#{w}/#{mat}: #{r.errors.map(&:message)}"
        assert_equal t, r.values['thickness']
        assert_in_delta w - 2 * t, r.values['internal_width'], 1e-9
        assert_in_delta r.values['internal_width'], r.values['brace_width'], 1e-9
        assert_in_delta r.values['internal_width'] + 2 * 8, r.values['back_width'], 1e-9
      end
    end
  end

  # --- Doors ----------------------------------------------------------------------
  def test_door_widths_for_1_2_3_doors
    { 1 => 1, 2 => 2, 3 => 3 }.each do |count, _|
      [600, 800, 900, 1200].each do |w|
        r = calc('width' => w, 'door_count' => count, 'door_reveal' => 1.5, 'door_gap' => 3)
        widths = r.values['door_widths']
        assert_equal count, widths.size
        total = widths.sum + 2 * 1.5 + (count - 1) * 3
        assert_in_delta w, total, 0.002, "#{count} doors on #{w}" # widths are rounded to 0.001 mm
      end
    end
    assert_equal [597.0], calc('width' => 600, 'door_count' => 1).values['door_widths']
    assert_equal [297.0, 297.0], calc('width' => 600, 'door_count' => 2).values['door_widths']
  end

  def test_door_reveal_is_parametric_not_hard_coded
    assert_equal [595.0], calc('width' => 600, 'door_count' => 1, 'door_reveal' => 2.5).values['door_widths']
    assert_equal [], calc('door_count' => 0).values['door_widths']
  end

  # --- Shelves --------------------------------------------------------------------
  def test_shelf_counts
    [0, 1, 2, 4].each do |n|
      pr = params('shelf_count' => n)
      r = R.compute(pr)
      assert r.ok?, r.errors.map(&:message).join
      shelves = CabinetCraft::Generators::PanelGenerator.generate(pr, r.values).select { |p| p.role == :shelf }
      assert_equal n, shelves.size
      # openings are equal: bottom/shelf/shelf/top spacing
      next if n.zero?

      zs = shelves.map { |s| s.origin[2] }
      t = r.values['thickness']
      gaps = [zs.first - t] + zs.each_cons(2).map { |a, b| b - a - t }
      gaps.each { |g| assert_in_delta r.values['shelf_gap'], g, 1e-6 }
    end
  end

  def test_too_many_shelves_is_an_error
    r = calc('height' => 300, 'shelf_count' => 10)
    refute r.ok?
    assert(r.errors.any? { |e| e.key == 'shelf_count' })
  end

  # --- Back panel thickness --------------------------------------------------------
  def test_back_thickness_variants
    [3, 6, 9, 12].each do |bt|
      pr = params('back_thickness' => bt)
      r = R.compute(pr)
      assert r.ok?
      back = CabinetCraft::Generators::PanelGenerator.generate(pr, r.values).find { |p| p.key == 'back' }
      assert_equal bt, back.thickness
    end
    thick = panels_for('back_thickness' => 18)
    back = thick.find { |p| p.key == 'back' }
    shelf = thick.find { |p| p.key == 'shelf_1' }
    refute back.overlaps?(shelf)
  end

  # --- Invalid input ------------------------------------------------------------------
  def test_too_narrow_cabinet_is_an_error
    r = calc('width' => 150, 'material' => 'ply_18')
    assert r.ok? # 114mm internal is valid
    pr = params('width' => 150)
    pr['width'] = 30.0
    refute R.compute(pr).ok?
  end

  # --- Geometry invariants over the whole matrix ------------------------------------------
  def test_panels_never_overlap_and_stay_in_bounds
    [600, 800, 900, 1200].each do |w|
      %w[mdf_18 mdf_16 ply_15].each do |mat|
        [0, 1, 2, 4].each do |shelves|
          %w[standard spec_example].each do |profile|
            [3, 6].each do |bt|
              ov = { 'width' => w, 'material' => mat, 'shelf_count' => shelves, 'construction' => profile, 'back_thickness' => bt }
              pr = params(ov)
              r = R.compute(pr)
              assert r.ok?, "#{ov}: #{r.errors.map(&:message)}"
              panels = CabinetCraft::Generators::PanelGenerator.generate(pr, r.values)
              panels.combination(2).each do |a, b|
                next if a.grooved_into.include?(b.key) || b.grooved_into.include?(a.key)

                refute a.overlaps?(b), "#{a.key} overlaps #{b.key} for #{ov}"
              end
              panels.each do |p|
                assert_operator p.min_corner[0], :>=, -1e-6 if p.key != 'back'
                assert_operator p.max_corner[0], :<=, w + 1e-6
                assert_operator p.min_corner[1], :>=, -1e-6 unless %i[door drawer_front].include?(p.role)
                assert_operator p.max_corner[1], :<=, pr['depth'] + 1e-6
                assert_operator p.min_corner[2], :>=, -1e-6
              end
            end
          end
        end
      end
    end
  end

  def test_grain_follows_panel_orientation
    ps = panels_for.to_h { |p| [p.key, p] }
    assert_equal :length, ps['side_left'].grain  # vertical grain along the 739mm length
    assert_equal :length, ps['bottom'].grain
    assert_equal :none,   ps['back'].grain
  end

  def test_same_inputs_same_outputs
    assert_equal calc.values, calc.values
  end
end
