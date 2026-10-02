# frozen_string_literal: true

# CabinetCraft Pro - extension loader.
# Install: copy this file AND the CabinetCraft/ folder into SketchUp's Plugins folder.

require 'sketchup.rb'
require 'extensions.rb'

module CabinetCraft
  VERSION = '0.1.0'
  PLUGIN_ROOT = File.join(File.dirname(__FILE__), 'CabinetCraft').freeze

  unless file_loaded?(__FILE__)
    ex = SketchupExtension.new('CabinetCraft Pro', File.join('CabinetCraft', 'main'))
    ex.description = 'Parametric cabinet design to manufacturing data inside SketchUp.'
    ex.version = VERSION
    ex.creator = 'CabinetCraft'
    ex.copyright = '2026'
    Sketchup.register_extension(ex, true)
    file_loaded(__FILE__)
  end
end
