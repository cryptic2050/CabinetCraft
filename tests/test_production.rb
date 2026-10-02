# frozen_string_literal: true

require_relative 'test_helper'

class TestProduction < Minitest::Test
  include TestParams
  P = CabinetCraft::Manufacturing::Production

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
  end

  def cab(label = 'B01', ov = {})
    CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(ov), label: label)
  end

  def rows(cabs)
    CabinetCraft::Manufacturing::PartsList.build(cabs)
  end

  def ops(cabs)
    CabinetCraft::Manufacturing::Machining.for_project(cabs)['ops'].group_by { |o| o['part_uid'] }
  end

  NOW = Time.utc(2026, 10, 2, 12, 0, 0)

  def test_stages_apply_only_where_they_make_sense
    c = cab('B01', 'door_count' => 1)
    r = rows([c])
    o = ops([c])
    back = r.find { |x| x['key'] == 'back' }
    door = r.find { |x| x['key'] == 'door_1' }
    refute_nil back
    expected = %w[cut] + (back['edge_codes'].empty? ? [] : %w[banded]) + (o.key?(back['part_uid']) ? %w[drilled] : []) + %w[assembled]
    assert_equal expected, P.applicable(back, o)
    assert_equal %w[cut assembled], P.applicable({ 'part_uid' => 'x', 'edge_codes' => {} }, {}) # no banding, no machining
    assert_includes P.applicable(door, o), 'banded' # doors are banded on all edges
    assert_includes P.applicable(door, o), 'drilled' # hinge cups and handle holes
    side = r.find { |x| x['key'] == 'side_left' }
    assert_includes P.applicable(side, o), 'drilled'
  end

  def test_mark_sets_and_clears_without_touching_the_old_state
    r = rows([cab]).first
    s0 = {}
    s1 = P.mark(s0, r, 'cut', true, NOW)
    assert_empty s0
    assert_equal({ 'cut' => true }, P.done_stages(r, s1))
    assert_equal '2026-10-02T12:00:00Z', s1[r['part_uid']]['stages']['cut']
    s2 = P.mark(s1, r, 'banded', true, NOW)
    assert_equal %w[banded cut], P.done_stages(r, s2).keys.sort
    s3 = P.mark(s2, r, 'cut', false)
    assert_equal %w[banded], P.done_stages(r, s3).keys
    assert_empty P.mark(s3, r, 'banded', false) # an empty record is removed, not kept
    assert_raises(ArgumentError) { P.mark(s0, r, 'painted', true) }
  end

  def test_a_part_that_changed_size_is_no_longer_done
    c = cab('B01', 'width' => 600)
    r = rows([c]).find { |x| x['key'] == 'bottom' }
    state = P.mark({}, r, 'cut', true, NOW)
    assert_equal({ 'cut' => true }, P.done_stages(r, state))
    wider = rows([cab('B01', 'width' => 700)]).find { |x| x['key'] == 'bottom' }.merge('part_uid' => r['part_uid'])
    assert_empty P.done_stages(wider, state)
    again = P.mark(state, wider, 'banded', true, NOW) # marking the new size starts a fresh record
    assert_equal %w[banded], P.done_stages(wider, again).keys
  end

  def test_corrupt_records_are_ignored
    r = rows([cab]).first
    ['x', 5, nil, { 'sig' => P.signature(r), 'stages' => 'no' }, { 'sig' => P.signature(r), 'stages' => { 'cut' => 5, 'zzz' => 'now' } }].each do |junk|
      assert_empty P.done_stages(r, { r['part_uid'] => junk }), junk.inspect
    end
  end

  def test_summary_counts_stages_cabinets_and_progress
    cabs = [cab('B01'), cab('B02', 'door_count' => 2)]
    rs = rows(cabs)
    o = ops(cabs)
    empty = P.summary(rs, {}, o)
    assert_equal 0.0, empty['progress']
    assert_equal 0, empty['complete_parts']
    assert_equal rs.size, empty['stages']['cut']['total']
    assert_equal rs.size, empty['stages']['assembled']['total']
    assert_operator empty['stages']['banded']['total'], :<, rs.size
    state = {}
    rs.select { |x| x['cabinet_label'] == 'B01' }.each { |x| state = P.mark(state, x, 'cut', true, NOW) }
    s = P.summary(rs, state, o)
    assert_equal rs.count { |x| x['cabinet_label'] == 'B01' }, s['stages']['cut']['done']
    assert_equal %w[B01 B02], s['cabinets'].map { |c| c['label'] }
    assert_equal s['stages']['cut']['done'], s['cabinets'][0]['stages']['cut']['done']
    assert_equal 0, s['cabinets'][1]['stages']['cut']['done']
    assert_operator s['progress'], :>, 0
  end

  def test_everything_done_is_100_percent_and_orphans_are_ignored
    cabs = [cab]
    rs = rows(cabs)
    o = ops(cabs)
    state = {}
    rs.each { |x| P.applicable(x, o).each { |st| state = P.mark(state, x, st, true, NOW) } }
    state['gone:part'] = { 'sig' => '1x1x1', 'stages' => { 'cut' => NOW.iso8601 } } # a deleted cabinet's record
    s = P.summary(rs, state, o)
    assert_equal [100.0, rs.size], [s['progress'], s['complete_parts']]
    assert_equal s['stages']['cut']['total'], s['stages']['cut']['done']
  end

  def test_part_status_lists_every_stage_with_applicability
    c = cab
    r = rows([c]).first
    st = P.part_status(r, P.mark({}, r, 'cut', true, NOW), ops([c]))
    assert_equal %w[cut banded drilled assembled], st.map { |x| x['stage'] }
    assert_equal true, st.first['done']
    assert_equal false, st.last['done']
    assert_equal true, st.first['applies']
  end
end
