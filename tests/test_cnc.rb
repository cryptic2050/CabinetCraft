# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'gcode_sim'
require 'open3'
require 'tmpdir'
require 'json'

class TestCnc < Minitest::Test
  include TestParams
  Cnc = CabinetCraft::Manufacturing::Cnc
  Posts = CabinetCraft::Manufacturing::CncPosts
  MC = CabinetCraft::MachiningConfig
  N = CabinetCraft::Manufacturing::Nesting

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    MC.current = MC.new
    cab = CabinetCraft::Cabinet.build(type: 'base_cabinet', label: 'B01',
                                      params: params('width' => 800, 'height' => 820, 'toe_kick_height' => 100, 'door_count' => 2, 'shelf_count' => 1, 'handle_type' => 'handle_bar'))
    @rows = cab.part_rows.select { |r| r['material'] == '18mm MDF' }
    @ops = CabinetCraft::Manufacturing::Machining.operations(cab)['ops']
    @ops_by_uid = @ops.group_by { |o| o['part_uid'] }
    parts = @rows.map { |r| { 'uid' => r['part_uid'], 'part_id' => r['part_id'], 'name' => r['name'], 'length' => r['length'], 'width' => r['width'], 'grain' => r['grain'], 'cabinet_label' => 'B01' } }
    sheet = { 'material' => '18mm MDF', 'sheet_length' => 2440.0, 'sheet_width' => 1220.0, 'grain_free' => true }
    @mat = N.nest(parts, sheet, { 'kerf' => 8.0, 'trim' => 10.0, 'spacing' => 0.0 })
    @nest = { 'materials' => [@mat] }
    @machine = MC::DEFAULT_MACHINE.merge('tools' => MC::DEFAULT_MACHINE['tools'].dup)
  end

  def machine(over = {})
    @machine.merge(over)
  end

  def programs(mach, face_up: 'a')
    Cnc.build(@mat, @ops_by_uid, mach, 18.0, face_up: face_up)
  end

  def text(mach, face_up: 'a')
    programs(mach, face_up: face_up).map { |p| Cnc.render(p, mach, [], name: 'T') }
  end

  # Independent expectation: where each face-A hole must be drilled, in machine coordinates.
  def expected_holes(mach, face_up: 'a')
    sl = @mat['sheet_length']
    sw = @mat['sheet_width']
    @mat['sheets'].flat_map do |sh|
      sh['placements'].flat_map do |p|
        @ops.select { |o| o['part_uid'] == p['uid'] && o['target'] == 'face' && o['side'] == face_up }.map do |o|
          x, y = p['rotated'] ? [p['x'] + o['y'], p['y'] + o['x']] : [p['x'] + o['x'], p['y'] + o['y']]
          x = sl - x if face_up == 'b'
          x = sl - x if %w[bottom_right top_right].include?(mach['origin'])
          y = sw - y if %w[top_left top_right].include?(mach['origin'])
          [sh['index'], o['dia'], x.round(2), y.round(2), o['through'] ? :through : o['depth']]
        end
      end
    end
  end

  def simulated_drills(mach, texts, thickness = 18.0)
    surface = mach['z_zero'] == 'spoilboard' ? thickness : 0.0
    texts.each_with_index.flat_map do |t, idx|
      sim = GcodeSim.run(t, surface_top: surface)
      drill_tools = mach['tools'].select { |x| x['kind'] == 'drill' }.to_h { |x| [x['number'], x['diameter']] }
      found = sim.drills + GcodeSim.explicit_drills(sim.moves, surface_top: surface)
      found = found.select { |d| drill_tools.key?(d[:tool]) }
      found.map do |d|
        depth = surface - d[:z]
        through = depth >= thickness + mach['cut_extra'] - 0.01
        [sheet_index_for(idx), drill_tools[d[:tool]], d[:x].round(2), d[:y].round(2), through ? :through : depth.round(2)]
      end
    end
  end

  def sheet_index_for(i)
    programs(machine).map { |p| p['index'] }[i]
  end

  def key(h)
    h.map { |a| a.map(&:to_s).join('|') }.sort
  end

  # --- G-code correctness: output text vs plan -------------------------------------------------------------
  def test_iso_canned_cycles_drill_every_planned_hole_once
    m = machine
    texts = text(m)
    assert_equal key(expected_holes(m)), key(simulated_drills(m, texts))
    texts.each do |t|
      assert_includes t, 'G81'
      assert_includes t, 'NOT verified'
      sim = GcodeSim.run(t)
      assert sim.ended
      assert_empty sim.violations
    end
  end

  def test_iso_without_canned_cycles_gives_same_holes
    m = machine('canned_cycles' => false)
    texts = text(m)
    refute_includes texts.join, 'G81'
    assert_equal key(expected_holes(m)), key(simulated_drills(m, texts))
    texts.each { |t| assert_empty GcodeSim.run(t).violations }
  end

  def test_grbl_uses_pauses_not_tool_change_and_no_canned
    m = machine('post' => 'grbl')
    texts = text(m)
    all = texts.join
    refute_includes all, 'M6'
    refute_includes all, 'G81'
    assert_includes all, 'M0'
    assert_equal key(expected_holes(m)), key(simulated_drills(m, texts))
  end

  def test_all_four_origins
    %w[bottom_left bottom_right top_left top_right].each do |o|
      m = machine('origin' => o)
      assert_equal key(expected_holes(m)), key(simulated_drills(m, text(m))), o
    end
  end

  def test_inches
    m = machine('units' => 'in', 'decimals' => 4)
    texts = text(m)
    assert(texts.all? { |t| t.include?('G20') })
    assert_equal key(expected_holes(m)), key(simulated_drills(m, texts))
  end

  def test_spoilboard_z_zero
    m = machine('z_zero' => 'spoilboard')
    assert_equal key(expected_holes(m)), key(simulated_drills(m, text(m)))
    sim = GcodeSim.run(text(m).first, surface_top: 18.0)
    assert_empty sim.violations
    assert_in_delta(-0.3, sim.moves.map { |mv| mv[:to]['Z'] }.min, 1e-6) # cuts end 0.3 below the spoilboard surface
  end

  def test_router_paths_surround_each_part_by_tool_radius_in_multiple_passes
    m = machine
    programs(m).each_with_index do |prog, i|
      sim = GcodeSim.run(Cnc.render(prog, m, [], name: 'T'))
      router = sim.moves.select { |mv| mv[:tool] == 1 && mv[:type] == :cut }
      sh = @mat['sheets'].find { |s| s['index'] == prog['index'] }
      sh['placements'].each do |p|
        box = [p['x'] - 4, p['y'] - 4, p['x'] + p['w'] + 4, p['y'] + p['h'] + 4]
        loops = router.select { |mv| mv[:to]['Z'] < -1 && [mv[:from]['X'], mv[:to]['X']].all? { |x| (x - box[0]).abs < 0.01 || (x - box[2]).abs < 0.01 } && [mv[:from]['Y'], mv[:to]['Y']].all? { |y| (y - box[1]).abs < 0.01 || (y - box[3]).abs < 0.01 } }
        assert_operator loops.size, :>=, 4 * 3, "#{p['part_id']} needs 3 passes of 4 sides" # 18.3 mm / 9 mm passes -> 3
        assert_in_delta(-18.3, loops.map { |mv| mv[:to]['Z'] }.min, 1e-6)
        assert_equal 3, loops.map { |mv| mv[:to]['Z'].round(3) }.uniq.size
      end
      assert_equal sh['placements'].size, prog['stats']['routes'], "sheet #{i}"
    end
  end

  def test_no_rapid_xy_moves_inside_material
    [machine, machine('canned_cycles' => false), machine('post' => 'grbl'), machine('z_zero' => 'spoilboard')].each do |m|
      surface = m['z_zero'] == 'spoilboard' ? 18.0 : 0.0
      text(m).each { |t| assert_empty GcodeSim.run(t, surface_top: surface).violations, m['post'] }
    end
  end

  def test_tool_changes_are_grouped_one_per_tool
    m = machine
    prog = programs(m).first
    tools = prog['events'].select { |e| e['t'] == 'tool' }.map { |e| e['number'] }
    assert_equal tools.uniq, tools, 'each tool is loaded once'
    assert_equal 1, tools.last # router last
    sim = GcodeSim.run(Cnc.render(prog, m, [], name: 'T'))
    assert_equal tools, sim.tools
  end

  def test_face_b_program_only_drills_and_mirrors
    m = machine
    texts = text(m, face_up: 'b')
    expected = expected_holes(m, face_up: 'b')
    skip 'no underside holes in this cabinet' if expected.empty?
    assert_equal key(expected), key(simulated_drills(m, texts))
    refute(texts.join.include?('Cut '), 'the underside program does not cut parts out')
  end

  def test_line_numbers_option
    t = text(machine('line_numbers' => true)).first
    assert_match(/^N10 /, t)
    assert_empty GcodeSim.run(t).violations
  end

  def test_unknown_drill_tool_raises
    m = machine('tools' => [{ 'number' => 1, 'kind' => 'router', 'diameter' => 8.0 }])
    assert_raises(ArgumentError) { programs(m) }
  end

  # --- checks that block export -----------------------------------------------------------------------------
  def test_check_flags_missing_tool_and_small_kerf
    m = machine('tools' => [{ 'number' => 1, 'kind' => 'router', 'diameter' => 8.0 }, { 'number' => 2, 'kind' => 'drill', 'diameter' => 5.0 }])
    issues = Cnc.check(@nest, @ops, m)
    codes = issues.map { |i| i['code'] }
    assert_includes codes, 'cnc_no_tool'
    assert_includes codes, 'cnc_edge_ops' # cam bores are horizontal
    assert_empty issues.select { |i| i['code'] == 'cnc_kerf_too_small' }
    tight = N.nest(@mat['sheets'].flat_map { |s| s['placements'] }.map { |p| { 'uid' => p['uid'], 'part_id' => p['part_id'], 'name' => '', 'length' => p['length'], 'width' => p['width'], 'grain' => 'none', 'cabinet_label' => 'B01' } },
                   { 'material' => '18mm MDF', 'sheet_length' => 2440.0, 'sheet_width' => 1220.0, 'grain_free' => true }, { 'kerf' => 3.0 })
    kerf = Cnc.check({ 'materials' => [tight] }, [], m).select { |i| i['code'] == 'cnc_kerf_too_small' }
    refute_empty kerf
    assert(kerf.all? { |i| i['severity'] == 'error' && i['message'].include?('at least 8') })
  end

  def test_check_reports_other_face_and_small_parts
    issues = Cnc.check(@nest, @ops, machine)
    assert(issues.any? { |i| i['code'] == 'cnc_other_face' })
    assert(issues.select { |i| i['severity'] == 'error' }.empty?, issues.select { |i| i['severity'] == 'error' }.inspect)
  end

  # --- posts ---------------------------------------------------------------------------------------------------------
  def test_template_post_renders_custom_format
    tpl = Posts::DEFAULT_TEMPLATES.merge('rapid' => 'RAPID {x} {y} {z}', 'drill' => 'HOLE X={x} Y={y} Z={z} D={r}', 'tool_change' => 'TOOL {t} dia {d} rpm {s}', 'footer' => 'DONE {safe}')
    custom = [{ 'id' => 'post_1', 'name' => 'mine', 'templates' => Posts.validate_templates(tpl), 'extension' => 'prg' }]
    m = machine('post' => 'post_1')
    out = Cnc.render(programs(m).first, m, custom, name: 'job')
    assert_includes out, 'RAPID '
    assert_match(/^HOLE X=[\d.]+ Y=[\d.]+ Z=-?[\d.]+ D=2$/, out)
    assert_match(/^TOOL 2 dia 5 rpm 18000$/, out)
    assert_match(/^DONE 15$/, out)
    assert_includes out, 'NOT verified'
    assert_equal 'prg', Posts.extension('post_1', custom)
  end

  def test_template_validation
    assert_raises(ArgumentError) { Posts.validate_templates(Posts::DEFAULT_TEMPLATES.merge('rapid' => 'G0 X{x} {evil}')) }
    assert_raises(ArgumentError) { Posts.validate_templates(Posts::DEFAULT_TEMPLATES.merge('footer' => '')) }
    assert_raises(ArgumentError) { Posts.validate_templates('nope') }
    assert Posts.validate_templates(Posts::DEFAULT_TEMPLATES)
  end

  def test_comment_text_cannot_inject_gcode
    m = machine
    prog = programs(m).first
    prog['events'].unshift('t' => 'comment', 'text' => "x)\nM30 (")
    out = Cnc.render(prog, m, [], name: 'T')
    refute_match(/^M30 \(/, out.lines.first(6).join)
    assert_equal 1, out.lines.count { |l| l.strip == 'M30' } # only our own footer
  end

  # --- machine configuration ----------------------------------------------------------------------------------------
  def test_machine_profiles_validate_and_persist
    store = CabinetCraft::Hardware::MemoryStore.new
    cfg = MC.new(store)
    raw = MC::DEFAULT_MACHINE.merge('id' => '', 'name' => 'Shop router', 'origin' => 'top_right', 'units' => 'in')
    saved = cfg.save_machine(raw)
    assert_equal 'machine_1', saved['id']
    again = MC.new(store)
    assert_equal 'machine_1', again.active_machine_id
    assert_equal 'top_right', again.machine['origin']
    [{ 'units' => 'cm' }, { 'origin' => 'middle' }, { 'spindle_rpm' => 5 }, { 'post' => 'nope' }, { 'name' => ' ' },
     { 'tools' => [{ 'number' => 1, 'kind' => 'drill', 'diameter' => 5 }] }, { 'tools' => [{ 'number' => 1, 'kind' => 'router', 'diameter' => 8 }, { 'number' => 1, 'kind' => 'drill', 'diameter' => 5 }] },
     { 'tools' => [{ 'number' => 0, 'kind' => 'router', 'diameter' => 8 }] }, { 'safe_z' => 0 }].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { cfg.save_machine(raw.merge(bad)) }
    end
    assert_raises(ArgumentError) { cfg.save_machine(MC::DEFAULT_MACHINE) } # built-in is read-only
    assert_raises(ArgumentError) { cfg.delete_machine('default_router') }
    assert cfg.delete_machine('machine_1')
    assert_equal 'default_router', cfg.active_machine_id
  end

  def test_custom_post_lifecycle_and_in_use_protection
    cfg = MC.new
    post = cfg.save_post(id: '', name: 'P', templates: Posts::DEFAULT_TEMPLATES, extension: 'tap')
    assert_equal 'post_1', post['id']
    cfg.save_machine(MC::DEFAULT_MACHINE.merge('id' => '', 'name' => 'uses post', 'post' => 'post_1'))
    assert_raises(ArgumentError) { cfg.delete_post('post_1') }
    assert_raises(ArgumentError) { cfg.save_post(id: '', name: 'x', templates: Posts::DEFAULT_TEMPLATES, extension: '../etc') }
  end

  # --- DXF / SVG ---------------------------------------------------------------------------------------------------------
  def dxf_files(dir)
    @mat['sheets'].reject { |sh| sh['placements'].empty? }.map do |sh|
      holes = Cnc.sheet_holes(sh, @ops_by_uid)
      path = File.join(dir, "sheet#{sh['index'] + 1}.dxf")
      File.write(path, CabinetCraft::Exporters::DxfExporter.sheet(@mat, sh, holes))
      { 'path' => path, 'parts' => sh['placements'].size,
        'holes' => holes.map { |h| [CabinetCraft::Exporters::DxfExporter.layer_name(h), h['x'], h['y'], h['dia'] / 2.0] } }
    end
  end

  def test_dxf_structure_is_valid_r12
    sh = @mat['sheets'].first
    dxf = CabinetCraft::Exporters::DxfExporter.sheet(@mat, sh, Cnc.sheet_holes(sh, @ops_by_uid))
    pairs = dxf.lines.map(&:chomp).each_slice(2).to_a
    assert_equal ['0', 'SECTION'], pairs.first
    assert_equal ['0', 'EOF'], pairs.last
    assert_includes pairs, %w[1 AC1009]
    assert_equal pairs.count { |p| p == %w[0 SECTION] }, pairs.count { |p| p == %w[0 ENDSEC] }
    assert_equal pairs.count { |p| p == %w[0 POLYLINE] }, pairs.count { |p| p == %w[0 SEQEND] }
    assert_equal sh['placements'].size + 1 + 1, pairs.count { |p| p == %w[0 POLYLINE] } # parts + sheet + trim
    layers = pairs.each_cons(2).select { |a, b| a == %w[0 LAYER] && b[0] == '2' }.map { |_, b| b[1] }
    assert_includes layers, 'PART_OUTLINE'
    assert(layers.any? { |l| l.start_with?('DRILL_A_D35_Z12-5') })
    assert(layers.all? { |l| l.match?(/\A[A-Z0-9_\-$]+\z/) }, 'R12 layer names allow only letters, digits, _ - $')
  end

  def test_dxf_label_text_is_sanitised
    sh = @mat['sheets'].first
    sh2 = Marshal.load(Marshal.dump(sh))
    sh2['placements'][0]['part_id'] = "EVIL\n0\nENDSEC"
    dxf = CabinetCraft::Exporters::DxfExporter.sheet(@mat, sh2, [])
    pairs = dxf.lines.map(&:chomp).each_slice(2).to_a
    assert_equal pairs.count { |p| p == %w[0 SECTION] }, pairs.count { |p| p == %w[0 ENDSEC] }
  end

  def test_dxf_parses_in_ezdxf_with_correct_geometry
    _, st = Open3.capture2e('python3', '-c', 'import ezdxf')
    skip 'python3 + ezdxf not installed' unless st.success?

    Dir.mktmpdir do |dir|
      files = dxf_files(dir)
      out, status = Open3.capture2e('python3', File.join(__dir__, 'tools', 'dxf_check.py'), stdin_data: JSON.generate('files' => files))
      assert status.success?, out
      assert_equal files.size, out.scan(/^OK /).size
    end
  end

  def test_svg_contains_every_part_and_hole
    sh = @mat['sheets'].first
    holes = Cnc.sheet_holes(sh, @ops_by_uid)
    svg = CabinetCraft::Exporters::SvgExporter.sheet(@mat, sh, holes, router_diameter: 8.0)
    assert_equal holes.size, svg.scan('<circle').size
    assert_operator svg.scan('<rect').size, :>=, sh['placements'].size * 2 + 2
    assert_match(/\A<svg /, svg)
  end
end
