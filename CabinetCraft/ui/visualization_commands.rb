# frozen_string_literal: true

require_relative '../scene/visualization'
require_relative '../scene/door_swing'
require_relative '../manufacturing/grain_sets'

module CabinetCraft
  module Interface
    # Visualization and presentation modes (see Manufacturing::Visualization). Mixed into Controller.
    module VisualizationCommands
      def visualization_state
        mode = current_visualization_mode
        assignment = build_visualization(mode)
        { 'modes' => Manufacturing::Visualization::MODES, 'mode' => mode, 'legend' => assignment['legend'], 'parts' => assignment['parts'].size }
      end

      # Colours the parts of every cabinet in the model. One undo step; 'material' puts the real materials back.
      def set_visualization(mode)
        raise ArgumentError, "Unknown visualization mode '#{mode}'" unless Manufacturing::Visualization::MODES.key?(mode)

        in_operation('CabinetCraft: Visualization', reidentify: false) do
          project_store.viz_mode = mode
          Scene::Visualization.apply(model, build_visualization(mode))
        end
        visualization_state
      end

      # Opens or closes the doors of the given cabinets (all cabinets when none are given), one undo step.
      # `open` nil toggles: if any door is open everything closes, otherwise everything opens.
      def toggle_doors(cabinet_ids = nil, angle = nil, open = nil)
        entries = Scene::Registry.entries(model)
        ids = Array(cabinet_ids).map(&:to_s)
        entries = entries.select { |e| ids.include?(e.cabinet.id) } unless ids.empty?
        entries = entries.select { |e| e.cabinet.calculation.ok? && e.cabinet.panels.any? { |p| p.role == :door } }
        return { 'ok' => false, 'error' => 'No cabinet with doors to open' } if entries.empty?

        deg = angle.nil? || angle.to_s.empty? ? Scene::DoorSwing::DEFAULT_ANGLE : Float(angle)
        raise ArgumentError, "Door angle must be between 0 and #{Scene::DoorSwing::MAX_ANGLE.round} degrees" unless deg.between?(0, Scene::DoorSwing::MAX_ANGLE)

        opening = open.nil? ? entries.none? { |e| Scene::DoorSwing.open?(e.entity) } : open ? true : false
        moved = 0
        in_operation(opening ? 'CabinetCraft: Open doors' : 'CabinetCraft: Close doors', reidentify: false) do
          entries.each { |e| moved += Scene::DoorSwing.set(e.entity, e.cabinet, opening ? deg : 0) }
        end
        { 'ok' => true, 'open' => opening, 'doors_moved' => moved, 'cabinets' => entries.size }
      end

      def doors_state
        entries = Scene::Registry.entries(model).select { |e| e.cabinet.calculation.ok? && e.cabinet.panels.any? { |p| p.role == :door } }
        { 'cabinets' => entries.size, 'open' => entries.count { |e| Scene::DoorSwing.open?(e.entity) }, 'default_angle' => Scene::DoorSwing::DEFAULT_ANGLE }
      end

      # --- Matching-grain sets ------------------------------------------------------------------------------------------
      def grain_sets_state
        map = current_grain_sets
        names = part_names_by_uid
        sets = Manufacturing::GrainSets.sets_of(map).map do |set, uids|
          { 'set' => set, 'parts' => uids.map { |u| { 'uid' => u, 'label' => map[u], 'part_id' => names[u] } } }
        end
        { 'sets' => sets, 'parts' => map.size }
      end

      # Puts the given parts (part uids, in pick order) into one new matching-grain set.
      def assign_grain_set(uids)
        valid = part_names_by_uid.keys
        list = Array(uids).map(&:to_s)
        unknown = list - valid
        raise ArgumentError, "Unknown part: #{unknown.first}" unless unknown.empty?

        in_operation('CabinetCraft: Matching-grain set', reidentify: false) do
          project_store.grain_sets = Manufacturing::GrainSets.assign(current_grain_sets, list)
          refresh_visualization
        end
        grain_sets_state
      end

      # Same, from the parts currently selected in the model (in selection order).
      def assign_selected_grain_set
        uids = model.selection.to_a.filter_map do |e|
          Scene::Containers.container?(e) ? e.get_attribute(Scene::PART_DICT, 'part_uid') : nil
        end.reject { |u| u.to_s.empty? }
        raise ArgumentError, 'Select two or more cabinet parts in the model first (open a cabinet and click the parts)' if uids.size < 2

        assign_grain_set(uids)
      end

      def clear_grain_sets
        in_operation('CabinetCraft: Clear matching-grain sets', reidentify: false) do
          project_store.grain_sets = {}
          refresh_visualization
        end
        grain_sets_state
      end

      # Label positions (SketchUp inches, world space) for the click tool to draw: [{ 'label', 'x', 'y', 'z' }].
      def grain_set_labels
        map = current_grain_sets
        return [] if map.empty?

        Scene::Registry.entries(model).flat_map do |e|
          chain = e.path + [e.entity]
          Scene::Containers.child_groups(e.entity).filter_map do |part|
            label = map[part.get_attribute(Scene::PART_DICT, 'part_uid')] or next
            b = part.bounds
            pt = ::Geom::Point3d.new((b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2, (b.min.z + b.max.z) / 2)
            pt = chain.reverse.reduce(pt) { |p, anc| p.transform(anc.transformation) }
            { 'label' => label, 'x' => pt.x, 'y' => pt.y, 'z' => pt.z }
          end
        end
      end

      # Called inside an operation after geometry was regenerated or production changed: new part groups get the active mode's colours.
      def refresh_visualization
        mode = current_visualization_mode
        return if mode == 'material'

        Scene::Visualization.apply(model, build_visualization(mode))
      end

      private

      def part_names_by_uid
        Scene::Registry.entries(model).flat_map { |e| e.cabinet.part_rows.map { |r| [r['part_uid'], r['part_id']] } }.to_h
      end

      def current_grain_sets
        Manufacturing::GrainSets.clean(project_store.grain_sets, part_names_by_uid.keys)
      end

      def current_visualization_mode
        m = project_store.viz_mode
        Manufacturing::Visualization::MODES.key?(m) ? m : 'material'
      end

      def build_visualization(mode)
        cabs = Scene::Registry.entries(model).map(&:cabinet)
        _, ops = production_inputs
        Manufacturing::Visualization.assign(mode, cabs, production: project_store.production, ops_by_uid: ops, grain_sets: current_grain_sets)
      end
    end
  end
end
