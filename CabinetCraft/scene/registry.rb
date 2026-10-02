# frozen_string_literal: true

require_relative 'attributes'
require_relative 'containers'

module CabinetCraft
  module Scene
    # Finds cabinets in the active model: at the top level and inside other groups or component instances (the search stops at each
    # cabinet; what is inside a cabinet is its parts). Each hit carries the chain of ancestors it sits in.
    module Registry
      MAX_DEPTH = 8
      Entry = Struct.new(:entity, :cabinet, :path) do
        def nested?
          !path.empty?
        end
      end

      module_function

      # Everything that carries CabinetCraft cabinet data, readable or not (cabinet is nil when the data is unusable).
      def candidates(model, entities = model.entities, path = [])
        out = []
        Containers.each_container(entities) do |e|
          if e.attribute_dictionary(CABINET_DICT)
            out << Entry.new(e, Attributes.read_cabinet(e), path)
          elsif path.size < MAX_DEPTH
            out.concat(candidates(model, Containers.entities(e), path + [e]))
          end
        end
        out
      end

      def entries(model)
        candidates(model).select(&:cabinet)
      end

      # => [[group, Cabinet], ...] (top level and nested)
      def cabinets(model)
        entries(model).map { |e| [e.entity, e.cabinet] }
      end

      def find(model, id)
        cabinets(model).find { |_, cab| cab.id == id }
      end

      def find_entry(model, id)
        entries(model).find { |e| e.cabinet.id == id }
      end

      # Sequential human label (B01, B02, ...). The stable identity is the UUID;
      # the label is only for people and labels on parts.
      def next_label(model, prefix = 'B')
        used = cabinets(model).filter_map { |_, c| c.label[/\A#{prefix}(\d+)\z/, 1]&.to_i }
        format('%<p>s%<n>02d', p: prefix, n: (used.max || 0) + 1)
      end

      # X position (mm) just right of the right-most existing cabinet, so new
      # cabinets do not land on top of old ones.
      def next_x_mm(model)
        found = entries(model)
        return 0.0 if found.empty?

        found.map { |e| Containers.world_box(e.entity, e.path)[:max][0] }.max
      end

      # Groups whose cabinet_id is already used by an earlier group (typically
      # copies made with move+copy). Returns [[group, cabinet], ...] to re-identify.
      def duplicates(model)
        seen = {}
        cabinets(model).select do |_, cab|
          dup = seen.key?(cab.id)
          seen[cab.id] = true
          dup
        end
      end
    end
  end
end
