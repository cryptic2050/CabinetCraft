# frozen_string_literal: true

require 'json'

module CabinetCraft
  module Scene
    # Project-level data stored inside the .skp (model attributes), so nesting
    # settings and locked part positions travel with the model.
    class ProjectStore
      DICT = 'CabinetCraft_Project'

      def initialize(model)
        @model = model
      end

      def name
        v = @model.get_attribute(DICT, 'project_name', nil).to_s.strip
        return v unless v.empty?

        t = @model.respond_to?(:title) ? @model.title.to_s.strip : ''
        t.empty? ? 'Untitled project' : t
      end

      def name=(value)
        @model.set_attribute(DICT, 'project_name', value.to_s.strip[0, 80])
      end

      def nest_settings
        read_json('nest_settings')
      end

      def nest_settings=(hash)
        @model.set_attribute(DICT, 'nest_settings', JSON.generate(hash))
      end

      # { part_uid => { 'sheet', 'x', 'y', 'rotated', 'sig' } }
      def locks
        read_json('nest_locks')
      end

      def locks=(hash)
        @model.set_attribute(DICT, 'nest_locks', JSON.generate(hash))
      end

      # Custom materials (and built-in overrides) used by this model, so it opens correctly on another machine.
      def materials_snapshot
        read_json('materials_snapshot')
      end

      def materials_snapshot=(hash)
        @model.set_attribute(DICT, 'materials_snapshot', JSON.generate(hash))
      end

      # User templates / presets used by this model, so it opens correctly on another machine.
      def templates_snapshot
        read_json('templates_snapshot')
      end

      def templates_snapshot=(hash)
        @model.set_attribute(DICT, 'templates_snapshot', JSON.generate(hash))
      end

      # Custom hardware, unit prices and placement rules used by this model, so it opens correctly on another machine.
      def hardware_snapshot
        read_json('hardware_snapshot')
      end

      def hardware_snapshot=(hash)
        @model.set_attribute(DICT, 'hardware_snapshot', JSON.generate(hash))
      end

      # Costing inputs are per project (prices change quote by quote).
      def cost_settings
        read_json('cost_settings')
      end

      def cost_settings=(hash)
        @model.set_attribute(DICT, 'cost_settings', JSON.generate(hash))
      end

      # Linked runs: { run_id => run hash } (see Run). Untrusted data: unreadable entries are skipped by the caller.
      def runs
        read_json('runs')
      end

      def runs=(hash)
        @model.set_attribute(DICT, 'runs', JSON.generate(hash))
      end

      # The active visualization mode (see Manufacturing::Visualization); 'material' when unset.
      # { part_uid => 'A1' } matching-grain sets (Manufacturing::GrainSets)
      def grain_sets
        read_json('grain_sets')
      end

      def grain_sets=(hash)
        @model.set_attribute(DICT, 'grain_sets', JSON.generate(hash))
      end

      def viz_mode
        @model.get_attribute(DICT, 'viz_mode', nil).to_s
      end

      def viz_mode=(value)
        @model.set_attribute(DICT, 'viz_mode', value.to_s)
      end

      # Production progress: { part_uid => { 'sig' => size, 'stages' => { stage => iso time } } } (see Manufacturing::Production).
      def production
        read_json('production')
      end

      def production=(hash)
        @model.set_attribute(DICT, 'production', JSON.generate(hash))
      end

      # Corner layouts: { layout_id => layout hash } (see CornerLayout::Record).
      def layouts
        read_json('layouts')
      end

      def layouts=(hash)
        @model.set_attribute(DICT, 'layouts', JSON.generate(hash))
      end

      private

      def read_json(key)
        raw = @model.get_attribute(DICT, key, nil)
        raw.to_s.empty? ? {} : JSON.parse(raw)
      rescue JSON::ParserError
        {} # corrupt data must never block the plugin
      end
    end
  end
end
