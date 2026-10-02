# frozen_string_literal: true

require_relative '../core/material'

module CabinetCraft
  module Manufacturing
    # Cutting list: identical parts grouped per material, with material,
    # edge-banding and hardware totals.
    #
    # Sheet counts here are an AREA-BASED ESTIMATE (area x waste allowance /
    # sheet area), not a nesting result. Real nesting arrives in Phase 4.
    module CuttingList
      DEFAULT_SHEET = [2440.0, 1220.0].freeze
      DEFAULT_WASTE_PCT = Material::DEFAULT_WASTE_PCT
      GRAIN_TEXT = { 'length' => 'along length', 'width' => 'along width', 'none' => 'none' }.freeze

      module_function

      # waste_pct: nil uses each material's own waste allowance (default 10%).
      # nested: a Nesting result (see Controller#nest). When given, each material's sheet count is the number of sheets the
      # nesting actually used; otherwise it is the area-based estimate.
      def build(cabinets, waste_pct: nil, nested: nil)
        rows = cabinets.flat_map(&:part_rows)
        {
          'materials' => materials(rows, waste_pct, nested),
          'edge_banding' => edge_banding(rows),
          'hardware' => hardware(cabinets),
          'cabinet_count' => cabinets.size,
          'part_count' => rows.size,
          'estimate_note' => if nested
                               'Sheet counts are the sheets used by the current nesting (a heuristic layout, not proven optimal); the nesting settings and any manual layout change them.'
                             else
                               "Sheet counts are an area-based estimate using each material's waste allowance#{waste_pct ? " (#{waste_pct}% override)" : ''}, not a nesting result."
                             end
        }
      end

      def sheet_for(material_id)
        m = Material.find(material_id)
        m ? [m.sheet_length.to_f, m.sheet_width.to_f] : DEFAULT_SHEET
      end

      def materials(rows, waste_pct, nested = nil)
        rows.group_by { |r| r['material'] }.sort_by { |name, _| name }.map do |name, mrows|
          mat = Material.find(mrows.first['material_id'])
          waste = waste_pct || (mat ? mat.waste_pct : DEFAULT_WASTE_PCT)
          sl, sw = sheet_for(mrows.first['material_id'])
          groups = mrows.group_by { |r| group_key(r) }.map { |_, g| group_row(g) }
                        .sort_by { |g| [-g['length'], -g['width'], g['name']] }
          area = mrows.sum { |r| r['length'] * r['width'] } / 1_000_000.0
          estimate = (area * (1 + waste / 100.0) / (sl * sw / 1_000_000.0)).ceil
          placed = nested && nested['materials'].find { |n| n['material'] == name }
          sheets = placed ? placed['total_sheets'] : estimate
          {
            'material' => name, 'thickness' => mrows.first['thickness'], 'sheet_length' => sl, 'sheet_width' => sw,
            'groups' => groups, 'part_count' => mrows.size, 'area_m2' => area.round(3), 'waste_pct' => waste,
            'estimated_sheets' => sheets, 'area_estimate_sheets' => estimate, 'sheet_basis' => placed ? 'nested' : 'area estimate',
            'price' => mat&.price, 'estimated_cost' => mat&.price ? (sheets * mat.price).round(2) : nil
          }
        end
      end

      # Parts are identical when material, size (to 0.1 mm), grain, edging and kind match.
      def group_key(r)
        [r['material'], r['generic_name'], r['length'].round(1), r['width'].round(1), r['thickness'].round(1),
         r['grain'], r['edge_codes']]
      end

      def group_row(g)
        r = g.first
        {
          'name' => r['generic_name'], 'length' => r['length'], 'width' => r['width'], 'thickness' => r['thickness'],
          'qty' => g.sum { |x| x['qty'] }, 'grain' => r['grain'], 'edge_text' => r['edge_text'],
          'cabinets' => g.map { |x| x['cabinet_label'] }.uniq.join(', ')
        }
      end

      # Banding metres per band thickness (finished-size lengths, no trim allowance).
      def edge_banding(rows)
        totals = Hash.new(0.0)
        rows.each do |r|
          lw = { 'L' => r['length'], 'W' => r['width'] }
          r['edge_codes'].each { |code, mm| totals[mm] += lw[code[0]] }
        end
        totals.sort.map { |mm, len| { 'thickness' => mm, 'length_m' => (len / 1000.0).round(3) } }
      end

      def hardware(cabinets)
        cabinets.flat_map(&:hardware_rows).group_by { |h| h['hardware_id'] }.map do |id, hs|
          { 'hardware_id' => id, 'name' => hs.first['name'], 'category' => hs.first['category'], 'qty' => hs.sum { |h| h['qty'] } }
        end.sort_by { |h| [h['category'], h['name']] }
      end

      # Flat rows for CSV: one per grouped part.
      def flat_rows(list)
        list['materials'].flat_map do |m|
          m['groups'].map do |g|
            { 'Material' => m['material'], 'Part' => g['name'], 'Length' => g['length'], 'Width' => g['width'],
              'Thickness' => g['thickness'], 'Qty' => g['qty'], 'Grain' => GRAIN_TEXT.fetch(g['grain'], g['grain']),
              'Edge banding' => g['edge_text'], 'Cabinets' => g['cabinets'] }
          end
        end
      end
    end
  end
end
