# frozen_string_literal: true

module CabinetCraft
  # A sheet material. Phase 1 ships a built-in library; user-defined materials,
  # prices and suppliers are editable in Phase 2 (fields exist, values are unset).
  class Material
    attr_reader :id, :name, :thickness, :sheet_length, :sheet_width,
                :grain, :color, :role, :price, :supplier, :waste_allowance

    # role: :carcass materials can be chosen for carcass panels,
    #       :back materials are used for back panels.
    def initialize(id:, name:, thickness:, color:, role:, grain: :length,
                   sheet_length: 2440, sheet_width: 1220,
                   price: nil, supplier: nil, waste_allowance: nil)
      @id = id
      @name = name
      @thickness = thickness.to_f
      @color = color
      @role = role
      @grain = grain
      @sheet_length = sheet_length
      @sheet_width = sheet_width
      @price = price
      @supplier = supplier
      @waste_allowance = waste_allowance
    end

    def to_h
      {
        'id' => id, 'name' => name, 'thickness' => thickness,
        'sheet_length' => sheet_length, 'sheet_width' => sheet_width,
        'grain' => grain.to_s, 'color' => color, 'role' => role.to_s,
        'price' => price, 'supplier' => supplier, 'waste_allowance' => waste_allowance
      }
    end

    LIBRARY = [
      new(id: 'mdf_18', name: '18mm MDF',     thickness: 18, color: '#d9c7a5', role: :carcass, grain: :none),
      new(id: 'ply_18', name: '18mm Plywood', thickness: 18, color: '#d8b57a', role: :carcass),
      new(id: 'mdf_16', name: '16mm MDF',     thickness: 16, color: '#d9c7a5', role: :carcass, grain: :none),
      new(id: 'ply_15', name: '15mm Plywood', thickness: 15, color: '#d8b57a', role: :carcass),
      new(id: 'ply_12', name: '12mm Plywood', thickness: 12, color: '#d8b57a', role: :carcass),
      new(id: 'mdf_9',  name: '9mm MDF',      thickness: 9,  color: '#d9c7a5', role: :back, grain: :none),
      new(id: 'mdf_6',  name: '6mm MDF',      thickness: 6,  color: '#d9c7a5', role: :back, grain: :none),
      new(id: 'hdf_3',  name: '3mm HDF',      thickness: 3,  color: '#8a6a4a', role: :back, grain: :none)
    ].freeze

    BY_ID = LIBRARY.to_h { |m| [m.id, m] }.freeze

    class << self
      def all
        LIBRARY
      end

      def carcass
        LIBRARY.select { |m| m.role == :carcass }
      end

      def fetch(id)
        BY_ID.fetch(id) { raise KeyError, "Unknown material '#{id}'" }
      end

      def exist?(id)
        BY_ID.key?(id)
      end

      # Library back material of this thickness, or a synthesised custom one.
      def back_or_custom(thickness)
        LIBRARY.find { |x| x.role == :back && (x.thickness - thickness).abs < 1e-6 } ||
          new(id: "custom_back_#{thickness.round(2)}", name: "#{thickness.round(2)}mm back panel",
              thickness: thickness, color: '#8a6a4a', role: :back, grain: :none)
      end

      # Material label for a back panel of the given thickness.
      def back_label(thickness)
        m = LIBRARY.find { |x| x.role == :back && (x.thickness - thickness).abs < 1e-6 }
        m ? m.name : "#{thickness.round(2)}mm back panel"
      end
    end
  end
end
