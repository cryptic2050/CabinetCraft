# frozen_string_literal: true

require_relative 'test_helper'

class TestRun < Minitest::Test
  def items(n = 3)
    Array.new(n) { |i| { 'cabinet_id' => "c#{i}" } }
  end

  def test_build_applies_default_limits_and_roundtrips_through_json
    run = CabinetCraft::Run.build(name: 'R01', length: 2400, items: items)
    assert_equal [300.0, 900.0, false], run.items.first.values_at('min', 'max', 'fixed')
    back = CabinetCraft::Run.from_h(JSON.parse(JSON.generate(run.to_h)))
    assert_equal run.to_h, back.to_h
    assert_equal %w[c0 c1 c2], back.member_ids
  end

  def test_plan_follows_length_and_rules
    run = CabinetCraft::Run.build(name: 'R', length: 2400, items: items)
    assert_equal [800, 800, 800], run.plan['widths']
    assert_equal [700, 700, 700], run.plan(2100)['widths']
    pinned = run.with(length: 2400, rules: [nil, { 'fixed' => true, 'width' => 600 }, nil])
    assert_equal [900, 600, 900], pinned.plan['widths']
    assert_equal 2400, run.length # original unchanged
    assert_equal false, run.items[1]['fixed']
  end

  def test_with_rejects_a_fixed_cabinet_without_a_width
    run = CabinetCraft::Run.build(name: 'R', length: 2400, items: items)
    assert_raises(ArgumentError) { run.with(rules: [{ 'fixed' => true }]) }
  end

  def test_from_h_rejects_untrusted_garbage
    [nil, 'x', [], {}, { 'id' => 5, 'items' => [{}] }, { 'id' => 'a', 'items' => [] }, { 'id' => 'a', 'items' => ['z'] },
     { 'id' => 'a', 'length' => 'abc', 'items' => [{ 'cabinet_id' => 'c' }] }, { 'id' => 'a', 'length' => 1, 'items' => [{ 'cabinet_id' => 'c', 'fixed' => true }] },
     { 'id' => 'a', 'length' => 1, 'items' => [{ 'cabinet_id' => '' }] }].each do |raw|
      assert_nil CabinetCraft::Run.from_h(raw), raw.inspect
    end
  end

  def test_build_raises_on_bad_items
    assert_raises(ArgumentError) { CabinetCraft::Run.build(name: 'R', length: 2400, items: [{ 'fixed' => true, 'cabinet_id' => 'c' }]) }
    assert_raises(ArgumentError) { CabinetCraft::Run.build(name: 'R', length: 'abc', items: items) }
  end
end
