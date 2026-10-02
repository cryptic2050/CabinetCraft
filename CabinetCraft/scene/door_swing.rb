# frozen_string_literal: true

require_relative 'attributes'
require_relative 'containers'
require_relative 'explode'
require_relative '../core/units'
require_relative '../core/hardware_rules'

module CabinetCraft
  module Scene
    # Opens and closes the doors of a cabinet in the SketchUp model (a presentation aid, like Explode). Each door swings
    # outwards about its hinge edge; the angle is stored on the door part so closing is exact and repeatable.
    module DoorSwing
      KEY = 'door_open'
      DEFAULT_ANGLE = 95.0
      MAX_ANGLE = 120.0

      module_function

      def door_parts(group, cabinet)
        keys = cabinet.panels.select { |p| p.role == :door }.map(&:key)
        Containers.child_groups(group).select { |g| keys.include?(g.get_attribute(PART_DICT, 'key')) }
      end

      def stored(part)
        raw = part.get_attribute(PART_DICT, KEY)
        v = raw.to_s.empty? ? 0.0 : raw.to_f
        v.abs > 1e-9 ? v : nil
      end

      def open?(group)
        Containers.child_groups(group).any? { |p| stored(p) }
      end

      # Opens (angle > 0) or closes (angle 0) every door of the cabinet. Returns the number of doors moved.
      def set(group, cabinet, angle)
        angle = angle.to_f.clamp(0.0, MAX_ANGLE)
        doors = cabinet.panels.select { |p| p.role == :door }.sort_by(&:key)
        parts = door_parts(group, cabinet).to_h { |g| [g.get_attribute(PART_DICT, 'key'), g] }
        moved = 0
        doors.each_with_index do |panel, i|
          part = parts[panel.key] or next
          target = angle.zero? ? 0.0 : swing_sign(i, doors.size, cabinet) * angle
          current = stored(part) || 0.0
          delta = target - current
          next if delta.abs < 1e-9

          part.transform!(rotation(panel, part, delta, hinge_right?(i, doors.size, cabinet)))
          part.set_attribute(PART_DICT, KEY, target.zero? ? '' : target.round(3))
          moved += 1
        end
        moved
      end

      def hinge_right?(index, total, cabinet)
        HardwareRules.hinge_side(index, total, cabinet.params['hinge_side']) == 'right'
      end

      # Left-hinged doors turn clockwise seen from above (the free edge moves to the front, -y); right-hinged the other way.
      # The sign encodes which way the stored angle was applied so the same pivot reverses it.
      def swing_sign(index, total, cabinet)
        hinge_right?(index, total, cabinet) ? 1.0 : -1.0
      end

      def rotation(panel, part, delta_deg, right)
        ox, oy, = panel.origin
        sx, = panel.size
        px = right ? ox + sx : ox
        pivot = [px, oy + panel.size[1], 0.0] # hinge edge, at the back face of the door
        off = Explode.stored(part) || [0.0, 0.0, 0.0]
        pivot = pivot.zip(off).map { |a, b| a + b }
        ::Geom::Transformation.rotation(::Geom::Point3d.new(*pivot.map { |v| Units.to_sketchup(v) }), ::Geom::Vector3d.new(0, 0, 1), delta_deg * Math::PI / 180.0)
      end
    end
  end
end
