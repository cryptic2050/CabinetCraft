# frozen_string_literal: true

module CabinetCraft
  module Manufacturing
    # Derives a real panel-saw (guillotine) cut sequence from a layout, or reports
    # honestly that the layout cannot be cut with edge-to-edge cuts.
    #
    # A cut is valid when its kerf slot [c, c + kerf] crosses no part and parts lie
    # entirely on both sides. Works on any layout (auto or manually edited).
    module CutSequence
      EPS = 1e-6
      Rect = Struct.new(:x, :y, :w, :h, :id)

      module_function

      # rects: [{ 'id' =>, 'x' =>, 'y' =>, 'w' =>, 'h' => }] in usable-area coordinates.
      # Returns { 'ok' => true, 'steps' => [...] } or { 'ok' => false, 'reason' => ... }.
      def compute(rects, usable_w, usable_h, kerf, offset: 0.0)
        steps = []
        list = rects.map { |r| Rect.new(r['x'].to_f, r['y'].to_f, r['w'].to_f, r['h'].to_f, r['id']) }
        region = Rect.new(0.0, 0.0, usable_w.to_f, usable_h.to_f)
        return { 'ok' => true, 'steps' => [] } if list.empty?

        unless solve(region, list, kerf.to_f, steps, offset)
          return { 'ok' => false, 'reason' => 'This arrangement cannot be cut with edge-to-edge (guillotine) cuts' }
        end

        steps.each_with_index { |s, i| s['step'] = i + 1 }
        { 'ok' => true, 'steps' => steps }
      end

      def solve(region, rects, kerf, steps, off)
        return true if rects.empty?
        return isolate(region, rects.first, kerf, steps, off) if rects.size == 1

        cut = find_cut(region, rects, kerf)
        return false unless cut

        axis, c = cut
        if axis == :horizontal
          steps << cut_step('horizontal', c, region.x, region.x + region.w, off, 'y', 'x')
          low = rects.select { |r| r.y + r.h <= c + EPS }
          high = rects - low
          solve(Rect.new(region.x, region.y, region.w, c - region.y), low, kerf, steps, off) &&
            solve(Rect.new(region.x, c + kerf, region.w, region.y + region.h - c - kerf), high, kerf, steps, off)
        else
          steps << cut_step('vertical', c, region.y, region.y + region.h, off, 'x', 'y')
          left = rects.select { |r| r.x + r.w <= c + EPS }
          right = rects - left
          solve(Rect.new(region.x, region.y, c - region.x, region.h), left, kerf, steps, off) &&
            solve(Rect.new(c + kerf, region.y, region.x + region.w - c - kerf, region.h), right, kerf, steps, off)
        end
      end

      def cut_step(axis, pos, from, to, off, _a, _b)
        { 'type' => 'cut', 'axis' => axis, 'position' => (pos + off).round(2),
          'from' => (from + off).round(2), 'to' => (to + off).round(2) }
      end

      # Candidate cuts sit on a part's far edge. Horizontal (rip along the sheet length) first.
      def find_cut(region, rects, kerf)
        candidates = ->(axis) do
          rects.map { |r| axis == :horizontal ? r.y + r.h : r.x + r.w }.uniq.sort.select do |c|
            lo = axis == :horizontal ? region.y : region.x
            hi = lo + (axis == :horizontal ? region.h : region.w)
            next false unless c > lo + EPS && c < hi - EPS

            sides = rects.map do |r|
              a0 = axis == :horizontal ? r.y : r.x
              a1 = a0 + (axis == :horizontal ? r.h : r.w)
              if a1 <= c + EPS then :low
              elsif a0 >= c + kerf - EPS then :high
              end
            end
            !sides.include?(nil) && sides.uniq.size == 2
          end
        end
        %i[horizontal vertical].each do |axis|
          c = candidates.call(axis).first
          return [axis, c] if c
        end
        nil
      end

      # One part left in a region: trim the waste around it where there is room for a saw cut.
      def isolate(region, r, kerf, steps, off)
        left = r.x - region.x
        right = region.x + region.w - (r.x + r.w)
        bottom = r.y - region.y
        top = region.y + region.h - (r.y + r.h)
        steps << cut_step('vertical', r.x - kerf, r.y, r.y + r.h, off, 'x', 'y') if left >= kerf - EPS && left > EPS
        steps << cut_step('vertical', r.x + r.w, r.y, r.y + r.h, off, 'x', 'y') if right >= kerf - EPS && right > EPS
        steps << cut_step('horizontal', r.y - kerf, r.x, r.x + r.w, off, 'y', 'x') if bottom >= kerf - EPS && bottom > EPS
        steps << cut_step('horizontal', r.y + r.h, r.x, r.x + r.w, off, 'y', 'x') if top >= kerf - EPS && top > EPS
        steps << { 'type' => 'part', 'part_id' => r.id }
        true
      end
    end
  end
end
