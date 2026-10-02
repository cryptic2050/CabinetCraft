# frozen_string_literal: true

module CabinetCraft
  module Interface
    # The project dashboard. Mixed into Controller. Everything is derived on demand from the same sources as the other tabs.
    module OverviewCommands
      def dashboard_state
        cabs = project_cabinets
        with_nest_memo do
          nesting = cabs.empty? ? nil : nest
          issues = (cabs.empty? ? [] : Validation::Validator.run(cabs, nesting: nesting)) + Scene::ModelChecker.run(model)
          issues = issues.sort_by { |i| [i['severity'] == 'error' ? 0 : 1, i['cabinet_label'].to_s, i['code']] }
          Manufacturing::Dashboard.build(
            project: project_store.name, cabinets: cabs, type_names: Library.entries.to_h { |e| [e['type'], e['name']] }, nesting: nesting,
            cost: cabs.empty? ? { 'enabled' => false } : cost_estimate, issues: issues, cnc: cabs.empty? ? nil : cnc_check,
            runs: runs_state['runs'], layouts: layouts_state['layouts'], materials: Material.all
          ).merge('currency_note' => 'Costs are estimates from your own prices.')
        end
      end

      private

      # Runs the block with the nesting computed once, so the dashboard does not nest again for every section.
      def with_nest_memo
        @nest_memo = project_cabinets.empty? ? nil : nest
        yield
      ensure
        @nest_memo = nil
      end
    end
  end
end
