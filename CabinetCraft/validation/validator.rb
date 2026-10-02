# frozen_string_literal: true

require_relative 'collision_checker'
require_relative 'machining_checker'
require_relative '../manufacturing/machining'
require_relative '../core/material'
require_relative '../core/rules'
require_relative '../manufacturing/nesting'
require_relative '../core/hardware'
require_relative '../core/edge_banding'

module CabinetCraft
  module Validation
    # Pre-production validation of cabinets (and, optionally, a nesting result).
    # Pure: no SketchUp calls. Every issue names the cabinet (and part) it concerns
    # so the UI can select it in the model.
    #
    # NOT CHECKED (listed in NOT_CHECKED and shown to the user): machine-specific limits and tool-path simulation.
    module Validator
      LIMITS = { min_front_gap: 2.0, min_reveal: 1.0, min_runner_clearance: 10.0 }.freeze
      NOT_CHECKED = ['Machine travel limits, clamps / vacuum zones and tool-path simulation (not modelled)'].freeze

      module_function

      def issue(severity, code, message, cabinet: nil, part_key: nil)
        {
          'severity' => severity.to_s, 'code' => code, 'message' => message,
          'cabinet_id' => cabinet&.id, 'cabinet_label' => cabinet&.label,
          'part_key' => part_key, 'part_id' => cabinet && part_key ? "#{cabinet.label}-#{part_key.upcase}" : nil
        }
      end

      # nesting: result of Controller#nest (optional).
      def run(cabinets, nesting: nil)
        issues = []
        cabinets.each { |c| issues.concat(check_cabinet(c)) }
        issues.concat(check_duplicates(cabinets))
        issues.concat(check_machining(cabinets))
        issues.concat(check_nesting(nesting, cabinets)) if nesting
        issues.sort_by { |i| [i['severity'] == 'error' ? 0 : 1, i['cabinet_label'].to_s, i['code']] }
      end

      def summary(issues)
        e = issues.count { |i| i['severity'] == 'error' }
        w = issues.count { |i| i['severity'] == 'warning' }
        { 'errors' => e, 'warnings' => w, 'status' => e.positive? ? 'error' : w.positive? ? 'warning' : 'valid' }
      end

      def check_machining(cabinets)
        res = Manufacturing::Machining.for_project(cabinets)
        by_id = cabinets.to_h { |c| [c.id, c] }
        custom = cabinets.select(&:custom?).map do |c|
          issue(:warning, 'machining_unsupported', "#{c.label} comes from a custom template: no drilling data is generated for it", cabinet: c)
        end
        res['issues'].map do |i|
          cab = by_id[i['cabinet_id']]
          issue(i['severity'].to_sym, i['code'], i['message'], cabinet: cab, part_key: i['part_key'])
        end + custom + MachiningChecker.check(res['ops'])
      end

      def check_cabinet(cab)
        out = []
        p = cab.params
        calc = cab.calculation
        calc.errors.each do |e|
          code = Rules::MATERIAL_KEYS.key?(e.key) ? 'missing_material' : 'impossible_geometry'
          out << issue(:error, code, e.message, cabinet: cab)
        end
        return out unless calc.ok? # panels are not meaningful when the rules fail

        out.concat(check_panels(cab))
        out.concat(check_hardware(cab)) unless cab.custom?
        out.concat(check_edges_and_grain(cab))
        out.concat(check_edge_options(cab)) unless cab.custom?
        out.concat(check_overrides(cab))
        out.concat(check_clearances(cab, p)) unless cab.custom?
        out
      end

      def check_overrides(cab)
        out = []
        cab.orphan_overrides.each do |k|
          out << issue(:warning, 'override_orphan', "Manual override for '#{k}' is ignored: that part no longer exists (reset it or restore the part)", cabinet: cab, part_key: k)
        end
        cab.auto_panels.each do |ap|
          ov = cab.overrides[ap.key]
          next unless ov && (ov.key?('thickness') || ov.key?('material'))

          eff = cab.panels.find { |p| p.key == ap.key }
          mat = Material.find(eff.material_id)
          next if mat.nil? || %i[back drawer_box].include?(eff.role)
          next if (mat.thickness - eff.thickness).abs < 1e-6

          out << issue(:warning, 'override_thickness', "#{eff.name}: thickness #{eff.thickness.round(2)} mm does not match #{mat.name} (#{mat.thickness} mm)", cabinet: cab, part_key: ap.key)
        end
        out
      end

      # Edge-band thicknesses the material is sold with.
      def check_edge_options(cab)
        { 'edge_carcass' => 'material', 'edge_front' => 'front_material' }.filter_map do |key, mat_key|
          mm = cab.params[key].to_f
          mat = Material.find(cab.params[mat_key])
          next if mm <= 0 || mat.nil? || mat.edge_options.any? { |o| (o - mm).abs < 1e-6 }

          issue(:warning, 'edge_band_option', "#{mm} mm edge band is not among #{mat.name}'s options (#{mat.edge_options.join(', ')})", cabinet: cab)
        end
      end

      def check_panels(cab)
        out = []
        keys = cab.panels.map(&:key)
        expected = cab.expected_keys
        (expected - keys).each { |k| out << issue(:error, 'missing_panel', "Expected panel '#{k}' was not generated", cabinet: cab, part_key: k) }

        cab.panels.each do |pn|
          if pn.size.any? { |s| !s.finite? || s <= 0 }
            out << issue(:error, 'invalid_dimension', "#{pn.name} has a zero, negative or invalid dimension", cabinet: cab, part_key: pn.key)
          end
        end
        CollisionChecker.panel_overlaps(cab.panels).each do |a, b, code|
          out << issue(:error, code, "#{a.name} overlaps #{b.name}", cabinet: cab, part_key: a.key)
        end
        out
      end

      def check_hardware(cab)
        out = []
        items = cab.hardware
        p = cab.params
        v = cab.calculation.values
        if v['door_widths'].any? && items.none? { |h| h['hardware_id'] == p['hinge_type'] && h['part_key'].start_with?('door_') }
          out << issue(:error, 'missing_hardware', 'Doors have no hinges', cabinet: cab, part_key: 'door_1')
        end
        if v['drawer_fronts'].any? && items.none? { |h| h['hardware_id'] == p['runner_type'] && h['part_key'].end_with?('_front') }
          out << issue(:error, 'missing_hardware', 'Drawers have no runners', cabinet: cab, part_key: 'drawer_1_front')
        end
        cab.hardware_issues.each { |i| out << issue(:warning, 'unknown_hardware', i['message'], cabinet: cab) }
        out
      end

      def check_edges_and_grain(cab)
        out = []
        cab.panels.each do |pn|
          if !cab.custom? && EdgeBanding::RULES.key?(pn.role) && pn.edges.empty?
            fronts = %i[door drawer_front].include?(pn.role)
            out << issue(:warning, 'missing_edge_banding', "#{pn.name} has no edge banding#{fronts ? ' on a visible front' : ''}", cabinet: cab, part_key: pn.key)
          end
          mat = Material.find(pn.material_id)
          if mat && mat.grain != :none && pn.grain == :none
            out << issue(:warning, 'grain_direction', "#{pn.name} has no grain direction but #{mat.name} is directional", cabinet: cab, part_key: pn.key)
          end
        end
        out
      end

      def check_clearances(cab, p)
        out = []
        fronts = cab.calculation.values['door_widths'].size + cab.calculation.values['drawer_fronts'].size
        if fronts.positive?
          if p['door_gap'].to_f < LIMITS[:min_front_gap] && fronts > 1
            out << issue(:warning, 'insufficient_clearance', "Gap between fronts is #{p['door_gap']} mm (minimum #{LIMITS[:min_front_gap]} mm)", cabinet: cab)
          end
          if p['door_reveal'].to_f < LIMITS[:min_reveal]
            out << issue(:warning, 'insufficient_clearance', "Outer reveal is #{p['door_reveal']} mm (minimum #{LIMITS[:min_reveal]} mm)", cabinet: cab)
          end
        end
        if p['drawer_count'].to_i.positive? && p['runner_clearance'].to_f < LIMITS[:min_runner_clearance]
          out << issue(:warning, 'insufficient_clearance', "Runner clearance is #{p['runner_clearance']} mm per side (typically at least #{LIMITS[:min_runner_clearance]} mm)", cabinet: cab)
        end
        out
      end

      def check_duplicates(cabinets)
        out = []
        cabinets.group_by(&:id).each do |id, group|
          next if group.size < 2

          group.each { |c| out << issue(:error, 'duplicate_cabinet_id', "Cabinet id #{id} is used by #{group.size} cabinets", cabinet: c) }
        end
        cabinets.flat_map { |c| c.part_rows.map { |r| [r['part_id'], c, r['key']] } }.group_by(&:first).each do |pid, list|
          next if list.size < 2

          list.each { |_, c, k| out << issue(:error, 'duplicate_part_id', "Part ID #{pid} appears #{list.size} times", cabinet: c, part_key: k) }
        end
        out
      end

      # nesting: { 'materials' => [per-material nest results] }
      def check_nesting(nesting, cabinets)
        out = []
        by_id = cabinets.to_h { |c| [c.id, c] }
        nesting['materials'].each do |m|
          m['unplaced'].each do |u|
            cab_id, key = u['uid'].split(':', 2)
            out << issue(:error, 'nesting_failure', "#{u['part_id']} (#{u['length']} x #{u['width']}) does not fit on a #{m['sheet_length'].round} x #{m['sheet_width'].round} sheet of #{m['material']}", cabinet: by_id[cab_id], part_key: key)
          end
          m['released_locks'].each { |l| out << issue(:warning, 'lock_released', "Lock on #{l['part_id']} was released: #{l['reason']}") }
          m['sheets'].each do |sh|
            sh['placements'].each do |pl|
              need = Manufacturing::Nesting.required_rotation(pl['grain'], m['grain_free'], m['grain_axis'] || 'length')
              next if need.nil? || need == pl['rotated']

              cab_id, key = pl['uid'].split(':', 2)
              out << issue(:error, 'grain_direction', "#{pl['part_id']} is placed against its grain direction on sheet #{sh['index'] + 1}", cabinet: by_id[cab_id], part_key: key)
            end
            cut = sh['cut_sequence']
            out << issue(:warning, 'no_cut_sequence', "#{m['material']} sheet #{sh['index'] + 1}: #{cut['reason']}") unless cut['ok']
          end
        end
        out
      end
    end
  end
end
