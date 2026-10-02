# frozen_string_literal: true

require_relative 'material'
require_relative 'construction'
require_relative 'hardware'

module CabinetCraft
  # Parameter schema + coercion/validation for a cabinet. Parameters are plain
  # string-keyed hashes so they round-trip through JSON and SketchUp attributes.
  module Parameter
    module_function

    # Built lazily so enum options always reflect the current libraries.
    def schema
      [
        { 'key' => 'width',  'label' => 'Width',  'group' => 'DIMENSIONS', 'type' => 'length', 'default' => 600.0, 'min' => 150.0, 'max' => 3000.0 },
        { 'key' => 'height', 'label' => 'Height', 'group' => 'DIMENSIONS', 'type' => 'length', 'default' => 757.0, 'min' => 200.0, 'max' => 3000.0 },
        { 'key' => 'depth',  'label' => 'Depth',  'group' => 'DIMENSIONS', 'type' => 'length', 'default' => 562.0, 'min' => 150.0, 'max' => 1000.0 },
        { 'key' => 'material', 'label' => 'Carcass material', 'group' => 'MATERIAL', 'type' => 'enum',
          'default' => 'mdf_18', 'options' => Material.carcass.map { |m| { 'value' => m.id, 'label' => m.name } } },
        { 'key' => 'back_thickness', 'label' => 'Back panel thickness', 'group' => 'MATERIAL', 'type' => 'length',
          'default' => 3.0, 'min' => 3.0, 'max' => 18.0 },
        { 'key' => 'construction', 'label' => 'Construction', 'group' => 'CARCASS', 'type' => 'enum',
          'default' => Construction::DEFAULT,
          'options' => Construction::PROFILES.map { |id, p| { 'value' => id, 'label' => p[:name] } } },
        { 'key' => 'shelf_count', 'label' => 'Shelves (per compartment)', 'group' => 'CARCASS', 'type' => 'int', 'default' => 1, 'min' => 0, 'max' => 10 },
        { 'key' => 'divider_count', 'label' => 'Vertical dividers', 'group' => 'CARCASS', 'type' => 'int', 'default' => 0, 'min' => 0, 'max' => 4,
          'note' => 'Dividers and shelves only exist in the open/door zone, not behind drawers.' },
        { 'key' => 'brace_depth', 'label' => 'Rail depth', 'group' => 'CARCASS', 'type' => 'length', 'default' => 100.0, 'min' => 40.0, 'max' => 300.0 },
        { 'key' => 'toe_kick_height', 'label' => 'Toe kick height', 'group' => 'BASE', 'type' => 'length', 'default' => 0.0, 'min' => 0.0, 'max' => 300.0,
          'note' => '0 = no toe kick. Included in overall height.' },
        { 'key' => 'toe_kick_depth', 'label' => 'Toe kick setback', 'group' => 'BASE', 'type' => 'length', 'default' => 50.0, 'min' => 0.0, 'max' => 150.0 },
        { 'key' => 'door_count', 'label' => 'Door count', 'group' => 'FRONTS', 'type' => 'int', 'default' => 1, 'min' => 0, 'max' => 4 },
        { 'key' => 'door_reveal', 'label' => 'Outer reveal', 'group' => 'FRONTS', 'type' => 'length', 'default' => 1.5, 'min' => 0.0, 'max' => 10.0 },
        { 'key' => 'door_gap', 'label' => 'Gap between fronts', 'group' => 'FRONTS', 'type' => 'length', 'default' => 3.0, 'min' => 0.0, 'max' => 10.0 },
        { 'key' => 'front_material', 'label' => 'Front material', 'group' => 'FRONTS', 'type' => 'enum', 'default' => 'mdf_18',
          'options' => Material.carcass.map { |m| { 'value' => m.id, 'label' => m.name } } },
        { 'key' => 'drawer_count', 'label' => 'Drawer count', 'group' => 'DRAWERS', 'type' => 'int', 'default' => 0, 'min' => 0, 'max' => 6,
          'note' => 'Drawers sit at the top. With no doors they fill the full height equally.' },
        { 'key' => 'drawer_front_height', 'label' => 'Drawer front height', 'group' => 'DRAWERS', 'type' => 'length', 'default' => 180.0, 'min' => 80.0, 'max' => 600.0,
          'note' => 'Used only when doors and drawers are combined.' },
        { 'key' => 'drawer_box_material', 'label' => 'Drawer box material', 'group' => 'DRAWERS', 'type' => 'enum', 'default' => 'mdf_16',
          'options' => Material.carcass.map { |m| { 'value' => m.id, 'label' => m.name } } },
        { 'key' => 'runner_clearance', 'label' => 'Runner clearance (per side)', 'group' => 'DRAWERS', 'type' => 'length', 'default' => 13.0, 'min' => 5.0, 'max' => 30.0 },
        { 'key' => 'edge_carcass', 'label' => 'Carcass edge band', 'group' => 'EDGE BANDING', 'type' => 'length', 'default' => 1.0, 'min' => 0.0, 'max' => 3.0,
          'note' => 'Applied to visible front edges. 0 = none.' },
        { 'key' => 'edge_front', 'label' => 'Door / drawer front band', 'group' => 'EDGE BANDING', 'type' => 'length', 'default' => 2.0, 'min' => 0.0, 'max' => 3.0,
          'note' => 'Applied to all four edges of fronts. 0 = none.' },
        { 'key' => 'hinge_type', 'label' => 'Hinge', 'group' => 'HARDWARE', 'type' => 'enum', 'open' => true, 'default' => 'hinge_standard', 'options' => hw_options('hinge') },
        { 'key' => 'hinge_side', 'label' => 'Hinge side (single door)', 'group' => 'HARDWARE', 'type' => 'enum', 'default' => 'left',
          'options' => [{ 'value' => 'left', 'label' => 'Left' }, { 'value' => 'right', 'label' => 'Right' }] },
        { 'key' => 'handle_type', 'label' => 'Handle', 'group' => 'HARDWARE', 'type' => 'enum', 'open' => true, 'default' => 'none',
          'options' => [{ 'value' => 'none', 'label' => 'None' }] + hw_options('handle') },
        { 'key' => 'runner_type', 'label' => 'Drawer runner', 'group' => 'HARDWARE', 'type' => 'enum', 'open' => true, 'default' => 'runner_side_mount', 'options' => hw_options('runner') },
        { 'key' => 'connector_type', 'label' => 'Connector', 'group' => 'HARDWARE', 'type' => 'enum', 'open' => true, 'default' => 'cam_lock', 'options' => hw_options('connector') },
        { 'key' => 'foot_type', 'label' => 'Legs / feet (needs toe kick)', 'group' => 'HARDWARE', 'type' => 'enum', 'open' => true, 'default' => 'none',
          'options' => [{ 'value' => 'none', 'label' => 'None' }] + hw_options('leg') }
      ]
    end

    def hw_options(category)
      Hardware.by_category(category).map { |i| { 'value' => i.id, 'label' => i.name } }
    end

    def defaults
      schema.to_h { |f| [f['key'], f['default']] }
    end

    # Returns [params, errors]. Unknown keys are dropped; missing keys take the
    # default. Every field that fails validation yields one error and the
    # caller must not generate geometry.
    def coerce(raw)
      raw = (raw || {}).transform_keys(&:to_s)
      params = {}
      errors = []
      schema.each do |f|
        key = f['key']
        value = raw.key?(key) ? raw[key] : f['default']
        begin
          params[key] = convert(f, value)
          range_check(f, params[key], errors)
        rescue ArgumentError, TypeError
          params[key] = f['default']
          errors << { 'severity' => 'error', 'key' => key, 'message' => "#{f['label']}: invalid value #{value.inspect}" }
        end
      end
      [params, errors]
    end

    def convert(field, value)
      case field['type']
      when 'length'
        v = Float(value)
        raise ArgumentError, 'not finite' unless v.finite?

        v
      when 'int'
        v = Float(value)
        raise ArgumentError, 'not finite' unless v.finite?
        raise ArgumentError, 'not integer' unless v == v.round

        v.round
      when 'enum'
        v = value.to_s
        known = field['options'].any? { |o| o['value'] == v }
        raise ArgumentError, 'unknown option' unless known || (field['open'] && !v.empty?)

        v
      else
        value
      end
    end

    def range_check(field, value, errors)
      return unless field['min'] && field['max'] && value.is_a?(Numeric)
      return if value >= field['min'] && value <= field['max']

      errors << { 'severity' => 'error', 'key' => field['key'],
                  'message' => "#{field['label']} must be between #{field['min']} and #{field['max']}" }
    end
  end
end
