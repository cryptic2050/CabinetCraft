# frozen_string_literal: true

module CabinetCraft
  module Manufacturing
    # Assembly documentation derived from a cabinet's panels and hardware: ordered steps and an exploded view.
    # Rule based: the order follows the usual carcass-first sequence, it is NOT a manufacturer-verified procedure.
    # Parts with a role this module does not know (custom templates) land in a generic "remaining parts" step.
    module Assembly
      # [title, roles, text]. The order is the build order.
      STEP_RULES = [
        ['Fit the toe kick', %i[toe_kick], 'Fix the toe kick to the underside of the carcass (or set the feet) before the cabinet is stood up.'],
        ['Join bottom and sides', %i[bottom side], 'Lay the bottom flat, then fit both sides. Check the corners are square before the joints are fully tightened.'],
        ['Fit rails and braces', %i[brace], 'Fix the front and rear rails between the sides. They hold the carcass square.'],
        ['Fit fixed shelves and dividers', %i[fixed_shelf divider], 'Fix these between the sides at their marked positions.'],
        ['Fit the back panel', %i[back], 'Measure both diagonals of the carcass: they must match before the back is fixed. The back holds the carcass square.'],
        ['Fit the shelves', %i[shelf], 'Fit the shelf pins at the drilled positions, then place the shelves.'],
        ['Fit the doors', %i[door], 'Fit the hinges to each door, hang the doors, then adjust the gaps.'],
        ['Fit the drawer fronts', %i[drawer_front], 'Fit the runners in the carcass and attach the fronts to the drawer boxes, then adjust the gaps.']
      ].freeze
      DRAWER_TITLE = 'Build drawer box'

      # Direction a part moves in the exploded view, as multiples of the explode amount, in cabinet axes (x right, y back, z up).
      DIRECTIONS = {
        'side_left' => [-1, 0, 0], 'side_right' => [1, 0, 0], 'bottom' => [0, 0, -1], 'back' => [0, 1, 0], 'toe_kick' => [0, 0, -1.5]
      }.freeze
      # Shelves and dividers stay between the sides (moving them by 'away from centre' can push them into drawer boxes).
      ROLE_DIRECTIONS = { fixed_shelf: [0, 0, 0], shelf: [0, 0, 0], divider: [0, 0, 0], door: [0, -1.2, 0], drawer_front: [0, -1.2, 0], brace: [0, 0, 1], drawer_box: [0, -0.5, 0] }.freeze

      module_function

      # => [{ 'n' => 1, 'title', 'text', 'parts' => [part ids], 'hardware' => [{ 'name', 'qty' }] }]
      def steps(cabinet)
        return [] unless cabinet.calculation.ok?

        panels = cabinet.panels
        hw = cabinet.hardware.group_by { |h| h['part_key'] }
        used = []
        out = []
        add = lambda do |title, text, group|
          next if group.empty?

          used.concat(group.map(&:key))
          out << step(title, text, group, hw, cabinet)
        end
        STEP_RULES.each do |title, roles, text|
          group = panels.select { |p| roles.include?(p.role) }
          group = group.sort_by(&:key)
          next add.call(title, text, group) unless roles == %i[drawer_front]

          drawer_boxes(panels).each { |n, boxes| add.call("#{DRAWER_TITLE} #{n}", 'Join the box sides, front, back and bottom, and fit the runners.', boxes) }
          add.call(title, text, group)
        end
        rest = panels.reject { |p| used.include?(p.key) }
        add.call('Fit the remaining parts', 'These parts have no built-in assembly rule (custom template): fit them as the design requires.', rest)
        finish(out, panels, hw, cabinet)
      end

      def drawer_boxes(panels)
        panels.select { |p| p.role == :drawer_box }.group_by { |p| p.key[/\Adrawer_(\d+)_/, 1] }.sort_by { |n, _| n.to_i }.map { |n, boxes| [n, boxes.sort_by(&:key)] }
      end

      def step(title, text, group, hw, cabinet)
        items = group.flat_map { |p| hw[p.key] || [] }.group_by { |h| h['name'] }.map { |name, list| { 'name' => name, 'qty' => list.sum { |h| h['qty'] } } }
        { 'title' => title, 'text' => text, 'parts' => group.map { |p| cabinet.part_id(p) }, 'hardware' => items }
      end

      def finish(out, panels, hw, cabinet)
        keys = panels.map(&:key)
        loose = hw.reject { |k, _| keys.include?(k) }.values.flatten.group_by { |h| h['name'] }.map { |n, l| { 'name' => n, 'qty' => l.sum { |h| h['qty'] } } }
        out << { 'title' => 'Fit loose hardware and check', 'text' => 'Fit the hardware that is not tied to a single part, level the cabinet and check that doors and drawers close evenly.',
                 'parts' => [], 'hardware' => loose }
        out.each_with_index.map { |s, i| { 'n' => i + 1 }.merge(s) }
      end

      # Everything the UI and the PDF need for one cabinet. Part numbers (seq) are the same in both views.
      def describe(cabinet, amount: nil)
        amount = default_amount(cabinet) if amount.nil?
        exploded = view(cabinet, amount: amount)
        assembled = view(cabinet, amount: 0)
        seq = exploded['boxes'].to_h { |b| [b['part_id'], b['seq']] }
        renumber(assembled, seq)
        rows = cabinet.part_rows.sort_by { |r| seq[r['part_id']] || 0 }
        parts = rows.map do |r|
          { 'seq' => seq[r['part_id']], 'part_id' => r['part_id'], 'name' => r['name'], 'material' => r['material'],
            'size' => "#{fmt(r['length'])} x #{fmt(r['width'])} x #{fmt(r['thickness'])}" }
        end
        { 'steps' => steps(cabinet), 'parts' => parts, 'assembled' => assembled, 'exploded' => exploded, 'amount' => amount }
      end

      def renumber(view, seq)
        view['boxes'].each { |b| b['seq'] = seq[b['part_id']] }
      end

      def fmt(v)
        v == v.round ? v.round.to_s : v.round(1).to_s
      end

      # A readable default separation: a quarter of the cabinet's largest dimension, in whole millimetres.
      def default_amount(cabinet)
        panels = cabinet.panels
        return 0 if panels.empty?

        lo = panels.map(&:min_corner).transpose.map(&:min)
        hi = panels.map(&:max_corner).transpose.map(&:max)
        (hi.zip(lo).map { |a, b| a - b }.max * 0.25).round
      end

      # { part key => [dx, dy, dz] } in mm. amount 0 means assembled.
      def explode_offsets(cabinet, amount)
        panels = cabinet.panels
        return {} if panels.empty?

        lo = panels.map(&:min_corner).transpose.map(&:min)
        hi = panels.map(&:max_corner).transpose.map(&:max)
        mid = lo.zip(hi).map { |a, b| (a + b) / 2.0 }
        dirs = {}
        generic = {} # direction guessed from the part's position (unknown role) rather than from a rule
        panels.each do |p|
          known = DIRECTIONS[p.key] || ROLE_DIRECTIONS[p.role]
          dirs[p.key] = known || outward(p, mid)
          generic[p.key] = known.nil?
        end
        mult = Hash.new(1.0)
        offsets = ->(p) { dirs[p.key].map { |v| v * amount * mult[p.key] } }
        spread_generic_parts(panels, offsets, dirs, generic, mult) if amount.positive? && generic.values.any?
        panels.to_h { |p| [p.key, offsets.call(p).map { |v| v.round(3) }] }
      end

      # Parts whose direction was guessed can end up inside a neighbour. Push such parts further out, a bit at a time, until the
      # explosion has not created any new overlap (or a few rounds have passed). Overlaps that exist when assembled are left alone.
      def spread_generic_parts(panels, offsets, dirs, generic, mult)
        already = overlapping_pairs(panels)
        6.times do
          moved = panels.map { |p| p.with(origin: p.origin.zip(offsets.call(p)).map { |a, b| a + b }) }
          clashes = overlapping_pairs(moved) - already
          pushed = false
          clashes.each do |ka, kb|
            key = [ka, kb].find { |k| generic[k] && dirs[k].any? { |v| v != 0 } } or next
            mult[key] += 0.6
            pushed = true
          end
          break unless pushed
        end
      end

      # [[key, key], ...] of parts whose volumes intersect (grooved joints are allowed to).
      def overlapping_pairs(panels)
        panels.combination(2).filter_map do |a, b|
          next if a.grooved_into.include?(b.key) || b.grooved_into.include?(a.key)

          [a.key, b.key] if a.overlaps?(b)
        end
      end

      # Away from the cabinet centre along the axis where the part is furthest off-centre; zero for parts at the centre.
      def outward(panel, mid)
        c = panel.min_corner.zip(panel.max_corner).map { |a, b| (a + b) / 2.0 }
        d = c.zip(mid).map { |a, b| a - b }
        i = d.each_index.max_by { |k| d[k].abs }
        return [0, 0, 0] if d[i].abs < 1.0

        v = [0, 0, 0]
        v[i] = d[i].positive? ? 1 : -1
        v
      end

      # Oblique projection (front face true shape, depth drawn up and to the right). Returns draw-ready polygons,
      # farthest first, with y pointing UP in the returned coordinates.
      K = 0.5
      ANGLE = 35.0 * Math::PI / 180

      def project(x, y, z)
        [x + K * y * Math.cos(ANGLE), z + K * y * Math.sin(ANGLE)]
      end

      def view(cabinet, amount: 0)
        offsets = explode_offsets(cabinet, amount)
        order = draw_order(cabinet.panels, offsets)
        boxes = order.each_with_index.map { |p, i| box(p, offsets[p.key] || [0, 0, 0], cabinet.part_id(p), i + 1) }
        pts = boxes.flat_map { |b| b['faces'].flat_map { |f| f['points'] } }
        xs = pts.map(&:first)
        ys = pts.map(&:last)
        { 'boxes' => boxes, 'bounds' => xs.empty? ? [0, 0, 1, 1] : [xs.min, ys.min, xs.max, ys.max], 'amount' => amount }
      end

      EPS = 1e-6

      # Panels in painter's order (farthest first). The viewer looks from the front (-y), the right (+x) and above (+z). For two
      # disjoint boxes that overlap on screen, one can hide the other only if on EVERY axis that separates them it lies on the viewer's
      # side; that gives an exact "draw this one first" relation, and the order is a topological sort of it. A cycle (three or more
      # boxes that hide each other in a ring, rare for cabinet parts) falls back to the farthest centre.
      def draw_order(panels, offsets)
        boxes = panels.map do |p|
          o = offsets[p.key] || [0, 0, 0]
          { panel: p, lo: p.min_corner.zip(o).map { |a, b| a + b }, hi: p.max_corner.zip(o).map { |a, b| a + b } }
        end
        boxes.each { |b| b[:rect] = screen_rect(b[:lo], b[:hi]); b[:depth] = depth_key(b) }
        n = boxes.size
        after = Array.new(n) { [] } # after[i]: boxes that must be drawn after i
        indeg = Array.new(n, 0)
        n.times do |i|
          (i + 1...n).each do |j|
            next unless rects_overlap?(boxes[i][:rect], boxes[j][:rect])

            a_hides_b = hides?(boxes[i], boxes[j])
            b_hides_a = hides?(boxes[j], boxes[i])
            if a_hides_b && !b_hides_a then (after[j] << i; indeg[i] += 1)
            elsif b_hides_a && !a_hides_b then (after[i] << j; indeg[j] += 1)
            end
          end
        end
        out = []
        left = (0...n).to_a
        until left.empty?
          ready = left.select { |i| indeg[i].zero? }
          ready = left if ready.empty? # a cycle: break it at the farthest box
          pick = ready.min_by { |i| [boxes[i][:depth], i] }
          left.delete(pick)
          out << boxes[pick][:panel]
          after[pick].each { |j| indeg[j] -= 1 }
        end
        out
      end

      # Farther from the viewer sorts first (smaller value).
      def depth_key(b)
        c = b[:lo].zip(b[:hi]).map { |x, y| (x + y) / 2.0 }
        (-(c[1] - c[0] - c[2])).round(6)
      end

      def screen_rect(lo, hi)
        pts = [lo[0], hi[0]].product([lo[1], hi[1]], [lo[2], hi[2]]).map { |x, y, z| project(x, y, z) }
        xs = pts.map(&:first)
        ys = pts.map(&:last)
        [xs.min, ys.min, xs.max, ys.max]
      end

      def rects_overlap?(a, b)
        a[0] < b[2] - EPS && b[0] < a[2] - EPS && a[1] < b[3] - EPS && b[1] < a[3] - EPS
      end

      # true when box a can be in front of (hide part of) box b.
      def hides?(a, b)
        separated = false
        # x: the viewer is at +x, so higher x is nearer
        if b[:hi][0] <= a[:lo][0] + EPS then separated = true
        elsif a[:hi][0] <= b[:lo][0] + EPS then return false
        end
        # y: the viewer is at -y, so lower y is nearer
        if a[:hi][1] <= b[:lo][1] + EPS then separated = true
        elsif b[:hi][1] <= a[:lo][1] + EPS then return false
        end
        # z: the viewer is above, so higher z is nearer
        if b[:hi][2] <= a[:lo][2] + EPS then separated = true
        elsif a[:hi][2] <= b[:lo][2] + EPS then return false
        end
        separated
      end

      def box(panel, off, part_id, seq)
        x0, y0, z0 = panel.min_corner.zip(off).map { |a, b| a + b }
        x1, y1, z1 = panel.max_corner.zip(off).map { |a, b| a + b }
        faces = [
          ['front', [[x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1]], 0.0],
          ['right', [[x1, y0, z0], [x1, y1, z0], [x1, y1, z1], [x1, y0, z1]], -0.18],
          ['top', [[x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]], 0.18]
        ].map { |kind, corners, shade| { 'kind' => kind, 'shade' => shade, 'points' => corners.map { |c| project(*c).map { |v| v.round(3) } } } }
        { 'key' => panel.key, 'part_id' => part_id, 'name' => panel.name, 'seq' => seq, 'role' => panel.role.to_s, 'faces' => faces,
          'anchor' => project((x0 + x1) / 2.0, y0, (z0 + z1) / 2.0).map { |v| v.round(3) } }
      end
    end
  end
end
