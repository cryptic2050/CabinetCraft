# frozen_string_literal: true

require 'sketchup.rb'

%w[
  core/units core/material core/material_config core/construction core/hardware core/parameter core/rules core/edge_banding core/panel core/overrides
  templates/expression templates/template templates/examples templates/registry
  core/run_planner core/run core/corner_layout core/hardware_rules core/standards core/library core/cabinet
  generators/panel_generator generators/cabinet_generator
  manufacturing/parts_list manufacturing/cutting_list manufacturing/cut_sequence manufacturing/nesting manufacturing/labels
  exporters/csv_exporter exporters/json_exporter exporters/label_html utilities/qr_code
  core/machining_config manufacturing/cnc_posts manufacturing/machining manufacturing/cnc manufacturing/costing manufacturing/dashboard manufacturing/production manufacturing/visualization manufacturing/assembly exporters/assembly_svg
  exporters/dxf_exporter exporters/svg_exporter exporters/pdf_writer exporters/pdf_reports
  validation/collision_checker validation/machining_checker validation/validator
  scene/containers scene/attributes scene/registry scene/settings_store scene/project_store scene/explode scene/visualization scene/model_checker
  utilities/self_test ui/layout_commands ui/overview_commands ui/production_commands ui/visualization_commands ui/run_edit_commands ui/controller ui/dialog
].each { |f| require File.join(CabinetCraft::PLUGIN_ROOT, f) }

module CabinetCraft
  Hardware.config = Hardware::Config.new(Scene::SettingsStore.new('hardware_config'))
  Material.config = MaterialConfig.new(Scene::SettingsStore.new('materials_config'))
  MachiningConfig.current = MachiningConfig.new(Scene::SettingsStore.new('machining_config'))
  Templates.config = Templates::Config.new(Scene::SettingsStore.new('templates_config'))
  Standards.current = Standards.new(Scene::SettingsStore.new('standards_config'))

  unless file_loaded?(__FILE__)
    open_cmd = ::UI::Command.new('CabinetCraft Pro') { Interface::Dashboard.show }
    open_cmd.tooltip = 'Open CabinetCraft Pro'
    open_cmd.status_bar_text = 'Parametric cabinet design and manufacturing data'
    # SVG icons need SketchUp 2016+; older versions get the PNGs.
    svg_ok = ::Sketchup.version.to_i >= 16
    open_cmd.small_icon = File.join(PLUGIN_ROOT, 'resources', svg_ok ? 'cabinet.svg' : 'cabinet_16.png')
    open_cmd.large_icon = File.join(PLUGIN_ROOT, 'resources', svg_ok ? 'cabinet.svg' : 'cabinet_24.png')

    sub = ::UI.menu('Extensions').add_submenu('CabinetCraft Pro')
    sub.add_item(open_cmd)
    sub.add_item('Run self test') { Interface::Dashboard.show_self_test }

    toolbar = ::UI::Toolbar.new('CabinetCraft Pro')
    toolbar.add_item(open_cmd)
    toolbar.restore

    file_loaded(__FILE__)
  end
end
