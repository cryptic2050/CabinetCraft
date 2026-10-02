# frozen_string_literal: true

module CabinetCraft
  module Scene
    # Persists plugin settings (custom hardware, hinge rules) in SketchUp's
    # per-user defaults (registry on Windows, plist on macOS). Shared by all models.
    class SettingsStore
      SECTION = 'CabinetCraftPro'

      def initialize(key = 'hardware_config')
        @key = key
      end

      def read
        ::Sketchup.read_default(SECTION, @key, nil)
      end

      def write(json)
        ::Sketchup.write_default(SECTION, @key, json)
      end
    end
  end
end
