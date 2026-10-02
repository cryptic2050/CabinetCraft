# frozen_string_literal: true

module CabinetCraft
  # Construction profiles are pure data: the constants the rule engine needs to
  # turn overall cabinet dimensions into panel dimensions. Nothing in the rule
  # engine hard-codes these values, so a company standard (Phase 6) is just
  # another profile.
  #
  # All values are millimetres unless noted.
  #
  #   side_height_deduction  nil => side height = H - bottom thickness
  #                          (sides stand on the full-width bottom panel).
  #   groove_depth           depth of the back-panel groove cut into each side.
  #   back_setback           distance from the cabinet's rear edge to the back
  #                          panel's rear face.
  #   back_top_deduction     back panel height = side height - bottom thickness
  #                          - this value.
  #   brace_count            1 = front rail only, 2 = front + rear rails.
  #   shelf_front_setback    shelf front edge set back from the cabinet front.
  #   shelf_rear_clearance   minimum space between shelf rear edge and cabinet
  #                          rear; auto-increased if the back panel needs more.
  #   shelf_side_clearance   clearance per side between shelf and sides.
  #   min_shelf_gap          smallest allowed vertical opening between panels.
  module Construction
    PROFILES = {
      'standard' => {
        name: 'Standard (sides on bottom)',
        description: 'Self-consistent stack: sides stand on the full-width bottom, ' \
                     'overall height = bottom + sides. Two rails, 8mm back groove.',
        side_height_deduction: nil,
        groove_depth: 8.0,
        back_setback: 10.0,
        back_top_deduction: 10.0,
        brace_count: 2,
        shelf_front_setback: 20.0,
        shelf_rear_clearance: 20.0,
        shelf_side_clearance: 0.0,
        min_shelf_gap: 30.0
      }.freeze,
      'spec_example' => {
        name: 'Specification example (757 -> 742)',
        description: 'Reproduces the dimensions in the product brief: 600x757x562 gives ' \
                     'sides 742, back 581x695, brace 564x100. NOTE: this stack is 3mm taller ' \
                     'than the overall height (18 + 742 = 760); the engine reports that.',
        side_height_deduction: 15.0,
        groove_depth: 8.5,
        back_setback: 10.0,
        back_top_deduction: 29.0,
        brace_count: 1,
        shelf_front_setback: 20.0,
        shelf_rear_clearance: 20.0,
        shelf_side_clearance: 0.0,
        min_shelf_gap: 30.0
      }.freeze
    }.freeze

    DEFAULT = 'standard'

    module_function

    def fetch(id)
      PROFILES.fetch(id) { raise KeyError, "Unknown construction profile '#{id}'" }
    end

    def exist?(id)
      PROFILES.key?(id)
    end

    def list
      PROFILES.map { |id, p| { 'id' => id, 'name' => p[:name], 'description' => p[:description] } }
    end
  end
end
