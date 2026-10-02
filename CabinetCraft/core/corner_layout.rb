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
  # Hand: 'left' (the default) has the corner at the left end of wall A, with wall A running along +X; 'right' is the mirror image: the corner
  # is at the right end of wall A, wall A runs along -X and wall B along +Y (the room corner is still the origin). Cabinets are never
  # reflected, only rotated, so the mirror image is built from mirrored placements.
  #
  # The clearance (default 20 mm) keeps run B off the door of the cabinet on run A's end. Door swing and handles are not modelled.
  module CornerLayout
    KINDS = %w[none blind l_shaped].freeze
    HANDS = %w[left right].freeze
    DEFAULT_DEPTH = 560.0
    DEFAULT_CLEARANCE = 20.0
    EPS = 1e-6

    module_function

    # corner: { 'width' => mm } for 'blind', { 'width_a' => mm, 'width_b' => mm } for 'l_shaped'.
    # => { 'ok', 'issues', 'kind', 'depth', 'clearance', 'a' => { 'start', 'length' }, 'b' => { 'start', 'length' },
    #      'corner' => { 'frame', 'width' | 'width_a', 'width_b' } or nil }
    def plan(wall_a, wall_b, kind: 'none', depth: DEFAULT_DEPTH, clearance: DEFAULT_CLEARANCE, corner: {}, hand: 'left')
      raise ArgumentError, "Corner kind must be one of #{KINDS.join(', ')}" unless KINDS.include?(kind)
      raise ArgumentError, "Hand must be one of #{HANDS.join(', ')}" unless HANDS.include?(hand)

      wall_a = positive(wall_a, 'Wall A length')
      wall_b = positive(wall_b, 'Wall B length')
      depth = positive(depth, 'Cabinet depth')
      clearance = Float(clearance)
      raise ArgumentError, 'Clearance cannot be negative' if clearance.negative?

      send("plan_#{kind}", wall_a, wall_b, depth, clearance, (corner || {}).transform_keys(&:to_s)).merge('hand' => hand).tap { |pl| add_frames(pl) }
    end

    # The corner cabinet's placement depends on the hand, which plan_<kind> does not know: fill it in here.
    def add_frames(plan)
      c = plan['corner']
      return unless c

      c['frame'] = plan['kind'] == 'blind' ? frame_a(0.0, c['width'], plan['depth'], plan['hand']) : corner_frame(plan['hand'])
    end

    # The L-shaped corner cabinet is built with its back corner at its origin and arms along +x and +y. For the right hand it is turned 90 degrees:
    # its x arm then runs along +y (wall B) and its y arm along -x (wall A), which is why the arm widths are swapped when it is sized.
    def corner_frame(hand)
      hand == 'right' ? { 'origin' => [0.0, 0.0], 'x_axis' => [0, 1], 'y_axis' => [-1, 0] } : { 'origin' => [0.0, 0.0], 'x_axis' => [1, 0], 'y_axis' => [0, 1] }
    end

    # Warnings about door swing and the blind panel. They never make a plan invalid: door swing and handles are only approximated.
    # a1_door: width (mm) of the door of the first cabinet of run A, or nil when it has none. blind: width (mm) of the blind panel of a blind corner cabinet.
    # A door can swing through a square as wide as itself in front of its cabinet, so the first cabinet of run A conflicts with run B when run B
    # starts closer than depth + that door width (kind 'none'); a blind panel narrower than the depth of the neighbouring run leaves that run's
    # first cabinet standing in front of the corner door.
    def warnings(plan, a1_door: nil, blind: nil)
      out = []
      d = plan['depth']
      if plan['kind'] == 'none' && a1_door && a1_door.positive? && plan['b']['length'].positive? && plan['b']['start'] < d + a1_door - EPS
        out << "The door of the first cabinet of run A (#{a1_door.round} mm wide) swings into run B, which starts #{(plan['b']['start'] - d).round} mm beyond the cabinet depth. " \
               "Use a blind or L-shaped corner cabinet, or a clearance of at least #{a1_door.round} mm"
      end
      if plan['kind'] == 'blind' && blind && blind < d + 10 - EPS
        out << "The blind panel (#{blind.round} mm) is narrower than the cabinet depth (#{d.round} mm): the first cabinet of run B stands in front of the corner door and blocks it. " \
               "Make the blind panel at least #{(d + 10).round} mm"
      end
      out
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
                                                         corner: { 'width' => w })
    end

    def plan_l_shaped(wall_a, wall_b, depth, clearance, corner)
      wa = positive(corner['width_a'], 'Corner arm A length')
      wb = positive(corner['width_b'], 'Corner arm B length')
      raise ArgumentError, 'Each corner arm must be longer than the cabinet depth' if wa <= depth || wb <= depth

      finish('l_shaped', wall_a, wall_b, depth, clearance, a_start: wa, b_start: wb,
                                                           corner: { 'width_a' => wa, 'width_b' => wb })
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
    # Left hand: the row advances towards +X. Right hand: it advances towards -X, so the cabinet sits at [-(start + width), -start].
    def frame_a(start, width, depth, hand = 'left')
      { 'origin' => [hand == 'right' ? -start : start + width, depth], 'x_axis' => [-1, 0], 'y_axis' => [0, -1] }
    end

    # Cabinet occupying [start, start + width] along wall B. Left hand: against the wall x = 0, front facing +X (turned 90 degrees, width
    # towards +Y). Right hand: the cabinet stands at x in [-depth, 0] facing -X, width towards -Y from the far end.
    def frame_b(start, width, depth, hand = 'left')
      if hand == 'right'
        { 'origin' => [-depth, start + width], 'x_axis' => [0, -1], 'y_axis' => [1, 0] }
      else
        { 'origin' => [depth, start], 'x_axis' => [0, 1], 'y_axis' => [-1, 0] }
      end
    end

    # +1 when the row advances towards +X / +Y, -1 towards -X (run A of a right-hand layout).
    def direction_a(hand)
      hand == 'right' ? -1 : 1
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
      plan['hand'] == 'right' ? rects.map { |l, x0, y0, x1, y1| [l, -x1, y0, -x0, y1] } : rects # the mirror image: x -> -x
    end

    def overlapping(rects, eps = 1e-6)
      rects.combination(2).select do |(_, ax0, ay0, ax1, ay1), (_, bx0, by0, bx1, by1)|
        ax0 < bx1 - eps && ax1 > bx0 + eps && ay0 < by1 - eps && ay1 > by0 + eps
      end.map { |a, b| [a[0], b[0]] }
    end
    # A corner layout remembered in the model: the corner kind and wall lengths, and which cabinets / runs belong to it.
    # Stored in ProjectStore#layouts. Untrusted on read (it comes from the model file).
    class Record
      attr_reader :id, :name, :kind, :wall_a, :wall_b, :depth, :clearance, :origin, :corner_cabinet_id, :run_a_id, :run_b_id, :hand

      def initialize(id:, name:, kind:, wall_a:, wall_b:, depth:, clearance:, origin:, corner_cabinet_id: nil, run_a_id: nil, run_b_id: nil, hand: 'left')
        raise ArgumentError, 'Unknown corner kind' unless KINDS.include?(kind)
        raise ArgumentError, 'Unknown hand' unless HANDS.include?(hand)

        @hand = hand

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
            corner_cabinet_id: raw['corner_cabinet_id'], run_a_id: raw['run_a_id'], run_b_id: raw['run_b_id'], hand: raw['hand'] || 'left')
      rescue ArgumentError, TypeError
        nil
      end

      def to_h
        { 'id' => id, 'name' => name, 'kind' => kind, 'wall_a' => wall_a, 'wall_b' => wall_b, 'depth' => depth, 'clearance' => clearance,
          'origin' => origin, 'corner_cabinet_id' => corner_cabinet_id, 'run_a_id' => run_a_id, 'run_b_id' => run_b_id, 'hand' => hand }
      end

      def with_walls(wall_a, wall_b)
        self.class.new(**to_h.transform_keys(&:to_sym).merge(wall_a: wall_a, wall_b: wall_b))
      end
    end
  end
end
