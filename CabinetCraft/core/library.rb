# frozen_string_literal: true

require_relative 'parameter'

module CabinetCraft
  # Cabinet type library. Only types with a working generator are in ENTRIES;
  # everything else is listed in PLANNED so the UI can show the roadmap without
  # offering buttons that do nothing.
  module Library
    # Presets share one generator; they differ only in default parameters.
    # Preset height 820 = 720 carcass + 100 toe kick.
    BASE_PRESET = { 'height' => 820.0, 'toe_kick_height' => 100.0 }.freeze

    ENTRIES = [
      {
        'type' => 'base_cabinet', 'category' => 'BASE CABINETS', 'name' => 'Base cabinet (general)',
        'description' => 'Fully configurable base carcass: doors, drawers, shelves, dividers and toe kick are all parameters. ' \
                         'Defaults match the Phase 1 example (600 x 757 x 562, one door, no toe kick).',
        'defaults' => { 'width' => 600.0, 'height' => 757.0, 'depth' => 562.0 }
      },
      {
        'type' => 'base_single_door', 'category' => 'BASE CABINETS', 'name' => 'Single-door base cabinet',
        'description' => 'One slab door, one shelf, 100 mm toe kick.',
        'defaults' => BASE_PRESET.merge('width' => 600.0, 'door_count' => 1, 'shelf_count' => 1)
      },
      {
        'type' => 'base_double_door', 'category' => 'BASE CABINETS', 'name' => 'Double-door base cabinet',
        'description' => 'Two slab doors, one shelf, 100 mm toe kick.',
        'defaults' => BASE_PRESET.merge('width' => 800.0, 'door_count' => 2, 'shelf_count' => 1)
      },
      {
        'type' => 'base_drawer_3', 'category' => 'BASE CABINETS', 'name' => '3-drawer base cabinet',
        'description' => 'Three equal drawers filling the full height, 100 mm toe kick.',
        'defaults' => BASE_PRESET.merge('width' => 600.0, 'door_count' => 0, 'drawer_count' => 3, 'shelf_count' => 0)
      },
      {
        'type' => 'base_drawer_4', 'category' => 'BASE CABINETS', 'name' => '4-drawer base cabinet',
        'description' => 'Four equal drawers filling the full height, 100 mm toe kick.',
        'defaults' => BASE_PRESET.merge('width' => 600.0, 'door_count' => 0, 'drawer_count' => 4, 'shelf_count' => 0)
      },
      {
        'type' => 'base_door_drawer', 'category' => 'BASE CABINETS', 'name' => 'Drawer-over-door base cabinet',
        'description' => 'One drawer on top, two doors below, fixed shelf between, 100 mm toe kick.',
        'defaults' => BASE_PRESET.merge('width' => 800.0, 'door_count' => 2, 'drawer_count' => 1, 'shelf_count' => 1)
      },
      {
        'type' => 'base_open_shelf', 'category' => 'BASE CABINETS', 'name' => 'Open shelf base cabinet',
        'description' => 'No fronts, two shelves, optional dividers, 100 mm toe kick.',
        'defaults' => BASE_PRESET.merge('width' => 600.0, 'door_count' => 0, 'shelf_count' => 2)
      }
    ].freeze

    PLANNED = {
      'BASE CABINETS' => ['Sink cabinet', 'Oven cabinet', 'Hob cabinet', 'Dishwasher cabinet',
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
