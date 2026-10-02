# frozen_string_literal: true

require 'sketchup.rb'

%w[
  core/units core/material core/construction core/parameter core/rules core/panel core/cabinet core/library
  generators/panel_generator generators/cabinet_generator
  scene/attributes scene/registry
  ui/controller ui/dialog
].each { |f| require File.join(CabinetCraft::PLUGIN_ROOT, f) }

module CabinetCraft
  unless file_loaded?(__FILE__)
    open_cmd = ::UI::Command.new('CabinetCraft Pro') { Interface::Dashboard.show }
    open_cmd.tooltip = 'Open CabinetCraft Pro'
    open_cmd.status_bar_text = 'Parametric cabinet design and manufacturing data'
    open_cmd.small_icon = File.join(PLUGIN_ROOT, 'resources', 'cabinet.svg')
    open_cmd.large_icon = File.join(PLUGIN_ROOT, 'resources', 'cabinet.svg')

    ::UI.menu('Extensions').add_submenu('CabinetCraft Pro').add_item(open_cmd)

    toolbar = ::UI::Toolbar.new('CabinetCraft Pro')
    toolbar.add_item(open_cmd)
    toolbar.restore

    file_loaded(__FILE__)
  end
end
