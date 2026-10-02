# frozen_string_literal: true

require 'securerandom'
require_relative '../core/units'
require_relative '../core/parameter'
require_relative '../core/library'
require_relative '../core/material'
require_relative '../core/construction'
require_relative '../core/cabinet'
require_relative '../generators/cabinet_generator'
require_relative '../core/hardware'
require_relative '../manufacturing/parts_list'
require_relative '../manufacturing/cutting_list'
require_relative '../exporters/csv_exporter'
require_relative '../exporters/json_exporter'
require_relative '../manufacturing/nesting'
require_relative '../manufacturing/labels'
require_relative '../manufacturing/machining'
require_relative '../manufacturing/cnc'
require_relative '../manufacturing/costing'
require_relative '../core/run_planner'
require_relative '../core/run'
require_relative 'layout_commands'
require_relative 'overview_commands'
require_relative '../manufacturing/dashboard'
require_relative '../manufacturing/assembly'
require_relative '../exporters/assembly_svg'
require_relative '../exporters/dxf_exporter'
require_relative '../exporters/pdf_reports'
require_relative '../exporters/svg_exporter'
require_relative '../validation/machining_checker'
require_relative '../exporters/label_html'
require_relative '../validation/validator'
require_relative '../scene/registry'
require_relative '../scene/project_store'
require_relative '../scene/model_checker'
require_relative '../scene/explode'

