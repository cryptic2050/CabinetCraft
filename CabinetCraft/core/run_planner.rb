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
    FILLER_MIN = 20.0
    FILLER_MAX = 150.0
    FILLER_TARGET = 50.0
    EPS = 1e-9

    # filler: a strip that closes the gap at a wall. It is sized last: the other cabinets are planned for the wall length minus the
    # fillers' target widths, then each filler takes an equal share of what is left, within its own min / max.
    Item = Struct.new(:fixed, :width, :min, :max, :filler, keyword_init: true)

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
      fillers = list.each_index.select { |i| list[i].filler }
      widths = list.map { |it| it.fixed && !it.filler ? it.width : nil }
      free = list.each_index.reject { |i| list[i].fixed || list[i].filler }
      target = fillers.sum { |i| list[i].width }
      remaining = length - widths.compact.sum - target
      distribute(widths, list, free, remaining, step)
      size_fillers(widths, list, fillers, length, step)
      finish(widths, length, list)
    end

    # Each filler gets an equal share of what the other cabinets leave, limited to its own min / max (rounded to the step).
    def size_fillers(widths, list, fillers, length, step)
      return if fillers.empty?

      left = length - widths.compact.sum
      share = left / fillers.size
      fillers.each { |i| widths[i] = floor_to(share.clamp(list[i].min, list[i].max), step) }
      extra = ((left - fillers.sum { |i| widths[i] }) / step + EPS).floor
      fillers.each do |i|
        break if extra <= 0
        next if widths[i] + step > list[i].max + EPS

        widths[i] += step
        extra -= 1
      end
    end

    def normalize(raw, index, step)
      return normalize_filler(raw, index, step) if raw['filler']

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

    def normalize_filler(raw, index, step)
      min = Float(raw['min'] || FILLER_MIN)
      max = Float(raw['max'] || FILLER_MAX)
      target = Float(raw['width'] || FILLER_TARGET)
      raise ArgumentError, "Filler #{index + 1}: minimum width must be positive" unless min.positive?
      raise ArgumentError, "Filler #{index + 1}: minimum width is larger than the maximum" if min > max + EPS
      raise ArgumentError, "Filler #{index + 1}: target width must be between #{min} and #{max} mm" unless target.between?(min - EPS, max + EPS)

      Item.new(fixed: false, width: target, min: ceil_to(min, step), max: floor_to(max, step), filler: true)
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

        if it.filler
          issues << "Filler #{i + 1} would have to be #{widths[i].round(1)} mm: that is its maximum, #{leftover.round(1)} mm of the wall stays empty" if leftover.positive? && (widths[i] - it.max).abs < EPS
          next
        end

        issues << "Cabinet #{i + 1} is at its minimum width (#{widths[i].round(1)} mm)" if (widths[i] - it.min).abs < EPS && it.min < it.max
        issues << "Cabinet #{i + 1} is at its maximum width (#{widths[i].round(1)} mm)" if (widths[i] - it.max).abs < EPS && it.min < it.max
      end
      { 'ok' => shortfall.zero?, 'widths' => widths.map { |w| w.round(3) }, 'used' => used.round(3), 'leftover' => leftover.round(3),
        'shortfall' => shortfall.round(3), 'issues' => issues }
    end
  end
end
