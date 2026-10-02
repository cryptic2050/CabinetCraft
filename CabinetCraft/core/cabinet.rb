# frozen_string_literal: true

require 'json'
require 'time'
require 'securerandom'
require_relative 'parameter'
require_relative 'rules'
require_relative 'material'
require_relative 'hardware_rules'
require_relative 'overrides'
require_relative 'library'
require_relative '../generators/panel_generator'

module CabinetCraft
  # A parametric cabinet: identity + validated parameters. Everything else
  # (dimensions, panels, geometry) is derived from it.
  class Cabinet
    SCHEMA_VERSION = 1

    attr_reader :id, :label, :type, :params, :created_at, :modified_at, :version, :overrides

    def self.build(type:, params:, label:)
      now = Time.now.utc.iso8601
      new(id: SecureRandom.uuid, label: label, type: type, params: params,
          created_at: now, modified_at: now, version: 1)
    end

    def initialize(id:, label:, type:, params:, created_at:, modified_at:, version:, overrides: {})
      @overrides = overrides.freeze # { part_key => { field => value } }, see Overrides
      @id = id
      @label = label
      @type = type
      @params = params.freeze
      @created_at = created_at
      @modified_at = modified_at
      @version = version
    end

    # True for cabinets generated from a user template (see Templates), false for the built-in generator.
    def custom?
      Templates.template_type?(type)
    end

    def template
      Templates.find(type)
    end

    def template_build
      @template_build ||= template&.build(params)
    end

    def calculation
      @calculation ||= if custom?
                         template_build ? template_build.result : missing_template_result
                       else
                         Rules.compute(params)
                       end
    end

    def missing_template_result
      Rules::Result.new({}, [Rules::Issue.new(:error, nil, "The template '#{type}' is not available on this machine")])
    end

    # Automatically calculated panels (no manual overrides).
    def auto_panels
      @auto_panels ||= if !calculation.ok? then []
                       elsif custom? then template_build.panels
                       else Generators::PanelGenerator.generate(params, calculation.values)
                       end
    end

    # The production panels: automatic ones with manual overrides applied. Everything downstream uses these.
    def panels
      @panels ||= Overrides.apply(auto_panels, overrides)
    end

    # Overrides whose part no longer exists (e.g. a door that was removed).
    def orphan_overrides
      keys = auto_panels.map(&:key)
      overrides.keys - keys
    end

    # Panel keys the cabinet must have; used by validation to spot missing parts.
    def expected_keys
      return auto_panels.map(&:key) if custom?

      v = calculation.values
      %w[bottom side_left side_right back] + v['door_widths'].each_index.map { |i| "door_#{i + 1}" } +
        v['drawer_fronts'].each_index.map { |i| "drawer_#{i + 1}_front" }
    end

    def part_id(panel)
      "#{label}-#{panel.key.upcase}"
    end

    # Hardware derived on demand from parameters + the current hardware config.
    # Not memoised: changing a hinge rule must show up immediately.
    def hardware
      return [] unless calculation.ok?
      return template_build.hardware if custom?

      items, = HardwareRules.compute(params, calculation.values, panels)
      items
    end

    def hardware_issues
      return [] unless calculation.ok? && !custom? # a template's hardware warnings are part of its calculation issues

      _, issues = HardwareRules.compute(params, calculation.values, panels)
      issues
    end

    def part_rows
      hw = hardware.group_by { |h| h['part_key'] }
      panels.map do |p|
        text = (hw[p.key] || []).map { |h| "#{h['qty']} x #{h['name']}" }.join('; ')
        p.to_h(part_id: part_id(p), cabinet_id: id).merge(
          'cabinet_id' => id, 'cabinet_label' => label, 'hardware' => text.empty? ? '-' : text
        )
      end
    end

    # One row per hardware item, tagged with the cabinet and part it belongs to.
    def hardware_rows
      hardware.map { |h| h.merge('cabinet_id' => id, 'cabinet_label' => label) }
    end

    # Same identity, new parameters (overrides are kept unless replaced), bumped version.
    def with_params(new_params, overrides: nil)
      self.class.new(id: id, label: label, type: type, params: new_params, created_at: created_at,
                     modified_at: Time.now.utc.iso8601, version: version + 1, overrides: overrides || self.overrides)
    end

    def with_overrides(new_overrides)
      self.class.new(id: id, label: label, type: type, params: params, created_at: created_at,
                     modified_at: Time.now.utc.iso8601, version: version + 1, overrides: new_overrides)
    end

    def with_identity(id:, label:)
      self.class.new(id: id, label: label, type: type, params: params, created_at: created_at,
                     modified_at: modified_at, version: version, overrides: overrides)
    end

    # Flat attribute set stored in the SketchUp attribute dictionary. `params_json`
    # is the authoritative copy; the flat fields exist for queries and other tools.
    def to_attributes
      attrs = {
        'schema_version' => SCHEMA_VERSION,
        'cabinet_id' => id,
        'cabinet_label' => label,
        'cabinet_type' => type,
        'width' => params['width'],
        'height' => params['height'],
        'depth' => params['depth'],
        'material' => params['material'],
        'material_thickness' => calculation.values['thickness'], # nil while a material is missing
        'back_thickness' => params['back_thickness'],
        'construction_type' => params['construction'],
        'shelf_count' => params['shelf_count'],
        'door_count' => params['door_count'],
        'edge_banding' => custom? ? nil : "carcass=#{params['edge_carcass']};front=#{params['edge_front']}",
        'hardware' => custom? ? hardware.map { |h| h['hardware_id'] }.uniq.join(',') : [params['hinge_type'], params['runner_type'], params['connector_type'], params['handle_type'], params['foot_type']].join(','),
        'created_date' => created_at,
        'modified_date' => modified_at,
        'version' => version,
        'overrides_json' => JSON.generate(overrides),
        'params_json' => JSON.generate(params)
      }
      attrs.reject { |_, v| v.nil? } # custom templates need not have width / height / depth / materials
    end

    # Returns nil when the attributes are missing or unusable.
    def self.from_attributes(attrs)
      return nil unless attrs['cabinet_id'] && attrs['params_json']

      raw = JSON.parse(attrs['params_json'])
      type = attrs['cabinet_type'].to_s
      if Templates.template_type?(type) && Library.schema_for(type).nil?
        params = raw # template not available here (yet): keep the data, the cabinet reports the problem
      else
        params, errors = Parameter.coerce(raw, Library.schema_for(type))
        return nil unless errors.empty?
      end

      new(id: attrs['cabinet_id'], label: attrs['cabinet_label'].to_s, type: attrs['cabinet_type'].to_s,
          params: params, created_at: attrs['created_date'].to_s, modified_at: attrs['modified_date'].to_s,
          version: attrs['version'].to_i, overrides: Overrides.sanitize(attrs['overrides_json'] ? JSON.parse(attrs['overrides_json']) : {}))
    rescue JSON::ParserError, KeyError
      nil
    end

    def summary
      { 'id' => id, 'label' => label, 'type' => type, 'params' => params, 'overrides' => overrides,
        'version' => version, 'modified_at' => modified_at }
    end
  end
end
