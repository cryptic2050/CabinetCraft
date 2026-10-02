# frozen_string_literal: true

require_relative '../scene/visualization'

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
