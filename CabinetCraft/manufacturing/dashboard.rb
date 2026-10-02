# frozen_string_literal: true

module CabinetCraft
  module Manufacturing
    # Project dashboard: one summary of everything already derived from the model (nesting, costs, checks, runs). Nothing here
    # is stored; it is recomputed on demand from the same sources as the individual tabs, so it can never disagree with them.
    module Dashboard
      # Cost categories shown in the part-to-whole bar (five, in this fixed order).
      COST_SEGMENTS = [
        ['materials', 'Materials', %w[materials_total]],
        ['edge', 'Edge banding', %w[edge_total]],
        ['hardware', 'Hardware', %w[hardware_total]],
        ['cnc', 'CNC', %w[cnc]],
        ['labour', 'Labour & site', %w[labour installation transport]] # labour, installation and transport
      ].freeze

      module_function

      # inputs: cabinets (Cabinet list), type_names { type => name }, nesting (Nesting result or nil), cost (Costing estimate or { 'enabled' => false }),
      # issues (Validator + ModelChecker issues), cnc (cnc_check result or nil), runs / layouts (summaries), materials (Material list)
      def build(project:, cabinets:, type_names:, nesting:, cost:, issues:, cnc:, runs:, layouts:, materials:)
        rows = cabinets.flat_map(&:part_rows)
        {
          'project' => project_block(project, cabinets, rows, type_names),
          'sheets' => sheets_block(nesting),
          'cost' => cost_block(cost),
          'hardware' => hardware_block(cabinets),
          'issues' => issues_block(issues),
          'layouts' => layouts_block(runs, layouts),
          'checks' => checks(cabinets, rows, nesting, cost, issues, cnc, runs, layouts, materials)
        }.tap { |d| d['ready'] = d['checks'].none? { |c| c['status'] == 'error' } && !cabinets.empty? }
      end

      def project_block(name, cabinets, rows, type_names)
        types = cabinets.group_by(&:type).map { |t, list| { 'name' => type_names[t] || t, 'count' => list.size } }.sort_by { |t| [-t['count'], t['name']] }
        { 'name' => name, 'cabinets' => cabinets.size, 'parts' => rows.size, 'types' => types,
          'overridden_parts' => rows.count { |r| r['status'] != 'AUTO' } }
      end

      def sheets_block(nesting)
        return { 'total' => 0, 'utilization' => 0.0, 'unplaced' => 0, 'materials' => [] } unless nesting

        t = nesting['totals']
        { 'total' => t['total_sheets'], 'utilization' => t['utilization'], 'unplaced' => t['unplaced'],
          'materials' => nesting['materials'].map { |m| { 'material' => m['material'], 'sheets' => m['total_sheets'], 'utilization' => m['utilization'], 'unplaced' => m['unplaced'].size } } }
      end

      def cost_block(cost)
        return { 'enabled' => false } unless cost && cost['enabled']

        segments = COST_SEGMENTS.map do |key, label, fields|
          value = fields.sum do |f|
            v = cost[f]
            v.is_a?(Hash) ? v['cost'].to_f : v.to_f
          end
          { 'key' => key, 'label' => label, 'value' => value.round(2) }
        end
        { 'enabled' => true, 'currency' => cost['currency'], 'total_cost' => cost['total_cost'], 'selling_price' => cost['selling_price'], 'profit' => cost['profit'],
          'segments' => segments, 'warnings' => cost['warnings'].size }
      end

      def hardware_block(cabinets)
        cabinets.flat_map(&:hardware).group_by { |h| h['name'] }.map { |n, l| { 'name' => n, 'qty' => l.sum { |h| h['qty'] } } }.sort_by { |h| [-h['qty'], h['name']] }.first(8)
      end

      def issues_block(issues)
        errors = issues.count { |i| i['severity'] == 'error' }
        { 'errors' => errors, 'warnings' => issues.size - errors, 'top' => issues.first(8) }
      end

      def layouts_block(runs, layouts)
        { 'runs' => runs.size, 'layouts' => layouts.size, 'out_of_sync' => runs.count { |r| !r['in_sync'] } + layouts.count { |l| !l['in_sync'] } }
      end

      def check(id, label, status, detail)
        { 'id' => id, 'label' => label, 'status' => status, 'detail' => detail }
      end

      # status: ok / warn / error / info / na. A project is "ready" when nothing is an error (and it has cabinets).
      def checks(cabinets, rows, nesting, cost, issues, cnc, runs, layouts, materials)
        return [check('empty', 'Project has cabinets', 'error', 'Create a cabinet to get started')] if cabinets.empty?

        errors = issues.count { |i| i['severity'] == 'error' }
        warnings = issues.size - errors
        out = []
        out << check('model', 'Model check', errors.positive? ? 'error' : warnings.positive? ? 'warn' : 'ok',
                     errors.positive? ? "#{errors} error#{'s' unless errors == 1}, #{warnings} warning#{'s' unless warnings == 1}" : warnings.positive? ? "#{warnings} warning#{'s' unless warnings == 1}" : 'No problems found')
        unplaced = nesting ? nesting['totals']['unplaced'] : 0
        out << check('nesting', 'All parts fit on sheets', unplaced.positive? ? 'error' : 'ok', unplaced.positive? ? "#{unplaced} part#{'s' unless unplaced == 1} do not fit on a sheet" : 'Every part is placed')
        out << cnc_check(cnc)
        out.concat(price_checks(rows, cost, materials))
        out << layout_check(runs, layouts)
        over = rows.count { |r| r['status'] != 'AUTO' }
        out << check('overrides', 'Manual overrides', over.positive? ? 'info' : 'ok', over.positive? ? "#{over} part#{'s' unless over == 1} manually overridden" : 'All parts follow the rules')
        out
      end

      def cnc_check(cnc)
        return check('cnc', 'Machining check', 'na', 'Not checked') unless cnc

        errs = cnc['errors']
        first = (cnc['issues'] || []).find { |i| i['severity'] == 'error' }
        check('cnc', 'Machining check', errs.positive? ? 'error' : cnc['warnings'].positive? ? 'warn' : 'ok',
              errs.positive? ? "#{errs} error#{'s' unless errs == 1} block CNC export: #{first ? first['message'] : 'see the CNC tab'}" : cnc['warnings'].positive? ? "#{cnc['warnings']} warning#{'s' unless cnc['warnings'] == 1}" : 'CNC export is possible')
      end

      def price_checks(rows, cost, materials)
        return [check('prices', 'Prices and costs', 'na', 'Cost calculation is switched off')] unless cost && cost['enabled']

        used = rows.map { |r| r['material_id'] }.uniq
        unpriced = materials.select { |m| used.include?(m.id) && m.price.nil? }.map(&:name)
        warns = cost['warnings'].size
        [check('prices', 'Prices set', unpriced.empty? && warns.zero? ? 'ok' : 'warn',
               unpriced.empty? && warns.zero? ? 'Every cost input has a price' : "#{warns} cost warning#{'s' unless warns == 1}#{unpriced.empty? ? '' : "; no price for #{unpriced.join(', ')}"}")]
      end

      def layout_check(runs, layouts)
        return check('layouts', 'Runs and corner layouts', 'na', 'None in this project') if runs.empty? && layouts.empty?

        bad = runs.count { |r| !r['in_sync'] } + layouts.count { |l| !l['in_sync'] }
        check('layouts', 'Runs and corner layouts', bad.positive? ? 'warn' : 'ok', bad.positive? ? "#{bad} out of sync (see RUNS / CORNERS)" : 'All in sync')
      end
    end
  end
end
