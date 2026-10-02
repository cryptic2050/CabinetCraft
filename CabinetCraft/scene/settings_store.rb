# frozen_string_literal: true

module CabinetCraft
  module Scene
    # Persists plugin settings (custom hardware, hinge rules) in SketchUp's
    # per-user defaults (registry on Windows, plist on macOS). Shared by all models.
    class SettingsStore
      SECTION = 'CabinetCraftPro'
      KEY = 'hardware_config'

      def read
        ::Sketchup.read_default(SECTION, KEY, nil)
      end

      def write(json)
        ::Sketchup.write_default(SECTION, KEY, json)
      end
    end
  end
end
