# frozen_string_literal: true

module CabinetCraft
  module Validation
    # Geometry checks on a cabinet's own panels (pure, no SketchUp).
    module CollisionChecker
      TOLERANCE = 0.01 # mm; dimensions are rounded to 0.001 mm

      module_function

      # => [[panel_a, panel_b, code], ...]; panels housed in each other (back in side grooves) are allowed.
      def panel_overlaps(panels)
        panels.combination(2).filter_map do |a, b|
          next if a.grooved_into.include?(b.key) || b.grooved_into.include?(a.key)
          next unless a.overlaps?(b, TOLERANCE)

          [a, b, code_for(a, b)]
        end
      end

      def code_for(a, b)
        fronts = %i[door drawer_front]
        return 'door_collision' if fronts.include?(a.role) && fronts.include?(b.role)
        return 'drawer_collision' if a.role == :drawer_box || b.role == :drawer_box || a.role == :drawer_front || b.role == :drawer_front

        'overlapping_parts'
      end

      # Axis-aligned boxes in mm: { min: [x,y,z], max: [x,y,z] }
      def boxes_overlap?(a, b, tolerance = 1.0)
        3.times.all? { |i| a[:min][i] < b[:max][i] - tolerance && a[:max][i] > b[:min][i] + tolerance }
      end
    end
  end
end
