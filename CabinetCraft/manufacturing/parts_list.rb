# frozen_string_literal: true

module CabinetCraft
  module Manufacturing
    # Project-wide parts list: one row per physical part, from every cabinet.
    # Rows are derived from cabinet parameters, so they can never drift from the model.
    module PartsList
      COLUMNS = [
        ['part_id', 'Part ID'], ['cabinet_label', 'Cabinet'], ['name', 'Part name'], ['length', 'Length'],
        ['width', 'Width'], ['thickness', 'Thickness'], ['qty', 'Qty'], ['material', 'Material'],
        ['grain', 'Grain'], ['edge_text', 'Edge banding'], ['hardware', 'Hardware']
      ].freeze

      module_function

      # cabinets: [Cabinet, ...]
      def build(cabinets)
        cabinets.flat_map(&:part_rows)
      end
    end
  end
end
