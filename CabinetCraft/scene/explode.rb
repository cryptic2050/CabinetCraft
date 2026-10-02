# frozen_string_literal: true

require_relative 'attributes'
require_relative 'containers'
require_relative '../core/units'
require_relative '../manufacturing/assembly'

module CabinetCraft
  module Scene
    # Moves a cabinet's part groups apart (and back) in the SketchUp model. The applied offset of every part is
    # stored on the part, so exploding is reversible and repeatable: changing the amount first undoes the old offset.
    # Offsets are in the cabinet group's own axes, so a rotated cabinet explodes along its own directions.
    module Explode
      KEY = 'explode_offset'

      module_function

      def exploded?(group)
        parts(group).any? { |p| !stored(p).nil? }
      end

      def parts(group)
        Containers.child_groups(group)
      end

      # "dx,dy,dz" in mm, or nil when the part is in its assembled position.
      def stored(part)
        raw = part.get_attribute(PART_DICT, KEY)
        return nil if raw.nil? || raw.to_s.empty?

        v = raw.to_s.split(',').map(&:to_f)
        v.size == 3 && v.any? { |n| n.abs > 1e-9 } ? v : nil
      end

      # Moves every part to its exploded position for `amount` mm (0 = assembled). Returns the number of parts moved.
      def apply(group, cabinet, amount)
        offsets = Manufacturing::Assembly.explode_offsets(cabinet, amount.to_f)
        moved = 0
        parts(group).each do |part|
          key = part.get_attribute(PART_DICT, 'key')
          target = offsets[key] || [0.0, 0.0, 0.0]
          current = stored(part) || [0.0, 0.0, 0.0]
          delta = target.zip(current).map { |t, c| t - c }
          next if delta.all? { |d| d.abs < 1e-9 }

          part.transform!(::Geom::Transformation.translation(::Geom::Vector3d.new(*delta.map { |d| Units.to_sketchup(d) })))
          part.set_attribute(PART_DICT, KEY, target.all? { |d| d.abs < 1e-9 } ? '' : target.map { |d| d.round(4) }.join(','))
          moved += 1
        end
        moved
      end

      def assemble(group)
        parts_moved = 0
        parts(group).each do |part|
          cur = stored(part) or next
          part.transform!(::Geom::Transformation.translation(::Geom::Vector3d.new(*cur.map { |d| Units.to_sketchup(-d) })))
          part.set_attribute(PART_DICT, KEY, '')
          parts_moved += 1
        end
        parts_moved
      end
    end
  end
end
