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
require_relative '../scene/registry'

module CabinetCraft
  module Interface
    # UI-independent command layer. The dialog forwards JSON calls here; tests
    # call it directly. Every public method returns a JSON-safe Hash.
    class Controller
      PUBLIC_METHODS = %w[bootstrap preview create update select list parts_list cutting_list hardware_state
                          add_hardware delete_hardware set_hinge_rules set_hardware_setting].freeze

      # kind => [formats]. 'project' is JSON only.
      EXPORTS = { 'parts' => %w[csv excel_csv json], 'cutting_list' => %w[csv excel_csv json],
                  'hardware' => %w[csv excel_csv json], 'project' => %w[json] }.freeze
      EXTENSIONS = { 'csv' => 'csv', 'excel_csv' => 'csv', 'json' => 'json' }.freeze

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
        when 'hardware'
          list = Manufacturing::CuttingList.hardware(cabs)
          rows = list.map { |h| { 'Hardware' => h['name'], 'Category' => h['category'], 'Qty' => h['qty'] } }
          format == 'json' ? Exporters::JsonExporter.data(list) : csv.call(rows, %w[Hardware Category Qty].map { |k| [k, k] })
        end
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
