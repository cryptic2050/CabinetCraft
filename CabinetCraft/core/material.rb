# frozen_string_literal: true

module CabinetCraft
  # A sheet material. Built-in materials ship with the plugin (name and thickness are fixed; price, supplier, sheet
  # size, grain, colour, texture, waste and edge-band options can be overridden). Custom materials are fully editable.
  # Both are managed by MaterialConfig, which persists per user and is mirrored inside the model (see ProjectStore).
  class Material
    GRAINS = %w[length width none].freeze # direction of the sheet's grain relative to the sheet: along its length / width / none
    DEFAULT_EDGE_OPTIONS = [0.4, 1.0, 2.0].freeze
    DEFAULT_WASTE_PCT = 10.0

    attr_reader :id, :name, :thickness, :sheet_length, :sheet_width, :grain, :color, :role, :price, :supplier,
                :waste_allowance, :texture, :edge_options, :custom

    def initialize(id:, name:, thickness:, color:, role:, grain: :length, sheet_length: 2440, sheet_width: 1220,
                   price: nil, supplier: nil, waste_allowance: nil, texture: nil, edge_options: DEFAULT_EDGE_OPTIONS, custom: false)
      @id = id
      @name = name
      @thickness = thickness.to_f
      @color = color
      @role = role.to_sym # :carcass (carcass, fronts, drawer boxes) or :back
      @grain = grain.to_sym
      @sheet_length = sheet_length.to_f
      @sheet_width = sheet_width.to_f
      @price = price
      @supplier = supplier
      @waste_allowance = waste_allowance
      @texture = texture
      @edge_options = edge_options.map(&:to_f)
      @custom = custom
    end

    def waste_pct
      waste_allowance || DEFAULT_WASTE_PCT
    end

    # Copy with some attributes replaced (symbol keys).
    def with(attrs)
      self.class.new(**to_args.merge(attrs))
    end

    def to_args
      { id: id, name: name, thickness: thickness, color: color, role: role, grain: grain, sheet_length: sheet_length,
        sheet_width: sheet_width, price: price, supplier: supplier, waste_allowance: waste_allowance, texture: texture,
        edge_options: edge_options, custom: custom }
    end

    def to_h
      { 'id' => id, 'name' => name, 'thickness' => thickness, 'sheet_length' => sheet_length, 'sheet_width' => sheet_width,
        'grain' => grain.to_s, 'color' => color, 'role' => role.to_s, 'price' => price, 'supplier' => supplier,
        'waste_allowance' => waste_allowance, 'texture' => texture, 'edge_options' => edge_options, 'custom' => custom }
    end

    BUILT_IN = [
      new(id: 'mdf_18', name: '18mm MDF',     thickness: 18, color: '#d9c7a5', role: :carcass, grain: :none),
      new(id: 'ply_18', name: '18mm Plywood', thickness: 18, color: '#d8b57a', role: :carcass),
      new(id: 'mdf_16', name: '16mm MDF',     thickness: 16, color: '#d9c7a5', role: :carcass, grain: :none),
      new(id: 'ply_15', name: '15mm Plywood', thickness: 15, color: '#d8b57a', role: :carcass),
      new(id: 'ply_12', name: '12mm Plywood', thickness: 12, color: '#d8b57a', role: :carcass),
      new(id: 'mdf_9',  name: '9mm MDF',      thickness: 9,  color: '#d9c7a5', role: :back, grain: :none),
      new(id: 'mdf_6',  name: '6mm MDF',      thickness: 6,  color: '#d9c7a5', role: :back, grain: :none),
      new(id: 'hdf_3',  name: '3mm HDF',      thickness: 3,  color: '#8a6a4a', role: :back, grain: :none)
    ].freeze

    BUILT_IN_BY_ID = BUILT_IN.to_h { |m| [m.id, m] }.freeze

    class << self
      attr_writer :config

      def config
        @config ||= MaterialConfig.new
      end

      # Built-ins (with the user's overrides applied) followed by custom materials.
      def all
        BUILT_IN.map { |m| config.apply_override(m) } + config.custom_materials
      end

      def carcass
        all.select { |m| m.role == :carcass }
      end

      def back_materials
        all.select { |m| m.role == :back }
      end

      def find(id)
        all.find { |m| m.id == id }
      end

      def fetch(id)
        find(id) or raise KeyError, "Unknown material '#{id}'"
      end

      def exist?(id)
        !find(id).nil?
      end

      # The back material for a cabinet: the chosen one, or (auto) the library back material of that thickness.
      def back_for(params, thickness)
        id = params['back_material']
        return find(id) if id && id != 'auto' && find(id)

        back_or_custom(thickness)
      end

      # Library back material of this thickness (custom ones win), or a synthesised placeholder.
      def back_or_custom(thickness)
        back_materials.sort_by { |m| m.custom ? 0 : 1 }.find { |x| (x.thickness - thickness).abs < 1e-6 } ||
          new(id: "custom_back_#{thickness.round(2)}", name: "#{thickness.round(2)}mm back panel",
              thickness: thickness, color: '#8a6a4a', role: :back, grain: :none)
      end

      # Material label for a back panel of the given thickness.
      def back_label(thickness)
        back_or_custom(thickness).name
      end
    end
  end
end

require_relative 'material_config'
