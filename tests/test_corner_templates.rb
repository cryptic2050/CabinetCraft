# frozen_string_literal: true

require_relative 'test_helper'

class TestCornerTemplates < Minitest::Test
  T = CabinetCraft::Templates::Template
  Ex = CabinetCraft::Templates::Examples

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Standards.current = CabinetCraft::Standards.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
  end

  def tpl(const)
    T.from_h(JSON.parse(JSON.generate(const)), id: 'tpl_x')
  end

  def build(t, over = {})
    p, errors = CabinetCraft::Parameter.coerce(t.defaults.merge(over), t.schema)
    raise "bad params #{errors}" unless errors.empty?

    t.build(p)
  end

  def l
    @l ||= tpl(Ex::L_SHAPED_CORNER_BASE)
  end

  def blind
    @blind ||= tpl(Ex::BLIND_CORNER_BASE)
  end

  def no_overlaps(panels)
    panels.combination(2).each { |a, b| refute a.overlaps?(b), "#{a.key} overlaps #{b.key}" }
  end

  def test_both_examples_are_valid_templates_with_defaults_that_build
    [l, blind].each do |t|
      b = build(t)
      assert b.result.ok?, b.result.issues.map(&:message).inspect
      assert_operator b.panels.size, :>=, 6
    end
    assert_equal 'CORNER', l.category
  end

  def test_examples_are_installable_through_the_registry
    assert Ex::ALL.key?('l_shaped_corner_base')
    assert Ex::ALL.key?('blind_corner_base')
    Ex::ALL.each_value { |raw| CabinetCraft::Templates.config.save_template(raw) }
  end

  def test_l_shaped_panels_never_overlap_and_stay_inside_the_footprint
    panels = build(l).panels
    no_overlaps(panels)
    panels.each do |p|
      lo = p.min_corner
      hi = p.max_corner
      assert_operator lo[0], :>=, -1e-9
      assert_operator lo[1], :>=, -1e-9
      assert hi[0] <= 900 + 1e-9 || p.key == 'door_a', p.key
    end
    hi = panels.map(&:max_corner)
    assert_in_delta 900, hi.map { |h| h[0] }.max, 1e-9 # arm A length along x
    assert_in_delta 900, hi.map { |h| h[1] }.max, 1e-9 # arm B length along y
  end

  def test_l_shaped_footprint_is_an_l_not_a_square
    # nothing at all may sit in the notch: x > depth and y > depth (front of both arms is the notch)
    panels = build(l, 'depth' => 560).panels
    panels.each do |p|
      next if p.key.start_with?('door')

      in_notch = p.min_corner[0] >= 560 - 1e-9 && p.min_corner[1] >= 560 - 1e-9
      refute in_notch, "#{p.key} is inside the notch"
    end
  end

  def test_l_shaped_door_sizes_and_hardware
    b = build(l, 'width_a' => 1000, 'width_b' => 900, 'depth' => 560, 'height' => 720)
    assert b.result.ok?, b.result.issues.map(&:message).inspect
    v = b.result.values
    assert_equal [440, 900 - 560 - 18, 716], [v['door_a_w'], v['door_b_w'], v['door_h']]
    da = b.panels.find { |p| p.key == 'door_a' }
    db = b.panels.find { |p| p.key == 'door_b' }
    assert_equal [440.0, 18.0, 716.0], da.size # x = width, y = thickness, z = height
    assert_equal [18.0, 322.0, 716.0], db.size
    hinges = b.hardware.select { |h| h['name'] =~ /hinge/i }.sum { |h| h['qty'] }
    assert_equal 4, hinges
    assert_equal 6, build(l, 'height' => 1000).hardware.select { |h| h['name'] =~ /hinge/i }.sum { |h| h['qty'] }
  end

  def test_l_shaped_rejects_arms_too_short_for_a_door
    r = build(l, 'width_a' => 600, 'depth' => 700).result
    refute r.ok?
    assert_match(/Arm A is too short/, r.issues.map(&:message).join)
    assert_match(/Arm B is too short/, build(l, 'width_b' => 600, 'depth' => 700).result.issues.map(&:message).join)
  end

  def test_blind_panels_and_door_cover_the_front_without_overlap
    panels = build(blind).panels
    no_overlaps(panels)
    door = panels.find { |p| p.key == 'door' }
    panel = panels.find { |p| p.key == 'blind_panel' }
    assert_in_delta 900 - 350 - 3, door.size[0], 1e-9
    assert_in_delta 350, panel.size[0], 1e-9
    assert door.max_corner[0] <= panel.min_corner[0] + 1e-9 # blind on the right: door left of the panel
    assert_in_delta 900, panel.max_corner[0], 1e-9
  end

  def test_blind_left_is_the_mirror_image
    r = build(blind, 'blind_right' => 1).panels
    left = build(blind, 'blind_right' => 0).panels
    dr = r.find { |p| p.key == 'door' }
    dl = left.find { |p| p.key == 'door' }
    pl = left.find { |p| p.key == 'blind_panel' }
    assert_in_delta 0, pl.min_corner[0], 1e-9
    assert_operator dl.min_corner[0], :>=, pl.max_corner[0] - 1e-9
    assert_in_delta dr.size[0], dl.size[0], 1e-9
    no_overlaps(left)
  end

  def test_blind_rejects_a_door_that_would_be_too_narrow_and_warns_about_a_wide_blind
    refute build(blind, 'width' => 600, 'blind' => 400).result.ok?
    r = build(blind, 'width' => 1000, 'blind' => 520).result
    assert r.ok?
    assert(r.issues.any? { |i| i.severity == :warning })
  end

  def test_corner_cabinets_flow_through_parts_cutting_and_assembly
    [l, blind].each_with_index do |t, i|
      cfg = CabinetCraft::Templates.config.save_template(JSON.parse(JSON.generate(t == l ? Ex::L_SHAPED_CORNER_BASE : Ex::BLIND_CORNER_BASE)))
      p, = CabinetCraft::Parameter.coerce(cfg.defaults, cfg.schema)
      cab = CabinetCraft::Cabinet.build(type: cfg.id, params: p, label: "B0#{i + 1}")
      assert cab.calculation.ok?
      rows = CabinetCraft::Manufacturing::PartsList.build([cab])
      assert_equal cab.panels.size, rows.size
      assert_equal cab.panels.size, CabinetCraft::Manufacturing::Assembly.steps(cab).sum { |s| s['parts'].size }
      assert_operator CabinetCraft::Manufacturing::CuttingList.build([cab])['part_count'], :==, cab.panels.size
    end
  end
end
