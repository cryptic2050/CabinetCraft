# frozen_string_literal: true

require_relative '../scene/visualization'
require_relative '../scene/door_swing'

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

      # Called inside an operation after geometry was regenerated or production changed: new part groups get the active mode's colours.
      def refresh_visualization
        mode = current_visualization_mode
        return if mode == 'material'

        Scene::Visualization.apply(model, build_visualization(mode))
      end

      private

      def current_visualization_mode
        m = project_store.viz_mode
        Manufacturing::Visualization::MODES.key?(m) ? m : 'material'
      end

      def build_visualization(mode)
        cabs = Scene::Registry.entries(model).map(&:cabinet)
        _, ops = production_inputs
        Manufacturing::Visualization.assign(mode, cabs, production: project_store.production, ops_by_uid: ops)
      end
    end
  end
end
