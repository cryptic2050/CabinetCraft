# frozen_string_literal: true

module CabinetCraft
  module Scene
    # Groups and component instances hold their contents differently: a Group has `entities`, a ComponentInstance has
    # `definition.entities`. Everything that looks inside a cabinet or searches for cabinets goes through here.
    module Containers
      module_function

      def container?(entity)
        entity.is_a?(::Sketchup::Group) || entity.is_a?(::Sketchup::ComponentInstance)
      end

      def entities(container)
        container.is_a?(::Sketchup::ComponentInstance) ? container.definition.entities : container.entities
      end

      # The group children of a container (the parts of a cabinet).
      def child_groups(container)
        entities(container).grep(::Sketchup::Group)
      end

      # Groups and component instances directly inside an Entities collection.
      def each_container(entities, &block)
        entities.each { |e| block.call(e) if container?(e) }
      end

      # World-space bounds in millimetres of `entity`, whose ancestors (outermost first) are `path`. Without ancestors this is
      # simply its own bounds; with them the corners are carried through every ancestor transformation.
      def world_box(entity, path = [])
        b = entity.bounds
        corners = [b.min.x, b.max.x].product([b.min.y, b.max.y], [b.min.z, b.max.z]).map { |x, y, z| ::Geom::Point3d.new(x, y, z) }
        corners = corners.map { |pt| path.reverse.reduce(pt) { |p, ancestor| p.transform(ancestor.transformation) } } unless path.empty?
        xs = corners.map(&:x)
        ys = corners.map(&:y)
        zs = corners.map(&:z)
        { min: [xs.min, ys.min, zs.min].map { |v| Units.from_sketchup(v) }, max: [xs.max, ys.max, zs.max].map { |v| Units.from_sketchup(v) } }
      end
    end
  end
end
