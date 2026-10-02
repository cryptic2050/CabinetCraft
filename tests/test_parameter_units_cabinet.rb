# frozen_string_literal: true

require_relative 'test_helper'

class TestParameter < Minitest::Test
  P = CabinetCraft::Parameter

  def test_defaults_are_valid
    _, errors = P.coerce(P.defaults)
    assert_empty errors
  end

  def test_coerces_strings
    p, errors = P.coerce('width' => '800', 'shelf_count' => '2')
    assert_empty errors
    assert_equal 800.0, p['width']
    assert_equal 2, p['shelf_count']
  end

  def test_rejects_bad_values
    [{ 'width' => 'abc' }, { 'width' => 5 }, { 'shelf_count' => 1.5 }, { 'material' => 'gold' },
     { 'width' => Float::NAN }, { 'depth' => 99_999 }].each do |bad|
      _, errors = P.coerce(bad)
      refute_empty errors, bad.inspect
    end
  end

  def test_unknown_keys_dropped
    p, = P.coerce('nope' => 1)
    refute p.key?('nope')
  end
end

class TestUnits < Minitest::Test
  U = CabinetCraft::Units

  def test_round_trip
    %w[mm cm m in].each { |u| assert_in_delta 600, U.to_mm(U.from_mm(600, u), u), 1e-9 }
    assert_in_delta 25.4, U.to_mm(1, 'in'), 1e-12
    assert_in_delta 1.0, U.to_sketchup(25.4), 1e-12
    assert_equal '60.0 cm', U.format(600, 'cm')
  end
end

class TestCabinet < Minitest::Test
  include TestParams

  def build
    CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params, label: 'B01')
  end

  def test_attribute_round_trip
    cab = build
    back = CabinetCraft::Cabinet.from_attributes(cab.to_attributes)
    assert_equal cab.id, back.id
    assert_equal cab.params, back.params
    assert_equal 'B01', back.label
  end

  def test_with_params_keeps_identity_and_bumps_version
    cab = build
    n = cab.with_params(params('width' => 800))
    assert_equal cab.id, n.id
    assert_equal 2, n.version
    assert_equal 800.0, n.params['width']
    assert_equal 1, cab.version
  end

  def test_part_ids_unique
    ids = build.part_rows.map { |r| r['part_id'] }
    assert_equal ids.uniq, ids
    assert_includes ids, 'B01-SIDE_LEFT'
  end

  def test_corrupt_attributes_return_nil
    assert_nil CabinetCraft::Cabinet.from_attributes('cabinet_id' => 'x', 'params_json' => '{oops')
    assert_nil CabinetCraft::Cabinet.from_attributes({})
  end
end
