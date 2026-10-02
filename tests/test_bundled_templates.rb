# frozen_string_literal: true

require_relative 'test_helper'

class TestBundledTemplates < Minitest::Test
  Ex = CabinetCraft::Templates::Examples
  NEW = %w[wall_cabinet tall_cabinet wardrobe vanity_unit tv_base_cabinet].freeze

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Standards.current = CabinetCraft::Standards.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
    @tpl = {}
  end

  def tpl(key)
    @tpl[key] ||= CabinetCraft::Templates.config.save_template(JSON.parse(JSON.generate(Ex::ALL.fetch(key))))
  end

  def build(key, over = {})
    t = tpl(key)
    p, errors = CabinetCraft::Parameter.coerce(t.defaults.merge(over), t.schema)
    raise "bad params #{errors}" unless errors.empty?

    [t.build(p), p]
  end

  def pairs_overlapping(panels)
    panels.combination(2).select { |a, b| !(a.grooved_into.include?(b.key) || b.grooved_into.include?(a.key)) && a.overlaps?(b) }.map { |a, b| [a.key, b.key] }
  end

  def test_every_bundled_template_is_valid_and_builds_with_its_defaults
    Ex::ALL.each_key do |k|
      b, = build(k)
      assert b.result.ok?, "#{k}: #{b.result.issues.map(&:message)}"
      assert_operator b.panels.size, :>=, 6, k
      assert_empty pairs_overlapping(b.panels), "#{k} defaults overlap"
    end
  end

  def test_extremes_of_every_parameter_never_raise_and_never_produce_overlapping_or_empty_parts
    checked = 0
    Ex::ALL.each_key do |k|
      t = tpl(k)
      t.schema.select { |f| %w[length int].include?(f['type']) && f['min'] && f['max'] }.each do |f|
        [f['min'], f['max']].each do |v|
          b, = build(k, f['key'] => v)
          checked += 1
          next unless b.result.ok? # a refusal with an error message is the right answer to an impossible size

          assert_empty pairs_overlapping(b.panels), "#{k} #{f['key']}=#{v}"
          b.panels.each { |p| assert(p.size.all?(&:positive?), "#{k} #{f['key']}=#{v}: #{p.key} has a non-positive size #{p.size.inspect}") }
        end
      end
    end
    assert_operator checked, :>, 100
  end

  def test_the_refusals_come_with_a_message_not_a_crash
    b, = build('wardrobe', 'width' => 500, 'dividers' => 5)
    refute b.result.ok?
    assert_match(/narrower than 200/, b.result.issues.map(&:message).join)
    b, = build('wall_cabinet', 'width' => 200, 'doors' => 2)
    refute b.result.ok?
    assert_match(/narrower than 150/, b.result.issues.map(&:message).join)
    b, = build('tall_cabinet', 'height' => 1000, 'split' => 800, 'doors' => 2)
    refute b.result.ok?
    assert_match(/at least 300/, b.result.issues.map(&:message).join)
  end

  # Bounding box of a template's panels against its width / height / depth parameters (doors may stand proud by the front thickness).
  def test_the_parts_fill_the_stated_dimensions
    NEW.each do |k|
      [{}, { 'width' => 900 }, { 'depth' => 400 }].each do |over|
        b, p = build(k, over)
        next unless b.result.ok?

        lo = b.panels.map(&:min_corner).transpose.map(&:min)
        hi = b.panels.map(&:max_corner).transpose.map(&:max)
        toe = p['toe'].to_f
        assert_in_delta 0, lo[0], 1e-6, "#{k} left"
        assert_in_delta p['width'], hi[0], 1e-6, "#{k} width"
        assert_in_delta toe, lo[2], 1e-6, "#{k} bottom"
        assert_in_delta toe + p['height'], hi[2], 1e-6, "#{k} height"
        assert_in_delta p['depth'], hi[1], 1e-6, "#{k} depth"
        assert_operator lo[1], :>=, -19, "#{k}: fronts stand at most one board proud"
      end
    end
  end

  def test_door_and_section_counts_follow_the_parameters
    assert_equal 0, build('wall_cabinet', 'doors' => 0)[0].panels.count { |p| p.role == :door }
    assert_equal 2, build('wall_cabinet', 'doors' => 2)[0].panels.count { |p| p.role == :door }
    assert_equal 3, build('wall_cabinet', 'shelves' => 3)[0].panels.count { |p| p.role == :shelf }
    assert_equal 1, build('tall_cabinet', 'doors' => 1)[0].panels.count { |p| p.role == :door }
    assert_equal 2, build('tall_cabinet', 'doors' => 2)[0].panels.count { |p| p.role == :door }
    assert_equal 0, build('tall_cabinet', 'doors' => 0)[0].panels.count { |p| p.role == :door }
    w = build('wardrobe', 'dividers' => 2, 'shelves' => 4)[0]
    assert_equal 2, w.panels.count { |p| p.role == :divider }
    assert_equal 12, w.panels.count { |p| p.role == :shelf } # 4 shelves in each of 3 sections
    assert_equal 4, build('tv_base_cabinet', 'doors' => 4)[0].panels.count { |p| p.role == :door }
    assert_equal 2, build('tv_base_cabinet', 'dividers' => 1, 'shelf' => 1)[0].panels.count { |p| p.role == :shelf }
    assert_equal 0, build('tv_base_cabinet', 'shelf' => 0)[0].panels.count { |p| p.role == :shelf }
    assert_equal 0, build('vanity_unit', 'shelf' => 0)[0].panels.count { |p| p.role == :shelf }
  end

  def test_the_vanity_has_no_back_and_the_wardrobe_shelves_stay_inside_their_sections
    v, = build('vanity_unit')
    assert_empty v.panels.select { |p| p.role == :back }
    assert_equal 2, v.panels.count { |p| p.role == :brace }
    w, p = build('wardrobe', 'dividers' => 2, 'shelves' => 2)
    dividers = w.panels.select { |x| x.role == :divider }.sort_by { |x| x.origin[0] }
    shelves = w.panels.select { |x| x.role == :shelf }
    shelves.each do |s|
      inside = dividers.none? { |d| s.origin[0] < d.max_corner[0] - 1e-6 && s.max_corner[0] > d.origin[0] + 1e-6 }
      assert inside, "#{s.key} cuts through a divider"
      assert_operator s.max_corner[0], :<=, p['width'] - 18 + 1e-6
    end
  end

  def test_hinge_counts_follow_the_door_height
    count = ->(b) { b.hardware.select { |h| h['category'] == 'hinge' }.sum { |h| h['qty'] } }
    assert_equal 2, count.call(build('wall_cabinet', 'doors' => 1, 'height' => 600)[0])
    assert_equal 3, count.call(build('wall_cabinet', 'doors' => 1, 'height' => 1000)[0])
    assert_equal 4, count.call(build('wall_cabinet', 'doors' => 2, 'height' => 600)[0])
    tall = build('tall_cabinet', 'doors' => 1, 'height' => 2000)[0]
    assert_equal 5, count.call(tall) # a 1997 mm door
    two = build('tall_cabinet', 'doors' => 2, 'height' => 2000, 'split' => 1000)[0]
    assert_equal 6, count.call(two) # 998 and 998: three hinges each
    assert_equal 0, count.call(build('wall_cabinet', 'doors' => 0)[0])
  end

  def test_handles_follow_the_door_count
    handles = ->(b) { b.hardware.select { |h| h['category'] == 'handle' }.sum { |h| h['qty'] } }
    assert_equal 2, handles.call(build('wall_cabinet', 'doors' => 2)[0])
    assert_equal 1, handles.call(build('tall_cabinet', 'doors' => 1)[0])
    assert_equal 2, handles.call(build('tall_cabinet', 'doors' => 2)[0])
    assert_equal 0, handles.call(build('tall_cabinet', 'doors' => 0)[0])
  end

  def test_bundled_cabinets_flow_through_every_report
    NEW.each_with_index do |k, i|
      t = tpl(k)
      p, = CabinetCraft::Parameter.coerce(t.defaults, t.schema)
      cab = CabinetCraft::Cabinet.build(type: t.id, params: p, label: "B0#{i + 1}")
      assert cab.calculation.ok?
      rows = CabinetCraft::Manufacturing::PartsList.build([cab])
      assert_equal cab.panels.size, rows.size
      assert_equal cab.panels.size, CabinetCraft::Manufacturing::Assembly.steps(cab).sum { |s| s['parts'].size }
      assert_equal cab.panels.size, CabinetCraft::Manufacturing::CuttingList.build([cab])['part_count']
      assert_operator CabinetCraft::Manufacturing::Assembly.view(cab, amount: 200)['boxes'].size, :==, cab.panels.size
    end
  end
end
