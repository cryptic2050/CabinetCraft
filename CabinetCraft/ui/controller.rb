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
require_relative '../exporters/label_html'
require_relative '../validation/validator'
require_relative '../scene/registry'
require_relative '../scene/project_store'
require_relative '../scene/model_checker'

module CabinetCraft
  module Interface
    # UI-independent command layer. The dialog forwards JSON calls here; tests
    # call it directly. Every public method returns a JSON-safe Hash.
    class Controller
      PUBLIC_METHODS = %w[bootstrap preview create update select list parts_list cutting_list hardware_state
                          add_hardware delete_hardware set_hinge_rules set_hardware_setting
                          project_state set_project_name nest nest_lock nest_lock_current nest_unlock nest_unlock_all
                          labels lookup_part validate select_target].freeze

      # kind => [formats]. 'project' is JSON only.
      EXPORTS = { 'parts' => %w[csv excel_csv json], 'cutting_list' => %w[csv excel_csv json],
                  'hardware' => %w[csv excel_csv json], 'project' => %w[json],
                  'nesting' => %w[csv excel_csv json], 'labels' => %w[html csv excel_csv json] }.freeze
      EXTENSIONS = { 'csv' => 'csv', 'excel_csv' => 'csv', 'json' => 'json', 'html' => 'html' }.freeze

      def model
        ::Sketchup.active_model
      end

      def bootstrap
        {
          'version' => defined?(CabinetCraft::VERSION) ? CabinetCraft::VERSION : 'dev',
          'library' => Library::ENTRIES,
          'planned' => Library::PLANNED,
          'schema' => Parameter.schema,
          'materials' => Material.all.map(&:to_h),
          'profiles' => Construction.list,
          'cabinets' => list['cabinets'],
          'selected' => selected_summary
        }
      end

      def list
        { 'cabinets' => Scene::Registry.cabinets(model).map { |_, c| c.summary } }
      end

      # Pure calculation: no model changes. Drives the live panel table.
      def preview(type, raw, label = nil)
        Library.entry(type) or return failure("Unknown cabinet type '#{type}'")
        # Preset defaults sit under whatever the caller supplies.
        params, errors = Parameter.coerce(Library.defaults_for(type).merge((raw || {}).transform_keys(&:to_s)))
        return { 'ok' => false, 'params' => params, 'issues' => errors, 'panels' => [], 'values' => {} } unless errors.empty?

        cab = Cabinet.build(type: type, params: params, label: label || Scene::Registry.next_label(model))
        issues = cab.calculation.issues.map(&:to_h)
        ok = cab.calculation.ok?
        issues += cab.hardware_issues if ok
        {
          'ok' => ok, 'params' => params, 'issues' => issues, 'values' => cab.calculation.values,
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
        end
        prev.merge('created' => true, 'cabinet' => cabinet.summary, 'panels' => cabinet.part_rows)
      end

      # Regenerates only the one cabinet that changed.
      def update(cabinet_id, raw)
        group, current = Scene::Registry.find(model, cabinet_id)
        return failure('That cabinet no longer exists in the model') unless group

        prev = preview(current.type, raw, current.label)
        return prev.merge('updated' => false) unless prev['ok']
        return prev.merge('updated' => false, 'cabinet' => current.summary) if prev['params'] == current.params

        updated = current.with_params(prev['params'])
        in_operation('CabinetCraft: Edit cabinet') do
          Generators::CabinetGenerator.rebuild(group, updated)
        end
        prev.merge('updated' => true, 'cabinet' => updated.summary, 'panels' => updated.part_rows)
      end

      # --- Reports: derived from every cabinet in the model, never stored ---------------

      def project_cabinets
        Scene::Registry.cabinets(model).map(&:last)
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

        content = render_export(kind, format)
        File.binwrite(path, content.encode('UTF-8'))
        { 'ok' => true, 'path' => path, 'bytes' => content.bytesize }
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
        store = project_store
        if settings && !settings.empty?
          clean = Manufacturing::Nesting.normalize_settings(settings)
          in_operation('CabinetCraft: Nesting settings', reidentify: false) { store.nest_settings = clean }
        end
        cfg = Manufacturing::Nesting.normalize_settings(store.nest_settings)
        rows = Manufacturing::PartsList.build(project_cabinets)
        locks = store.locks
        materials = rows.group_by { |r| r['material'] }.sort_by(&:first).map do |label, mrows|
          mat = Material.exist?(mrows.first['material_id']) ? Material.fetch(mrows.first['material_id']) : nil
          sheet = { 'material' => label, 'grain_free' => mat.nil? || mat.grain == :none,
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

      # --- Hardware library and rules ---------------------------------------------------

      def hardware_state
        cfg = Hardware.config
        {
          'library' => Hardware.all.map(&:to_h), 'categories' => Hardware::CATEGORIES,
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
