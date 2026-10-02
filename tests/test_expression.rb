# frozen_string_literal: true

require_relative 'test_helper'
require File.join(CabinetCraft::PLUGIN_ROOT, 'templates/expression')

class TestExpression < Minitest::Test
  E = CabinetCraft::Templates::Expression

  def v(text, vars = {})
    E.run(text, vars)
  end

  def test_arithmetic_and_precedence
    assert_equal 7.0, v('1 + 2 * 3')
    assert_equal 9.0, v('(1 + 2) * 3')
    assert_equal 1.0, v('10 % 3')
    assert_equal(-5.0, v('-2 - 3'))
    assert_equal 2.5, v('5 / 2')
    assert_equal 4.0, v('2 * -2 + 8')
    assert_equal 3.5, v('.5 + 3')
    assert_equal 6.0, v('1 - 2 - 3 + 10') # left associative
    assert_equal 2.0, v('8 / 2 / 2')
  end

  def test_variables_and_the_brief_example
    assert_equal 564.0, v('W - t - t', 'W' => 600.0, 't' => 18.0) # 600 - 18 - 18
    assert_in_delta 297.0, v('(W - 2 * r - (n - 1) * g) / n', 'W' => 600.0, 'r' => 1.5, 'g' => 3.0, 'n' => 2.0), 1e-9
    assert_equal %w[W r t], E.variables(E.parse('W - r * min(t, 3)')).uniq
  end

  def test_comparison_and_logic
    assert_equal 1.0, v('3 > 2 && 2 >= 2')
    assert_equal 0.0, v('3 < 2 || 1 == 2')
    assert_equal 1.0, v('!(1 > 2)')
    assert_equal 1.0, v('1 != 2')
    assert_equal 1.0, v('0.1 + 0.2 == 0.3') # tolerant equality
  end

  def test_functions
    assert_equal 2.0, v('min(5, 2, 9)')
    assert_equal 9.0, v('max(5, 2, 9)')
    assert_equal 3.0, v('abs(-3)')
    assert_equal 2.0, v('floor(2.9)')
    assert_equal 3.0, v('ceil(2.1)')
    assert_equal 3.0, v('round(2.5)')
    assert_equal 2.35, v('round(2.349, 2)')
    assert_equal 4.0, v('sqrt(16)')
    assert_equal 5.0, v('clamp(9, 1, 5)')
    assert_equal 1.0, v('clamp(-4, 1, 5)')
    assert_equal 10.0, v('if(1, 10, 20)')
    assert_equal 20.0, v('if(0, 10, 20)')
  end

  def test_if_only_evaluates_the_chosen_branch
    assert_equal 5.0, v('if(1, 5, 1 / 0)') # the division by zero is never evaluated
    assert_equal 1.0, v('1 || 1 / 0') # the right side of || is skipped
    assert_equal 0.0, v('0 && 1 / 0')
  end

  def test_evaluation_errors
    assert_raises(E::EvalError) { v('1 / 0') }
    assert_raises(E::EvalError) { v('5 % 0') }
    assert_raises(E::EvalError) { v('sqrt(-1)') }
    err = assert_raises(E::EvalError) { v('missing + 1') }
    assert_match(/missing/, err.message)
  end

  def test_parse_errors_have_readable_messages
    { '' => /empty/, '1 +' => /ends unexpectedly/, '(1 + 2' => /Expected '\)'/, '1 2' => /Unexpected/, '@' => /Unexpected character/,
      'foo(1)' => /Unknown function/, 'min()' => /argument/, 'abs(1, 2)' => /argument/, 'if(1, 2)' => /argument/, ')' => /Unexpected/, '1 + * 2' => /Unexpected/ }.each do |src, pattern|
      err = assert_raises(E::ParseError, src.inspect) { E.parse(src) }
      assert_match pattern, err.message, src.inspect
    end
  end

  def test_limits_stop_hostile_input
    assert_raises(E::ParseError) { E.parse('1+' * 300 + '1') } # too long
    assert_raises(E::ParseError) { E.parse('(' * 60 + '1' + ')' * 60) } # too deep
    assert_raises(E::ParseError) { E.parse((['1'] * 150).join(' + ')) } # too many nodes
  end

  def test_nothing_ruby_can_be_smuggled_in
    ["`ls`", 'system("ls")', 'File.read(1)', '1; 2', '"a"', '[1,2]', 'puts', '__method__', '1.send(:+, 2)', '$x'].each do |src|
      assert_raises(E::ParseError, E::EvalError, src) { v(src) }
    end
    assert_raises(E::EvalError) { v('Kernel') } # a bare name is just an unknown variable
  end

  def test_results_must_be_finite
    assert_raises(E::EvalError) { v('x * 2', 'x' => Float::INFINITY) }
  end
end
