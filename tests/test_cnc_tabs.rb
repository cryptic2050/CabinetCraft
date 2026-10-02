# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'gcode_sim'

class TestCncTabs < Minitest::Test
  include TestParams
  Cnc = CabinetCraft::Manufacturing::Cnc
  MC = CabinetCraft::MachiningConfig
  N = CabinetCraft::Manufacturing::Nesting

  TAB_Z = -15.0 # material top at 0, 18 mm board, 3 mm tabs
  THROUGH = -18.3

  def setup
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Standards.current = CabinetCraft::Standards.new
    MC.current = MC.new
    cab = CabinetCraft::Cabinet.build(type: 'base_cabinet', label: 'B01', params: params('width' => 800, 'height' => 820, 'door_count' => 2, 'shelf_count' => 1))
    rows = cab.part_rows.select { |r| r['material'] == '18mm MDF' }
    @ops_by_uid = CabinetCraft::Manufacturing::Machining.operations(cab)['ops'].group_by { |o| o['part_uid'] }
    parts = rows.map { |r| { 'uid' => r['part_uid'], 'part_id' => r['part_id'], 'name' => r['name'], 'length' => r['length'], 'width' => r['width'], 'grain' => r['grain'], 'cabinet_label' => 'B01' } }
    @mat = N.nest(parts, { 'material' => '18mm MDF', 'sheet_length' => 2440.0, 'sheet_width' => 1220.0, 'grain_free' => true }, { 'kerf' => 8.0, 'trim' => 10.0, 'spacing' => 0.0 })
    @machine = MC::DEFAULT_MACHINE.merge('tools' => MC::DEFAULT_MACHINE['tools'].dup)
  end

  def tabbed(over = {})
    @machine.merge({ 'tabs' => true }.merge(over))
  end

  def program_text(mach, mat = @mat, thickness = 18.0)
    Cnc.build(mat, @ops_by_uid, mach, thickness, face_up: 'a').map { |p| Cnc.render(p, mach, [], name: 'T') }
  end

  def sim(mach, mat = @mat, thickness = 18.0, surface = 0.0)
    program_text(mach, mat, thickness).map { |t| GcodeSim.run(t, surface_top: surface) }
  end

  # Cutting moves of the router (tool 1) at tab height that travel in XY: the tab tops.
  def tab_tops(result, z = TAB_Z)
    result.moves.select { |m| m[:type] == :cut && m[:tool] == 1 && (m[:to]['Z'] - z).abs < 1e-6 && (m[:from]['Z'] - z).abs < 1e-6 && (m[:from]['X'] != m[:to]['X'] || m[:from]['Y'] != m[:to]['Y']) }
  end

  def rects(sheet)
    r = 4.0
    sheet['placements'].map { |p| [p['x'] - r, p['y'] - r, p['x'] + p['w'] + r, p['y'] + p['h'] + r] }
  end

  def test_tabs_are_off_by_default_and_the_program_says_so
    res = sim(@machine)
    assert(res.all? { |r| tab_tops(r).empty? })
    assert(program_text(@machine).all? { |t| t.include?('No tabs or hold-down logic generated') })
    assert_equal 0, Cnc.build(@mat, @ops_by_uid, @machine, 18.0, face_up: 'a').sum { |p| p['stats']['tabs'] }
  end

  def test_every_tab_is_on_a_part_edge_clear_of_the_corners_with_the_set_width
    mach = tabbed('tab_width' => 10.0, 'tab_spacing' => 500.0)
    sim(mach).each_with_index do |r, i|
      tops = tab_tops(r)
      refute_empty tops, "sheet #{i + 1} has no tabs"
      tops.each do |m|
        x0, y0 = m[:from].values_at('X', 'Y')
        x1, y1 = m[:to].values_at('X', 'Y')
        assert_in_delta 10.0, Math.hypot(x1 - x0, y1 - y0), 0.01
        edge = rects(@mat['sheets'][i]).flat_map { |a, b, c, d| [[[a, b], [c, b]], [[c, b], [c, d]], [[c, d], [a, d]], [[a, d], [a, b]]] }.find do |(px, py), (qx, qy)|
          on = ->(x, y) { ((qx - px) * (y - py) - (qy - py) * (x - px)).abs < 0.01 && x.between?([px, qx].min - 0.01, [px, qx].max + 0.01) && y.between?([py, qy].min - 0.01, [py, qy].max + 0.01) }
          on.call(x0, y0) && on.call(x1, y1)
        end
        refute_nil edge, "tab #{[x0, y0, x1, y1].inspect} is not on a part edge"
        (px, py), (qx, qy) = edge
        len = Math.hypot(qx - px, qy - py)
        d0 = Math.hypot(x0 - px, y0 - py)
        d1 = Math.hypot(x1 - px, y1 - py)
        near = [d0, d1].min
        far = [d0, d1].max
        assert_operator near, :>=, 10.0 - 0.01, 'tab too close to a corner'
        assert_operator len - far, :>=, 10.0 - 0.01, 'tab too close to a corner'
      end
    end
  end

  def test_the_cutter_is_only_raised_to_tab_height_never_cut_through_below_it_on_a_tab
    mach = tabbed
    sim(mach).each do |r|
      cuts = r.moves.select { |m| m[:type] == :cut && m[:tool] == 1 }
      assert_operator cuts.map { |m| m[:to]['Z'] }.min, :<=, THROUGH + 1e-6 # the board is still cut through elsewhere
      tab_tops(r).each { |m| assert_in_delta TAB_Z, m[:to]['Z'], 1e-6 }
      assert_empty r.violations
      assert r.ended
    end
  end

  def test_upper_passes_have_no_tabs
    # 18.3 mm of cutting in 9 mm passes: -6.1, -12.2 (both above the tabs at -15) and -18.3 (the tabbed pass)
    res = sim(tabbed)
    parts = @mat['sheets'].sum { |sh| sh['placements'].size }
    [-6.1, -12.2].each do |z|
      xy = res.flat_map(&:moves).select { |m| m[:type] == :cut && m[:tool] == 1 && (m[:to]['Z'] - z).abs < 1e-6 && (m[:from]['Z'] - z).abs < 1e-6 && (m[:from]['X'] != m[:to]['X'] || m[:from]['Y'] != m[:to]['Y']) }
      assert_equal parts * 4, xy.size, "pass at #{z}: one move per edge, no tab detours"
    end
    tabbed_pass = res.flat_map(&:moves).select { |m| m[:type] == :cut && m[:tool] == 1 && (m[:to]['Z'] - THROUGH).abs < 1e-6 && (m[:from]['Z'] - THROUGH).abs < 1e-6 && (m[:from]['X'] != m[:to]['X'] || m[:from]['Y'] != m[:to]['Y']) }
    assert_operator tabbed_pass.size, :>, parts * 4 # the last pass is split around the tabs
  end

  def test_longer_edges_get_more_tabs_with_a_smaller_spacing
    few = sim(tabbed('tab_spacing' => 3000.0)).sum { |r| tab_tops(r).size }
    many = sim(tabbed('tab_spacing' => 300.0)).sum { |r| tab_tops(r).size }
    assert_operator many, :>, few
    assert_operator few, :>, 0
  end

  def test_stats_count_the_tabs_that_the_g_code_contains
    mach = tabbed
    programs = Cnc.build(@mat, @ops_by_uid, mach, 18.0, face_up: 'a')
    programs.zip(sim(mach)).each { |p, r| assert_equal tab_tops(r).size, p['stats']['tabs'] }
  end

  def test_tab_height_is_limited_on_thin_sheets
    thin = @mat.merge('material' => '3mm HDF')
    res = sim(tabbed('tab_height' => 3.0), thin, 3.0)
    # 3 mm sheet: tabs at most half the thickness: z = -3 + 1.5 = -1.5
    refute_empty res.flat_map { |r| tab_tops(r, -1.5) }
    assert(res.all? { |r| tab_tops(r, 0.0).empty? })
  end

  def test_a_small_part_still_gets_tabs
    tiny = { 'material' => '18mm MDF', 'sheet_length' => 2440.0, 'sheet_width' => 1220.0, 'trim' => 10.0, 'kerf' => 8.0, 'sheets' => [{ 'index' => 0, 'placements' => [{ 'uid' => 'u', 'part_id' => 'B01-X', 'x' => 100.0, 'y' => 100.0, 'w' => 60.0, 'h' => 60.0, 'rotated' => false }] }] }
    n = sim(tabbed, tiny).sum { |r| tab_tops(r).size }
    assert_operator n, :>=, 2
  end

  def test_the_small_part_warning_goes_away_when_tabs_are_on
    tiny = { 'material' => '18mm MDF', 'sheet_length' => 2440.0, 'sheet_width' => 1220.0, 'trim' => 10.0, 'kerf' => 8.0, 'sheets' => [{ 'index' => 0, 'placements' => [{ 'uid' => 'u', 'part_id' => 'B01-X', 'x' => 100.0, 'y' => 100.0, 'w' => 60.0, 'h' => 60.0, 'rotated' => false }] }] }
    nest = { 'materials' => [tiny] }
    off = Cnc.check(nest, [], @machine).map { |i| i['code'] }
    on = Cnc.check(nest, [], tabbed).map { |i| i['code'] }
    assert_includes off, 'cnc_small_part'
    refute_includes on, 'cnc_small_part'
  end

  def test_all_posts_render_tabbed_programs
    %w[iso grbl].each do |post|
      mach = tabbed('post' => post)
      texts = program_text(mach)
      assert(texts.all? { |t| t.include?('-15.000') || t.include?('-15') })
    end
  end

  def test_machine_settings_are_validated_and_old_machines_keep_working
    cfg = MC.new
    base = MC::DEFAULT_MACHINE.reject { |k, _| k == 'id' }.merge('name' => 'M')
    m = cfg.save_machine(base.reject { |k, _| k.start_with?('tab') }) # saved before tabs existed
    assert_equal [false, 10.0, 3.0, 500.0], m.values_at('tabs', 'tab_width', 'tab_height', 'tab_spacing')
    ok = cfg.save_machine(base.merge('tabs' => true, 'tab_width' => '12', 'tab_height' => 2, 'tab_spacing' => 400))
    assert_equal [true, 12.0, 2.0, 400.0], ok.values_at('tabs', 'tab_width', 'tab_height', 'tab_spacing')
    [{ 'tab_width' => 1 }, { 'tab_width' => 99 }, { 'tab_height' => 0 }, { 'tab_height' => 11 }, { 'tab_spacing' => 50 }, { 'tab_width' => 'abc' }].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { cfg.save_machine(base.merge('tabs' => true).merge(bad)) }
    end
    store = CabinetCraft::Hardware::MemoryStore.new
    store.write(JSON.generate('machines' => [{ 'id' => 'machine_1', 'name' => 'Old', 'tools' => MC::DEFAULT_MACHINE['tools'] }]))
    assert_equal false, MC.new(store).machine('machine_1')['tabs']
  end
end
