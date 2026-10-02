# frozen_string_literal: true

module CabinetCraft
  # Plan-view geometry of an inside corner where two walls meet at 90 degrees.
  #
  # Frame (millimetres, seen from above): the room corner is the origin, wall A runs along +X (the wall is the line y = 0)
  # and wall B along +Y (the line x = 0). Cabinets stand in front of their wall, so run A occupies y in [0, depth] and run B
  # occupies x in [0, depth], both with their fronts facing into the room.
  #
  # Corner kinds:
  #   'none'     - no corner cabinet: run A starts in the corner, run B starts after the depth of run A (plus a clearance).
  #   'blind'    - a blind corner cabinet (width W) opens run A; its blind side points at the corner. Run A continues after
  #                it, run B starts after the depth of run A (plus a clearance).
  #   'l_shaped' - an L-shaped cabinet fills the corner with arms width_a and width_b; run A starts after arm A and run B
  #                after arm B.
  #
  # The clearance (default 20 mm) keeps run B off the door of the cabinet on run A's end. Door swing and handles are not modelled.
  module CornerLayout
    KINDS = %w[none blind l_shaped].freeze
    DEFAULT_DEPTH = 560.0
    DEFAULT_CLEARANCE = 20.0

    module_function

    # corner: { 'width' => mm } for 'blind', { 'width_a' => mm, 'width_b' => mm } for 'l_shaped'.
    # => { 'ok', 'issues', 'kind', 'depth', 'clearance', 'a' => { 'start', 'length' }, 'b' => { 'start', 'length' },
    #      'corner' => { 'frame', 'width' | 'width_a', 'width_b' } or nil }
    def plan(wall_a, wall_b, kind: 'none', depth: DEFAULT_DEPTH, clearance: DEFAULT_CLEARANCE, corner: {})
      raise ArgumentError, "Corner kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(kind)

      wall_a = positive(wall_a, 'Wall A length')
      wall_b = positive(wall_b, 'Wall B length')
      depth = positive(depth, 'Cabinet depth')
      clearance = Float(clearance)
      raise ArgumentError, 'Clearance cannot be negative' if clearance.negative?

      send("plan_#{kind}", wall_a, wall_b, depth, clearance, (corner || {}).transform_keys(&:to_s))
    end

    def positive(value, label)
      v = Float(value)
      raise ArgumentError, "#{label} must be positive" unless v.positive?

      v
    rescue TypeError
      raise ArgumentError, "#{label} must be a number"
    end

    def plan_none(wall_a, wall_b, depth, clearance, _corner)
      finish('none', wall_a, wall_b, depth, clearance, a_start: 0.0, b_start: depth + clearance, corner: nil)
    end

    def plan_blind(wall_a, wall_b, depth, clearance, corner)
      w = positive(corner['width'], 'Blind corner cabinet width')
      finish('blind', wall_a, wall_b, depth, clearance, a_start: w, b_start: depth + clearance,
                                                         corner: { 'width' => w, 'frame' => frame_a(0.0, w, depth) })
    end

    def plan_l_shaped(wall_a, wall_b, depth, clearance, corner)
      wa = positive(corner['width_a'], 'Corner arm A length')
      wb = positive(corner['width_b'], 'Corner arm B length')
      raise ArgumentError, 'Each corner arm must be longer than the cabinet depth' if wa <= depth || wb <= depth

      finish('l_shaped', wall_a, wall_b, depth, clearance, a_start: wa, b_start: wb,
                                                           corner: { 'width_a' => wa, 'width_b' => wb, 'frame' => { 'origin' => [0.0, 0.0], 'x_axis' => [1, 0], 'y_axis' => [0, 1] } })
    end

    def finish(kind, wall_a, wall_b, depth, clearance, a_start:, b_start:, corner:)
      la = wall_a - a_start
      lb = wall_b - b_start
      issues = []
      issues << "Wall A (#{wall_a.round(1)} mm) is too short for the corner cabinet" if la <= 0
      issues << "Wall B (#{wall_b.round(1)} mm) is too short: run B cannot start (#{b_start.round(1)} mm needed for the corner)" if lb <= 0
      { 'ok' => issues.empty?, 'issues' => issues, 'kind' => kind, 'depth' => depth, 'clearance' => clearance,
        'a' => { 'start' => a_start, 'length' => [la, 0.0].max }, 'b' => { 'start' => b_start, 'length' => [lb, 0.0].max }, 'corner' => corner }
    end

    # Where a cabinet of `width` that occupies [start, start + width] along wall A stands. The cabinet's own frame has its front
    # on y = 0 and its back on y = depth, so it is turned 180 degrees about the vertical axis: its width runs towards -X.
    def frame_a(start, width, depth)
      { 'origin' => [start + width, depth], 'x_axis' => [-1, 0], 'y_axis' => [0, -1] }
    end

    # Cabinet occupying [start, start + width] along wall B (x = 0 wall), front facing +X: turned 90 degrees, width runs towards +Y.
    def frame_b(start, width, depth)
      { 'origin' => [depth, start], 'x_axis' => [0, 1], 'y_axis' => [-1, 0] }
    end

    # Plan rectangles [label, x0, y0, x1, y1] of every piece, for overlap checks and drawings. Widths are the run cabinets' widths.
    def rectangles(plan, widths_a, widths_b)
      d = plan['depth']
      rects = []
      c = plan['corner']
      case plan['kind']
      when 'blind' then rects << ['corner', 0.0, 0.0, c['width'], d]
      when 'l_shaped'
        rects << ['corner_a', 0.0, 0.0, c['width_a'], d]
        rects << ['corner_b', 0.0, d, d, c['width_b']]
      end
      x = plan['a']['start']
      widths_a.each_with_index { |w, i| rects << ["a#{i + 1}", x, 0.0, x + w, d]; x += w }
      y = plan['b']['start']
      widths_b.each_with_index { |w, i| rects << ["b#{i + 1}", 0.0, y, d, y + w]; y += w }
      rects
    end

    def overlapping(rects, eps = 1e-6)
      rects.combination(2).select do |(_, ax0, ay0, ax1, ay1), (_, bx0, by0, bx1, by1)|
        ax0 < bx1 - eps && ax1 > bx0 + eps && ay0 < by1 - eps && ay1 > by0 + eps
      end.map { |a, b| [a[0], b[0]] }
    end
    # A corner layout remembered in the model: the corner kind and wall lengths, and which cabinets / runs belong to it.
    # Stored in ProjectStore#layouts. Untrusted on read (it comes from the model file).
    class Record
      attr_reader :id, :name, :kind, :wall_a, :wall_b, :depth, :clearance, :origin, :corner_cabinet_id, :run_a_id, :run_b_id

      def initialize(id:, name:, kind:, wall_a:, wall_b:, depth:, clearance:, origin:, corner_cabinet_id: nil, run_a_id: nil, run_b_id: nil)
        raise ArgumentError, 'Unknown corner kind' unless KINDS.include?(kind)

        @id = id
        @name = name
        @kind = kind
        @wall_a = Float(wall_a)
        @wall_b = Float(wall_b)
        @depth = Float(depth)
        @clearance = Float(clearance)
        @origin = origin.map { |v| Float(v) }.first(2)
        raise ArgumentError, 'Layout origin needs x and y' unless @origin.size == 2

        @corner_cabinet_id = corner_cabinet_id
        @run_a_id = run_a_id
        @run_b_id = run_b_id
      end

      def self.from_h(raw)
        return nil unless raw.is_a?(Hash) && raw['id'].is_a?(String) && !raw['id'].empty?

        new(id: raw['id'], name: raw['name'].to_s[0, 40], kind: raw['kind'].to_s, wall_a: raw['wall_a'], wall_b: raw['wall_b'], depth: raw['depth'],
            clearance: raw['clearance'] || DEFAULT_CLEARANCE, origin: raw['origin'].is_a?(Array) ? raw['origin'] : [0, 0],
            corner_cabinet_id: raw['corner_cabinet_id'], run_a_id: raw['run_a_id'], run_b_id: raw['run_b_id'])
      rescue ArgumentError, TypeError
        nil
      end

      def to_h
        { 'id' => id, 'name' => name, 'kind' => kind, 'wall_a' => wall_a, 'wall_b' => wall_b, 'depth' => depth, 'clearance' => clearance,
          'origin' => origin, 'corner_cabinet_id' => corner_cabinet_id, 'run_a_id' => run_a_id, 'run_b_id' => run_b_id }
      end

      def with_walls(wall_a, wall_b)
        self.class.new(**to_h.transform_keys(&:to_sym).merge(wall_a: wall_a, wall_b: wall_b))
      end
    end
  end
end
