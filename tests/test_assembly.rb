# frozen_string_literal: true

require_relative 'test_helper'

class TestAssembly < Minitest::Test
  include TestParams
  A = CabinetCraft::Manufacturing::Assembly

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
  end

  def cab(ov = {})
    CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(ov), label: 'B01')
  end

  def full
    cab('door_count' => 2, 'drawer_count' => 2, 'height' => 820, 'shelf_count' => 1)
  end

  def test_every_part_is_in_exactly_one_step
    c = full
    ids = A.steps(c).flat_map { |s| s['parts'] }
    assert_equal c.panels.map { |p| c.part_id(p) }.sort, ids.sort
    assert_equal ids.uniq, ids
  end

  def test_steps_are_numbered_ordered_and_carcass_comes_before_fronts
    titles = A.steps(full).map { |s| s['title'] }
    assert_equal (1..titles.size).to_a, A.steps(full).map { |s| s['n'] }
    assert_operator titles.index('Join bottom and sides'), :<, titles.index('Fit the back panel')
    assert_operator titles.index('Fit the back panel'), :<, titles.index('Fit the doors')
    assert_equal 'Fit loose hardware and check', titles.last
    assert_equal 2, titles.count { |t| t.start_with?('Build drawer box') }
  end

  def test_hardware_quantities_in_steps_match_the_hardware_list
    c = full
    from_steps = A.steps(c).flat_map { |s| s['hardware'] }.group_by { |h| h['name'] }.transform_values { |l| l.sum { |h| h['qty'] } }
    from_list = c.hardware.group_by { |h| h['name'] }.transform_values { |l| l.sum { |h| h['qty'] } }
    assert_equal from_list, from_steps
  end

  def test_unknown_roles_get_a_generic_step_not_silence
    t = CabinetCraft::Templates.config.save_template(CabinetCraft::Templates::Examples::OPEN_SHELF_UNIT)
    p, = CabinetCraft::Parameter.coerce(t.defaults, t.schema)
    c = CabinetCraft::Cabinet.build(type: t.id, params: p, label: 'B01')
    steps = A.steps(c)
    assert_equal c.panels.size, steps.sum { |s| s['parts'].size }
  end

  def test_no_steps_when_the_cabinet_has_errors
    assert_empty A.steps(cab('material' => 'nope'))
  end

  def test_zero_amount_is_assembled_and_offsets_scale_linearly
    c = full
    assert(A.explode_offsets(c, 0).values.all? { |v| v.all?(&:zero?) })
    a = A.explode_offsets(c, 100)
    b = A.explode_offsets(c, 200)
    a.each { |k, v| assert_equal v.map { |n| n * 2 }, b[k], k }
    assert_equal [-100, 0, 0], a['side_left']
    assert_equal [100, 0, 0], a['side_right']
    assert_operator a['door_1'][1], :<, 0 # fronts move toward the viewer
    assert_operator a['back'][1], :>, 0
  end

  def test_exploded_parts_do_not_overlap_each_other
    c = full
    off = A.explode_offsets(c, A.default_amount(c))
    moved = c.panels.map { |p| p.with(origin: p.origin.zip(off[p.key]).map { |a, b| a + b }) }
    moved.combination(2).each do |a, b|
      next if a.key.start_with?('drawer_') && b.key.start_with?('drawer_') # drawer boxes keep their own internal fit
      next if a.grooved_into.include?(b.key) || b.grooved_into.include?(a.key)

      refute a.overlaps?(b), "#{a.key} overlaps #{b.key} when exploded"
    end
  end

  def test_view_geometry_projects_and_numbers_every_part
    c = full
    v = A.view(c, amount: 0)
    assert_equal c.panels.size, v['boxes'].size
    assert_equal (1..c.panels.size).to_a, v['boxes'].map { |b| b['seq'] }
    x0, y0, x1, y1 = v['bounds']
    v['boxes'].flat_map { |b| b['faces'].flat_map { |f| f['points'] } }.each do |x, y|
      assert x.between?(x0 - 1e-6, x1 + 1e-6) && y.between?(y0 - 1e-6, y1 + 1e-6)
    end
    # the front face of the left side is its true shape: width = thickness, height = side height
    side = v['boxes'].find { |b| b['key'] == 'side_left' }['faces'].find { |f| f['kind'] == 'front' }['points']
    assert_in_delta c.panels.find { |p| p.key == 'side_left' }.size[0], side[1][0] - side[0][0], 1e-6
    wide = A.view(c, amount: 200)['bounds']
    assert_operator wide[2] - wide[0], :>, x1 - x0
  end

  def test_describe_numbers_match_between_views_and_parts_table
    d = A.describe(full)
    assert_equal d['exploded']['boxes'].to_h { |b| [b['part_id'], b['seq']] }, d['assembled']['boxes'].to_h { |b| [b['part_id'], b['seq']] }
    assert_equal d['parts'].map { |p| p['seq'] }, (1..d['parts'].size).to_a
    assert_match(/\A\d+ x \d+ x \d+(\.\d)?/, d['parts'].first['size'])
  end

  def test_svg_and_pdf_render
    d = A.describe(full)
    svg = CabinetCraft::Exporters::AssemblySvg.svg(d['exploded'])
    assert_equal d['parts'].size, svg.scan('<g data-part=').size
    assert svg.start_with?('<svg')
    item = { 'label' => 'B01', 'type_name' => 'Base', 'dims' => '600 x 820 x 562 mm', 'steps' => d['steps'], 'parts' => d['parts'], 'assembled' => d['assembled'], 'exploded' => d['exploded'] }
    pdf = CabinetCraft::Exporters::PdfReports.assembly([item, item], project: 'P')
    assert pdf.start_with?('%PDF-1.4'.b)
    assert_includes pdf, 'Assembly instructions'.b
    assert_includes pdf, 'Join bottom and sides'.b
    assert_operator pdf.scan('/Type /Page ').size, :>=, 2
  end
end
