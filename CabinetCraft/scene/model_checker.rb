# frozen_string_literal: true

require_relative 'attributes'
require_relative 'explode'
require_relative '../validation/validator'
require_relative '../validation/collision_checker'

module CabinetCraft
  module Scene
    # Checks the SketchUp model itself against the cabinet data: deleted or extra
    # parts, edited part geometry, scaled cabinets, missing IDs, overlapping cabinets.
    module ModelChecker
      SIZE_TOLERANCE_MM = 0.2

      module_function

      def run(model)
        issues = []
        boxes = []
        model.entities.grep(::Sketchup::Group).each do |group|
          dict = group.attribute_dictionary(CABINET_DICT)
          next unless dict

          cab = Attributes.read_cabinet(group)
          if cab.nil?
            code = dict['cabinet_id'].to_s.empty? ? 'missing_cabinet_id' : 'unreadable_cabinet'
            msg = code == 'missing_cabinet_id' ? 'A CabinetCraft group has no cabinet ID' : 'Cabinet data could not be read (it may have been edited by hand)'
            issues << Validation::Validator.issue(:error, code, msg).merge('entity_id' => group.entityID)
            next
          end
          issues.concat(check_group(group, cab))
          if Explode.exploded?(group)
            issues << Validation::Validator.issue(:warning, 'cabinet_exploded', "#{cab.label} is shown exploded in the model (ASSEMBLY tab: Assemble). Its position is not checked against other cabinets.", cabinet: cab)
          else
            boxes << [cab, world_box(group)]
          end
        end
        issues.concat(check_overlaps(boxes))
        issues
      end

      def check_group(group, cab)
        out = []
        t = group.transformation
        if t.respond_to?(:xscale) && [t.xscale, t.yscale, t.zscale].any? { |s| (s - 1.0).abs > 1e-6 }
          out << Validation::Validator.issue(:warning, 'cabinet_scaled', 'The cabinet group has been scaled; part sizes no longer match its parameters', cabinet: cab)
        end
        return out unless cab.calculation.ok? # no expected parts while the rules fail; that error is reported separately

        expected = cab.part_rows.to_h { |r| [r['part_id'], r] }
        panels = cab.panels.to_h { |p| [cab.part_id(p), p] }
        children = group.entities.grep(::Sketchup::Group)
        names = children.map(&:name)

        (expected.keys - names).each do |pid|
          out << Validation::Validator.issue(:error, 'missing_in_model', "#{pid} is missing from the model (deleted?) - edit the cabinet to regenerate it", cabinet: cab, part_key: expected[pid]['key'])
        end
        (names - expected.keys).each do |name|
          out << Validation::Validator.issue(:warning, 'unexpected_geometry', "Unexpected group '#{name}' inside #{cab.label}", cabinet: cab)
        end
        children.each do |part|
          next unless expected.key?(part.name)

          out.concat(check_part(part, cab, panels[part.name], expected[part.name]))
        end
        out
      end

      def check_part(part, cab, panel, row)
        out = []
        pid = part.get_attribute(PART_DICT, 'cabinet_id')
        if pid.to_s.empty?
          out << Validation::Validator.issue(:error, 'missing_cabinet_id', "#{part.name} has no cabinet ID", cabinet: cab, part_key: row['key'])
        elsif pid != cab.id
          out << Validation::Validator.issue(:error, 'wrong_cabinet_id', "#{part.name} belongs to a different cabinet ID", cabinet: cab, part_key: row['key'])
        end
        b = part.bounds
        actual = [b.max.x - b.min.x, b.max.y - b.min.y, b.max.z - b.min.z].map { |v| Units.from_sketchup(v) }.sort
        wanted = panel.size.sort
        if actual.zip(wanted).any? { |a, w| (a - w).abs > SIZE_TOLERANCE_MM }
          out << Validation::Validator.issue(:warning, 'geometry_modified',
                                             "#{part.name} was edited in the model (#{actual.map { |v| v.round(1) }.join(' x ')} instead of #{wanted.map { |v| v.round(1) }.join(' x ')} mm); reports use the parameters",
                                             cabinet: cab, part_key: row['key'])
        end
        out
      end

      def world_box(group)
        b = group.bounds
        { min: [b.min.x, b.min.y, b.min.z].map { |v| Units.from_sketchup(v) }, max: [b.max.x, b.max.y, b.max.z].map { |v| Units.from_sketchup(v) } }
      end

      def check_overlaps(boxes)
        boxes.combination(2).filter_map do |(a, ba), (b, bb)|
          next unless Validation::CollisionChecker.boxes_overlap?(ba, bb)

          Validation::Validator.issue(:warning, 'cabinets_overlap', "#{a.label} and #{b.label} overlap in the model", cabinet: a)
        end
      end
    end
  end
end
