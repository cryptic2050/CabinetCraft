# frozen_string_literal: true

require_relative 'test_helper'

class TestCncTravel < Minitest::Test
  Cnc = CabinetCraft::Manufacturing::Cnc
  MC = CabinetCraft::MachiningConfig

  def setup
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    @machine = MC::DEFAULT_MACHINE
  end

  def nest(sheet_length: 2440.0, sheet_width: 1220.0, material: '18mm MDF', placements: 1)
    pl = Array.new(placements) { |i| { 'uid' => "u#{i}", 'part_id' => "P#{i}", 'x' => 100.0 + i * 300, 'y' => 100.0, 'w' => 200.0, 'h' => 200.0, 'rotated' => false } }
    { 'materials' => [{ 'material' => material, 'sheet_length' => sheet_length, 'sheet_width' => sheet_width, 'trim' => 10.0, 'kerf' => 8.0, 'sheets' => [{ 'index' => 0, 'placements' => pl }] }] }
  end

  def codes(machine, n)
    Cnc.check(n, [], machine).select { |i| i['severity'] == 'error' }.map { |i| i['code'] }
  end

  def test_a_standard_sheet_fits_the_default_machine
    refute_includes codes(@machine, nest), 'cnc_exceeds_travel'
  end

  def test_a_sheet_larger_than_the_x_or_y_travel_is_an_error_naming_the_machine
    assert_includes codes(@machine, nest(sheet_length: 3200.0)), 'cnc_exceeds_travel'
    assert_includes codes(@machine, nest(sheet_width: 1600.0)), 'cnc_exceeds_travel'
    msg = Cnc.check(nest(sheet_length: 3200.0), [], @machine).find { |i| i['code'] == 'cnc_exceeds_travel' }['message']
    assert_match(/3200.*larger than the travel.*Generic 3-axis router/, msg)
  end

  def test_a_smaller_machine_rejects_a_standard_sheet
    small = @machine.merge('bed_x' => 1300.0, 'bed_y' => 900.0, 'name' => 'Small')
    assert_includes codes(small, nest), 'cnc_exceeds_travel'
    exact = @machine.merge('bed_x' => 2440.0, 'bed_y' => 1220.0)
    refute_includes codes(exact, nest), 'cnc_exceeds_travel' # exactly the sheet size is fine
  end

  def test_z_travel_must_cover_the_board_and_the_safe_height
    shallow = @machine.merge('bed_z' => 30.0) # 18 + 15 = 33 > 30
    assert_includes codes(shallow, nest), 'cnc_exceeds_travel'
    ok = @machine.merge('bed_z' => 40.0)
    refute_includes codes(ok, nest), 'cnc_exceeds_travel'
    assert_includes codes(shallow, nest), 'cnc_exceeds_travel'
    refute_includes codes(shallow, nest(material: 'unknown board')), 'cnc_exceeds_travel' # an unknown board has no known thickness: only X / Y are checked
  end

  def test_a_machine_without_travel_keys_uses_the_defaults
    old = @machine.reject { |k, _| k.start_with?('bed_') }
    refute_includes codes(old, nest), 'cnc_exceeds_travel'
    assert_includes codes(old, nest(sheet_length: 4000.0)), 'cnc_exceeds_travel'
  end

  def test_machine_travel_is_validated_and_old_saved_machines_get_defaults
    cfg = MC.new
    base = @machine.reject { |k, _| k == 'id' }.merge('name' => 'M')
    m = cfg.save_machine(base.reject { |k, _| k.start_with?('bed_') })
    assert_equal [3050.0, 1550.0, 150.0], m.values_at('bed_x', 'bed_y', 'bed_z')
    assert_equal [2800.0, 1300.0, 120.0], cfg.save_machine(base.merge('bed_x' => '2800', 'bed_y' => 1300, 'bed_z' => 120)).values_at('bed_x', 'bed_y', 'bed_z')
    [{ 'bed_x' => 100 }, { 'bed_x' => 20_000 }, { 'bed_y' => 10 }, { 'bed_z' => 5 }, { 'bed_z' => 'abc' }].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { cfg.save_machine(base.merge(bad)) }
    end
  end
end
