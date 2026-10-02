# frozen_string_literal: true

require 'sketchup.rb'

%w[
  core/units core/material core/construction core/hardware core/parameter core/rules core/edge_banding core/panel
  core/hardware_rules core/cabinet core/library
  generators/panel_generator generators/cabinet_generator
  manufacturing/parts_list manufacturing/cutting_list manufacturing/cut_sequence manufacturing/nesting manufacturing/labels
  exporters/csv_exporter exporters/json_exporter exporters/label_html utilities/qr_code
  core/machining_config manufacturing/cnc_posts manufacturing/machining manufacturing/cnc
  exporters/dxf_exporter exporters/svg_exporter
  validation/collision_checker validation/machining_checker validation/validator
  scene/attributes scene/registry scene/settings_store scene/project_store scene/model_checker
  ui/controller ui/dialog
].each { |f| require File.join(CabinetCraft::PLUGIN_ROOT, f) }

module CabinetCraft
  Hardware.config = Hardware::Config.new(Scene::SettingsStore.new('hardware_config'))
  MachiningConfig.current = MachiningConfig.new(Scene::SettingsStore.new('machining_config'))

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
