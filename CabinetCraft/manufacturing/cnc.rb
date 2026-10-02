# frozen_string_literal: true

require_relative 'cnc_posts'

module CabinetCraft
  module Manufacturing
    # Builds machine-neutral CNC programs from a nesting result + machining operations.
    #
    # Scope (be aware): flat-bed 3-axis router. Vertical (face) holes and rectangular part outlines only.
    # NOT generated: tabs / onion skin / hold-down logic, cutter compensation (G41/G42; the offset path is
    # calculated explicitly), horizontal edge boring, helical interpolation of large holes, tool-path simulation.
    module Cnc
      EPS = 1e-6
      SMALL_PART = 80.0 # mm: smaller parts may shift when cut free

      module_function

      # Local part coordinates -> sheet coordinates (physical sheet, bottom-left origin, face A up).
      def to_sheet(p, lx, ly)
        p['rotated'] ? [p['x'] + ly, p['y'] + lx] : [p['x'] + lx, p['y'] + ly]
      end

      # All face operations for one nested sheet, in sheet coordinates (unmirrored, as seen from face A).
      def sheet_holes(sheet, ops_by_uid)
        sheet['placements'].flat_map do |p|
          (ops_by_uid[p['uid']] || []).select { |o| o['target'] == 'face' }.map do |o|
            x, y = to_sheet(p, o['x'], o['y'])
            { 'x' => x.round(3), 'y' => y.round(3), 'dia' => o['dia'], 'depth' => o['depth'], 'through' => o['through'],
              'side' => o['side'], 'kind' => o['kind'], 'part_id' => p['part_id'] }
          end
        end
      end

      def router_tool(machine)
        machine['tools'].select { |t| t['kind'] == 'router' }.min_by { |t| t['number'] }
      end

      def drill_tool(machine, dia)
        machine['tools'].select { |t| t['kind'] == 'drill' && (t['diameter'] - dia).abs < 0.01 }.min_by { |t| t['number'] }
      end

      # Issues that make a program unsafe or impossible. Errors block G-code export.
      def check(nest, ops, machine, face_up: 'a')
        issues = []
        r = router_tool(machine)
        edge = ops.count { |o| o['target'] == 'edge' }
        issues << warn('cnc_edge_ops', "#{edge} horizontal edge bores are not part of router output (they need a horizontal boring head or manual drilling)") if edge.positive?
        other = ops.count { |o| o['target'] == 'face' && o['side'] != face_up }
        issues << warn('cnc_other_face', "#{other} holes are on face #{face_up == 'a' ? 'B' : 'A'}: they are excluded from this program (export the other face separately)") if other.positive?
        dias = ops.select { |o| o['target'] == 'face' && o['side'] == face_up }.map { |o| o['dia'] }.uniq.sort
        dias.each do |d|
          issues << err('cnc_no_tool', "No drill of Ø#{d} mm in machine '#{machine['name']}' - add a tool or change the hardware") unless drill_tool(machine, d)
        end
        nest['materials'].each do |m|
          m['sheets'].each do |sh|
            issues.concat(sheet_issues(m, sh, r, machine))
          end
        end
        issues.uniq
      end

      def sheet_issues(m, sh, router, machine)
        out = []
        d = router['diameter']
        pl = sh['placements']
        close = pl.combination(2).filter_map do |a, b|
          dx = [b['x'] - (a['x'] + a['w']), a['x'] - (b['x'] + b['w']), 0].max
          dy = [b['y'] - (a['y'] + a['h']), a['y'] - (b['y'] + b['h']), 0].max
          gap = Math.hypot(dx, dy)
          [gap, a, b] if gap < d - EPS
        end
        unless close.empty?
          gap, a, b = close.min_by(&:first)
          out << err('cnc_kerf_too_small', "#{m['material']} sheet #{sh['index'] + 1}: #{close.size} pairs of parts are closer than the router (\u00D8#{d} mm); closest is #{a['part_id']} / #{b['part_id']} at #{gap.round(2)} mm - raise the nesting kerf/spacing to at least #{d}")
        end
        pl.each do |p|
          out << warn('cnc_small_part', "#{p['part_id']} is #{[p['w'], p['h']].min.round(1)} mm wide: it may move when cut free (tabs are not generated)") if [p['w'], p['h']].min < SMALL_PART
          r = d / 2.0
          if p['x'] - r < -EPS || p['y'] - r < -EPS || p['x'] + p['w'] + r > m['sheet_length'] + EPS || p['y'] + p['h'] + r > m['sheet_width'] + EPS
            out << warn('cnc_outside_sheet', "#{p['part_id']}: the cutting path leaves the sheet edge (raise the trim to at least #{r})")
          end
        end
        out
      end

      def err(code, msg)
        { 'severity' => 'error', 'code' => code, 'message' => msg }
      end

      def warn(code, msg)
        { 'severity' => 'warning', 'code' => code, 'message' => msg }
      end

      # material: one entry of nest['materials']; thickness in mm. Returns one program per sheet:
      # [{ 'index', 'events', 'stats' }]
      def build(material, ops_by_uid, machine, thickness, face_up: 'a')
        material['sheets'].reject { |s| s['placements'].empty? }.map do |sh|
          events, stats = sheet_events(material, sh, ops_by_uid, machine, thickness, face_up)
          { 'index' => sh['index'], 'events' => events, 'stats' => stats }
        end
      end

      def sheet_events(m, sh, ops_by_uid, machine, thickness, face_up)
        top = machine['z_zero'] == 'spoilboard' ? thickness : 0.0
        safe = top + machine['safe_z']
        retract = top + 2.0
        sl = m['sheet_length']
        sw = m['sheet_width']
        tx = lambda do |x, y|
          x = sl - x if face_up == 'b'
          x = sl - x if %w[bottom_right top_right].include?(machine['origin'])
          y = sw - y if %w[top_left top_right].include?(machine['origin'])
          [x.round(3), y.round(3)]
        end
        events = [{ 't' => 'comment', 'text' => "#{m['material']} #{thickness}mm, sheet #{sh['index'] + 1}, #{sl} x #{sw}, face #{face_up.upcase} up" },
                  { 't' => 'comment', 'text' => 'No tabs or hold-down logic generated. Origin: ' + machine['origin'].tr('_', ' ') + ', Z0 at ' + machine['z_zero'].tr('_', ' ') },
                  { 't' => 'rapid', 'x' => nil, 'y' => nil, 'z' => safe }]
        stats = { 'drills' => 0, 'routes' => 0, 'tool_changes' => 0 }

        holes = sheet_holes(sh, ops_by_uid).select { |h| h['side'] == face_up }
        holes.group_by { |h| h['dia'] }.sort.each do |dia, hs|
          tool = drill_tool(machine, dia) or raise ArgumentError, "No drill of #{dia} mm in machine '#{machine['name']}'"
          events << tool_event(tool, machine)
          stats['tool_changes'] += 1
          nearest(hs.map { |h| [h, tx.call(h['x'], h['y'])] }).each do |h, (x, y)|
            z = h['through'] ? (top - thickness) - machine['cut_extra'] : top - h['depth']
            events << { 't' => 'drill', 'x' => x, 'y' => y, 'z' => z.round(3), 'r' => retract, 'safe' => safe, 'f' => machine['feed_drill'] }
            stats['drills'] += 1
          end
          events << { 't' => 'drill_end' }
          events << { 't' => 'rapid', 'x' => nil, 'y' => nil, 'z' => safe }
        end

        if face_up == 'a'
          router = router_tool(machine)
          events << tool_event(router, machine)
          stats['tool_changes'] += 1
          r = router['diameter'] / 2.0
          depth = thickness + machine['cut_extra']
          passes = (depth / machine['pass_depth']).ceil
          starts = sh['placements'].map { |p| [p, tx.call(p['x'] - r, p['y'] - r)] }
          nearest(starts).each do |p, (sx, sy)|
            corners = [[p['x'] - r, p['y'] - r], [p['x'] + p['w'] + r, p['y'] - r], [p['x'] + p['w'] + r, p['y'] + p['h'] + r], [p['x'] - r, p['y'] + p['h'] + r]]
            path = (corners + [corners.first]).map { |cx, cy| tx.call(cx, cy) }
            events << { 't' => 'comment', 'text' => "Cut #{p['part_id']}" }
            events << { 't' => 'rapid', 'x' => sx, 'y' => sy, 'z' => safe }
            events << { 't' => 'rapid', 'x' => sx, 'y' => sy, 'z' => retract }
            passes.times do |i|
              z = (top - depth * (i + 1) / passes.to_f).round(3)
              z = ((top - thickness) - machine['cut_extra']).round(3) if i == passes - 1
              events << { 't' => 'linear', 'x' => sx, 'y' => sy, 'z' => z, 'f' => machine['feed_plunge'] }
              path[1..].each { |x, y| events << { 't' => 'linear', 'x' => x, 'y' => y, 'z' => z, 'f' => machine['feed_cut'] } }
            end
            events << { 't' => 'rapid', 'x' => sx, 'y' => sy, 'z' => safe }
            stats['routes'] += 1
          end
        end
        events << { 't' => 'end', 'safe' => safe }
        [events, stats]
      end

      def tool_event(tool, machine)
        { 't' => 'tool', 'number' => tool['number'], 'kind' => tool['kind'], 'diameter' => tool['diameter'], 'rpm' => machine['spindle_rpm'],
          'desc' => "#{tool['kind']} #{tool['diameter']}mm" }
      end

      # Greedy nearest-neighbour ordering starting near the machine origin. items: [[payload, [x, y]], ...]
      def nearest(items)
        left = items.dup
        out = []
        cur = [0.0, 0.0]
        until left.empty?
          nxt = left.min_by { |_, (x, y)| Math.hypot(x - cur[0], y - cur[1]) }
          left.delete_at(left.index { |i| i.equal?(nxt) })
          out << nxt
          cur = nxt[1]
        end
        out
      end

      def render(program, machine, custom_posts, name:)
        post = CncPosts.build(machine['post'], machine, custom_posts)
        post.render(program['events'], 'name' => name, 'sheet' => "sheet #{program['index'] + 1}")
      end
    end
  end
end
