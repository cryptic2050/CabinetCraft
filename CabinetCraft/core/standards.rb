# frozen_string_literal: true

require 'json'
require_relative 'parameter'
require_relative 'rules'
require_relative 'hardware'

module CabinetCraft
  # Company manufacturing standards: default values that every NEW cabinet starts with.
  #
  # Only manufacturing choices can be standardised (materials, thicknesses, reveals, edge banding, construction,
  # hardware types, toe kick). Design choices (size, door / drawer / shelf counts) are never part of a standard, so a
  # standard can never turn a drawer preset into a door cabinet. Precedence for a new cabinet:
  #   schema defaults  <  company standards  <  the cabinet type's own explicit defaults (e.g. a saved preset)
  # Existing cabinets are never changed by editing the standards.
  class Standards
    ALLOWED = %w[material back_material back_thickness front_material drawer_box_material construction brace_depth toe_kick_height
                 toe_kick_depth door_reveal door_gap runner_clearance edge_carcass edge_front hinge_type hinge_side handle_type runner_type
                 connector_type foot_type].freeze

    attr_reader :name, :values

    def initialize(store = Hardware::MemoryStore.new)
      @store = store
      @name = ''
      @values = {}
      load
    end

    # Schema fields a standard may set (same format as Parameter.schema, so the UI form is generated from it).
    def self.fields
      Parameter.schema.select { |f| ALLOWED.include?(f['key']) }
    end

    # raw: { key => value }. Only the given keys become standards. Raises ArgumentError listing every problem.
    def save(name:, values:)
      name = name.to_s.strip
      raise ArgumentError, 'Company name can be at most 60 characters' if name.size > 60

      raw = (values || {}).transform_keys(&:to_s)
      unknown = raw.keys - ALLOWED
      raise ArgumentError, "Not a manufacturing standard: #{unknown.join(', ')}" unless unknown.empty?

      params, errors = Parameter.coerce(Parameter.defaults.merge(raw))
      bad = errors.select { |e| raw.key?(e['key']) }
      raise ArgumentError, bad.map { |e| e['message'] }.join('; ') unless bad.empty?

      clean = raw.keys.to_h { |k| [k, params[k]] }
      result = Rules.compute(params)
      raise ArgumentError, "These standards give an invalid default cabinet: #{result.errors.first(2).map(&:message).join('; ')}" unless result.ok?

      @name = name
      @values = clean
      save_store
      self
    end

    def reset
      @name = ''
      @values = {}
      save_store
    end

    # Applies the standards on top of schema defaults.
    def apply(defaults)
      defaults.merge(values)
    end

    class << self
      attr_writer :current

      def current
        @current ||= new
      end
    end

    private

    def save_store
      @store.write(JSON.generate('name' => @name, 'values' => @values))
    end

    def load
      raw = @store.read
      return if raw.nil? || raw.to_s.empty?

      d = JSON.parse(raw)
      @name = d['name'].to_s[0, 60]
      @values = (d['values'] || {}).select { |k, _| ALLOWED.include?(k) }
      _, errors = Parameter.coerce(Parameter.defaults.merge(@values))
      raise ArgumentError, 'invalid' unless errors.none? { |e| @values.key?(e['key']) }
    rescue StandardError
      @name = '' # damaged settings fall back to the factory defaults
      @values = {}
    end
  end
end
