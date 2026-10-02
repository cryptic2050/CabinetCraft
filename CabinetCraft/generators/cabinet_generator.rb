# frozen_string_literal: true

require_relative '../core/units'
require_relative '../core/material'
require_relative '../scene/attributes'

module CabinetCraft
  module Generators
    # Builds SketchUp geometry for a Cabinet: one Group per cabinet containing one
    # Group per production panel. The only place that creates cabinet geometry.
    module CabinetGenerator
      module_function

      # Creates a new cabinet group in `entities`, optionally translated by `transformation`.
      def create(entities, cabinet, transformation = nil)
        group = entities.add_group
        group.transform!(transformation) if transformation
        populate(group, cabinet)
        group
      end

      # Rebuilds the contents of an existing cabinet group in place. The group's
      # own transformation (position/rotation in the model) is preserved.
      def rebuild(group, cabinet)
        group.make_unique if group.respond_to?(:make_unique)
        group.entities.clear!
        populate(group, cabinet)
        group
      end

      def populate(group, cabinet)
        rows = cabinet.part_rows.to_h { |r| [r['key'], r] } # computed once, not per panel
        cabinet.panels.each do |panel|
          part = group.entities.add_group
          build_box(part.entities, panel)
          part.name = cabinet.part_id(panel)
          part.material = sketchup_material(group, panel)
          Scene::Attributes.write_part(part, rows.fetch(panel.key), cabinet)
        end
        group.name = "#{cabinet.label} #{cabinet.type}"
        Scene::Attributes.write_cabinet(group, cabinet)
      end

      # Axis-aligned box: rectangle in the XY plane at z0, extruded by dz.
      def build_box(entities, panel)
        x, y, z = panel.origin.map { |v| Units.to_sketchup(v) }
        dx, dy, dz = panel.size.map { |v| Units.to_sketchup(v) }
        pts = [
          Geom::Point3d.new(x, y, z), Geom::Point3d.new(x + dx, y, z),
          Geom::Point3d.new(x + dx, y + dy, z), Geom::Point3d.new(x, y + dy, z)
        ]
        face = entities.add_face(pts)
        face.reverse! if face.normal.z < 0 # always extrude upwards
        face.pushpull(dz)
      end

      def sketchup_material(group, panel)
        model = group.model
        id = panel.material_id
        name = "CabinetCraft #{panel.material_label}"
        existing = model.materials[name]
        return existing if existing

        mat = model.materials.add(name)
        mat.color = colour_for(id)
        apply_texture(mat, id)
        mat
      end

      # Texture is optional and best-effort: a missing or unreadable image never stops generation.
      def apply_texture(sketchup_material, material_id)
        path = Material.find(material_id)&.texture
        return unless path && File.file?(path) && sketchup_material.respond_to?(:texture=)

        sketchup_material.texture = path
      rescue StandardError
        nil
      end

      def colour_for(material_id)
        hex = Material.find(material_id)&.color || '#8a6a4a'
        r, g, b = hex.delete('#').scan(/../).map { |c| c.to_i(16) }
        Sketchup::Color.new(r, g, b)
      end
    end
  end
end
