# frozen_string_literal: true

require 'json'
require 'time'
require 'securerandom'
require_relative 'parameter'
require_relative 'rules'
require_relative 'material'
require_relative 'hardware_rules'
require_relative '../generators/panel_generator'

module CabinetCraft
  # A parametric cabinet: identity + validated parameters. Everything else
  # (dimensions, panels, geometry) is derived from it.
  class Cabinet
    SCHEMA_VERSION = 1

    attr_reader :id, :label, :type, :params, :created_at, :modified_at, :version

    def self.build(type:, params:, label:)
      now = Time.now.utc.iso8601
      new(id: SecureRandom.uuid, label: label, type: type, params: params,
          created_at: now, modified_at: now, version: 1)
    end

    def initialize(id:, label:, type:, params:, created_at:, modified_at:, version:)
      @id = id
      @label = label
      @type = type
      @params = params.freeze
      @created_at = created_at
      @modified_at = modified_at
      @version = version
    end

    def calculation
      @calculation ||= Rules.compute(params)
    end

    def panels
      @panels ||= calculation.ok? ? Generators::PanelGenerator.generate(params, calculation.values) : []
    end

    def part_id(panel)
      "#{label}-#{panel.key.upcase}"
    end

    # Hardware derived on demand from parameters + the current hardware config.
    # Not memoised: changing a hinge rule must show up immediately.
    def hardware
      return [] unless calculation.ok?

      items, = HardwareRules.compute(params, calculation.values, panels)
      items
    end

    def hardware_issues
      return [] unless calculation.ok?

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

    # Same identity, new parameters, bumped version.
    def with_params(new_params)
      self.class.new(id: id, label: label, type: type, params: new_params,
                     created_at: created_at, modified_at: Time.now.utc.iso8601, version: version + 1)
    end

    def with_identity(id:, label:)
      self.class.new(id: id, label: label, type: type, params: params,
                     created_at: created_at, modified_at: modified_at, version: version)
    end

    # Flat attribute set stored in the SketchUp attribute dictionary. `params_json`
    # is the authoritative copy; the flat fields exist for queries and other tools.
    def to_attributes
      {
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
        'edge_banding' => "carcass=#{params['edge_carcass']};front=#{params['edge_front']}",
        'hardware' => [params['hinge_type'], params['runner_type'], params['connector_type'], params['handle_type'], params['foot_type']].join(','),
        'created_date' => created_at,
        'modified_date' => modified_at,
        'version' => version,
        'params_json' => JSON.generate(params)
      }
    end

    # Returns nil when the attributes are missing or unusable.
    def self.from_attributes(attrs)
      return nil unless attrs['cabinet_id'] && attrs['params_json']

      params, errors = Parameter.coerce(JSON.parse(attrs['params_json']))
      return nil unless errors.empty?

      new(id: attrs['cabinet_id'], label: attrs['cabinet_label'].to_s, type: attrs['cabinet_type'].to_s,
          params: params, created_at: attrs['created_date'].to_s, modified_at: attrs['modified_date'].to_s,
          version: attrs['version'].to_i)
    rescue JSON::ParserError, KeyError
      nil
    end

    def summary
      { 'id' => id, 'label' => label, 'type' => type, 'params' => params,
        'version' => version, 'modified_at' => modified_at }
    end
  end
end
