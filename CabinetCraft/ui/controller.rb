# frozen_string_literal: true

require 'securerandom'
require_relative '../core/units'
require_relative '../core/parameter'
require_relative '../core/library'
require_relative '../core/material'
require_relative '../core/construction'
require_relative '../core/cabinet'
require_relative '../generators/cabinet_generator'
require_relative '../scene/registry'

module CabinetCraft
  module Interface
    # UI-independent command layer. The dialog forwards JSON calls here; tests
    # call it directly. Every public method returns a JSON-safe Hash.
    class Controller
      PUBLIC_METHODS = %w[bootstrap preview create update select list].freeze

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
        entry = Library.entry(type) or return failure("Unknown cabinet type '#{type}'")
        _ = entry
        params, errors = Parameter.coerce(raw)
        return { 'ok' => false, 'params' => params, 'issues' => errors, 'panels' => [], 'values' => {} } unless errors.empty?

        cab = Cabinet.build(type: type, params: params, label: label || Scene::Registry.next_label(model))
        issues = cab.calculation.issues.map(&:to_h)
        {
          'ok' => cab.calculation.ok?, 'params' => params, 'issues' => issues,
          'values' => cab.calculation.values, 'panels' => cab.calculation.ok? ? cab.part_rows : []
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
