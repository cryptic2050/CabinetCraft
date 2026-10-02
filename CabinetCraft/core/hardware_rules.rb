# frozen_string_literal: true

require_relative 'hardware'

module CabinetCraft
  # Rule-based hardware placement. Pure: (params, rule-engine values, panels) in,
  # hardware items + issues out. Nothing here is stored in the model; it is
  # always derived from the cabinet parameters and the current hardware config,
  # so a changed door height or rule table updates quantities automatically.
  module HardwareRules
    Result = Struct.new(:items, :issues)

    module_function

    # Hinge cup positions measured from the bottom edge of a door.
    def hinge_positions(door_height, count, inset)
      return [(door_height / 2.0).round(1)] if count == 1

      inset = [inset, door_height / 4.0].min
      step = (door_height - 2 * inset) / (count - 1)
      Array.new(count) { |i| (inset + i * step).round(1) }
    end

    # First half of the doors hinge on the left, the rest on the right; a single
    # door follows the hinge_side parameter.
    def hinge_side(index, total, param)
      return param if total == 1

      index < total / 2 ? 'left' : 'right'
    end

    def compute(params, values, panels, config = Hardware.config)
      st = config.settings
      items = []
      issues = []
      add = lambda do |id, qty, part_key, detail = nil|
        next if qty <= 0

        items << { 'hardware_id' => id, 'name' => Hardware.name_of(id), 'category' => Hardware.find(id)&.category || 'unknown',
                   'qty' => qty, 'part_key' => part_key, 'detail' => detail }
        issues << { 'severity' => 'warning', 'key' => nil, 'message' => "Hardware '#{id}' is not in the library" } unless Hardware.find(id)
      end

      doors(params, panels, config, st, add)
      drawers(params, panels, add)
      connectors(params, values, panels, st, add)
      shelf_pins(panels, st, add)
      feet(params, add)
      [items, issues.uniq]
    end

    # Dimensions come from the panels (not the rule values) so manual overrides flow into hardware quantities.
    def doors(params, panels, config, st, add)
      door_panels = panels.select { |p| p.role == :door }.sort_by(&:key)
      n = door_panels.size
      handle = params['handle_type']
      door_panels.each_with_index do |door, i|
        key = door.key
        h = door.size[2]
        count = config.hinge_count(h)
        side = hinge_side(i, n, params['hinge_side'])
        pos = hinge_positions(h, count, st['hinge_inset'])
        add.call(params['hinge_type'], count, key, "#{side} side, #{pos.join(' / ')} mm from bottom")
        next if handle == 'none'

        free = side == 'left' ? 'right' : 'left'
        add.call(handle, 1, key, "#{st['handle_inset']} mm from #{free} edge, #{st['handle_top_offset']} mm below top")
      end
    end

    def drawers(params, panels, add)
      panels.select { |p| p.role == :drawer_front }.sort_by(&:key).each_with_index do |front, i|
        key = front.key
        side = panels.find { |p| p.key == "drawer_#{i + 1}_side_left" }
        add.call(params['runner_type'], 1, key, "pair, length #{side ? side.size[1].round(1) : '?'} mm")
        add.call(params['handle_type'], 1, key, 'centred on front') unless params['handle_type'] == 'none'
      end
    end

    # Fixings along a joint of the given length: one every `spacing` mm, at least 2.
    def connector_count(length, spacing)
      [2, (length / spacing).ceil].max
    end

    # Evenly spaced positions along a joint (distances from its start), kept away from the ends.
    def joint_positions(length, count, inset)
      inset = [inset, length / 4.0].min
      return [length / 2.0] if count == 1

      step = (length - 2 * inset) / (count - 1)
      Array.new(count) { |i| (inset + i * step).round(3) }
    end

    # Joints: [owner part key, joint length]. Fixings sit on the owner part.
    def joints(values, panels)
      by_key = panels.to_h { |p| [p.key, p] }
      depth = ->(k) { by_key[k].size[1] } # joint length = the part's depth (y)
      list = []
      %w[side_left side_right].each { |k| list << [k, depth.call(k)] if by_key[k] }
      %w[brace_front brace_rear].each { |k| 2.times { list << [k, depth.call(k)] } if by_key[k] }
      2.times { list << ['zone_shelf', depth.call('zone_shelf')] } if by_key['zone_shelf']
      panels.select { |p| p.role == :divider }.each { |p| list << [p.key, p.size[1]] }
      list
    end

    def connectors(params, values, panels, st, add)
      type = params['connector_type']
      per_part = Hash.new(0)
      joints(values, panels).each do |key, length|
        per_part[key] += connector_count(length, st['connector_spacing'])
      end
      companions = Hardware.find(type)&.companions || {}
      per_part.each do |key, qty|
        add.call(type, qty, key, "#{qty} fixings along its joints")
        companions.each { |cid, per| add.call(cid, qty * per, key, "with #{Hardware.name_of(type)}") }
      end
    end

    def shelf_pins(panels, st, add)
      panels.select { |p| p.role == :shelf }.each do |p|
        add.call('shelf_pin', st['shelf_pins_per_shelf'], p.key, "#{st['shelf_pins_per_shelf']} pins per shelf")
      end
    end

    # Four feet, plus two more under wide cabinets, only when there is a toe kick.
    def feet(params, add)
      return if params['foot_type'] == 'none' || params['toe_kick_height'].to_f <= 0

      add.call(params['foot_type'], params['width'].to_f > 900 ? 6 : 4, 'cabinet', 'under the carcass')
    end
  end
end
