# frozen_string_literal: true

require_relative 'test_helper'
require File.join(CabinetCraft::PLUGIN_ROOT, 'manufacturing/grain_sets')

class TestGrainSets < Minitest::Test
  G = CabinetCraft::Manufacturing::GrainSets

  def test_letters_run_a_to_z_then_aa
    assert_equal %w[A B Z AA AB], [0, 1, 25, 26, 27].map { |i| G.letter(i) }
  end

  def test_a_set_numbers_parts_in_pick_order
    m = G.assign({}, %w[p3 p1 p2])
    assert_equal({ 'p3' => 'A1', 'p1' => 'A2', 'p2' => 'A3' }, m)
  end

  def test_the_next_set_takes_the_next_free_letter_and_pulls_parts_out_of_the_old_one
    m = G.assign({}, %w[a b c])
    m = G.assign(m, %w[c d])
    assert_equal({ 'a' => 'A1', 'b' => 'A2', 'c' => 'B1', 'd' => 'B2' }, m)
  end

  def test_a_set_left_with_one_part_disappears_and_letters_are_reused
    m = G.assign({}, %w[a b])
    m = G.assign(m, %w[b c]) # a is alone in A now
    assert_equal({ 'b' => 'A1', 'c' => 'A2' }, m)
  end

  def test_needs_two_distinct_parts
    assert_raises(ArgumentError) { G.assign({}, %w[a]) }
    assert_raises(ArgumentError) { G.assign({}, %w[a a]) }
  end

  def test_clean_drops_missing_parts_and_renumbers
    m = { 'a' => 'A1', 'b' => 'A2', 'c' => 'A3' }
    assert_equal({ 'a' => 'A1', 'c' => 'A2' }, G.clean(m, %w[a c]))
    assert_equal({}, G.clean(m, %w[a]))
  end
end
