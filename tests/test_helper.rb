# frozen_string_literal: true

require 'minitest/autorun'

module CabinetCraft
  PLUGIN_ROOT = File.expand_path('../CabinetCraft', __dir__)
end

%w[core/units core/material core/construction core/parameter core/rules core/panel
   generators/panel_generator core/cabinet core/library core/material_config core/overrides templates/expression templates/template templates/examples templates/registry core/library core/hardware core/hardware_rules core/standards core/edge_banding manufacturing/cut_sequence manufacturing/nesting manufacturing/labels exporters/label_html validation/validator manufacturing/parts_list manufacturing/cutting_list exporters/csv_exporter exporters/json_exporter
   exporters/dxf_exporter exporters/svg_exporter exporters/pdf_writer exporters/pdf_reports core/machining_config manufacturing/cnc_posts manufacturing/machining manufacturing/cnc manufacturing/costing manufacturing/assembly exporters/assembly_svg validation/machining_checker].each do |f|
  require File.join(CabinetCraft::PLUGIN_ROOT, f)
end

# Every test starts from factory settings: global configuration never leaks between tests.
module ResetGlobals
  def before_setup
    super
    CabinetCraft::Hardware.config = CabinetCraft::Hardware::Config.new
    CabinetCraft::Material.config = CabinetCraft::MaterialConfig.new
    CabinetCraft::Templates.config = CabinetCraft::Templates::Config.new
    CabinetCraft::Standards.current = CabinetCraft::Standards.new
    CabinetCraft::MachiningConfig.current = CabinetCraft::MachiningConfig.new
  end
end
Minitest::Test.prepend ResetGlobals

module TestParams
  def params(overrides = {})
    p, errors = CabinetCraft::Parameter.coerce(CabinetCraft::Parameter.defaults.merge(overrides.transform_keys(&:to_s)))
    raise "bad test params: #{errors}" unless errors.empty?

    p
  end

  def calc(overrides = {})
    CabinetCraft::Rules.compute(params(overrides))
  end

  def panels_for(overrides = {})
    pr = params(overrides)
    r = CabinetCraft::Rules.compute(pr)
    CabinetCraft::Generators::PanelGenerator.generate(pr, r.values)
  end
end
