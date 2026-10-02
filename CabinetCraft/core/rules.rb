# frozen_string_literal: true

require_relative 'material'
require_relative 'construction'

module CabinetCraft
  # The dimensional calculation engine. Pure functions: params (validated,
  # string-keyed) in, derived dimensions + issues out. No SketchUp dependency.
  #
  # Vertical layout (z, mm, cabinet-local):
  #   0 .. toe                    toe kick zone (plinth board, if toe > 0)
  #   toe .. toe+t                bottom panel
  #   toe+t .. top                sides; open/door zone below, drawer zone on top
  # Doors and drawer fronts sit in front of the carcass (y < 0).
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

    def round_deep(v)
      case v
      when Float then v.round(3)
      when Array then v.map { |x| round_deep(x) }
      when Hash then v.transform_values { |x| round_deep(x) }
      else v
      end
    end

    def compute(params)
      issues = []
      profile = Construction.fetch(params['construction'])
      v = carcass_values(params, profile)
      v.merge!(front_values(params, profile, v))
      v.merge!(interior_values(params, v))
      v.merge!(drawer_values(params, profile, v))
      v = round_deep(v)
      validate(issues, v, profile, params)
      Result.new(v, issues)
    end

    def carcass_values(params, profile)
      t  = Material.fetch(params['material']).thickness
      w  = params['width'].to_f
      h  = params['height'].to_f
      d  = params['depth'].to_f
      bt = params['back_thickness'].to_f
      toe = params['toe_kick_height'].to_f
      carcass_h = h - toe
      internal_w = w - 2 * t
      side_h = carcass_h - (profile[:side_height_deduction] || t)
      back_y = d - profile[:back_setback] - bt
      {
        'thickness' => t, 'back_thickness' => bt, 'toe_height' => toe, 'toe_depth' => params['toe_kick_depth'].to_f,
        'carcass_height' => carcass_h, 'internal_width' => internal_w,
        'side_height' => side_h, 'side_depth' => d, 'bottom_width' => w, 'bottom_depth' => d,
        'back_width' => internal_w + 2 * profile[:groove_depth], 'back_height' => side_h - t - profile[:back_top_deduction],
        'back_y' => back_y, 'brace_width' => internal_w, 'brace_depth' => params['brace_depth'].to_f,
        'brace_count' => profile[:brace_count],
        'carcass_top_z' => toe + t + side_h, 'stack_height' => toe + t + side_h
      }
    end

    # Door and drawer-front sizes/positions. Drawers occupy the top; doors fill the rest.
    def front_values(params, _profile, v)
      h = params['height'].to_f
      r = params['door_reveal'].to_f
      g = params['door_gap'].to_f
      nd = params['drawer_count'].to_i
      doors = params['door_count'].to_i
      front_top = h - r
      front_bottom = v['toe_height'] + r
      front_t = Material.fetch(params['front_material']).thickness
      out = { 'front_thickness' => front_t, 'door_widths' => door_widths(width: params['width'].to_f, count: doors, reveal: r, gap: g),
              'door_height' => 0.0, 'door_z' => front_bottom, 'drawer_fronts' => [], 'zone_shelf_z' => nil }

      if nd.positive? && doors.zero?
        fh = (v['carcass_height'] - 2 * r - (nd - 1) * g) / nd
        out['drawer_fronts'] = Array.new(nd) { |i| { 'z' => front_top - (i + 1) * fh - i * g, 'height' => fh } }
      elsif nd.positive?
        fh = params['drawer_front_height'].to_f
        drawers_bottom = front_top - nd * fh - (nd - 1) * g
        out['drawer_fronts'] = Array.new(nd) { |i| { 'z' => front_top - (i + 1) * fh - i * g, 'height' => fh } }
        out['door_height'] = drawers_bottom - g - front_bottom
        out['zone_shelf_z'] = front_bottom + out['door_height'] + g / 2.0 - v['thickness'] # bottom face of the fixed shelf
      elsif doors.positive?
        out['door_height'] = v['carcass_height'] - 2 * r
      end
      out
    end

    # Open (door/open) zone: shelves and vertical dividers live here.
    def interior_values(params, v)
      t = v['thickness']
      nd = params['drawer_count'].to_i
      lower = nd.zero? || params['door_count'].to_i.positive?
      shelves = lower ? params['shelf_count'].to_i : 0
      dividers = lower ? params['divider_count'].to_i : 0
      profile = Construction.fetch(params['construction'])
      z_lo = v['toe_height'] + t
      z_hi = v['zone_shelf_z'] || v['carcass_top_z']
      comp_w = (v['internal_width'] - dividers * t) / (dividers + 1).to_f
      shelf_w = comp_w - 2 * profile[:shelf_side_clearance]
      shelf_rear = [profile[:shelf_rear_clearance], profile[:back_setback] + v['back_thickness']].max
      {
        'open_zone' => lower, 'open_z_lo' => z_lo, 'open_z_hi' => z_hi,
        'shelf_count' => shelves, 'divider_count' => dividers,
        'compartment_width' => comp_w, 'shelf_width' => shelf_w,
        'shelf_depth' => params['depth'].to_f - profile[:shelf_front_setback] - shelf_rear,
        'shelf_gap' => (z_hi - z_lo - shelves * t) / (shelves + 1).to_f,
        'divider_top_z' => v['zone_shelf_z'] ? z_hi : z_hi - t,
        'divider_depth' => v['back_y']
      }
    end

    def drawer_values(params, profile, v)
      step = profile[:drawer_step]
      rc = params['runner_clearance'].to_f
      st = Material.fetch(params['drawer_box_material']).thickness
      usable = v['back_y'] - profile[:drawer_rear_clearance]
      depth = (usable / step).floor * step
      floor_z = v['toe_height'] + v['thickness'] + profile[:drawer_box_lift] # never below the bottom panel
      boxes = v['drawer_fronts'].map do |f|
        top = f['z'] + f['height'] - (profile[:drawer_box_height_deduction] - profile[:drawer_box_lift])
        z = [f['z'] + profile[:drawer_box_lift], floor_z].max
        { 'z' => z, 'height' => top - z }
      end
      { 'drawer_boxes' => boxes, 'drawer_box_width' => v['internal_width'] - 2 * rc, 'drawer_box_depth' => depth.to_f,
        'drawer_box_thickness' => st, 'drawer_bottom_thickness' => profile[:drawer_bottom_thickness] }
    end

    def validate(issues, v, profile, params)
      err = ->(key, msg) { issues << Issue.new(:error, key, msg) }
      warn = ->(key, msg) { issues << Issue.new(:warning, key, msg) }
      nd = params['drawer_count'].to_i
      doors = params['door_count'].to_i

      err.call('width', "Internal width is #{v['internal_width']} mm - cabinet too narrow for the panel thickness") if v['internal_width'] <= 0
      err.call('height', "Side height is #{v['side_height']} mm - cabinet too low") if v['side_height'] <= 0
      err.call('height', "Back panel height is #{v['back_height']} mm - cabinet too low for this construction") if v['back_height'] <= 0
      err.call('depth', "Shelf depth is #{v['shelf_depth']} mm - cabinet too shallow") if v['shelf_depth'] <= 0

      if v['toe_height'].positive? && v['toe_depth'] + v['thickness'] >= params['depth'].to_f
        err.call('toe_kick_depth', 'Toe kick setback is deeper than the cabinet')
      end

      if v['open_zone'] && v['side_height'].positive?
        open_h = v['open_z_hi'] - v['open_z_lo']
        if open_h < profile[:min_shelf_gap]
          err.call(nd.positive? ? 'drawer_front_height' : 'height', "Open zone is only #{open_h.round(3)} mm high - too little room for doors")
        elsif v['shelf_count'].positive? && v['shelf_gap'] < profile[:min_shelf_gap]
          err.call('shelf_count', "Too many shelves: openings would be #{v['shelf_gap']} mm (minimum #{profile[:min_shelf_gap]} mm)")
        end
      end

      if v['divider_count'].positive?
        err.call('divider_count', "Compartments would be #{v['compartment_width']} mm wide - too many dividers") if v['compartment_width'] < 100
        warn.call('divider_count', "Narrow compartments (#{v['compartment_width']} mm)") if v['compartment_width'] >= 100 && v['compartment_width'] < 150
      end

      if nd.positive? && doors.zero?
        warn.call('shelf_count', 'Shelves ignored: drawers fill the whole cabinet') if params['shelf_count'].to_i.positive?
        warn.call('divider_count', 'Dividers ignored: drawers fill the whole cabinet') if params['divider_count'].to_i.positive?
      end

      if v['brace_depth'] * v['brace_count'] > v['back_y']
        err.call('brace_depth', 'Rails are deeper than the space in front of the back panel')
      end

      if doors.positive?
        dw = v['door_widths'].first
        err.call('door_count', "Door width would be #{dw} mm - too many doors for this width") if dw <= 0
        err.call('door_count', "Door height would be #{v['door_height']} mm - no room for doors") if v['door_height'] <= 0
        warn.call('door_count', "Very narrow doors (#{dw} mm)") if dw.positive? && dw < 100
        warn.call('door_count', "Wide doors (#{dw} mm) - consider more doors") if dw > 600
      end

      validate_drawers(issues, v, profile, params) if nd.positive?

      return unless (v['stack_height'] - params['height'].to_f).abs > 1e-6

      warn.call('construction',
                "Panel stack is #{v['stack_height']} mm but overall height is #{params['height']} mm " \
                "(#{(v['stack_height'] - params['height'].to_f).round(3)} mm difference)")
    end

    def validate_drawers(issues, v, profile, params)
      err = ->(key, msg) { issues << Issue.new(:error, key, msg) }
      err.call('runner_clearance', "Drawer box would be #{v['drawer_box_width'].round(3)} mm wide") if v['drawer_box_width'] <= 2 * v['drawer_box_thickness'] + 50
      if v['drawer_box_depth'] < profile[:drawer_min_depth]
        err.call('depth', "Drawer box depth would be #{v['drawer_box_depth']} mm (minimum #{profile[:drawer_min_depth]} mm) - cabinet too shallow")
      end
      v['drawer_fronts'].each_with_index do |f, i|
        err.call('drawer_front_height', "Drawer #{i + 1} front would be #{f['height'].round(3)} mm high") if f['height'] < 80
        box_h = v['drawer_boxes'][i]['height']
        err.call('drawer_front_height', "Drawer #{i + 1} box would be only #{box_h.round(3)} mm high") if box_h < v['drawer_bottom_thickness'] + 40
      end
      err.call('door_count', "Door height would be #{v['door_height']} mm - drawers take too much height") if params['door_count'].to_i.positive? && v['door_height'] <= 0
    end
  end
end
