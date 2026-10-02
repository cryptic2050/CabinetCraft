# frozen_string_literal: true

require_relative 'cutting_list'
require_relative '../core/hardware'

module CabinetCraft
  module Manufacturing
    # Cost estimate for a project. Inputs: cabinets, the nesting result (real sheet counts), machining operations and the
    # user's cost settings. Output: a breakdown plus a per-cabinet allocation that adds up EXACTLY to the totals.
    #
    # selling price = total cost / (1 - margin): the margin is a share of the SELLING price (25% margin on a price of 100
    # leaves 25 profit and 75 cost). Everything is an estimate: unpriced items are listed as warnings, never silently free.
    module Costing
      DEFAULTS = {
        'enabled' => true, 'currency' => '$', 'material_basis' => 'nesting', 'waste_pct' => 10.0,
        'edge_prices' => { 'default' => 0.0 }, 'edge_waste_pct' => 5.0, 'cnc_per_sheet' => 0.0, 'cnc_per_hole' => 0.0,
        'labour_rate' => 0.0, 'labour_hours_per_cabinet' => 0.0, 'labour_minutes_per_part' => 0.0,
        'transport' => 0.0, 'installation_per_cabinet' => 0.0, 'margin_pct' => 25.0
      }.freeze
      MONEY_KEYS = %w[cnc_per_sheet cnc_per_hole labour_rate transport installation_per_cabinet].freeze

      module_function

      # Validates and fills in defaults. Raises ArgumentError.
      def normalize(raw)
        raw = (raw || {}).transform_keys(&:to_s)
        out = {}
        out['enabled'] = raw.key?('enabled') ? raw['enabled'] == true || raw['enabled'] == 'true' : DEFAULTS['enabled']
        cur = (raw['currency'] || DEFAULTS['currency']).to_s.strip
        raise ArgumentError, 'Currency symbol must be 1-4 characters' unless cur.size.between?(1, 4)

        out['currency'] = cur
        basis = raw['material_basis'] || DEFAULTS['material_basis']
        raise ArgumentError, "Material cost basis must be 'nesting' or 'area'" unless %w[nesting area].include?(basis)

        out['material_basis'] = basis
        out['waste_pct'] = num(raw, 'waste_pct', 0, 100, 'Waste percentage')
        out['edge_waste_pct'] = num(raw, 'edge_waste_pct', 0, 100, 'Edge banding waste')
        out['margin_pct'] = num(raw, 'margin_pct', 0, 95, 'Profit margin')
        out['labour_hours_per_cabinet'] = num(raw, 'labour_hours_per_cabinet', 0, 1000, 'Labour hours per cabinet')
        out['labour_minutes_per_part'] = num(raw, 'labour_minutes_per_part', 0, 10_000, 'Labour minutes per part')
        MONEY_KEYS.each { |k| out[k] = num(raw, k, 0, 10_000_000, k.tr('_', ' ').capitalize) }
        edge = raw['edge_prices'] || DEFAULTS['edge_prices']
        raise ArgumentError, 'Edge banding prices must be a list of thickness => price per metre' unless edge.is_a?(Hash)

        out['edge_prices'] = edge.to_h do |k, v|
          key = k.to_s == 'default' ? 'default' : format('%.1f', Float(k))
          price = Float(v)
          raise ArgumentError, 'Edge banding prices cannot be negative' if price.negative?

          [key, price]
        end
        out['edge_prices']['default'] ||= 0.0
        out
      rescue TypeError, ArgumentError => e
        raise ArgumentError, e.message.start_with?('Edge') || e.message.include?('must') ? e.message : 'Cost settings must be numbers'
      end

      def num(raw, key, lo, hi, label)
        v = raw.key?(key) ? Float(raw[key]) : DEFAULTS[key].to_f
        raise ArgumentError, "#{label} must be between #{lo} and #{hi}" unless v.between?(lo, hi)

        v
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{label} must be a number between #{lo} and #{hi}"
      end

      def r2(v)
        v.round(2)
      end

      # cabinets: [Cabinet]; nest: Controller#nest result; ops: Machining operations (all cabinets); settings: normalized.
      def estimate(cabinets, nest, ops, settings)
        return { 'enabled' => false } unless settings['enabled']

        warnings = []
        rows = cabinets.flat_map(&:part_rows)
        mats = material_costs(cabinets, rows, nest, settings, warnings)
        edges = edge_costs(cabinets, settings, warnings)
        hw = hardware_costs(cabinets, warnings)
        cnc = cnc_costs(cabinets, rows, nest, ops, settings)
        labour = labour_costs(cabinets, settings)
        manufacturing = r2(mats[:total] + edges[:total] + hw[:total] + cnc[:total] + labour[:total])
        transport = r2(settings['transport'])
        installation = r2(settings['installation_per_cabinet'] * cabinets.size)
        total = r2(manufacturing + transport + installation)
        selling = total / (1 - settings['margin_pct'] / 100.0)
        per_cabinet = allocate(cabinets, rows, mats, edges, hw, cnc, labour, settings, selling)
        {
          'enabled' => true, 'currency' => settings['currency'], 'material_basis' => settings['material_basis'],
          'materials' => mats[:lines], 'materials_total' => r2(mats[:total]),
          'edge_banding' => edges[:lines], 'edge_total' => r2(edges[:total]),
          'hardware' => hw[:lines], 'hardware_total' => r2(hw[:total]),
          'cnc' => cnc[:detail].merge('cost' => r2(cnc[:total])), 'labour' => labour[:detail].merge('cost' => r2(labour[:total])),
          'manufacturing_cost' => manufacturing, 'transport' => transport, 'installation' => installation,
          'total_cost' => total, 'margin_pct' => settings['margin_pct'], 'selling_price' => r2(selling), 'profit' => r2(selling - total),
          'per_cabinet' => per_cabinet, 'warnings' => warnings.uniq
        }
      end

      def material_costs(cabinets, rows, nest, settings, warnings)
        list = CuttingList.build(cabinets, waste_pct: settings['waste_pct'])['materials'].to_h { |m| [m['material'], m] }
        nested = (nest && nest['materials'] || []).to_h { |m| [m['material'], m] }
        lines = list.map do |name, m|
          mat = Material.find(rows.find { |r| r['material'] == name }['material_id'])
          price = mat&.price
          warnings << "No price set for #{name} (set it in MATERIALS): its cost counts as 0" if price.nil?
          sheets = settings['material_basis'] == 'nesting' && nested[name] ? nested[name]['total_sheets'] : m['estimated_sheets']
          basis = settings['material_basis'] == 'nesting' && nested[name] ? 'nested sheets' : "area + #{settings['waste_pct']}% waste"
          { 'material' => name, 'sheets' => sheets, 'sheet_price' => price, 'cost' => r2(sheets * price.to_f), 'basis' => basis, 'area_m2' => m['area_m2'] }
        end
        { lines: lines, total: lines.sum { |l| l['cost'] }, by_name: lines.to_h { |l| [l['material'], l['cost']] } }
      end

      def edge_costs(cabinets, settings, warnings)
        per = cabinets.to_h { |c| [c.id, Hash.new(0.0)] }
        cabinets.each do |c|
          c.panels.each { |p| p.edge_lengths.each { |mm, len| per[c.id][format('%.1f', mm)] += len / 1000.0 } }
        end
        totals = Hash.new(0.0)
        per.each_value { |h| h.each { |k, m| totals[k] += m } }
        factor = 1 + settings['edge_waste_pct'] / 100.0
        lines = totals.sort.map do |k, metres|
          price = settings['edge_prices'].key?(k) ? settings['edge_prices'][k] : settings['edge_prices']['default']
          warnings << "No edge banding price for #{k} mm (set a price or a default): its cost counts as 0" if price.to_f.zero? && !settings['edge_prices'].key?(k)
          { 'thickness' => k.to_f, 'metres' => r2(metres), 'metres_with_waste' => r2(metres * factor), 'price_per_m' => price, 'cost' => r2(metres * factor * price) }
        end
        { lines: lines, total: lines.sum { |l| l['cost'] }, per_cabinet: per, factor: factor, settings: settings }
      end

      def hardware_costs(cabinets, warnings)
        by_item = Hash.new { |h, k| h[k] = { 'qty' => 0, 'name' => nil } }
        cabinets.each do |c|
          c.hardware_rows.each do |h|
            by_item[h['hardware_id']]['qty'] += h['qty']
            by_item[h['hardware_id']]['name'] = h['name']
          end
        end
        lines = by_item.map do |id, v|
          price = Hardware.price_of(id)
          warnings << "No price set for hardware '#{v['name']}' (set it in HARDWARE): its cost counts as 0" if price.nil?
          { 'hardware_id' => id, 'name' => v['name'], 'qty' => v['qty'], 'unit_price' => price, 'cost' => r2(v['qty'] * price.to_f) }
        end.sort_by { |l| l['name'].to_s }
        { lines: lines, total: lines.sum { |l| l['cost'] } }
      end

      def cnc_costs(cabinets, rows, nest, ops, settings)
        sheets = (nest && nest['materials'] || []).sum { |m| m['sheets'].count { |s| !s['placements'].empty? } }
        holes = ops.count { |o| o['target'] == 'face' }
        sheet_cost = sheets * settings['cnc_per_sheet']
        hole_cost = holes * settings['cnc_per_hole']
        { total: r2(sheet_cost + hole_cost), detail: { 'sheets' => sheets, 'holes' => holes, 'per_sheet' => settings['cnc_per_sheet'], 'per_hole' => settings['cnc_per_hole'] },
          sheet_cost: sheet_cost, hole_cost: hole_cost, holes_by_cabinet: ops.select { |o| o['target'] == 'face' }.group_by { |o| o['cabinet_id'] }.transform_values(&:size) }
      end

      def labour_costs(cabinets, settings)
        parts = cabinets.sum { |c| c.part_rows.size }
        hours = cabinets.size * settings['labour_hours_per_cabinet'] + parts * settings['labour_minutes_per_part'] / 60.0
        { total: r2(hours * settings['labour_rate']), detail: { 'hours' => r2(hours), 'rate' => settings['labour_rate'] } }
      end

      # Splits every cost line across cabinets: materials and CNC sheets by part area, banding / hardware / holes / labour /
      # installation directly, transport by volume. Rounded to cents with the last cabinet absorbing rounding so sums are exact.
      def allocate(cabinets, rows, mats, edges, hw, cnc, labour, settings, selling)
        area = ->(c) { c.part_rows.sum { |r| r['length'] * r['width'] } }
        total_area = cabinets.sum(&area).to_f
        vol = ->(c) { c.params.values_at('width', 'height', 'depth').all? ? c.params['width'] * c.params['height'] * c.params['depth'] : area.call(c) }
        total_vol = cabinets.sum(&vol).to_f
        factor = edges[:factor]
        res = cabinets.map do |c|
          mat = c.part_rows.group_by { |r| r['material'] }.sum do |name, rs|
            tot = rows.select { |r| r['material'] == name }.sum { |r| r['length'] * r['width'] }
            tot.zero? ? 0.0 : mats[:by_name].fetch(name, 0.0) * rs.sum { |r| r['length'] * r['width'] } / tot
          end
          edge = edges[:per_cabinet][c.id].sum { |k, m| m * factor * (settings['edge_prices'].key?(k) ? settings['edge_prices'][k] : settings['edge_prices']['default']) }
          hardware = c.hardware_rows.sum { |h| h['qty'] * Hardware.price_of(h['hardware_id']).to_f }
          machine = (total_area.zero? ? 0.0 : cnc[:sheet_cost] * area.call(c) / total_area) + cnc[:holes_by_cabinet].fetch(c.id, 0) * settings['cnc_per_hole']
          lab = (settings['labour_hours_per_cabinet'] + c.part_rows.size * settings['labour_minutes_per_part'] / 60.0) * settings['labour_rate']
          inst = settings['installation_per_cabinet']
          trans = total_vol.zero? ? 0.0 : settings['transport'] * vol.call(c) / total_vol
          { cabinet: c, 'material' => mat, 'edge_banding' => edge, 'hardware' => hardware, 'cnc' => machine, 'labour' => lab, 'installation' => inst, 'transport' => trans }
        end
        keys = %w[material edge_banding hardware cnc labour installation transport]
        rounded = res.map { |h| h.merge(keys.to_h { |k| [k, r2(h[k])] }) }
        targets = { 'material' => mats[:total], 'edge_banding' => edges[:total], 'hardware' => hw[:total], 'cnc' => cnc[:total], 'labour' => labour[:total],
                    'installation' => r2(settings['installation_per_cabinet'] * cabinets.size), 'transport' => r2(settings['transport']) }
        keys.each do |k|
          delta = r2(targets[k]) - rounded.sum { |h| h[k] }
          rounded.last[k] = r2(rounded.last[k] + delta) if rounded.any? && delta.abs > 1e-9
        end
        costs = rounded.map { |h| r2(keys.sum { |k| h[k] }) }
        margin = 1 - settings['margin_pct'] / 100.0
        prices = costs.map { |cost| r2(cost / margin) }
        want = r2(selling)
        prices[-1] = r2(prices.last + want - prices.sum) if prices.any?
        rounded.each_with_index.map do |h, i|
          c = h[:cabinet]
          { 'cabinet_id' => c.id, 'label' => c.label, 'type' => c.type, 'width' => c.params['width'], 'height' => c.params['height'], 'depth' => c.params['depth'],
            'parts' => c.part_rows.size }.merge(keys.to_h { |k| [k, h[k]] }).merge('cost' => costs[i], 'price' => prices[i])
        end
      end
    end
  end
end
