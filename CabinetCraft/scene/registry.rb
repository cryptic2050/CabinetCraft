# frozen_string_literal: true

require_relative 'attributes'

module CabinetCraft
  module Scene
    # Finds cabinets in the active model. Phase 1 scans top-level groups only;
    # cabinets nested inside other groups/components are not discovered yet.
    module Registry
      module_function

      # => [[group, Cabinet], ...]
      def cabinets(model)
        model.entities.grep(::Sketchup::Group).filter_map do |g|
          next unless Attributes.cabinet?(g)

          cab = Attributes.read_cabinet(g)
          cab ? [g, cab] : nil
        end
      end

      def find(model, id)
        cabinets(model).find { |_, cab| cab.id == id }
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
        groups = cabinets(model).map(&:first)
        return 0.0 if groups.empty?

        Units.from_sketchup(groups.map { |g| g.bounds.max.x }.max)
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
