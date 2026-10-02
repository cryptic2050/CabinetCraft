# frozen_string_literal: true

# CabinetCraft Pro - extension loader.
# Install: copy this file AND the CabinetCraft/ folder into SketchUp's Plugins folder.

require 'sketchup.rb'
require 'extensions.rb'

module CabinetCraft
  VERSION = '0.1.0'
  PLUGIN_ROOT = File.join(File.dirname(__FILE__), 'CabinetCraft').freeze

  # UI::HtmlDialog (the whole interface) exists from SketchUp 2017.
  MIN_SKETCHUP = 17

  if Sketchup.version.to_i < MIN_SKETCHUP
    UI.messagebox("CabinetCraft Pro needs SketchUp 20#{MIN_SKETCHUP} or newer (this is #{Sketchup.version}). It was not loaded.") unless file_loaded?(__FILE__)
    file_loaded(__FILE__)
  elsif !file_loaded?(__FILE__)
    ex = SketchupExtension.new('CabinetCraft Pro', File.join('CabinetCraft', 'main'))
    ex.description = 'Parametric cabinet design to manufacturing data inside SketchUp.'
    ex.version = VERSION
    ex.creator = 'CabinetCraft'
    ex.copyright = '2026'
    Sketchup.register_extension(ex, true)
    file_loaded(__FILE__)
  end
end
