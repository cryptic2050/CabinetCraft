# frozen_string_literal: true

module CabinetCraft
  # Sizes a row of cabinets so it fills a wall length exactly ("Smart Space fill").
  #
  # Items with a fixed width keep it; the others share the remaining length equally, limited to their min / max width
  # (anything clamped passes its share on to the rest). Widths are rounded to `step` mm and the rounding remainder is
  # handed out so the total is exact. If the flexible cabinets cannot absorb the length, the result reports the
  # `leftover` (a filler strip is needed) or the `shortfall` (the row does not fit) instead of silently bending a limit.
  module RunPlanner
    DEFAULT_MIN = 300.0
    DEFAULT_MAX = 900.0
    EPS = 1e-9

    Item = Struct.new(:fixed, :width, :min, :max, keyword_init: true)

    module_function

    # items: [{ 'fixed' => true/false, 'width' => mm (fixed items), 'min' => mm, 'max' => mm }]
    # => { 'ok', 'widths' => [mm], 'used' => mm, 'leftover' => mm (>= 0), 'shortfall' => mm (>= 0), 'issues' => [string] }
    def plan(length, items, step: 1.0)
      length = Float(length)
      step = Float(step)
      raise ArgumentError, 'Wall length must be positive' unless length.positive?
      raise ArgumentError, 'Rounding step must be positive' unless step.positive?
      raise ArgumentError, 'Add at least one cabinet to the run' if items.empty?

      list = items.each_with_index.map { |raw, i| normalize(raw, i, step) }
      widths = list.map { |it| it.fixed ? it.width : nil }
      free = list.each_index.reject { |i| list[i].fixed }
      remaining = length - widths.compact.sum
      distribute(widths, list, free, remaining, step)
      finish(widths, length, list)
    end

    def normalize(raw, index, step)
      fixed = raw['fixed'] ? true : false
      min = Float(raw['min'] || DEFAULT_MIN)
      max = Float(raw['max'] || DEFAULT_MAX)
      width = raw['width'].nil? ? nil : Float(raw['width'])
      raise ArgumentError, "Cabinet #{index + 1}: a fixed width is required" if fixed && width.nil?
      raise ArgumentError, "Cabinet #{index + 1}: minimum width must be positive" unless min.positive?
      raise ArgumentError, "Cabinet #{index + 1}: minimum width is larger than the maximum" if min > max + EPS
      raise ArgumentError, "Cabinet #{index + 1}: width must be positive" if fixed && !width.positive?

      Item.new(fixed: fixed, width: width, min: ceil_to(min, step), max: floor_to(max, step))
    end

    def ceil_to(v, step)
      (v / step - EPS).ceil * step
    end

    def floor_to(v, step)
      (v / step + EPS).floor * step
    end

    # Water-filling: share equally, pin what hits a limit, repeat; then round to the step.
    def distribute(widths, list, free, remaining, step)
      pending = free.dup
      pinned = 0.0
      loop do
        break if pending.empty?

        share = (remaining - pinned) / pending.size
        over = pending.select { |i| share > list[i].max + EPS }
        under = pending.select { |i| share < list[i].min - EPS }
        # pin the side that is violated by more cabinets first; pinning both at once could over-correct
        hit = over.size >= under.size ? over : under
        break if hit.empty?

        hit.each do |i|
          widths[i] = over.include?(i) ? list[i].max : list[i].min
          pinned += widths[i]
        end
        pending -= hit
      end
      return if pending.empty?

      share = (remaining - pinned) / pending.size
      round_shares(widths, pending, share * pending.size, step)
    end

    # Rounds each share down to the step, then gives the leftover steps one by one so the sum is exact.
    def round_shares(widths, indices, total, step)
      base = floor_to(total / indices.size, step)
      indices.each { |i| widths[i] = base }
      extra = ((total - base * indices.size) / step + EPS).floor
      indices.first(extra).each { |i| widths[i] += step }
    end

    def finish(widths, length, list)
      used = widths.sum
      issues = []
      diff = length - used
      leftover = diff > EPS ? diff : 0.0
      shortfall = diff < -EPS ? -diff : 0.0
      issues << "The cabinets are at their maximum width and #{leftover.round(1)} mm of the wall is still empty: add a filler strip or another cabinet" if leftover.positive?
      issues << "The row is #{shortfall.round(1)} mm too long even at the minimum widths: remove a cabinet or reduce a fixed width" if shortfall.positive?
      list.each_with_index do |it, i|
        next if it.fixed

        issues << "Cabinet #{i + 1} is at its minimum width (#{widths[i].round(1)} mm)" if (widths[i] - it.min).abs < EPS && it.min < it.max
        issues << "Cabinet #{i + 1} is at its maximum width (#{widths[i].round(1)} mm)" if (widths[i] - it.max).abs < EPS && it.min < it.max
      end
      { 'ok' => shortfall.zero?, 'widths' => widths.map { |w| w.round(3) }, 'used' => used.round(3), 'leftover' => leftover.round(3),
        'shortfall' => shortfall.round(3), 'issues' => issues }
    end
  end
end
