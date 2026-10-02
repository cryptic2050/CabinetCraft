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
