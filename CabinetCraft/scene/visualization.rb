# frozen_string_literal: true

require_relative 'attributes'
require_relative 'containers'
require_relative 'registry'
require_relative '../generators/cabinet_generator'

module CabinetCraft
  module Scene
    # Paints the part groups of every cabinet according to a Manufacturing::Visualization assignment. Nothing is stored on the parts:
    # the real materials are always recomputed from the cabinet data, so 'material' mode puts everything back exactly.
    module Visualization
      module_function

      # Returns the number of parts painted.
      def apply(model, assignment)
        count = 0
        Registry.entries(model).each do |entry|
          cab = entry.cabinet
          panels = cab.panels.to_h { |p| [p.key, p] }
          Containers.child_groups(entry.entity).each do |part|
            info = assignment['parts'][part.get_attribute(PART_DICT, 'part_uid')] or next
            panel = panels[part.get_attribute(PART_DICT, 'key')]
            part.material = if info['real'] && panel then Generators::CabinetGenerator.sketchup_material(entry.entity, panel)
                            else paint(model, info)
                            end
            count += 1
          end
        end
        count
      end

      # One SketchUp material per colour (and transparency), reused across parts and across modes.
      def paint(model, info)
        name = "CabinetCraft viz #{info['color']}#{info['alpha'] ? " a#{(info['alpha'] * 100).round}" : ''}"
        existing = model.materials[name]
        return existing if existing

        mat = model.materials.add(name)
        hex = info['color'].delete('#')
        mat.color = ::Sketchup::Color.new(*hex.scan(/../).map { |c| c.to_i(16) })
        mat.alpha = info['alpha'] if info['alpha'] && mat.respond_to?(:alpha=)
        mat
      end
    end
  end
end
