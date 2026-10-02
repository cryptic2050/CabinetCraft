# frozen_string_literal: true

require_relative '../core/cabinet'
require_relative 'containers'

module CabinetCraft
  # Everything that touches SketchUp attribute dictionaries lives in Scene.
  # (Named Scene, not Sketchup/UI, so it never shadows the SketchUp constants.)
  module Scene
    CABINET_DICT = 'CabinetCraft'
    PART_DICT = 'CabinetCraft_Part'

    module Attributes
      module_function

      def cabinet?(entity)
        Containers.container?(entity) && !entity.get_attribute(CABINET_DICT, 'cabinet_id').nil?
      end

      def write_cabinet(entity, cabinet)
        cabinet.to_attributes.each { |k, v| entity.set_attribute(CABINET_DICT, k, v) }
      end

      # Returns a Cabinet or nil if the entity is not a (readable) cabinet.
      def read_cabinet(entity)
        dict = entity.attribute_dictionary(CABINET_DICT)
        return nil unless dict

        attrs = {}
        dict.each_pair { |k, v| attrs[k] = v }
        Cabinet.from_attributes(attrs)
      end

      def write_part(entity, row, cabinet)
        # Only scalar, stable values are stored; derived data (hardware text, edge hashes) is recomputed on demand.
        row.each do |k, v|
          next if k == 'hardware' || !(v.is_a?(String) || v.is_a?(Numeric))

          entity.set_attribute(PART_DICT, k, v)
        end
        entity.set_attribute(PART_DICT, 'cabinet_id', cabinet.id)
        entity.set_attribute(PART_DICT, 'cabinet_label', cabinet.label)
      end
    end
  end
end
