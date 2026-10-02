# frozen_string_literal: true

require_relative 'cut_sequence'

module CabinetCraft
  module Manufacturing
    # 2D sheet nesting for rectangular parts.
    #
    # ALGORITHM (heuristic - NOT guaranteed optimal): guillotine bin packing with a
    # best-area-fit rule and shorter-leftover-axis splits. Several part orderings are
    # tried and the best result is kept (fewest unplaced parts, then fewest sheets,
    # then the largest reusable offcut). Optimality is not claimed or checked.
    #
    # Rules enforced: grain (a part with directional grain is never rotated against
    # the sheet's grain, which runs along the sheet length; sheets of non-directional
    # material may rotate freely), kerf, edge trim, extra minimum spacing, and
    # locked parts that must stay exactly where the user put them.
    module Nesting
      DEFAULTS = { 'kerf' => 4.0, 'trim' => 10.0, 'spacing' => 0.0, 'min_offcut' => 150.0 }.freeze
      LIMITS = { 'kerf' => [0.0, 10.0], 'trim' => [0.0, 50.0], 'spacing' => [0.0, 50.0], 'min_offcut' => [20.0, 1000.0] }.freeze
      MAX_SHEETS = 200
      EPS = 1e-6

      Free = Struct.new(:x, :y, :w, :h)

      module_function

      def normalize_settings(raw)
        out = {}
        DEFAULTS.each do |k, d|
          v = raw && raw.key?(k) && !raw[k].to_s.empty? ? Float(raw[k]) : d
          lo, hi = LIMITS[k]
          raise ArgumentError, "#{k} must be between #{lo} and #{hi}" unless v.between?(lo, hi)

          out[k] = v
        end
        %w[sheet_length sheet_width].each do |k|
          next unless raw && !raw[k].to_s.empty?

          v = Float(raw[k])
          raise ArgumentError, "#{k} must be between 300 and 6000" unless v.between?(300, 6000)

          out[k] = v
        end
        out
      end

      # Allowed orientations as [width along sheet X, height along sheet Y, rotated?].
      # The sheet's grain runs along its length (X) or, for some materials, its width (Y): a part with directional
      # grain must have its grain direction on the same axis as the sheet's.
      def orientations(part, grain_free, grain_axis = 'length')
        l = part['length'].to_f
        w = part['width'].to_f
        return [[l, w, false], [w, l, true]] if grain_free || part['grain'] == 'none'

        rotated = (part['grain'] == 'width') != (grain_axis == 'width')
        rotated ? [[w, l, true]] : [[l, w, false]]
      end

      # Expected rotation for a grain-constrained part, or nil if free.
      def required_rotation(part_grain, grain_free, grain_axis)
        return nil if grain_free || part_grain == 'none'

        (part_grain == 'width') != (grain_axis == 'width')
      end

      # parts:   [{ 'uid', 'part_id', 'name', 'length', 'width', 'grain', 'cabinet_label' }]
      # sheet:   { 'material', 'sheet_length', 'sheet_width', 'grain_free' }
      # locked:  { uid => { 'sheet' => i, 'x' =>, 'y' =>, 'rotated' => bool } } (physical sheet coordinates, mm)
      # Returns a Hash (see below), JSON-safe.
      def nest(parts, sheet, settings, locked = {})
        s = DEFAULTS.merge(settings || {})
        trim = s['trim']
        uw = sheet['sheet_length'] - 2 * trim
        uh = sheet['sheet_width'] - 2 * trim
        gap = s['kerf'] + s['spacing']
        ctx = { sheet: sheet, uw: uw, uh: uh, gap: gap, trim: trim, settings: s }

        released = []
        fixed, auto = split_locked(parts, locked, ctx, released)
        build_result(search(auto, fixed, ctx), ctx, released)
      end

      FITS = %i[area short long].freeze     # how a free rectangle is scored for a part
      SPLITS = %i[short long].freeze        # which leftover axis the guillotine cut follows

      # Tries every sort order x fit rule x split rule, then seeded random perturbations of the three best orders, and keeps
      # the best packing (fewest unplaced, then fewest sheets, then the largest free block on the last sheet). Deterministic:
      # the same input always gives the same layout. Still a heuristic: nothing here proves a layout optimal.
      def search(auto, fixed, ctx)
        runs = []
        sort_orders.each do |order|
          sorted = auto.sort_by(&order)
          FITS.each { |fit| SPLITS.each { |split| runs << run(sorted, fixed, ctx, fit: fit, split: split).merge(order: sorted, fit: fit, split: split) } }
        end
        rng = Random.new(auto.size * 7919 + auto.sum { |p| p['length'] * p['width'] }.to_i % 100_000)
        per = auto.size < 2 ? 0 : (random_runs(auto.size) / 3.0).ceil # nothing to reorder with fewer than two parts
        runs.sort_by { |r| quality(r) }.first(3).each do |base|
          per.times do
            order = perturb(base[:order], rng)
            runs << run(order, fixed, ctx, fit: base[:fit], split: base[:split]).merge(order: order, fit: base[:fit], split: base[:split])
          end
        end
        runs.min_by { |r| quality(r) }
      end

      def quality(run)
        [run[:unplaced].size, run[:sheets].size, -run[:offcut]]
      end

      # How many extra random packings to try: fewer for big projects, so the time stays reasonable.
      def random_runs(count)
        if count <= 40 then 48
        elsif count <= 100 then 24
        elsif count <= 250 then 9
        elsif count <= 500 then 3
        else 0
        end
      end

      # Moves a few parts one or two places in the order (the order stays mostly "big first").
      def perturb(order, rng)
        return order if order.size < 2

        out = order.dup
        [out.size / 4, 1].max.times do
          i = rng.rand(out.size)
          j = [[i + rng.rand(-3..3), 0].max, out.size - 1].min
          out.insert(j, out.delete_at(i))
        end
        out
      end

      def sort_orders
        [
          ->(p) { [-p['length'] * p['width'], -p['length'], p['part_id'].to_s] },
          ->(p) { [-[p['length'], p['width']].max, -p['length'] * p['width'], p['part_id'].to_s] },
          ->(p) { [-[p['length'], p['width']].min, -[p['length'], p['width']].max, p['part_id'].to_s] },
          ->(p) { [-(p['length'] + p['width']), p['part_id'].to_s] }
        ]
      end

      # Locked parts that still fit are kept; the rest are released with a reason.
      def split_locked(parts, locked, ctx, released)
        fixed = []
        auto = []
        parts.each do |p|
          lk = locked[p['uid']]
          unless lk
            auto << p
            next
          end
          w, h = lk['rotated'] ? [p['width'], p['length']] : [p['length'], p['width']]
          reason = lock_problem(p, lk, w, h, fixed, ctx)
          if reason
            released << { 'uid' => p['uid'], 'part_id' => p['part_id'], 'reason' => reason }
            auto << p
          else
            fixed << { part: p, sheet: lk['sheet'].to_i, x: lk['x'].to_f - ctx[:trim], y: lk['y'].to_f - ctx[:trim],
                       w: w, h: h, rotated: lk['rotated'] ? true : false }
          end
        end
        [fixed, auto]
      end

      def lock_problem(part, lk, w, h, fixed, ctx)
        return 'part size changed' unless lk['sig'].nil? || lk['sig'] == signature(part)
        return 'sheet index out of range' unless lk['sheet'].to_i.between?(0, MAX_SHEETS - 1)

        rotated = lk['rotated'] ? true : false
        return 'grain direction forbids this rotation' unless orientations(part, ctx[:sheet]['grain_free'], ctx[:sheet]['grain_axis'] || 'length').any? { |_, _, r| r == rotated }

        x = lk['x'].to_f - ctx[:trim]
        y = lk['y'].to_f - ctx[:trim]
        return 'outside the sheet (trim or sheet size changed)' if x < -EPS || y < -EPS || x + w > ctx[:uw] + EPS || y + h > ctx[:uh] + EPS

        clash = fixed.find { |f| f[:sheet] == lk['sheet'].to_i && overlap?(f[:x], f[:y], f[:w] + ctx[:gap], f[:h] + ctx[:gap], x, y, w + ctx[:gap], h + ctx[:gap]) }
        clash ? "too close to #{clash[:part]['part_id']}" : nil
      end

      def signature(part)
        "#{part['length'].round(1)}x#{part['width'].round(1)}"
      end

      def overlap?(ax, ay, aw, ah, bx, by, bw, bh)
        ax < bx + bw - EPS && bx < ax + aw - EPS && ay < by + bh - EPS && by < ay + ah - EPS
      end

      # One packing run for a given part order.
      def run(order, fixed, ctx, fit: :area, split: :short)
        gap = ctx[:gap]
        sheets = []
        new_sheet = -> { sheets << { free: [Free.new(0.0, 0.0, ctx[:uw] + gap, ctx[:uh] + gap)], placed: [] } }
        top = fixed.map { |f| f[:sheet] }.max
        (top + 1).times { new_sheet.call } if top
        fixed.each do |f|
          sh = sheets[f[:sheet]]
          sh[:placed] << f.merge(locked: true)
          subtract(sh[:free], f[:x], f[:y], f[:w] + gap, f[:h] + gap)
        end

        unplaced = []
        order.each do |part|
          opts = orientations(part, ctx[:sheet]['grain_free'], ctx[:sheet]['grain_axis'] || 'length')
          pick = best_spot(sheets, opts, gap, fit)
          if pick.nil? && sheets.size < MAX_SHEETS && opts.any? { |w, h, _| w <= ctx[:uw] + EPS && h <= ctx[:uh] + EPS }
            new_sheet.call
            pick = best_spot(sheets, opts, gap, fit)
          end
          if pick
            place(sheets[pick[:sheet]], part, pick, gap, split)
          else
            unplaced << part
          end
        end
        last = sheets.last
        offcut = last ? last[:free].map { |f| [f.w - gap, 0].max * [f.h - gap, 0].max }.max.to_f : 0.0
        { sheets: sheets, unplaced: unplaced, offcut: offcut, gap: gap }
      end

      def best_spot(sheets, opts, gap, fit = :area)
        best = nil
        sheets.each_with_index do |sh, si|
          sh[:free].each_with_index do |f, fi|
            opts.each do |w, h, rot|
              iw = w + gap
              ih = h + gap
              next if iw > f.w + EPS || ih > f.h + EPS

              area = f.w * f.h - iw * ih
              score = case fit
                      when :short then [[f.w - iw, f.h - ih].min, area, si]
                      when :long then [[f.w - iw, f.h - ih].max, area, si]
                      else [area, [f.w - iw, f.h - ih].min, si]
                      end
              best = { score: score, sheet: si, free: fi, w: w, h: h, rotated: rot } if best.nil? || (score <=> best[:score]) == -1
            end
          end
        end
        best
      end

      def place(sheet, part, pick, gap, split = :short)
        f = sheet[:free].delete_at(pick[:free])
        iw = pick[:w] + gap
        ih = pick[:h] + gap
        sheet[:placed] << { part: part, x: f.x, y: f.y, w: pick[:w], h: pick[:h], rotated: pick[:rotated], locked: false }
        right_w = f.w - iw
        top_h = f.h - ih
        if (right_w < top_h) == (split == :short) # :short splits along the shorter leftover axis, :long along the longer
          add_free(sheet[:free], f.x + iw, f.y, right_w, ih)
          add_free(sheet[:free], f.x, f.y + ih, f.w, top_h)
        else
          add_free(sheet[:free], f.x + iw, f.y, right_w, f.h)
          add_free(sheet[:free], f.x, f.y + ih, iw, top_h)
        end
      end

      def add_free(list, x, y, w, h)
        list << Free.new(x, y, w, h) if w > EPS && h > EPS
      end

      # Removes the rectangle (ox, oy, ow, oh) from the free list, keeping the pieces disjoint.
      def subtract(free, ox, oy, ow, oh)
        out = []
        free.each do |f|
          unless overlap?(f.x, f.y, f.w, f.h, ox, oy, ow, oh)
            out << f
            next
          end
          add_free(out, f.x, f.y, ox - f.x, f.h) if ox > f.x + EPS
          add_free(out, ox + ow, f.y, f.x + f.w - (ox + ow), f.h) if ox + ow < f.x + f.w - EPS
          x0 = [f.x, ox].max
          x1 = [f.x + f.w, ox + ow].min
          add_free(out, x0, f.y, x1 - x0, oy - f.y) if oy > f.y + EPS
          add_free(out, x0, oy + oh, x1 - x0, f.y + f.h - (oy + oh)) if oy + oh < f.y + f.h - EPS
        end
        free.replace(out)
      end

      def build_result(run, ctx, released)
        sheet_area = ctx[:sheet]['sheet_length'] * ctx[:sheet]['sheet_width']
        sheets = run[:sheets].each_with_index.map do |sh, i|
          placements = sh[:placed].sort_by { |p| [p[:y], p[:x]] }.map do |p|
            { 'uid' => p[:part]['uid'], 'part_id' => p[:part]['part_id'], 'name' => p[:part]['name'],
              'cabinet_label' => p[:part]['cabinet_label'],
              'x' => (p[:x] + ctx[:trim]).round(2), 'y' => (p[:y] + ctx[:trim]).round(2),
              'w' => p[:w].round(2), 'h' => p[:h].round(2), 'rotated' => p[:rotated], 'locked' => p[:locked],
              'length' => p[:part]['length'], 'width' => p[:part]['width'], 'grain' => p[:part]['grain'] }
          end
          used = placements.sum { |p| p['w'] * p['h'] }
          cut = CutSequence.compute(placements.map { |p| { 'id' => p['part_id'], 'x' => p['x'] - ctx[:trim], 'y' => p['y'] - ctx[:trim], 'w' => p['w'], 'h' => p['h'] } },
                                    ctx[:uw], ctx[:uh], ctx[:settings]['kerf'], offset: ctx[:trim])
          { 'index' => i, 'placements' => placements, 'used_area' => used.round(1), 'waste_area' => (sheet_area - used).round(1),
            'utilization' => (used * 100.0 / sheet_area).round(2), 'cut_sequence' => cut, 'offcuts' => offcuts(sh[:free], ctx) }
        end
        used = sheets.sum { |s| s['used_area'] }
        total = sheets.size * sheet_area
        all_offcuts = sheets.flat_map { |sh| sh['offcuts'] }
        {
          'offcut_count' => all_offcuts.size, 'offcut_area' => all_offcuts.sum { |o| o['w'] * o['h'] }.round(1),
          'material' => ctx[:sheet]['material'], 'sheet_length' => ctx[:sheet]['sheet_length'], 'sheet_width' => ctx[:sheet]['sheet_width'],
          'trim' => ctx[:trim], 'kerf' => ctx[:settings]['kerf'], 'spacing' => ctx[:settings]['spacing'],
          'grain_free' => ctx[:sheet]['grain_free'], 'grain_axis' => ctx[:sheet]['grain_axis'] || 'length', 'sheets' => sheets,
          'unplaced' => run[:unplaced].map { |p| { 'uid' => p['uid'], 'part_id' => p['part_id'], 'name' => p['name'], 'length' => p['length'], 'width' => p['width'] } },
          'released_locks' => released,
          'total_sheets' => sheets.size, 'total_area' => total.round(1), 'used_area' => used.round(1),
          'waste_area' => (total - used).round(1), 'utilization' => total.zero? ? 0.0 : (used * 100.0 / total).round(2),
          'algorithm' => 'Guillotine free-rectangle heuristic: best of every sort order x fit rule x split rule plus seeded perturbations (not guaranteed optimal)'
        }
      end

      # Reusable leftovers of one sheet: the free rectangles (touching ones merged) that are at least `min_offcut` on both sides,
      # in physical sheet coordinates, biggest first. The cutting gap is already taken off. Free rectangles are guillotine pieces, so
      # these are rectangles the saw could really release, but an offcut is only as good as the cuts you choose to make.
      def offcuts(free, ctx)
        gap = ctx[:gap]
        min = ctx[:settings]['min_offcut']
        merge_free(free).filter_map do |f|
          w = f.w - gap
          h = f.h - gap
          next if w < min - EPS || h < min - EPS

          { 'x' => (f.x + ctx[:trim]).round(2), 'y' => (f.y + ctx[:trim]).round(2), 'w' => w.round(2), 'h' => h.round(2) }
        end.sort_by { |o| [-o['w'] * o['h'], o['y'], o['x']] }
      end

      # Joins free rectangles that share a full edge, until nothing more can be joined.
      def merge_free(list)
        rects = list.map { |f| Free.new(f.x, f.y, f.w, f.h) }
        loop do
          pair = rects.combination(2).find do |a, b|
            (near?(a.x, b.x) && near?(a.w, b.w) && (near?(a.y + a.h, b.y) || near?(b.y + b.h, a.y))) ||
              (near?(a.y, b.y) && near?(a.h, b.h) && (near?(a.x + a.w, b.x) || near?(b.x + b.w, a.x)))
          end
          return rects unless pair

          a, b = pair
          rects.delete_if { |r| r.equal?(a) || r.equal?(b) }
          x = [a.x, b.x].min
          y = [a.y, b.y].min
          rects << Free.new(x, y, [a.x + a.w, b.x + b.w].max - x, [a.y + a.h, b.y + b.h].max - y)
        end
      end

      def near?(a, b)
        (a - b).abs < 1e-6
      end

      # Checks a proposed manual placement against a nesting result (excluding the part itself).
      # Returns nil if valid, else an error string.
      def check_move(result, part, sheet_index, x, y, rotated)
        trim = result['trim']
        gap = result['kerf'] + result['spacing']
        w, h = rotated ? [part['width'], part['length']] : [part['length'], part['width']]
        return 'Grain direction does not allow this rotation' unless orientations(part, result['grain_free'], result['grain_axis'] || 'length').any? { |_, _, r| r == rotated }
        return 'Outside the sheet or inside the trim margin' if x < trim - EPS || y < trim - EPS ||
                                                                 x + w > result['sheet_length'] - trim + EPS || y + h > result['sheet_width'] - trim + EPS
        return 'That sheet does not exist' if sheet_index.negative? || sheet_index > result['sheets'].size

        others = (result['sheets'][sheet_index] || { 'placements' => [] })['placements'].reject { |p| p['uid'] == part['uid'] }
        clash = others.find { |o| overlap?(o['x'], o['y'], o['w'] + gap, o['h'] + gap, x, y, w + gap, h + gap) }
        clash ? "Too close to (or overlapping) #{clash['part_id']} - parts need #{gap} mm clearance" : nil
      end
    end
  end
end
