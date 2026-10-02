# frozen_string_literal: true

require_relative 'parameter'
require_relative 'standards'
require_relative '../templates/registry'

module CabinetCraft
  # Cabinet type library. Only types with a working generator are in ENTRIES;
  # everything else is listed in PLANNED so the UI can show the roadmap without
  # offering buttons that do nothing.
  module Library
    # Presets share one generator; they differ only in default parameters. A 'carcass_height' default means the
    # overall height is that plus the toe kick (which follows the company standard, 100 mm by default).
    BASE_TOE = 100.0
    BASE_PRESET = { 'carcass_height' => 720.0 }.freeze

    ENTRIES = [
      {
        'type' => 'base_cabinet', 'category' => 'BASE CABINETS', 'name' => 'Base cabinet (general)',
        'description' => 'Fully configurable base carcass: doors, drawers, shelves, dividers and toe kick are all parameters. ' \
                         'Defaults match the Phase 1 example (600 x 757 x 562, one door, no toe kick).',
        'defaults' => { 'width' => 600.0, 'height' => 757.0, 'depth' => 562.0 }
      },
      {
        'type' => 'base_single_door', 'category' => 'BASE CABINETS', 'name' => 'Single-door base cabinet',
        'description' => 'One slab door, one shelf, toe kick (100 mm by default).',
        'defaults' => BASE_PRESET.merge('width' => 600.0, 'door_count' => 1, 'shelf_count' => 1)
      },
      {
        'type' => 'base_double_door', 'category' => 'BASE CABINETS', 'name' => 'Double-door base cabinet',
        'description' => 'Two slab doors, one shelf, toe kick (100 mm by default).',
        'defaults' => BASE_PRESET.merge('width' => 800.0, 'door_count' => 2, 'shelf_count' => 1)
      },
      {
        'type' => 'base_drawer_3', 'category' => 'BASE CABINETS', 'name' => '3-drawer base cabinet',
        'description' => 'Three equal drawers filling the full height, toe kick (100 mm by default).',
        'defaults' => BASE_PRESET.merge('width' => 600.0, 'door_count' => 0, 'drawer_count' => 3, 'shelf_count' => 0)
      },
      {
        'type' => 'base_drawer_4', 'category' => 'BASE CABINETS', 'name' => '4-drawer base cabinet',
        'description' => 'Four equal drawers filling the full height, toe kick (100 mm by default).',
        'defaults' => BASE_PRESET.merge('width' => 600.0, 'door_count' => 0, 'drawer_count' => 4, 'shelf_count' => 0)
      },
      {
        'type' => 'base_door_drawer', 'category' => 'BASE CABINETS', 'name' => 'Drawer-over-door base cabinet',
        'description' => 'One drawer on top, two doors below, fixed shelf between, toe kick (100 mm by default).',
        'defaults' => BASE_PRESET.merge('width' => 800.0, 'door_count' => 2, 'drawer_count' => 1, 'shelf_count' => 1)
      },
      {
        'type' => 'base_open_shelf', 'category' => 'BASE CABINETS', 'name' => 'Open shelf base cabinet',
        'description' => 'No fronts, two shelves, optional dividers, toe kick (100 mm by default).',
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
      'TV UNITS' => ['Floating TV unit (installable example in TEMPLATES)', 'Full-height TV wall', 'Base TV cabinet', 'Open shelf TV unit']
    }.freeze

    module_function

    # Built-in cabinets, then the user's presets and templates (all dynamic).
    def entries
      ENTRIES + preset_entries + template_entries
    end

    def preset_entries
      Templates.config.presets.map do |p|
        { 'type' => p['id'], 'category' => p['category'], 'name' => p['name'], 'description' => p['description'].to_s, 'defaults' => p['defaults'],
          'base_type' => p['base_type'], 'user' => 'preset' }
      end
    end

    def template_entries
      Templates.config.templates.map do |t|
        { 'type' => t.id, 'category' => t.category, 'name' => t.name, 'description' => t.description, 'defaults' => t.defaults, 'user' => 'template' }
      end
    end

    def entry(type)
      entries.find { |e| e['type'] == type }
    end

    # Parameter schema for a cabinet type. nil for a template that is not available (e.g. missing on this machine).
    def schema_for(type)
      return Templates.find(type)&.schema if Templates.template_type?(type)

      Parameter.schema
    end

    # Starting values for a new cabinet of this type (see Standards for the precedence).
    def defaults_for(type)
      e = entry(type) or raise KeyError, "Unknown cabinet type '#{type}'"
      return e['defaults'] if e['user'] == 'template'

      own = e['defaults'].dup
      carcass = own.delete('carcass_height')
      merged = Standards.current.apply(Parameter.defaults).merge(own)
      merged['toe_kick_height'] = Standards.current.values['toe_kick_height'] || BASE_TOE if carcass && !own.key?('toe_kick_height')
      merged['height'] = carcass + merged['toe_kick_height'].to_f if carcass
      merged
    end
  end
end
