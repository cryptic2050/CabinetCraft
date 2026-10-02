# frozen_string_literal: true

require_relative 'parameter'

module CabinetCraft
  # Cabinet type library. Only types with a working generator are in ENTRIES;
  # everything else is listed in PLANNED so the UI can show the roadmap without
  # offering buttons that do nothing.
  module Library
    ENTRIES = [
      {
        'type' => 'base_cabinet',
        'category' => 'BASE CABINETS',
        'name' => 'Base cabinet',
        'description' => 'Carcass with bottom, two sides, back, rails and adjustable-count shelves. ' \
                         'Doors, drawers and toe kick are added in Phase 2.',
        'defaults' => { 'width' => 600.0, 'height' => 757.0, 'depth' => 562.0 }
      }
    ].freeze

    PLANNED = {
      'BASE CABINETS' => ['Single-door base (3D fronts)', 'Double-door base', 'Drawer cabinet', '3-drawer cabinet',
                          '4-drawer cabinet', 'Sink cabinet', 'Oven cabinet', 'Hob cabinet', 'Dishwasher cabinet',
                          'Corner base cabinet', 'Blind corner cabinet', 'Pull-out cabinet', 'Bottle cabinet',
                          'Appliance cabinet'],
      'WALL CABINETS' => ['Single-door wall', 'Double-door wall', 'Lift-up wall', 'Open wall', 'Corner wall'],
      'TALL CABINETS' => ['Pantry', 'Oven tower', 'Microwave tower', 'Refrigerator housing', 'Utility cabinet',
                          'Tall drawer cabinet'],
      'WARDROBES' => ['2-door wardrobe', '3-door wardrobe', 'Sliding wardrobe', 'Hinged wardrobe', 'Open wardrobe',
                      'Wardrobe with drawers', 'Hanging section', 'Shelf section', 'Walk-in modules'],
      'VANITIES' => ['Single vanity', 'Double vanity', 'Drawer vanity', 'Open vanity'],
      'TV UNITS' => ['Floating TV unit', 'Full-height TV wall', 'Base TV cabinet', 'Open shelf TV unit'],
      'CUSTOM' => ['Custom parametric cabinet (template creator, Phase 6)']
    }.freeze

    module_function

    def entry(type)
      ENTRIES.find { |e| e['type'] == type }
    end

    def defaults_for(type)
      e = entry(type) or raise KeyError, "Unknown cabinet type '#{type}'"
      Parameter.defaults.merge(e['defaults'])
    end
  end
end
