# frozen_string_literal: true

require_relative 'test_helper'

class TestLabelsAndValidation < Minitest::Test
  include TestParams
  L = CabinetCraft::Manufacturing::Labels
  V = CabinetCraft::Validation::Validator

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
  end

  def cab(ov = {}, label = 'B01')
    CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params(ov), label: label)
  end

  def codes(issues)
    issues.map { |i| i['code'] }
  end

  # --- Labels / QR payloads -----------------------------------------------------------------
  def test_label_contents_and_payload_round_trip
    c = cab('door_count' => 1, 'height' => 720)
    labels = L.build([c], project_name: 'VALENTINA KITCHEN')
    assert_equal c.part_rows.size, labels.size
    side = labels.find { |l| l['part_id'] == 'B01-SIDE_LEFT' }
    assert_equal 'VALENTINA KITCHEN', side['project']
    assert_equal 'B01', side['cabinet']
    assert_equal 'Left side', side['part']
    assert_equal '702 x 562 x 18', side['dimensions']
    assert_equal '18mm MDF', side['material']
    assert_equal 'along length', side['grain']
    assert_equal 'L1 1.0mm', side['edge_banding']
    assert_match(/\Ax 0.0 \/ y 0.0 \/ z 18.0 mm\z/, side['position'])
    assert_equal [c.id, 'side_left'], L.parse(side['qr_payload'])
    assert_match(/\A<svg/, side['qr_svg'])
  end

  def test_every_part_gets_a_unique_qr_code
    cabs = [cab({ 'door_count' => 2, 'drawer_count' => 1, 'width' => 800 }, 'B01'), cab({}, 'B02')]
    labels = L.build(cabs, project_name: 'P')
    payloads = labels.map { |l| l['qr_payload'] }
    assert_equal payloads.uniq, payloads
    assert_equal payloads.size, labels.map { |l| l['qr_svg'] }.uniq.size # different codes -> different symbols
  end

  def test_payload_fits_in_a_small_qr_and_encodes
    c = cab('door_count' => 0, 'drawer_count' => 6, 'shelf_count' => 0, 'height' => 1000, 'width' => 800)
    longest = c.panels.map { |p| L.payload(c.id, p.key) }.max_by(&:size)
    assert_operator longest.bytesize, :<=, 61 # version 4-M
    assert_equal 33, CabinetCraft::QrCode.encode(longest).size
  end

  def test_parse_rejects_garbage
    [nil, '', 'hello', 'CC1|short|x', "CC1|#{SecureRandom.uuid}|Side Left", "CC2|#{SecureRandom.uuid}|side"].each { |s| assert_nil L.parse(s), s.inspect }
    assert L.parse("  CC1|#{SecureRandom.uuid}|side_left \n")
  end

  def test_label_html_escapes_user_text
    labels = L.build([cab], project_name: '<script>alert(1)</script> & "x"')
    html = CabinetCraft::Exporters::LabelHtml.render(labels)
    refute_includes html, '<script>alert'
    assert_includes html, '&lt;script&gt;'
    assert_equal labels.size, html.scan('class="label"').size
    assert_includes html, '<svg'
  end

  # --- Validator -------------------------------------------------------------------------------
  def test_clean_cabinet_has_no_issues
    assert_empty V.run([cab('door_count' => 1, 'drawer_count' => 0)])
    presets = CabinetCraft::Library::ENTRIES.each_with_index.map do |e, i|
      CabinetCraft::Cabinet.build(type: e['type'], params: params(CabinetCraft::Library.defaults_for(e['type'])), label: format('B%02d', i + 1))
    end
    assert_empty V.run(presets).map { |i| i['message'] }
  end

  def test_impossible_geometry_reported
    bad = CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params.merge('height' => 300, 'shelf_count' => 10), label: 'B01')
    issues = V.run([bad])
    assert_includes codes(issues), 'impossible_geometry'
    assert(issues.all? { |i| i['cabinet_id'] == bad.id }, 'issue points at the cabinet')
  end

  def test_missing_edge_banding_on_fronts
    issues = V.run([cab('edge_front' => 0, 'door_count' => 2, 'width' => 800)])
    miss = issues.select { |i| i['code'] == 'missing_edge_banding' }
    assert_equal %w[door_1 door_2], miss.map { |i| i['part_key'] }
    assert(miss.all? { |i| i['severity'] == 'warning' && i['message'].include?('visible front') })
  end

  def test_insufficient_clearances
    issues = V.run([cab('door_count' => 2, 'door_gap' => 1, 'door_reveal' => 0.5, 'width' => 800, 'drawer_count' => 0)])
    assert_equal 2, issues.count { |i| i['code'] == 'insufficient_clearance' }
    runner = V.run([cab('door_count' => 0, 'drawer_count' => 2, 'shelf_count' => 0, 'runner_clearance' => 8)])
    assert_includes codes(runner), 'insufficient_clearance'
  end

  def test_unknown_hardware_is_a_warning
    issues = V.run([cab('hinge_type' => 'custom_42')])
    w = issues.find { |i| i['code'] == 'unknown_hardware' }
    assert_equal 'warning', w['severity']
  end

  def test_duplicate_ids_are_errors
    a = cab({}, 'B01')
    b = cab({}, 'B01') # same label -> same part ids
    issues = V.run([a, b])
    assert_includes codes(issues), 'duplicate_part_id'
    twin = a.with_identity(id: a.id, label: 'B02')
    assert_includes codes(V.run([a, twin])), 'duplicate_cabinet_id'
    refute_includes codes(V.run([a, cab({}, 'B02')])), 'duplicate_part_id'
  end

  def test_missing_material_is_an_error
    c = CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params.merge('material' => 'gone'), label: 'B01')
    assert_raises(KeyError) { c.calculation } # engine refuses unknown materials outright
  end

  def test_overlap_detection_flags_door_and_drawer_collisions
    # Hand-built panels: two doors overlapping, a drawer box through the bottom.
    mk = lambda do |key, role, origin, size, ax|
      CabinetCraft::Panel.new(key: key, name: key, role: role, origin: origin, size: size, thickness_axis: ax, material_id: 'mdf_18', material_label: 'm')
    end
    d1 = mk.call('door_1', :door, [0, -18, 0], [300, 18, 700], :y)
    d2 = mk.call('door_2', :door, [290, -18, 0], [300, 18, 700], :y)
    box = mk.call('drawer_1_bottom', :drawer_box, [0, 0, 0], [300, 400, 3], :z)
    bottom = mk.call('bottom', :bottom, [0, 0, 0], [600, 560, 18], :z)
    found = CabinetCraft::Validation::CollisionChecker.panel_overlaps([d1, d2, box, bottom]).map(&:last)
    assert_includes found, 'door_collision'
    assert_includes found, 'drawer_collision'
  end

  def test_nesting_failures_and_grain_violations_reported
    big = cab('width' => 3000, 'door_count' => 0, 'shelf_count' => 0)
    parts = CabinetCraft::Manufacturing::PartsList.build([big])
    nest = { 'materials' => [{
      'material' => '18mm MDF', 'sheet_length' => 2440.0, 'sheet_width' => 1220.0, 'grain_free' => false,
      'unplaced' => [{ 'uid' => parts[0]['part_uid'], 'part_id' => parts[0]['part_id'], 'length' => 3000, 'width' => 562 }],
      'released_locks' => [{ 'part_id' => 'X', 'reason' => 'part size changed' }],
      'sheets' => [{ 'index' => 0, 'cut_sequence' => { 'ok' => false, 'reason' => 'no guillotine' },
                     'placements' => [{ 'uid' => "#{big.id}:side_left", 'part_id' => 'B01-SIDE_LEFT', 'grain' => 'length', 'rotated' => true }] }]
    }] }
    issues = V.run([big], nesting: nest)
    assert_equal %w[grain_direction lock_released nesting_failure no_cut_sequence], codes(issues).sort
    assert_equal big.id, issues.find { |i| i['code'] == 'nesting_failure' }['cabinet_id']
  end

  def test_summary_and_ordering
    issues = V.run([cab('edge_front' => 0), CabinetCraft::Cabinet.build(type: 'base_cabinet', params: params.merge('height' => 300, 'shelf_count' => 10), label: 'B02')])
    assert_equal 'error', issues.first['severity'] # errors sort first
    s = V.summary(issues)
    assert_equal 'error', s['status']
    assert_equal 'valid', V.summary([])['status']
    assert_equal 'warning', V.summary(V.run([cab('edge_front' => 0)]))['status']
  end

  def test_not_checked_list_is_honest
    assert_match(/drilling/i, V::NOT_CHECKED.join)
  end
end
