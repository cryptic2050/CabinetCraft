# frozen_string_literal: true

require_relative '../utilities/qr_code'

module CabinetCraft
  module Manufacturing
    # Production labels. The QR code carries a short, stable part identifier
    # ("CC1|<cabinet uuid>|<part key>"), never a dimension, so a label stays
    # valid when the design changes; the plugin resolves it against the live model.
    module Labels
      PREFIX = 'CC1'
      CODE_PATTERN = /\A#{PREFIX}\|([0-9a-fA-F-]{36})\|([a-z0-9_]+)\z/.freeze
      GRAIN_TEXT = { 'length' => 'along length', 'width' => 'along width', 'none' => 'none' }.freeze

      module_function

      def payload(cabinet_id, part_key)
        "#{PREFIX}|#{cabinet_id}|#{part_key}"
      end

      # => [cabinet_id, part_key] or nil
      def parse(code)
        m = CODE_PATTERN.match(code.to_s.strip)
        m && [m[1], m[2]]
      end

      def build(cabinets, project_name:, qr: true)
        cabinets.flat_map do |cab|
          cab.part_rows.map do |r|
            code = payload(cab.id, r['key'])
            {
              'project' => project_name, 'cabinet' => cab.label, 'part' => r['name'], 'part_id' => r['part_id'],
              'dimensions' => "#{fmt(r['length'])} x #{fmt(r['width'])} x #{fmt(r['thickness'])}", 'material' => r['material'],
              'qty' => r['qty'], 'grain' => GRAIN_TEXT.fetch(r['grain'], r['grain']), 'edge_banding' => r['edge_text'],
              'position' => r['position'], 'override' => r['status'] == 'AUTO' ? '' : r['status'], 'qr_payload' => code, 'qr_svg' => qr ? QrCode.svg(code, quiet: 1) : nil
            }
          end
        end
      end

      def fmt(v)
        v == v.round ? v.round.to_s : v.round(1).to_s
      end

      COLUMNS = [
        %w[project Project], %w[cabinet Cabinet], %w[part Part], %w[part_id Part\ ID], %w[dimensions Dimensions],
        %w[material Material], %w[qty Qty], %w[grain Grain], %w[edge_banding Edge\ banding], %w[position Assembly\ position],
        %w[qr_payload QR\ code]
      ].freeze
    end
  end
end
