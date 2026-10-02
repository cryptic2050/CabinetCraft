# frozen_string_literal: true

require_relative 'material'
require_relative 'panel'

module CabinetCraft
  # Manual per-part overrides of the automatically calculated production panels.
  #
  # Stored with the cabinet as { part_key => { field => value } }. Overrides are never silently overwritten:
  # changing cabinet parameters that would alter an overridden size is held back until the user decides
  # (see Overrides.affected and Controller#update).
  #
  # Fields: 'length' / 'width' / 'thickness' (mm, measured along the part's own length / width / thickness axes as
  # generated), 'offset_x' / 'offset_y' / 'offset_z' (mm shift of the part in the cabinet, relative to its automatic
  # position), 'material' (a material id), 'edges' ({ face => band mm }, replaces the automatic banding entirely).
  module Overrides
    SIZE_FIELDS = %w[length width thickness].freeze
    OFFSET_FIELDS = %w[offset_x offset_y offset_z].freeze
    FIELDS = (SIZE_FIELDS + OFFSET_FIELDS + %w[material edges]).freeze
    LIMITS = { 'length' => [1.0, 5000.0], 'width' => [1.0, 5000.0], 'thickness' => [1.0, 100.0],
               'offset_x' => [-2000.0, 2000.0], 'offset_y' => [-2000.0, 2000.0], 'offset_z' => [-2000.0, 2000.0] }.freeze
    STATUS_AUTO = 'AUTO'
    STATUS_MANUAL = 'MANUAL OVERRIDE'

    module_function

    def blank?(v)
      v.nil? || v.to_s.strip.empty?
    end

    # Validates raw fields for one part and merges them into `existing`. A blank value removes that override.
    # Returns the new { field => value } (possibly empty). Raises ArgumentError with a readable message.
    def clean_part(auto_panel, raw, existing = {})
      out = existing.dup
      FIELDS.each do |f|
        next unless raw.key?(f)

        v = raw[f]
        if f == 'edges'
          if v.nil? || (v.respond_to?(:empty?) && v.empty? && !v.is_a?(Hash)) || v == ''
            out.delete(f)
          else
            out[f] = clean_edges(auto_panel, v)
          end
        elsif blank?(v)
          out.delete(f)
        elsif f == 'material'
          raise ArgumentError, "Unknown material '#{v}'" unless Material.exist?(v.to_s)

          out[f] = v.to_s
        else
          lo, hi = LIMITS.fetch(f)
          n = begin
            Float(v)
          rescue ArgumentError, TypeError
            raise ArgumentError, "#{label(f)} must be a number"
          end
          raise ArgumentError, "#{label(f)} must be between #{lo} and #{hi} mm" unless n.finite? && n.between?(lo, hi)

          out[f] = n.round(3)
        end
      end
      out
    end

    def label(field)
      field.tr('_', ' ').capitalize
    end

    # { face => mm }: faces must be edges of this part (not on its thickness axis); thickness 0 = no banding there.
    def clean_edges(panel, raw)
      raise ArgumentError, 'Edges must be a set of face => thickness' unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(face, mm), acc|
        face = face.to_sym
        raise ArgumentError, "'#{face}' is not a face" unless Panel::FACES.key?(face)
        raise ArgumentError, "#{panel.name} has no edge on its #{face} face" if Panel::FACES[face][0] == panel.thickness_axis

        v = begin
          Float(mm)
        rescue ArgumentError, TypeError
          raise ArgumentError, "Edge band on #{face} must be a number"
        end
        raise ArgumentError, 'Edge band must be between 0 and 5 mm' unless v.between?(0, 5)

        acc[face.to_s] = v if v.positive?
      end
    end

    # panels: automatically generated panels. Returns panels with overrides applied (unknown keys are ignored).
    def apply(panels, overrides)
      return panels if overrides.nil? || overrides.empty?

      panels.map { |p| (ov = overrides[p.key]) && !ov.empty? ? apply_one(p, ov) : p }
    end

    def apply_one(panel, ov)
      size = panel.size.dup
      origin = panel.origin.dup
      la, wa = panel.plane_axes
      ax = Panel::AXES
      size[ax.index(la)] = ov['length'] if ov['length']
      size[ax.index(wa)] = ov['width'] if ov['width']
      size[ax.index(panel.thickness_axis)] = ov['thickness'] if ov['thickness']
      origin[0] += ov['offset_x'].to_f
      origin[1] += ov['offset_y'].to_f
      origin[2] += ov['offset_z'].to_f
      mat = ov['material'] && Material.find(ov['material'])
      edges = ov['edges'] ? ov['edges'].transform_keys(&:to_sym) : nil
      panel.with(size: size, origin: origin, material: mat, edges: edges, overridden: ov.keys.sort)
    end

    # Parts whose overridden SIZE would change if the automatic value changed: [{ 'part_key', 'name', 'field',
    # 'override', 'auto_old', 'auto_new', 'orphaned' }]. Position, material and edge overrides are relative or
    # absolute choices that stay meaningful, so they are never "affected".
    def affected(old_auto, new_auto, overrides)
      old = old_auto.to_h { |p| [p.key, p] }
      new = new_auto.to_h { |p| [p.key, p] }
      overrides.flat_map do |key, ov|
        next [] unless old[key]

        if new[key].nil?
          next [{ 'part_key' => key, 'name' => old[key].name, 'field' => nil, 'orphaned' => true }]
        end

        SIZE_FIELDS.filter_map do |f|
          next unless ov.key?(f)

          a = auto_value(old[key], f)
          b = auto_value(new[key], f)
          next if (a - b).abs < 0.001

          { 'part_key' => key, 'name' => old[key].name, 'field' => f, 'override' => ov[f], 'auto_old' => a.round(3), 'auto_new' => b.round(3), 'orphaned' => false }
        end
      end
    end

    def auto_value(panel, field)
      case field
      when 'length' then panel.length
      when 'width' then panel.width
      when 'thickness' then panel.thickness
      end
    end

    # Drops the given affected fields (and parts left empty) from an overrides hash.
    def reset_affected(overrides, affected)
      out = overrides.transform_values(&:dup)
      affected.each do |a|
        if a['orphaned']
          out.delete(a['part_key'])
        else
          out[a['part_key']]&.delete(a['field'])
        end
      end
      out.reject { |_, v| v.empty? }
    end

    # JSON-safe overrides from stored data; anything malformed is dropped.
    def sanitize(raw)
      return {} unless raw.is_a?(Hash)

      raw.each_with_object({}) do |(key, ov), acc|
        next unless key.is_a?(String) && ov.is_a?(Hash)

        clean = ov.select { |f, _| FIELDS.include?(f) }
        clean = clean.reject { |f, v| (SIZE_FIELDS + OFFSET_FIELDS).include?(f) && !v.is_a?(Numeric) }
        clean = clean.reject { |f, v| f == 'material' && !v.is_a?(String) }
        clean = clean.reject { |f, v| f == 'edges' && !v.is_a?(Hash) }
        acc[key] = clean unless clean.empty?
      end
    end
  end
end
