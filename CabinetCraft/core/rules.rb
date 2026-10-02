# frozen_string_literal: true

require_relative 'material'
require_relative 'construction'

module CabinetCraft
  # The dimensional calculation engine. Pure functions: params (validated,
  # string-keyed) in, derived dimensions + issues out. No SketchUp dependency.
  module Rules
    Issue = Struct.new(:severity, :key, :message) do
      def to_h
        { 'severity' => severity.to_s, 'key' => key, 'message' => message }
      end
    end

    class Result
      attr_reader :values, :issues

      def initialize(values, issues)
        @values = values
        @issues = issues
      end

      def errors
        issues.select { |i| i.severity == :error }
      end

      def warnings
        issues.select { |i| i.severity == :warning }
      end

      def ok?
        errors.empty?
      end
    end

    module_function

    # Width of each door: (cabinet width - 2 outer reveals - gaps between doors) / count.
    def door_widths(width:, count:, reveal:, gap:)
      return [] if count.zero?

      each = (width - 2 * reveal - (count - 1) * gap) / count.to_f
      Array.new(count, each.round(3))
    end

    def compute(params)
      issues = []
      profile  = Construction.fetch(params['construction'])
      material = Material.fetch(params['material'])

      w  = params['width'].to_f
      h  = params['height'].to_f
      d  = params['depth'].to_f
      t  = material.thickness
      bt = params['back_thickness'].to_f
      n  = params['shelf_count'].to_i
      bd = params['brace_depth'].to_f

      internal_w = w - 2 * t
      side_h     = h - (profile[:side_height_deduction] || t)
      back_w     = internal_w + 2 * profile[:groove_depth]
      back_h     = side_h - t - profile[:back_top_deduction]
      back_y     = d - profile[:back_setback] - bt
      shelf_rear = [profile[:shelf_rear_clearance], profile[:back_setback] + bt].max
      shelf_w    = internal_w - 2 * profile[:shelf_side_clearance]
      shelf_d    = d - profile[:shelf_front_setback] - shelf_rear
      shelf_gap  = (side_h - n * t) / (n + 1).to_f
      stack_h    = t + side_h
      doors      = door_widths(width: w, count: params['door_count'].to_i,
                               reveal: params['door_reveal'].to_f, gap: params['door_gap'].to_f)

      values = {
        'thickness' => t, 'back_thickness' => bt,
        'internal_width' => internal_w, 'side_height' => side_h, 'side_depth' => d,
        'bottom_width' => w, 'bottom_depth' => d,
        'back_width' => back_w, 'back_height' => back_h, 'back_y' => back_y,
        'brace_width' => internal_w, 'brace_depth' => bd, 'brace_count' => profile[:brace_count],
        'shelf_width' => shelf_w, 'shelf_depth' => shelf_d, 'shelf_count' => n, 'shelf_gap' => shelf_gap,
        'door_widths' => doors, 'stack_height' => stack_h
      }.transform_values { |v| v.is_a?(Float) ? v.round(3) : v }

      validate(issues, values, profile, params)
      Result.new(values, issues)
    end

    def validate(issues, v, profile, params)
      err = ->(key, msg) { issues << Issue.new(:error, key, msg) }
      warn = ->(key, msg) { issues << Issue.new(:warning, key, msg) }

      err.call('width', "Internal width is #{v['internal_width']} mm - cabinet too narrow for the panel thickness") if v['internal_width'] <= 0
      err.call('height', "Side height is #{v['side_height']} mm - cabinet too low") if v['side_height'] <= 0
      err.call('height', "Back panel height is #{v['back_height']} mm - cabinet too low for this construction") if v['back_height'] <= 0
      err.call('depth', "Shelf depth is #{v['shelf_depth']} mm - cabinet too shallow") if v['shelf_depth'] <= 0

      if v['shelf_count'].positive? && v['side_height'].positive? && v['shelf_gap'] < profile[:min_shelf_gap]
        err.call('shelf_count', "Too many shelves: openings would be #{v['shelf_gap']} mm (minimum #{profile[:min_shelf_gap]} mm)")
      end

      if v['brace_depth'] * v['brace_count'] > v['back_y']
        err.call('brace_depth', 'Rails are deeper than the space in front of the back panel')
      end

      if params['door_count'].to_i.positive?
        dw = v['door_widths'].first
        err.call('door_count', "Door width would be #{dw} mm - too many doors for this width") if dw <= 0
        warn.call('door_count', "Very narrow doors (#{dw} mm)") if dw.positive? && dw < 100
        warn.call('door_count', "Wide doors (#{dw} mm) - consider more doors") if dw > 600
      end

      return unless (v['stack_height'] - params['height'].to_f).abs > 1e-6

      warn.call('construction',
                "Panel stack is #{v['stack_height']} mm but overall height is #{params['height']} mm " \
                "(#{(v['stack_height'] - params['height'].to_f).round(3)} mm difference)")
    end
  end
end
