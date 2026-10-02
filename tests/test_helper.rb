# frozen_string_literal: true

require 'minitest/autorun'

module CabinetCraft
  PLUGIN_ROOT = File.expand_path('../CabinetCraft', __dir__)
end

%w[core/units core/material core/construction core/parameter core/rules core/panel
   generators/panel_generator core/cabinet core/library core/hardware core/hardware_rules core/edge_banding manufacturing/parts_list manufacturing/cutting_list exporters/csv_exporter exporters/json_exporter].each do |f|
  require File.join(CabinetCraft::PLUGIN_ROOT, f)
end

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
