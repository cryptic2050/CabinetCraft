# frozen_string_literal: true

require_relative '../core/machining_config'
require_relative '../core/hardware_rules'

module CabinetCraft
  module Manufacturing
    # Machining data: drilling operations derived from cabinet parameters (never stored).
    #
    # Each operation is a Hash in PANEL-LOCAL coordinates: x along the part's length, y along its
    # width, measured from its minimum corner.
    #   face op: 'target' => 'face', 'side' => 'a' | 'b'   (a = the max side of the thickness axis, b = the min side)
    #            'x', 'y' = hole centre, 'dia', 'depth', 'through'
    #   edge op: 'target' => 'edge', 'edge' => 'L1'|'L2'|'W1'|'W2', 'along' = position along that edge,
    #            'z' = height within the thickness, 'dia', 'depth'   (horizontal boring, NOT router work)
    #
    # IMPLEMENTED: shelf pins, hinge cups + plate holes, handle holes, side-mount runner holes, cam lock /
    # dowel / confirmat joints, user-defined patterns. NOT implemented (reported as warnings, never silently
    # skipped): lamello and mortise-and-tenon slots, undermount/other runner patterns, runner holes on the drawer box.
    module Machining
      SUPPORTED_CONNECTORS = %w[cam_lock dowel confirmat].freeze
      MOUNT_TOLERANCE = 30.0

      module_function

      # => { 'ops' => [...], 'issues' => [{ 'severity', 'code', 'message', 'part_key' }] }
      def operations(cabinet, config = MachiningConfig.current, hw_settings = Hardware.config.settings)
        return { 'ops' => [], 'issues' => [] } unless cabinet.calculation.ok?

        ctx = { cab: cabinet, panels: cabinet.panels.to_h { |p| [p.key, p] }, v: cabinet.calculation.values,
                params: cabinet.params, st: config.settings, hw: hw_settings, ops: [], issues: [] }
        shelf_pins(ctx)
        hinges(ctx)
        handles(ctx)
        runners(ctx)
        connectors(ctx)
        custom_patterns(ctx, config)
        { 'ops' => ctx[:ops], 'issues' => ctx[:issues] }
      end

      def for_project(cabinets, config = MachiningConfig.current)
        res = cabinets.map { |c| [c, operations(c, config)] }
        { 'ops' => res.flat_map { |_, r| r['ops'] },
          'issues' => res.flat_map { |c, r| r['issues'].map { |i| i.merge('cabinet_id' => c.id, 'cabinet_label' => c.label) } } }
      end

      # --- op builders -------------------------------------------------------------------------
      def base(ctx, panel, kind, hardware_id = nil)
        cab = ctx[:cab]
        { 'cabinet_id' => cab.id, 'cabinet_label' => cab.label, 'part_key' => panel.key, 'part_id' => cab.part_id(panel),
          'part_uid' => "#{cab.id}:#{panel.key}", 'kind' => kind, 'hardware_id' => hardware_id,
          'part_length' => panel.length.round(3), 'part_width' => panel.width.round(3), 'part_thickness' => panel.thickness.round(3) }
      end

      # point: cabinet-local [x, y, z]; only the coordinates in the panel's plane matter.
      # `through` is an explicit intent (handles, confirmat clearance holes). Every other hole is blind
      # and must leave material under it, even if its depth happens to equal the part thickness.
      def face_op(ctx, panel, side, point, dia, depth, kind, hardware_id = nil, note = nil, through: false)
        lx, ly, = panel.to_local(point)
        ctx[:ops] << base(ctx, panel, kind, hardware_id).merge(
          'target' => 'face', 'side' => side, 'x' => lx.round(3), 'y' => ly.round(3), 'dia' => dia, 'depth' => depth,
          'through' => through, 'note' => note
        )
      end

      def local_face_op(ctx, panel, side, lx, ly, dia, depth, kind, note)
        ctx[:ops] << base(ctx, panel, kind).merge('target' => 'face', 'side' => side, 'x' => lx, 'y' => ly, 'dia' => dia,
                                                  'depth' => depth, 'through' => depth >= panel.thickness - 1e-6, 'note' => note)
      end

      def edge_op(ctx, panel, face, point, dia, depth, kind, hardware_id = nil)
        code = panel.edge_code(face)
        lx, ly, lz = panel.to_local(point)
        ctx[:ops] << base(ctx, panel, kind, hardware_id).merge(
          'target' => 'edge', 'edge' => code, 'along' => (code.start_with?('L') ? lx : ly).round(3), 'z' => lz.round(3),
          'dia' => dia, 'depth' => depth, 'through' => false, 'note' => nil
        )
      end

      def issue(ctx, severity, code, message, part_key = nil)
        key = [code, message]
        return if ctx[:issues].any? { |i| [i['code'], i['message']] == key }

        ctx[:issues] << { 'severity' => severity, 'code' => code, 'message' => message, 'part_key' => part_key }
      end

      def side_face(panel, direction) # direction :max / :min of the thickness axis
        direction == :max ? 'a' : 'b'
      end

      # --- shelf pins ------------------------------------------------------------------------------
      def shelf_pins(ctx)
        st = ctx[:st]
        total = ctx[:hw]['shelf_pins_per_shelf'].to_i
        per_side = [total / 2, 1].max
        shelves = ctx[:cab].panels.select { |p| p.role == :shelf }
        issue(ctx, 'warning', 'machining_pin_count', "Shelf pins per shelf (#{total}) is odd: machining drills #{per_side * 2}") if shelves.any? && total.odd?
        uprights = ctx[:cab].panels.select { |p| %i[side divider].include?(p.role) }
        shelves.each do |sh|
          left = uprights.select { |u| u.max_corner[0] <= sh.origin[0] + 1e-3 }.max_by { |u| u.max_corner[0] }
          right = uprights.select { |u| u.min_corner[0] >= sh.max_corner[0] - 1e-3 }.min_by { |u| u.min_corner[0] }
          next unless left && right

          ys = HardwareRules.joint_positions(sh.size[1] - 2 * st['shelf_pin_inset'], per_side, 0).map { |d| sh.origin[1] + st['shelf_pin_inset'] + d }
          ys = [sh.origin[1] + st['shelf_pin_inset'], sh.max_corner[1] - st['shelf_pin_inset']] if per_side == 2
          z = sh.origin[2] - st['shelf_pin_below']
          ys.each do |y|
            face_op(ctx, left, 'a', [left.max_corner[0], y, z], st['shelf_pin_dia'], st['shelf_pin_depth'], 'shelf_pin', 'shelf_pin')
            face_op(ctx, right, 'b', [right.min_corner[0], y, z], st['shelf_pin_dia'], st['shelf_pin_depth'], 'shelf_pin', 'shelf_pin')
          end
        end
      end

      # --- hinges -----------------------------------------------------------------------------------
      def hinges(ctx)
        st = ctx[:st]
        doors = ctx[:cab].panels.select { |p| p.role == :door }
        return if doors.empty?

        hid = ctx[:params]['hinge_type']
        issue(ctx, 'warning', 'machining_custom_hardware', "Hinge '#{Hardware.name_of(hid)}' is custom: the standard cup/plate drilling pattern is used") unless Hardware::BUILT_IN.any? { |h| h.id == hid }
        left_side = ctx[:panels]['side_left']
        right_side = ctx[:panels]['side_right']
        doors.each_with_index do |door, i|
          side = HardwareRules.hinge_side(i, doors.size, ctx[:params]['hinge_side'])
          count = Hardware.config.hinge_count(door.size[2])
          edge_x = side == 'left' ? door.origin[0] : door.max_corner[0]
          cup_x = side == 'left' ? edge_x + st['hinge_cup_edge'] : edge_x - st['hinge_cup_edge']
          zs = HardwareRules.hinge_positions(door.size[2], count, ctx[:hw]['hinge_inset']).map { |p| door.origin[2] + p }
          mount = side == 'left' ? left_side : right_side
          inner_x = side == 'left' ? mount.max_corner[0] : mount.min_corner[0]
          mounted = (edge_x - inner_x).abs <= MOUNT_TOLERANCE
          issue(ctx, 'warning', 'machining_no_mount', "#{door.name}: no side panel behind its hinge edge, so hinge plate holes were not drilled (inner doors need a divider)", door.key) unless mounted
          zs.each do |z|
            face_op(ctx, door, 'a', [cup_x, door.origin[1], z], st['hinge_cup_dia'], st['hinge_cup_depth'], 'hinge_cup', hid)
            next unless mounted

            [-1, 1].each do |sgn|
              face_op(ctx, mount, side == 'left' ? 'a' : 'b', [inner_x, mount.origin[1] + st['hinge_plate_setback'], z + sgn * st['hinge_plate_pitch'] / 2.0],
                      st['hinge_plate_dia'], st['hinge_plate_depth'], 'hinge_plate', hid)
            end
          end
        end
      end

      # --- handles -----------------------------------------------------------------------------------
      def handles(ctx)
        hid = ctx[:params]['handle_type']
        return if hid == 'none'

        st = ctx[:st]
        issue(ctx, 'warning', 'machining_custom_hardware', "Handle '#{Hardware.name_of(hid)}' is custom: a two-hole pattern at #{st['handle_spacing']} mm is used") unless Hardware::BUILT_IN.any? { |h| h.id == hid }
        spacing = st['handle_spacing']
        doors = ctx[:cab].panels.select { |p| p.role == :door }
        doors.each_with_index do |d, i|
          side = HardwareRules.hinge_side(i, doors.size, ctx[:params]['hinge_side'])
          x = side == 'left' ? d.max_corner[0] - ctx[:hw]['handle_inset'] : d.origin[0] + ctx[:hw]['handle_inset']
          top = d.max_corner[2] - ctx[:hw]['handle_top_offset']
          [top, top - spacing].each { |z| face_op(ctx, d, 'b', [x, d.origin[1], z], st['handle_dia'], d.thickness, 'handle', hid, through: true) }
        end
        ctx[:cab].panels.select { |p| p.role == :drawer_front }.each do |f|
          cx = (f.origin[0] + f.max_corner[0]) / 2.0
          cz = (f.origin[2] + f.max_corner[2]) / 2.0
          [-1, 1].each { |s| face_op(ctx, f, 'b', [cx + s * spacing / 2.0, f.origin[1], cz], st['handle_dia'], f.thickness, 'handle', hid, through: true) }
        end
      end

      # --- drawer runners ------------------------------------------------------------------------------
      def runners(ctx)
        fronts = ctx[:cab].panels.select { |p| p.role == :drawer_front }.sort_by(&:key)
        return if fronts.empty?

        rid = ctx[:params]['runner_type']
        unless rid == 'runner_side_mount'
          issue(ctx, 'warning', 'machining_unsupported', "Runner '#{Hardware.name_of(rid)}': no machining pattern is implemented, so runner holes were not generated")
          return
        end
        st = ctx[:st]
        l = ctx[:panels]['side_left']
        r = ctx[:panels]['side_right']
        fronts.each_index do |i|
          box_side = ctx[:panels]["drawer_#{i + 1}_side_left"] or next
          z = (box_side.origin[2] + box_side.max_corner[2]) / 2.0
          st['runner_hole_count'].times do |k|
            y = l.origin[1] + st['runner_front_hole'] + k * st['runner_hole_pitch']
            face_op(ctx, l, 'a', [l.max_corner[0], y, z], st['runner_dia'], st['runner_depth'], 'runner', rid)
            face_op(ctx, r, 'b', [r.min_corner[0], y, z], st['runner_dia'], st['runner_depth'], 'runner', rid)
          end
        end
      end

      # --- connectors ------------------------------------------------------------------------------------
      # Joint lists mirror HardwareRules.joints so machining and the hardware list always agree.
      def connectors(ctx)
        type = ctx[:params]['connector_type']
        unless SUPPORTED_CONNECTORS.include?(type)
          issue(ctx, 'warning', 'machining_unsupported', "Connector '#{Hardware.name_of(type)}': no machining pattern is implemented (slots/mortises), so no joint operations were generated")
          return
        end
        st = ctx[:st]
        spacing = ctx[:hw]['connector_spacing']
        panels = ctx[:panels]
        v = ctx[:v]
        t = v['thickness']
        positions = ->(len) { HardwareRules.joint_positions(len, HardwareRules.connector_count(len, spacing), st['joint_inset']) }

        %w[side_left side_right].each do |k|
          side = panels[k]
          bottom = panels['bottom']
          left = k == 'side_left'
          zj = bottom.max_corner[2]
          positions.call(side.size[1]).each do |d|
            y = side.origin[1] + d
            xc = side.origin[0] + t / 2.0
            joint(ctx, type, edge: [side, :bottom, [xc, y, zj]], cam: [side, left ? 'a' : 'b', [left ? side.max_corner[0] : side.min_corner[0], y, zj + st['cam_distance']]],
                  face: [bottom, 'a', [xc, y, zj]])
          end
        end
        %w[brace_front brace_rear zone_shelf].each do |k|
          pn = panels[k] or next
          len = pn.size[1]
          zc = pn.origin[2] + pn.thickness / 2.0
          [[:left, 'side_left', 'a'], [:right, 'side_right', 'b']].each do |dir, sk, fside|
            sd = panels[sk]
            xj = dir == :left ? sd.max_corner[0] : sd.min_corner[0]
            positions.call(len).each do |d|
              y = pn.origin[1] + d
              cam_x = dir == :left ? pn.origin[0] + st['cam_distance'] : pn.max_corner[0] - st['cam_distance']
              joint(ctx, type, edge: [pn, dir, [xj, y, zc]], cam: [pn, 'a', [cam_x, y, zc]], face: [sd, fside, [xj, y, zc]])
            end
          end
        end
        ctx[:cab].panels.select { |p| p.role == :divider }.each do |dv|
          bottom = panels['bottom']
          zj = bottom.max_corner[2]
          positions.call(dv.size[1]).each do |d|
            y = dv.origin[1] + d
            xc = dv.origin[0] + t / 2.0
            joint(ctx, type, edge: [dv, :bottom, [xc, y, zj]], cam: [dv, 'a', [dv.max_corner[0], y, zj + st['cam_distance']]], face: [bottom, 'a', [xc, y, zj]])
          end
        end
      end

      # edge: [panel, edge face, point]; cam: [panel, side, point]; face: [panel, side, point]
      def joint(ctx, type, edge:, cam:, face:)
        st = ctx[:st]
        ep, eface, epoint = edge
        fp, fside, fpoint = face
        case type
        when 'cam_lock'
          face_op(ctx, *cam[0, 2], cam[2], st['cam_dia'], st['cam_depth'], 'connector_cam', 'cam_lock')
          edge_op(ctx, ep, eface, epoint, st['cam_bore_dia'], st['cam_distance'], 'connector_bore', 'cam_lock')
          face_op(ctx, fp, fside, fpoint, st['bolt_hole_dia'], st['bolt_hole_depth'], 'connector_bolt', 'cam_bolt')
        when 'dowel'
          edge_op(ctx, ep, eface, epoint, st['dowel_dia'], st['dowel_edge_depth'], 'connector_dowel', 'dowel')
          face_op(ctx, fp, fside, fpoint, st['dowel_dia'], st['dowel_face_depth'], 'connector_dowel', 'dowel')
        when 'confirmat'
          edge_op(ctx, ep, eface, epoint, st['confirmat_pilot_dia'], st['confirmat_pilot_depth'], 'connector_confirmat', 'confirmat')
          face_op(ctx, fp, fside == 'a' ? 'b' : 'a', fpoint, st['confirmat_clear_dia'], fp.thickness, 'connector_confirmat', 'confirmat', through: true)
        end
      end

      # --- user patterns -----------------------------------------------------------------------------------
      def custom_patterns(ctx, config)
        config.patterns.each do |pat|
          ctx[:cab].panels.select { |p| p.role.to_s == pat['role'] }.each do |panel|
            pat['holes'].each do |h|
              local_face_op(ctx, panel, pat['side'], h['x'], h['y'], h['dia'], h['depth'], 'custom', pat['name'])
            end
          end
        end
      end
    end
  end
end