module CabinetCraft
  module Interface
    # UI-independent command layer. The dialog forwards JSON calls here; tests
    # call it directly. Every public method returns a JSON-safe Hash.
    class Controller
      include LayoutCommands
      include OverviewCommands

      PUBLIC_METHODS = %w[bootstrap preview create update select list parts_list cutting_list hardware_state
                          add_hardware delete_hardware set_hinge_rules set_hardware_setting
                          project_state set_project_name nest nest_lock nest_lock_current nest_unlock nest_unlock_all
                          labels lookup_part validate select_target
                          materials_state save_material delete_material reset_material
                          advanced_parts set_override reset_overrides
                          library_state templates_state validate_template save_template delete_template install_example
                          save_preset delete_preset standards_state save_standards reset_standards
                          cost_state save_cost_settings set_hardware_price
                          assembly_state explode_cabinet assemble_cabinet plan_run create_run runs_state restretch_run unlink_run
                          plan_corner create_corner_layout layouts_state unlink_layout restretch_layout dashboard_state
                          machining_state set_machining_setting add_pattern delete_pattern select_machine save_machine
                          delete_machine save_post delete_post cnc_check cnc_preview].freeze

      # kind => [formats]. 'project' is JSON only.
      EXPORTS = { 'parts' => %w[csv excel_csv json pdf], 'cutting_list' => %w[csv excel_csv json pdf],
                  'hardware' => %w[csv excel_csv json], 'project' => %w[json],
                  'nesting' => %w[csv excel_csv json pdf], 'labels' => %w[pdf html csv excel_csv json],
                  'machining' => %w[csv excel_csv json], 'costing' => %w[csv excel_csv json pdf], 'quote' => %w[pdf], 'assembly' => %w[pdf], 'dxf' => %w[dxf], 'svg' => %w[svg], 'gcode' => %w[nc], 'gcode_b' => %w[nc] }.freeze
      EXTENSIONS = { 'csv' => 'csv', 'excel_csv' => 'csv', 'json' => 'json', 'html' => 'html', 'pdf' => 'pdf', 'dxf' => 'dxf', 'svg' => 'svg', 'nc' => 'nc' }.freeze
      MULTI_FILE = %w[dxf svg gcode gcode_b].freeze # one file per nested sheet

      def model
        ::Sketchup.active_model
      end

      def bootstrap
        {
          'version' => defined?(CabinetCraft::VERSION) ? CabinetCraft::VERSION : 'dev',
          'library' => (sync_templates && library_entries),
          'standards' => standards_summary,
          'planned' => Library::PLANNED,
          'schema' => Parameter.schema,
          'schemas' => template_schemas,
          'materials' => (sync_materials && Material.all.map(&:to_h)),
          'profiles' => Construction.list,
          'cabinets' => list['cabinets'],
          'selected' => selected_summary
        }
      end

      def list
        { 'cabinets' => Scene::Registry.cabinets(model).map { |_, c| c.summary } }
      end

      # Pure calculation: no model changes. Drives the live panel table. When `cabinet_id` is given, that
      # cabinet's manual overrides are included so the table matches what the model will show.
      def preview(type, raw, label = nil, cabinet_id = nil)
        Library.entry(type) or return failure("Unknown cabinet type '#{type}'")
        # Preset defaults sit under whatever the caller supplies.
        params, errors = Parameter.coerce(Library.defaults_for(type).merge((raw || {}).transform_keys(&:to_s)), Library.schema_for(type))
        return { 'ok' => false, 'params' => params, 'issues' => errors, 'panels' => [], 'values' => {} } unless errors.empty?

        cab = Cabinet.build(type: type, params: params, label: label || Scene::Registry.next_label(model))
        if cabinet_id && (found = Scene::Registry.find(model, cabinet_id))
          cab = cab.with_overrides(found[1].overrides)
        end
        issues = cab.calculation.issues.map(&:to_h)
        ok = cab.calculation.ok?
        issues += cab.hardware_issues if ok
        derived = cab.custom? && cab.template ? cab.template.derived.map { |d| { 'name' => d['name'], 'label' => d['label'], 'value' => cab.calculation.values[d['name']] } } : nil
        {
          'ok' => ok, 'params' => params, 'issues' => issues, 'values' => cab.calculation.values, 'derived' => derived,
          'panels' => ok ? cab.part_rows : [], 'hardware' => ok ? cab.hardware_rows : []
        }
      end

      def create(type, raw)
        prev = preview(type, raw)
        return prev.merge('created' => false) unless prev['ok']

        cabinet = nil
        in_operation('CabinetCraft: Create cabinet', reidentify: false) do
          reidentify_duplicates
          cabinet = Cabinet.build(type: type, params: prev['params'], label: Scene::Registry.next_label(model))
          x = Units.to_sketchup(Scene::Registry.next_x_mm(model))
          group = Generators::CabinetGenerator.create(model.entities, cabinet,
                                                      Geom::Transformation.new(Geom::Point3d.new(x, 0, 0)))
          model.selection.clear
          model.selection.add(group)
          snapshot_materials
          snapshot_templates
        end
        prev.merge('created' => true, 'cabinet' => cabinet.summary, 'panels' => cabinet.part_rows)
      end

      # Regenerates only the one cabinet that changed.
      #
      # `mode` decides what happens when the change would alter a manually overridden size:
      #   nil     - nothing is changed; the reply has 'needs_confirmation' => true and the 'affected' parts
      #   'keep'  - apply the change, keep every override
      #   'reset' - apply the change and return the affected overridden fields to AUTO
      def update(cabinet_id, raw, mode = nil)
        group, current = Scene::Registry.find(model, cabinet_id)
        return failure('That cabinet no longer exists in the model') unless group

        prev = preview(current.type, raw, current.label, cabinet_id)
        return prev.merge('updated' => false) unless prev['ok']
        return prev.merge('updated' => false, 'cabinet' => current.summary) if prev['params'] == current.params

        overrides = current.overrides
        unless overrides.empty?
          candidate = current.with_params(prev['params'])
          affected = Overrides.affected(current.auto_panels, candidate.auto_panels, overrides)
          if affected.any?
            unless %w[keep reset].include?(mode)
              named = affected.map { |a| a.merge('part_id' => "#{current.label}-#{a['part_key'].upcase}") }
              return prev.merge('updated' => false, 'needs_confirmation' => true, 'affected' => named, 'cabinet' => current.summary)
            end
            overrides = Overrides.reset_affected(overrides, affected) if mode == 'reset'
          end
        end
        updated = current.with_params(prev['params'], overrides: overrides)
        in_operation('CabinetCraft: Edit cabinet') do
          Generators::CabinetGenerator.rebuild(group, updated)
          snapshot_materials
          snapshot_templates
        end
        prev.merge('updated' => true, 'cabinet' => updated.summary, 'panels' => updated.part_rows, 'reset' => mode == 'reset')
      end

      # --- Manual overrides ("advanced parts") --------------------------------------------------

      def advanced_parts(cabinet_id)
        _, cab = Scene::Registry.find(model, cabinet_id)
        return failure('That cabinet no longer exists in the model') unless cab

        advanced_state(cab)
      end

      # fields: { 'length' => 700, 'width' => '', 'offset_x' => 5, 'material' => 'ply_18', 'edges' => { 'front' => 1 } };
      # a blank value returns that field to AUTO.
      def set_override(cabinet_id, part_key, fields)
        group, cab = Scene::Registry.find(model, cabinet_id)
        raise ArgumentError, 'That cabinet no longer exists in the model' unless group

        auto = cab.auto_panels.find { |p| p.key == part_key } or raise ArgumentError, "Unknown part '#{part_key}'"
        part = Overrides.clean_part(auto, fields || {}, cab.overrides[part_key] || {})
        new_ov = cab.overrides.reject { |k, _| k == part_key }
        new_ov = new_ov.merge(part_key => part) unless part.empty?
        return advanced_state(cab) if new_ov == cab.overrides

        apply_overrides(group, cab, new_ov)
      end

      # Returns every overridden field of one part (or of the whole cabinet) to AUTO.
      def reset_overrides(cabinet_id, part_key = nil)
        group, cab = Scene::Registry.find(model, cabinet_id)
        raise ArgumentError, 'That cabinet no longer exists in the model' unless group

        new_ov = part_key ? cab.overrides.reject { |k, _| k == part_key } : {}
        return advanced_state(cab) if new_ov == cab.overrides

        apply_overrides(group, cab, new_ov)
      end

      def apply_overrides(group, cab, new_ov)
        updated = cab.with_overrides(new_ov)
        in_operation('CabinetCraft: Override part') { Generators::CabinetGenerator.rebuild(group, updated) }
        advanced_state(updated)
      end

      def advanced_state(cab)
        eff = cab.panels.to_h { |p| [p.key, p] }
        strs = ->(h) { h.transform_keys(&:to_s) }
        rows = cab.auto_panels.map do |ap|
          ep = eff[ap.key]
          ov = cab.overrides[ap.key] || {}
          fields = {
            'length' => { 'auto' => ap.length.round(3), 'value' => ov['length'], 'effective' => ep.length.round(3) },
            'width' => { 'auto' => ap.width.round(3), 'value' => ov['width'], 'effective' => ep.width.round(3) },
            'thickness' => { 'auto' => ap.thickness.round(3), 'value' => ov['thickness'], 'effective' => ep.thickness.round(3) },
            'material' => { 'auto' => ap.material_id, 'value' => ov['material'], 'effective' => ep.material_id },
            'edges' => { 'auto' => strs.call(ap.edges), 'value' => ov['edges'], 'effective' => strs.call(ep.edges) }
          }
          Overrides::OFFSET_FIELDS.each { |f| fields[f] = { 'auto' => 0.0, 'value' => ov[f], 'effective' => ov[f] || 0.0 } }
          { 'key' => ap.key, 'part_id' => cab.part_id(ap), 'name' => ap.name, 'status' => ep.status, 'fields' => fields,
            'edge_faces' => Panel::FACES.select { |_, (axis, _)| axis != ap.thickness_axis }.keys.map(&:to_s) }
        end
        { 'ok' => true, 'cabinet' => cab.summary, 'parts' => rows, 'orphans' => cab.orphan_overrides,
          'materials' => Material.all.map { |m| { 'id' => m.id, 'name' => m.name } },
          'issues' => Validation::Validator.check_cabinet(cab).select { |i| i['part_key'] || i['code'] == 'override_orphan' } }
      end

      # --- Reports: derived from every cabinet in the model, never stored ---------------

      def project_cabinets
        sync_materials
        sync_templates
        Scene::Registry.cabinets(model).map(&:last)
      end

      # --- Templates and presets -------------------------------------------------------------------

      # Restores templates / presets stored in the model that this machine does not have yet.
      def sync_templates
        Templates.config.import_missing(project_store.templates_snapshot)
      end

      def snapshot_templates
        project_store.templates_snapshot = Templates.config.snapshot
      end

      def template_schemas
        Library.template_entries.to_h { |e| [e['type'], Templates.find(e['type']).schema] }
      end

      # Library entries with the starting values a NEW cabinet of each type gets (standards applied server-side).
      def library_entries
        Library.entries.map { |e| e.merge('resolved' => Library.defaults_for(e['type'])) }
      end

      def standards_summary
        { 'name' => Standards.current.name, 'values' => Standards.current.values }
      end

      def library_state
        sync_templates
        { 'library' => library_entries, 'schemas' => template_schemas, 'planned' => Library::PLANNED, 'standards' => standards_summary }
      end

      # --- Cost estimation ---------------------------------------------------------------------

      def cost_settings
        Manufacturing::Costing.normalize(project_store.cost_settings)
      end

      def cost_estimate
        cabs = project_cabinets
        settings = cost_settings
        return { 'enabled' => false } unless settings['enabled']

        ops = Manufacturing::Machining.for_project(cabs)['ops']
        Manufacturing::Costing.estimate(cabs, cabs.empty? ? nil : nest, ops, settings)
      end

      def cost_state
        thick = project_cabinets.flat_map(&:panels).flat_map { |p| p.edges.values }.uniq.sort.map { |v| format('%.1f', v) }
        { 'settings' => cost_settings, 'estimate' => cost_estimate, 'edge_thicknesses' => thick, 'cabinet_count' => project_cabinets.size }
      end

      def save_cost_settings(raw)
        clean = Manufacturing::Costing.normalize(raw)
        in_operation('CabinetCraft: Cost settings', reidentify: false) { project_store.cost_settings = clean }
        cost_state
      end

      def set_hardware_price(id, price)
        Hardware.config.set_price(id, price)
        hardware_state
      end

      # --- Assembly documentation --------------------------------------------------------------

      MAX_EXPLODE_MM = 2000.0

      def assembly_state(cabinet_id, amount = nil)
        group, cab = Scene::Registry.find(model, cabinet_id)
        return failure('That cabinet no longer exists in the model') unless group
        return failure('This cabinet has calculation errors; fix them before documenting its assembly') unless cab.calculation.ok?

        assembly_payload(group, cab, explode_amount(amount))
      end

      # Moves the cabinet's parts apart in the SketchUp model (reversible; ASSEMBLE puts them back).
      def explode_cabinet(cabinet_id, amount = nil)
        group, cab = Scene::Registry.find(model, cabinet_id)
        raise ArgumentError, 'That cabinet no longer exists in the model' unless group
        raise ArgumentError, 'This cabinet has calculation errors' unless cab.calculation.ok?

        amt = explode_amount(amount)
        in_operation('CabinetCraft: Explode cabinet', reidentify: false) { Scene::Explode.apply(group, cab, amt) }
        assembly_payload(group, cab, amt)
      end

      def assemble_cabinet(cabinet_id)
        group, cab = Scene::Registry.find(model, cabinet_id)
        raise ArgumentError, 'That cabinet no longer exists in the model' unless group

        in_operation('CabinetCraft: Assemble cabinet', reidentify: false) { Scene::Explode.assemble(group) }
        assembly_payload(group, cab, nil)
      end

      def explode_amount(amount)
        return nil if amount.nil? || amount.to_s.strip.empty?

        v = Float(amount)
        raise ArgumentError, "Explode distance must be between 0 and #{MAX_EXPLODE_MM.round} mm" unless v.between?(0, MAX_EXPLODE_MM)

        v
      rescue ArgumentError, TypeError
        raise ArgumentError, "Explode distance must be a number between 0 and #{MAX_EXPLODE_MM.round} mm"
      end

      def assembly_payload(group, cab, amount)
        d = Manufacturing::Assembly.describe(cab, amount: amount)
        { 'ok' => true, 'cabinet' => cab.summary, 'steps' => d['steps'], 'parts' => d['parts'], 'amount' => d['amount'],
          'svg_assembled' => Exporters::AssemblySvg.svg(d['assembled']), 'svg_exploded' => Exporters::AssemblySvg.svg(d['exploded']),
          'exploded_in_model' => Scene::Explode.exploded?(group), 'custom' => cab.custom? }
      end

      def assembly_item(cab)
        d = Manufacturing::Assembly.describe(cab)
        names = Library.entries.to_h { |e| [e['type'], e['name']] }
        p = cab.params
        dims = p['width'] && p['height'] && p['depth'] ? "#{p['width']} x #{p['height']} x #{p['depth']} mm (W x H x D)" : 'Custom template'
        { 'label' => cab.label, 'type_name' => names[cab.type] || cab.type, 'dims' => dims, 'steps' => d['steps'], 'parts' => d['parts'],
          'assembled' => d['assembled'], 'exploded' => d['exploded'] }
      end

      # --- Cabinet runs (Smart Space fill) ---------------------------------------------------------

      # Pure calculation: widths for a row of cabinets along a wall of `length` mm. Nothing is changed in the model.
      def plan_run(length, items)
        list = run_items(items)
        plan = RunPlanner.plan(length, list.map { |i| i.slice('fixed', 'width', 'min', 'max') })
        plan.merge('items' => list.each_with_index.map { |i, n| { 'type' => i['type'], 'width' => plan['widths'][n], 'fixed' => i['fixed'] } })
      rescue ArgumentError, TypeError => e
        { 'ok' => false, 'widths' => [], 'issues' => [e.message], 'items' => [] }
      end

      # Creates the whole run in one undo step, left to right from the right-most existing cabinet. Nothing is created
      # if any cabinet is invalid or the row does not fit. A leftover gap (cabinets at maximum width) is allowed and reported.
      def create_run(length, items)
        plan = plan_run(length, items)
        raise ArgumentError, plan['issues'].first.to_s unless plan['ok']

        list = run_items(items)
        prepared = list.each_with_index.map do |it, n|
          prev = preview(it['type'], (it['params'] || {}).merge('width' => plan['widths'][n]))
          raise ArgumentError, "Cabinet #{n + 1} (#{it['type']}): #{prev['issues'].find { |i| i['severity'] == 'error' }&.fetch('message', nil) || 'invalid'}" unless prev['ok']

          [it['type'], prev['params']]
        end
        created = []
        in_operation('CabinetCraft: Create cabinet run', reidentify: false) do
          reidentify_duplicates
          x = Scene::Registry.next_x_mm(model)
          prepared.each do |type, params|
            cabinet = Cabinet.build(type: type, params: params, label: Scene::Registry.next_label(model))
            Generators::CabinetGenerator.create(model.entities, cabinet, Geom::Transformation.new(Geom::Point3d.new(Units.to_sketchup(x), 0, 0)))
            x += params['width']
            created << cabinet.summary
          end
          snapshot_materials
          snapshot_templates
          run = Run.build(name: next_run_name, length: length, items: list.each_with_index.map { |it, n| run_item(it, created[n]['id'], plan['widths'][n]) })
          save_run(run)
        end
        { 'ok' => true, 'created' => created, 'plan' => plan, 'runs' => runs_state['runs'] }
      end

      def run_item(item, cabinet_id, width)
        { 'cabinet_id' => cabinet_id, 'fixed' => item['fixed'] ? true : false, 'width' => item['fixed'] ? width : nil, 'min' => item['min'] || RunPlanner::DEFAULT_MIN,
          'max' => item['max'] || RunPlanner::DEFAULT_MAX }
      end

      # --- Linked runs ---------------------------------------------------------------------------

      def stored_runs
        project_store.runs.values.filter_map { |raw| Run.from_h(raw) }
      end

      def save_run(run)
        all = project_store.runs
        all[run.id] = run.to_h
        project_store.runs = all
      end

      def next_run_name
        used = stored_runs.filter_map { |r| r.name[/\AR(\d+)\z/, 1]&.to_i }
        format('R%<n>02d', n: (used.max || 0) + 1)
      end

      # Every stored run with the state of its member cabinets in the model:
      # ok / missing (deleted) / resized (width differs from the plan) / moved (not where the plan puts it).
      def runs_state
        { 'runs' => stored_runs.map { |r| run_summary(r) } }
      end

      def run_summary(run)
        plan = (run.plan rescue nil) # rubocop:disable Style/RescueModifier
        found = run.items.map { |i| Scene::Registry.find(model, i['cabinet_id']) }
        base = found.first&.first&.then { |g| along(g, run.axis) } # positions are judged against the first cabinet
        x = 0.0
        members = run.items.each_with_index.map do |item, n|
          group, cab = found[n]
          expected_w = plan && plan['widths'][n]
          expected_x = base ? base + x : nil
          x += expected_w.to_f
          status = if cab.nil? then 'missing'
                   elsif expected_w && (cab.params['width'].to_f - expected_w).abs > 0.01 then 'resized'
                   elsif expected_x && (along(group, run.axis) - expected_x).abs > 0.5 then 'moved'
                   else 'ok'
                   end
          { 'n' => n + 1, 'cabinet_id' => item['cabinet_id'], 'label' => cab&.label, 'type' => cab&.type, 'fixed' => item['fixed'], 'min' => item['min'], 'max' => item['max'],
            'width' => cab&.params&.fetch('width', nil), 'expected_width' => expected_w, 'status' => status }
        end
        { 'id' => run.id, 'name' => run.name, 'length' => run.length, 'axis' => run.axis, 'members' => members, 'in_sync' => members.all? { |m| m['status'] == 'ok' },
          'leftover' => plan && plan['leftover'], 'fits' => plan ? plan['ok'] : false }
      end

      def unlink_run(run_id)
        all = project_store.runs
        raise ArgumentError, 'That run no longer exists' unless all.key?(run_id)

        in_operation('CabinetCraft: Unlink run', reidentify: false) do
          all.delete(run_id)
          project_store.runs = all
        end
        runs_state
      end

      # Quick Stretch: re-plans the run for a new wall length (and optionally new per-cabinet rules), resizes the member
      # cabinets and puts them edge to edge again, starting where the first cabinet currently is. One undo step.
      # rules: index-aligned [{ 'fixed' => bool, 'width' => mm, 'min' => mm, 'max' => mm }] (partial hashes allowed).
      # mode: 'keep' / 'reset' decides what happens to manual overrides a new width would change (as in `update`).
      def restretch_run(run_id, length, rules = nil, mode = nil)
        job = restretch_job(run_id, length, rules, mode)
        return job if job.key?('needs_confirmation')

        in_operation('CabinetCraft: Resize run', reidentify: false) { apply_restretch(job) }
        { 'ok' => true, 'updated' => true, 'plan' => job[:plan], 'runs' => runs_state['runs'] }
      end

      # Everything needed to resize one run, with no model changes. Returns a Hash reply (with 'needs_confirmation') when manual
      # overrides would change and the caller has not chosen keep / reset; raises ArgumentError for impossible requests.
      # base: where the first cabinet should start along the run's axis (mm); defaults to where it is now.
      def restretch_job(run_id, length, rules, mode, base: nil)
        run = stored_runs.find { |r| r.id == run_id } or raise ArgumentError, 'That run no longer exists'
        rules = rules&.each_with_index&.map { |r, n| fixed_with_current_width(run, r, n) }
        updated = run.with(length: length, rules: rules)
        plan = updated.plan
        raise ArgumentError, plan['issues'].first.to_s unless plan['ok']

        members = updated.items.map { |i| Scene::Registry.find(model, i['cabinet_id']) }
        missing = members.each_index.select { |n| members[n].nil? }
        raise ArgumentError, "Cabinet #{missing.first + 1} of #{run.name} is no longer in the model: unlink the run and create it again" if missing.any?

        prepared = stretch_prepare(members, plan['widths'], mode)
        return prepared if prepared.is_a?(Hash)

        { run: updated, plan: plan, prepared: prepared, base: base || along(members.first[0], updated.axis) }
      end

      def apply_restretch(job)
        stretch_apply(job[:prepared], job[:base], job[:run].axis)
        save_run(job[:run])
      end

      # Making a cabinet fixed without giving a width pins it at the width it has now.
      def fixed_with_current_width(run, rule, index)
        return rule unless rule && rule['fixed'] && rule['width'].to_s.strip.empty? && run.items[index]['width'].nil?

        _, cab = Scene::Registry.find(model, run.items[index]['cabinet_id'])
        cab ? rule.merge('width' => cab.params['width']) : rule
      end

      # => Array of [group, new_cabinet_or_nil, width] or a Hash reply when the caller must confirm / the plan is invalid.
      def stretch_prepare(members, widths, mode)
        affected_all = []
        out = members.each_with_index.map do |(group, cab), n|
          next [group, nil, widths[n]] if (cab.params['width'].to_f - widths[n]).abs < 1e-9

          prev = preview(cab.type, cab.params.merge('width' => widths[n]), cab.label, cab.id)
          raise ArgumentError, "#{cab.label}: #{prev['issues'].find { |i| i['severity'] == 'error' }&.fetch('message', nil) || 'invalid'}" unless prev['ok']

          overrides = cab.overrides
          unless overrides.empty?
            affected = Overrides.affected(cab.auto_panels, cab.with_params(prev['params']).auto_panels, overrides)
            affected_all.concat(affected.map { |a| a.merge('part_id' => "#{cab.label}-#{a['part_key'].upcase}") })
            overrides = Overrides.reset_affected(overrides, affected) if mode == 'reset' && affected.any?
          end
          [group, cab.with_params(prev['params'], overrides: overrides), widths[n]]
        end
        return { 'ok' => false, 'updated' => false, 'needs_confirmation' => true, 'affected' => affected_all } if affected_all.any? && !%w[keep reset].include?(mode)

        out
      end

      # Position (mm) of a group's minimum corner along a model axis ('x' or 'y').
      def along(group, axis)
        Units.from_sketchup(axis == 'y' ? group.bounds.min.y : group.bounds.min.x)
      end

      def stretch_apply(prepared, base, axis = 'x')
        pos = base
        prepared.each do |group, new_cab, width|
          Generators::CabinetGenerator.rebuild(group, new_cab) if new_cab
          delta = Units.to_sketchup(pos - along(group, axis))
          if delta.abs > 1e-9
            vec = axis == 'y' ? Geom::Vector3d.new(0, delta, 0) : Geom::Vector3d.new(delta, 0, 0)
            group.transform!(Geom::Transformation.translation(vec))
          end
          pos += width
        end
        snapshot_materials
      end

      def run_items(items)
        raise ArgumentError, 'Add at least one cabinet to the run' unless items.is_a?(Array) && !items.empty?

        items.map do |raw|
          it = raw.transform_keys(&:to_s)
          raise ArgumentError, "Unknown cabinet type '#{it['type']}'" unless Library.entry(it['type'])

          if it['fixed'] && it['width'].to_s.strip.empty?
            it['width'] = (it['params'] || {})['width'] || Library.defaults_for(it['type'])['width'] || Parameter.defaults['width']
          end
          it
        end
      end

      # --- Factory standards -----------------------------------------------------------------------

      def standards_state
        { 'standards' => standards_summary, 'fields' => Standards.fields, 'allowed' => Standards::ALLOWED,
          'schema_defaults' => Parameter.defaults.slice(*Standards::ALLOWED),
          'hardware_settings' => Hardware.config.settings }
      end

      def save_standards(name, values)
        Standards.current.save(name: name, values: values)
        standards_state.merge('library' => library_entries, 'schemas' => template_schemas)
      end

      def reset_standards
        Standards.current.reset
        standards_state.merge('library' => library_entries, 'schemas' => template_schemas)
      end

      def type_users(type)
        Scene::Registry.cabinets(model).select { |_, c| c.type == type }.map { |_, c| c.label }
      end

      def templates_state
        sync_templates
        cfg = Templates.config
        {
          'templates' => cfg.templates.map do |t|
            h = t.to_h
            { 'id' => t.id, 'name' => t.name, 'category' => t.category, 'description' => t.description, 'json' => JSON.pretty_generate(h),
              'parameters' => h['parameters'].size, 'panels' => h['panels'].size, 'used_by' => type_users(t.id) }
          end,
          'presets' => cfg.presets.map { |p| p.merge('used_by' => type_users(p['id'])) },
          'examples' => Templates::Examples::ALL.to_h { |k, v| [k, { 'name' => v['name'], 'description' => v['description'], 'json' => JSON.pretty_generate(v) }] },
          'roles' => Templates::Template::ROLES, 'param_types' => Templates::Template::PARAM_TYPES,
          'functions' => Templates::Expression::FUNCTIONS.keys, 'hardware' => Hardware.all.reject(&:hidden).map { |h| [h.id, h.name, h.category] }
        }
      end

      # Checks a template's JSON and shows what it builds with its default values. Never changes anything.
      def validate_template(json)
        t = Templates::Template.from_json(json.to_s)
        b = t.build(t.defaults)
        rows = b.panels.map { |p| p.to_h(part_id: "PREVIEW-#{p.key.upcase}", cabinet_id: 'preview') }
        labels = t.derived.to_h { |d| [d['name'], d['label']] }
        { 'ok' => true, 'name' => t.name, 'parameters' => t.parameters.size, 'panels' => rows, 'hardware' => b.hardware,
          'derived' => b.result.values.select { |k, _| labels.key?(k) }.map { |k, v| { 'name' => k, 'label' => labels[k], 'value' => v } },
          'issues' => b.result.issues.map(&:to_h), 'defaults' => t.defaults }
      rescue Templates::Template::Invalid => e
        { 'ok' => false, 'errors' => e.errors }
      end

      def save_template(json, id = nil)
        t = Templates.config.save_template(json, id)
        regenerate(Scene::Registry.cabinets(model).select { |_, c| c.type == t.id }, 'CabinetCraft: Edit template')
        snapshot_templates
        templates_state.merge('saved_id' => t.id, 'library' => library_entries, 'schemas' => template_schemas)
      rescue Templates::Template::Invalid => e
        { 'ok' => false, 'errors' => e.errors }
      end

      def delete_template(id)
        users = type_users(id)
        raise ArgumentError, "In use by #{users.join(', ')} - delete or change those cabinets first" unless users.empty?

        Templates.config.delete_template(id) or raise ArgumentError, 'Unknown template'
        snapshot_templates
        templates_state.merge('library' => library_entries, 'schemas' => template_schemas)
      end

      def install_example(key)
        ex = Templates::Examples::ALL[key] or raise ArgumentError, 'Unknown example'
        save_template(ex)
      end

      # Saves the given parameters of a built-in cabinet as a new library entry ("save as template").
      def save_preset(name, category, description, base_type, params)
        Templates.config.save_preset(name: name, category: category, description: description, base_type: base_type, params: params)
        snapshot_templates
        templates_state.merge('library' => library_entries, 'schemas' => template_schemas)
      end

      def delete_preset(id)
        users = type_users(id)
        raise ArgumentError, "In use by #{users.join(', ')}" unless users.empty?

        Templates.config.delete_preset(id) or raise ArgumentError, 'Unknown preset'
        snapshot_templates
        templates_state.merge('library' => library_entries, 'schemas' => template_schemas)
      end

      # --- Materials ----------------------------------------------------------------------------

      # Restores custom materials stored in the model that this machine does not have yet.
      def sync_materials
        added = Material.config.import_missing(project_store.materials_snapshot)
        added
      end

      def snapshot_materials
        project_store.materials_snapshot = Material.config.snapshot
      end

      def material_users(id)
        Scene::Registry.cabinets(model).select { |_, c| c.params.values.include?(id) }
      end

      def materials_state
        sync_materials
        users = Scene::Registry.cabinets(model).flat_map { |_, c| c.params.select { |_, v| v.is_a?(String) }.values.uniq.map { |v| [v, c.label] } }.group_by(&:first)
        {
          'materials' => Material.all.map { |m| m.to_h.merge('used_by' => (users[m.id] || []).map(&:last).uniq) },
          'grains' => Material::GRAINS, 'overridden' => Material.config.overrides.keys, 'schema' => Parameter.schema
        }
      end

      # Creates or updates a material. Cabinets that use it are regenerated (only those).
      def save_material(raw)
        mat = Material.config.save(raw)
        regenerated = regenerate(material_users(mat.id), 'CabinetCraft: Edit material')
        snapshot_materials
        materials_state.merge('saved_id' => mat.id, 'regenerated' => regenerated)
      end

      def delete_material(id)
        users = material_users(id)
        raise ArgumentError, "In use by #{users.map { |_, c| c.label }.join(', ')} - change those cabinets first" unless users.empty?

        Material.config.delete(id) or raise ArgumentError, 'Unknown material'
        snapshot_materials
        materials_state
      end

      def reset_material(id)
        regenerated = regenerate(material_users(id), 'CabinetCraft: Reset material') if Material.config.reset_override(id)
        snapshot_materials
        materials_state.merge('regenerated' => regenerated || 0)
      end

      def regenerate(pairs, name)
        return 0 if pairs.empty?

        in_operation(name, reidentify: false) { pairs.each { |group, cab| Generators::CabinetGenerator.rebuild(group, cab) } }
        pairs.size
      end

      def parts_list
        { 'columns' => Manufacturing::PartsList::COLUMNS, 'rows' => Manufacturing::PartsList.build(project_cabinets),
          'cabinet_count' => project_cabinets.size }
      end

      def cutting_list
        Manufacturing::CuttingList.build(project_cabinets)
      end

      # Writes an export to `path`. Returns { 'ok' => true, 'path' => ..., 'bytes' => n }.
      def export(kind, format, path)
        raise ArgumentError, "Unknown export '#{kind}'" unless EXPORTS.key?(kind)
        raise ArgumentError, "#{kind} cannot be exported as #{format}" unless EXPORTS[kind].include?(format)
        raise ArgumentError, 'No file path given' if path.to_s.strip.empty?
        raise ArgumentError, "Folder does not exist: #{File.dirname(path)}" unless Dir.exist?(File.dirname(path))
        return export_sheets(kind, path) if MULTI_FILE.include?(kind)

        if %w[costing quote].include?(kind) && !cost_settings['enabled']
          raise ArgumentError, 'Cost calculations are switched off for this project (COSTS tab)'
        end
        content = format == 'pdf' ? render_pdf(kind) : render_export(kind, format)
        File.binwrite(path, format == 'pdf' ? content : content.encode('UTF-8'))
        { 'ok' => true, 'path' => path, 'bytes' => content.bytesize }
      end

      # PDF documents are built from the same derived data as the on-screen reports.
      def render_pdf(kind)
        cabs = project_cabinets
        raise ArgumentError, 'There are no cabinets to export' if cabs.empty?

        project = project_store.name
        case kind
        when 'parts' then Exporters::PdfReports.parts_list(Manufacturing::PartsList.build(cabs), project: project)
        when 'cutting_list' then Exporters::PdfReports.cutting_list(Manufacturing::CuttingList.build(cabs), project: project)
        when 'labels' then Exporters::PdfReports.labels(Manufacturing::Labels.build(cabs, project_name: project, qr: false), project: project)
        when 'nesting' then Exporters::PdfReports.nesting(nest, project: project)
        when 'costing' then Exporters::PdfReports.costing(cost_estimate, project: project)
        when 'assembly' then Exporters::PdfReports.assembly(cabs.map { |c| assembly_item(c) }, project: project)
        when 'quote' then Exporters::PdfReports.quote(cost_estimate, project: project, cabinets: cabs, type_names: Library.entries.to_h { |e| [e['type'], e['name']] })
        else raise ArgumentError, "#{kind} cannot be exported as pdf"
        end
      end

      def render_export(kind, format)
        cabs = project_cabinets
        csv = lambda do |rows, cols|
          Exporters::CsvExporter.render(rows, cols, excel: format == 'excel_csv')
        end
        case kind
        when 'project' then Exporters::JsonExporter.project(cabs, Manufacturing::CuttingList.build(cabs))
        when 'parts'
          rows = Manufacturing::PartsList.build(cabs)
          format == 'json' ? Exporters::JsonExporter.data(rows) : csv.call(rows, Manufacturing::PartsList::COLUMNS)
        when 'cutting_list'
          list = Manufacturing::CuttingList.build(cabs)
          rows = Manufacturing::CuttingList.flat_rows(list)
          format == 'json' ? Exporters::JsonExporter.data(list) : csv.call(rows, rows.first ? rows.first.keys.map { |k| [k, k] } : [])
        when 'nesting'
          res = nest
          rows = nesting_rows(res)
          format == 'json' ? Exporters::JsonExporter.data(res) : csv.call(rows, (rows.first || { 'Material' => 0 }).keys.map { |k| [k, k] })
        when 'labels'
          list = Manufacturing::Labels.build(cabs, project_name: project_store.name)
          case format
          when 'html' then Exporters::LabelHtml.render(list)
          when 'json' then Exporters::JsonExporter.data(list.map { |l| l.reject { |k, _| k == 'qr_svg' } })
          else csv.call(list, Manufacturing::Labels::COLUMNS)
          end
        when 'costing'
          est = cost_estimate
          rows = est['per_cabinet'].map { |c| { 'Cabinet' => c['label'], 'Parts' => c['parts'], 'Materials' => c['material'], 'Edge banding' => c['edge_banding'], 'Hardware' => c['hardware'],
                                                'CNC' => c['cnc'], 'Labour' => c['labour'], 'Installation' => c['installation'], 'Transport' => c['transport'], 'Cost' => c['cost'], 'Price' => c['price'] } }
          format == 'json' ? Exporters::JsonExporter.data(est) : csv.call(rows, (rows.first || { 'Cabinet' => 0 }).keys.map { |k| [k, k] })
        when 'machining'
          ops = Manufacturing::Machining.for_project(cabs)['ops']
          rows = ops.map { |o| machining_row(o) }
          format == 'json' ? Exporters::JsonExporter.data(ops) : csv.call(rows, machining_row(ops.first || {}).keys.map { |k| [k, k] })
        when 'hardware'
          list = Manufacturing::CuttingList.hardware(cabs)
          rows = list.map { |h| { 'Hardware' => h['name'], 'Category' => h['category'], 'Qty' => h['qty'] } }
          format == 'json' ? Exporters::JsonExporter.data(list) : csv.call(rows, %w[Hardware Category Qty].map { |k| [k, k] })
        end
      end

      # --- Project, nesting, labels, validation -------------------------------------------

      def project_store
        Scene::ProjectStore.new(model)
      end

      def project_state
        { 'name' => project_store.name, 'nest_settings' => Manufacturing::Nesting.normalize_settings(project_store.nest_settings),
          'cabinet_count' => project_cabinets.size }
      end

      def set_project_name(name)
        in_operation('CabinetCraft: Project name', reidentify: false) { project_store.name = name }
        project_state
      end

      # Nests every material in the model. Passing `settings` validates and saves them first.
      def nest(settings = nil)
        return @nest_memo if @nest_memo && (settings.nil? || settings.empty?)

        store = project_store
        if settings && !settings.empty?
          clean = Manufacturing::Nesting.normalize_settings(settings)
          in_operation('CabinetCraft: Nesting settings', reidentify: false) { store.nest_settings = clean }
        end
        cfg = Manufacturing::Nesting.normalize_settings(store.nest_settings)
        rows = Manufacturing::PartsList.build(project_cabinets)
        locks = store.locks
        materials = rows.group_by { |r| r['material'] }.sort_by(&:first).map do |label, mrows|
          mat = Material.find(mrows.first['material_id'])
          sheet = { 'material' => label, 'grain_free' => mat.nil? || mat.grain == :none, 'grain_axis' => mat&.grain == :width ? 'width' : 'length',
                    'sheet_length' => cfg['sheet_length'] || (mat ? mat.sheet_length : 2440).to_f,
                    'sheet_width' => cfg['sheet_width'] || (mat ? mat.sheet_width : 1220).to_f }
          parts = mrows.map { |r| nest_part(r) }
          uids = parts.map { |p| p['uid'] }
          Manufacturing::Nesting.nest(parts, sheet, cfg, locks.select { |uid, _| uids.include?(uid) })
        end
        total = materials.sum { |m| m['total_area'] }
        used = materials.sum { |m| m['used_area'] }
        { 'settings' => cfg, 'materials' => materials,
          'totals' => { 'total_sheets' => materials.sum { |m| m['total_sheets'] }, 'total_area' => total.round(1), 'used_area' => used.round(1),
                        'waste_area' => (total - used).round(1), 'utilization' => total.zero? ? 0.0 : (used * 100.0 / total).round(2),
                        'unplaced' => materials.sum { |m| m['unplaced'].size } } }
      end

      def nest_part(r)
        { 'uid' => r['part_uid'], 'part_id' => r['part_id'], 'name' => r['name'], 'length' => r['length'], 'width' => r['width'],
          'grain' => r['grain'], 'cabinet_label' => r['cabinet_label'] }
      end

      # Manually positions a part (and locks it there).
      def nest_lock(material, uid, sheet, x, y, rotated)
        res = nest
        m = res['materials'].find { |r| r['material'] == material } or return { 'ok' => false, 'error' => 'Unknown material' }
        row = Manufacturing::PartsList.build(project_cabinets).find { |r| r['part_uid'] == uid } or return { 'ok' => false, 'error' => 'Unknown part' }
        part = nest_part(row)
        err = Manufacturing::Nesting.check_move(m, part, sheet.to_i, x.to_f, y.to_f, rotated ? true : false)
        return { 'ok' => false, 'error' => err } if err

        save_lock(uid, 'sheet' => sheet.to_i, 'x' => x.to_f.round(2), 'y' => y.to_f.round(2), 'rotated' => rotated ? true : false,
                        'sig' => Manufacturing::Nesting.signature(part))
        nest.merge('ok' => true)
      end

      # Locks a part where the optimiser currently has it.
      def nest_lock_current(uid)
        pl = nest['materials'].flat_map { |m| m['sheets'].flat_map { |s| s['placements'].map { |p| p.merge('sheet' => s['index']) } } }.find { |p| p['uid'] == uid }
        return { 'ok' => false, 'error' => 'Unknown part' } unless pl

        save_lock(uid, 'sheet' => pl['sheet'], 'x' => pl['x'], 'y' => pl['y'], 'rotated' => pl['rotated'],
                        'sig' => Manufacturing::Nesting.signature(pl))
        nest.merge('ok' => true)
      end

      def nest_unlock(uid)
        in_operation('CabinetCraft: Unlock part', reidentify: false) { project_store.locks = project_store.locks.reject { |k, _| k == uid } }
        nest.merge('ok' => true)
      end

      def nest_unlock_all
        in_operation('CabinetCraft: Unlock all parts', reidentify: false) { project_store.locks = {} }
        nest.merge('ok' => true)
      end

      def save_lock(uid, lock)
        in_operation('CabinetCraft: Lock part', reidentify: false) { project_store.locks = project_store.locks.merge(uid => lock) }
      end

      def nesting_rows(res)
        res['materials'].flat_map do |m|
          m['sheets'].flat_map do |s|
            s['placements'].map do |p|
              { 'Material' => m['material'], 'Sheet' => s['index'] + 1, 'Part ID' => p['part_id'], 'Part' => p['name'], 'Cabinet' => p['cabinet_label'],
                'X' => p['x'], 'Y' => p['y'], 'Width' => p['w'], 'Height' => p['h'], 'Rotated' => p['rotated'] ? 'yes' : 'no', 'Locked' => p['locked'] ? 'yes' : 'no' }
            end
          end
        end
      end

      def labels
        { 'project' => project_store.name, 'labels' => Manufacturing::Labels.build(project_cabinets, project_name: project_store.name) }
      end

      # Resolves a scanned/pasted QR payload to the live part and cabinet.
      def lookup_part(code)
        parsed = Manufacturing::Labels.parse(code)
        return { 'ok' => false, 'error' => 'Not a CabinetCraft part code' } unless parsed

        cab = project_cabinets.find { |c| c.id == parsed[0] } or return { 'ok' => false, 'error' => 'That cabinet is not in this model' }
        row = cab.part_rows.find { |r| r['key'] == parsed[1] } or return { 'ok' => false, 'error' => "#{cab.label} has no part '#{parsed[1]}' any more" }
        { 'ok' => true, 'cabinet' => cab.summary, 'part' => row, 'hardware' => cab.hardware.select { |h| h['part_key'] == row['key'] } }
      end

      def validate
        cabs = project_cabinets
        nesting = cabs.empty? ? nil : nest
        issues = Validation::Validator.run(cabs, nesting: nesting) + Scene::ModelChecker.run(model)
        issues = issues.sort_by { |i| [i['severity'] == 'error' ? 0 : 1, i['cabinet_label'].to_s, i['code']] }
        { 'issues' => issues, 'summary' => Validation::Validator.summary(issues), 'not_checked' => Validation::Validator::NOT_CHECKED,
          'cabinet_count' => cabs.size }
      end

      # Selects a cabinet, or one of its parts (which opens the cabinet group for editing).
      def select_target(cabinet_id, part_key = nil, entity_id = nil)
        if cabinet_id
          group, cab = Scene::Registry.find(model, cabinet_id)
          return failure('That cabinet no longer exists in the model') unless group

          if part_key
            part = group.entities.grep(::Sketchup::Group).find { |g| g.name == "#{cab.label}-#{part_key.upcase}" }
            if part
              model.active_path = [group]
              model.selection.clear
              model.selection.add(part)
              model.active_view.zoom(part)
              return { 'ok' => true, 'selected' => 'part' }
            end
          end
          model.active_path = nil
          return select(cabinet_id)
        end
        ent = entity_id && model.find_entity_by_id(entity_id)
        return failure('Nothing to select for this item') unless ent

        model.active_path = nil
        model.selection.clear
        model.selection.add(ent)
        { 'ok' => true }
      end

      # --- Machining and CNC ------------------------------------------------------------------------

      def machining_config
        MachiningConfig.current
      end

      def machining_row(o)
        { 'Cabinet' => o['cabinet_label'], 'Part ID' => o['part_id'], 'Kind' => o['kind'], 'Target' => o['target'],
          'Face / edge' => o['target'] == 'face' ? o['side'].to_s.upcase : o['edge'], 'X / along' => o['target'] == 'face' ? o['x'] : o['along'],
          'Y / z' => o['target'] == 'face' ? o['y'] : o['z'], 'Diameter' => o['dia'], 'Depth' => o['through'] ? 'through' : o['depth'],
          'Hardware' => o['hardware_id'], 'Note' => o['note'] }
      end

      def machining_state
        cfg = machining_config
        res = Manufacturing::Machining.for_project(project_cabinets)
        ops = res['ops']
        {
          'settings' => cfg.settings, 'patterns' => cfg.patterns, 'roles' => MachiningConfig::PATTERN_ROLES,
          'machines' => cfg.machines, 'active' => cfg.active_machine_id, 'posts' => Manufacturing::CncPosts.list(cfg.posts),
          'custom_posts' => cfg.posts, 'default_templates' => Manufacturing::CncPosts::DEFAULT_TEMPLATES,
          'template_keys' => Manufacturing::CncPosts::TEMPLATE_KEYS, 'placeholders' => Manufacturing::CncPosts::PLACEHOLDERS,
          'summary' => { 'total' => ops.size, 'face' => ops.count { |o| o['target'] == 'face' }, 'edge' => ops.count { |o| o['target'] == 'edge' },
                         'by_kind' => ops.group_by { |o| o['kind'] }.transform_values(&:size).sort.to_h,
                         'by_cabinet' => ops.group_by { |o| o['cabinet_label'] }.transform_values(&:size).sort.to_h },
          'issues' => res['issues'] + Validation::MachiningChecker.check(ops)
        }
      end

      def set_machining_setting(key, value)
        machining_config.set_setting(key, value)
        machining_state
      end

      def add_pattern(name, role, side, holes)
        machining_config.add_pattern(name: name, role: role, side: side, holes: holes)
        machining_state
      end

      def delete_pattern(id)
        machining_config.delete_pattern(id) or raise ArgumentError, 'Unknown pattern'
        machining_state
      end

      def select_machine(id)
        machining_config.select_machine(id)
        machining_state
      end

      def save_machine(raw)
        machining_config.save_machine(raw)
        machining_state
      end

      def delete_machine(id)
        machining_config.delete_machine(id) or raise ArgumentError, 'Unknown machine'
        machining_state
      end

      def save_post(id, name, templates, extension = 'nc')
        machining_config.save_post(id: id, name: name, templates: templates, extension: extension)
        machining_state
      end

      def delete_post(id)
        machining_config.delete_post(id) or raise ArgumentError, 'Unknown post-processor'
        machining_state
      end

      # Everything that would stop (errors) or qualify (warnings) a CNC export for the active machine.
      def cnc_check(face_up = 'a')
        cabs = project_cabinets
        nest_res = nest
        res = Manufacturing::Machining.for_project(cabs)
        machine = machining_config.machine
        issues = Manufacturing::Cnc.check(nest_res, res['ops'], machine, face_up: face_up)
        issues += Validation::MachiningChecker.check(res['ops']).select { |i| i['severity'] == 'error' }
        issues += nest_res['materials'].flat_map { |m| m['unplaced'].map { |u| { 'severity' => 'error', 'code' => 'nesting_failure', 'message' => "#{u['part_id']} does not fit on a sheet of #{m['material']}" } } }
        errors = issues.count { |i| i['severity'] == 'error' }
        { 'issues' => issues, 'errors' => errors, 'warnings' => issues.size - errors, 'exportable' => errors.zero? && !cabs.empty?, 'machine' => machine }
      end

      def cnc_preview(material, sheet_index = 0)
        nest_res = nest
        m = nest_res['materials'].find { |r| r['material'] == material } || nest_res['materials'].first
        return { 'ok' => false, 'error' => 'Nothing to preview' } unless m

        sh = m['sheets'][sheet_index.to_i] || m['sheets'].first
        return { 'ok' => false, 'error' => 'No sheets' } unless sh

        ops = Manufacturing::Machining.for_project(project_cabinets)['ops'].group_by { |o| o['part_uid'] }
        holes = Manufacturing::Cnc.sheet_holes(sh, ops)
        router = Manufacturing::Cnc.router_tool(machining_config.machine)
        { 'ok' => true, 'material' => m['material'], 'sheet' => sh['index'], 'sheets' => m['sheets'].size, 'holes' => holes.size,
          'svg' => Exporters::SvgExporter.sheet(m, sh, holes, router_diameter: router['diameter']) }
      end

      # One file per nested sheet: <path without extension>_<material>_sheet<N>.<ext>
      def export_sheets(kind, path)
        cabs = project_cabinets
        raise ArgumentError, 'There are no cabinets to export' if cabs.empty?

        nest_res = nest
        res = Manufacturing::Machining.for_project(cabs)
        ops_by_uid = res['ops'].group_by { |o| o['part_uid'] }
        cfg = machining_config
        machine = cfg.machine
        face_up = kind == 'gcode_b' ? 'b' : 'a'
        if kind.start_with?('gcode')
          chk = cnc_check(face_up)
          blockers = chk['issues'].select { |i| i['severity'] == 'error' }
          raise ArgumentError, "G-code was not written - fix these first: #{blockers.first(3).map { |i| i['message'] }.join(' | ')}" unless blockers.empty?
        end
        rows = Manufacturing::PartsList.build(cabs)
        base = path.sub(/\.[^.\/\\]+\z/, '')
        ext = kind.start_with?('gcode') ? Manufacturing::CncPosts.extension(machine['post'], cfg.posts) : kind
        written = []
        nest_res['materials'].each do |m|
          slug = m['material'].downcase.gsub(/[^a-z0-9]+/, '-').gsub(/\A-|-\z/, '')
          thickness = rows.find { |r| r['material'] == m['material'] }['thickness']
          sheets = m['sheets'].reject { |s| s['placements'].empty? }
          if kind.start_with?('gcode')
            Manufacturing::Cnc.build(m, ops_by_uid, machine, thickness, face_up: face_up).each do |prog|
              text = Manufacturing::Cnc.render(prog, machine, cfg.posts, name: project_store.name)
              written << write_text("#{base}_#{slug}_sheet#{prog['index'] + 1}#{face_up == 'b' ? '_underside' : ''}.#{ext}", text)
            end
          else
            sheets.each do |sh|
              holes = Manufacturing::Cnc.sheet_holes(sh, ops_by_uid)
              text = if kind == 'dxf'
                       Exporters::DxfExporter.sheet(m, sh, holes)
                     else
                       Exporters::SvgExporter.sheet(m, sh, holes, router_diameter: Manufacturing::Cnc.router_tool(machine)['diameter'])
                     end
              written << write_text("#{base}_#{slug}_sheet#{sh['index'] + 1}.#{ext}", text)
            end
          end
        end
        raise ArgumentError, 'Nothing to write for this export' if written.empty?

        { 'ok' => true, 'paths' => written, 'path' => written.first, 'count' => written.size }
      end

      def write_text(file, text)
        File.binwrite(file, text.encode('UTF-8'))
        file
      end

      # --- Hardware library and rules ---------------------------------------------------

      def hardware_state
        cfg = Hardware.config
        {
          'library' => Hardware.all.map { |h| h.to_h.merge('price' => Hardware.price_of(h.id)) }, 'categories' => Hardware::CATEGORIES,
          'hinge_rules' => cfg.hinge_rules, 'settings' => cfg.settings, 'schema' => Parameter.schema
        }
      end

      def add_hardware(name, category, price = nil, supplier = nil)
        Hardware.config.add_custom(name: name, category: category, price: price, supplier: supplier)
        hardware_state
      end

      # Refuses to delete hardware that cabinets in the model still reference.
      def delete_hardware(id)
        used = Scene::Registry.cabinets(model).select { |_, c| c.params.values.include?(id) }.map { |_, c| c.label }
        raise ArgumentError, "In use by #{used.join(', ')} - change those cabinets first" unless used.empty?

        Hardware.config.delete_custom(id) or raise ArgumentError, 'Only custom hardware can be deleted'
        hardware_state
      end

      def set_hinge_rules(rows)
        Hardware.config.hinge_rules = rows
        hardware_state
      end

      def set_hardware_setting(key, value)
        Hardware.config.set_setting(key, value)
        hardware_state
      end

      def select(cabinet_id)
        group, = Scene::Registry.find(model, cabinet_id)
        return failure('That cabinet no longer exists in the model') unless group

        model.selection.clear
        model.selection.add(group)
        model.active_view.zoom(group)
        { 'ok' => true }
      end

      # Cabinet summary if exactly one cabinet is selected, else nil.
      def selected_summary
        sel = model.selection
        return nil unless sel.length == 1 && Scene::Attributes.cabinet?(sel.first)

        Scene::Attributes.read_cabinet(sel.first)&.summary
      end

      private

      def failure(message)
        { 'ok' => false, 'issues' => [{ 'severity' => 'error', 'key' => nil, 'message' => message }] }
      end

      # Copies of a cabinet share its id; give each copy its own identity and
      # rebuild so its parts carry the new cabinet id.
      def reidentify_duplicates
        Scene::Registry.duplicates(model).each do |group, cab|
          fixed = cab.with_identity(id: SecureRandom.uuid, label: Scene::Registry.next_label(model))
          Generators::CabinetGenerator.rebuild(group, fixed)
        end
      end

      def in_operation(name, reidentify: true)
        model.start_operation(name, true)
        reidentify_duplicates if reidentify
        yield
        model.commit_operation
      rescue StandardError
        model.abort_operation
        raise
      end
    end
  end
end
