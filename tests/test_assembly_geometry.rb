# frozen_string_literal: true

require_relative 'test_helper'

class TestAssemblyGeometry < Minitest::Test
  include TestParams
  A = CabinetCraft::Manufacturing::Assembly
  K = A::K
  CA = Math.cos(A::ANGLE)
  SA = Math.sin(A::ANGLE)

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
  end

  def builtin(ov = {})
    CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(ov), label: 'B01')
  end

  def from_template(raw, over = {})
    t = CabinetCraft::Templates.config.save_template(JSON.parse(JSON.generate(raw)))
    p, = CabinetCraft::Parameter.coerce(t.defaults.merge(over), t.schema)
    CabinetCraft::Cabinet.build(type: t.id, params: p, label: 'B01')
  end

  def all_cabinets
    ex = CabinetCraft::Templates::Examples
    @all_cabinets ||= [builtin, builtin('door_count' => 2, 'drawer_count' => 2, 'height' => 820, 'shelf_count' => 2), builtin('door_count' => 0, 'drawer_count' => 3, 'height' => 820),
     builtin('width' => 1000, 'door_count' => 2, 'divider_count' => 1, 'shelf_count' => 1)] + ex::ALL.values.map { |raw| from_template(raw) }
  end

  # Boxes (with the offsets applied) in the order the view draws them.
  def drawn(cab, amount)
    off = A.explode_offsets(cab, amount)
    A.draw_order(cab.panels, off).map do |p|
      o = off[p.key]
      { key: p.key, lo: p.min_corner.zip(o).map(&:sum), hi: p.max_corner.zip(o).map(&:sum) }
    end
  end

  # Where the screen point (px, py) hits a box: the interval of y (depth) along the viewing ray inside it, or nil.
  def hit(box, px, py)
    ylo = box[:lo][1]
    yhi = box[:hi][1]
    # x = px - K*CA*y must lie in [lo.x, hi.x]; z = py - K*SA*y in [lo.z, hi.z]
    k1 = K * CA
    k2 = K * SA
    [[(px - box[:hi][0]) / k1, (px - box[:lo][0]) / k1], [(py - box[:hi][2]) / k2, (py - box[:lo][2]) / k2]].each do |a, b|
      ylo = [ylo, a].max
      yhi = [yhi, b].min
    end
    yhi - ylo > 1e-6 ? ylo : nil
  end

  def test_the_last_drawn_box_at_every_screen_point_is_the_one_the_viewer_sees
    rng = Random.new(5)
    bad = []
    all_cabinets.each_with_index do |cab, ci|
      [0, 80, 250].each do |amount|
        boxes = drawn(cab, amount)
        xs = boxes.flat_map { |b| [b[:lo][0], b[:hi][0]] }
        zs = boxes.flat_map { |b| [b[:lo][2], b[:hi][2]] }
        ys = boxes.flat_map { |b| [b[:lo][1], b[:hi][1]] }
        400.times do
          # a random point inside a random box, projected: guaranteed to be covered by at least that box
          b = boxes.sample(random: rng)
          pt = [rng.rand(b[:lo][0]..b[:hi][0]), rng.rand(b[:lo][1]..b[:hi][1]), rng.rand(b[:lo][2]..b[:hi][2])]
          px, py = A.project(*pt)
          hits = boxes.each_with_index.filter_map { |bx, i| (y = hit(bx, px, py)) && [i, y] }
          nearest = hits.min_by { |_, y| y }.first # smallest y = nearest to a viewer in front
          last_drawn = hits.max_by { |i, _| i }.first
          bad << [ci, amount, boxes[last_drawn][:key], boxes[nearest][:key]] unless hits.size < 2 || last_drawn == nearest || (hits.map(&:last).sort[0] - hits.map(&:last).sort[1]).abs < 1e-6
        end
        refute_nil xs.max && zs.max && ys.max
      end
    end
    assert_empty bad.first(5), "#{bad.size} sample points are painted in the wrong order, e.g. #{bad.first(3).inspect}"
  end

  def test_exploding_never_creates_an_overlap_for_any_cabinet_or_template
    [20, 80, 150, 300, 600].each do |amount|
      all_cabinets.each do |cab|
        before = A.overlapping_pairs(cab.panels)
        off = A.explode_offsets(cab, amount)
        moved = cab.panels.map { |p| p.with(origin: p.origin.zip(off[p.key]).map(&:sum)) }
        created = A.overlapping_pairs(moved) - before
        assert_empty created, "#{cab.type} at #{amount} mm: #{created.inspect}"
      end
    end
  end

  def test_amount_zero_means_assembled_and_the_draw_order_covers_every_part_once
    all_cabinets.each do |cab|
      assert(A.explode_offsets(cab, 0).values.all? { |v| v.all?(&:zero?) })
      order = A.draw_order(cab.panels, A.explode_offsets(cab, 100))
      assert_equal cab.panels.map(&:key).sort, order.map(&:key).sort
    end
  end

  def test_part_numbers_are_the_draw_order_and_stay_consistent
    cab = builtin('door_count' => 2, 'drawer_count' => 2, 'height' => 820)
    d = A.describe(cab)
    assert_equal d['exploded']['boxes'].map { |b| b['part_id'] }.sort, d['assembled']['boxes'].map { |b| b['part_id'] }.sort
    assert_equal (1..cab.panels.size).to_a, d['parts'].map { |p| p['seq'] }
  end

  def test_a_cycle_of_boxes_still_terminates
    # three boxes hiding each other in a ring cannot be ordered exactly; the sort must still return every box
    mk = lambda do |key, lo, hi|
      CabinetCraft::Panel.new(key: key, name: key, role: :panel, origin: lo, size: hi.zip(lo).map { |h, l| h - l }, thickness_axis: :x, material_id: 'm', material_label: 'm')
    end
    panels = [mk.call('a', [0, 0, 0], [10, 100, 10]), mk.call('b', [5, 50, 5], [15, 150, 15]), mk.call('c', [-5, 20, 8], [8, 120, 20])]
    order = A.draw_order(panels, {})
    assert_equal %w[a b c], order.map(&:key).sort
  end
end
