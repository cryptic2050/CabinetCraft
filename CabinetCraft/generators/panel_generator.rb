# frozen_string_literal: true

require_relative '../core/panel'
require_relative '../core/material'
require_relative '../core/construction'
require_relative '../core/edge_banding'

module CabinetCraft
  module Generators
    # Turns rule-engine output into positioned Panel objects. No SketchUp calls.
    # Cabinet-local axes: x width, y depth (front = 0, doors at y < 0), z up.
    module PanelGenerator
      module_function

      def generate(params, values)
        ctx = Context.new(params, values)
        panels = carcass(ctx)
        panels.concat(interior(ctx))
        panels.concat(toe_kick(ctx))
        panels.concat(doors(ctx))
        panels.concat(drawers(ctx))
        panels.map { |p| EdgeBanding.apply(p, params) }
      end

      # Shared lookups so each builder stays short.
      class Context
        attr_reader :params, :v, :profile, :carcass_mat, :front_mat, :box_mat

        def initialize(params, values)
          @params = params
          @v = values
          @profile = Construction.fetch(params['construction'])
          @carcass_mat = Material.fetch(params['material'])
          @front_mat = Material.fetch(params['front_material'])
          @box_mat = Material.fetch(params['drawer_box_material'])
        end

        def w
          params['width'].to_f
        end

        def d
          params['depth'].to_f
        end

        def t
          v['thickness']
        end

        def panel(key, name, role, origin, size, thickness_axis, grain_axis, mat, grooved_into: [])
          Panel.new(key: key, name: name, role: role, origin: origin, size: size, thickness_axis: thickness_axis,
                    grain_axis: grain_axis, material_id: mat.id, material_label: mat.name, grooved_into: grooved_into)
        end
      end

      def carcass(c)
        v = c.v
        t = c.t
        toe = v['toe_height']
        bt = v['back_thickness']
        base = [
          c.panel('bottom', 'Bottom', :bottom, [0, 0, toe], [c.w, c.d, t], :z, :x, c.carcass_mat),
          c.panel('side_left', 'Left side', :side, [0, 0, toe + t], [t, c.d, v['side_height']], :x, :z, c.carcass_mat),
          c.panel('side_right', 'Right side', :side, [c.w - t, 0, toe + t], [t, c.d, v['side_height']], :x, :z, c.carcass_mat),
          c.panel('back', 'Back', :back, [t - c.profile[:groove_depth], v['back_y'], toe + t],
                  [v['back_width'], bt, v['back_height']], :y, nil, Material.back_or_custom(bt),
                  grooved_into: %w[side_left side_right])
        ]
        brace_z = v['carcass_top_z'] - t
        base << brace('brace_front', 'Front rail', [t, 0, brace_z], c)
        base << brace('brace_rear', 'Rear rail', [t, v['back_y'] - v['brace_depth'], brace_z], c) if v['brace_count'] >= 2
        base
      end

      def brace(key, name, origin, c)
        c.panel(key, name, :brace, origin, [c.v['brace_width'], c.v['brace_depth'], c.t], :z, :x, c.carcass_mat)
      end

      # Dividers, per-compartment shelves, and the fixed shelf under the drawers.
      def interior(c)
        v = c.v
        t = c.t
        out = []
        if v['zone_shelf_z']
          out << c.panel('zone_shelf', 'Fixed shelf (under drawers)', :fixed_shelf, [t, 0, v['zone_shelf_z']],
                         [v['internal_width'], v['back_y'], t], :z, :x, c.carcass_mat)
        end
        return out unless v['open_zone']

        ndiv = v['divider_count']
        comp = v['compartment_width']
        ndiv.times do |i|
          out << c.panel("divider_#{i + 1}", "Divider #{i + 1}", :divider,
                         [t + comp * (i + 1) + t * i, 0, v['open_z_lo']],
                         [t, v['divider_depth'], v['divider_top_z'] - v['open_z_lo']], :x, :z, c.carcass_mat)
        end
        (ndiv + 1).times do |ci|
          cx = t + (comp + t) * ci + c.profile[:shelf_side_clearance]
          v['shelf_count'].times do |i|
            z = v['open_z_lo'] + v['shelf_gap'] * (i + 1) + t * i
            key = ndiv.zero? ? "shelf_#{i + 1}" : "shelf_c#{ci + 1}_#{i + 1}"
            name = ndiv.zero? ? "Shelf #{i + 1}" : "Shelf #{i + 1} (compartment #{ci + 1})"
            out << c.panel(key, name, :shelf, [cx, c.profile[:shelf_front_setback], z],
                           [v['shelf_width'], v['shelf_depth'], t], :z, :x, c.carcass_mat)
          end
        end
        out
      end

      # Plinth board, set back from the front, under the raised carcass.
      def toe_kick(c)
        v = c.v
        return [] unless v['toe_height'].positive?

        [c.panel('toe_kick', 'Toe kick', :toe_kick, [0, v['toe_depth'], 0], [c.w, c.t, v['toe_height']], :y, :x, c.carcass_mat)]
      end

      # Slab doors, full overlay, in front of the carcass.
      def doors(c)
        v = c.v
        r = c.params['door_reveal'].to_f
        gap = c.params['door_gap'].to_f
        ft = v['front_thickness']
        v['door_widths'].each_with_index.map do |dw, i|
          c.panel("door_#{i + 1}", "Door #{i + 1}", :door, [r + i * (dw + gap), -ft, v['door_z']],
                  [dw, ft, v['door_height']], :y, :z, c.front_mat)
        end
      end

      # Drawer fronts and boxes (front, back, two sides, bottom).
      def drawers(c)
        v = c.v
        return [] if v['drawer_fronts'].empty?

        ft = v['front_thickness']
        st = v['drawer_box_thickness']
        bot = v['drawer_bottom_thickness']
        bw = v['drawer_box_width']
        bd = v['drawer_box_depth']
        x0 = c.t + c.params['runner_clearance'].to_f
        r = c.params['door_reveal'].to_f
        bottom_mat = Material.back_or_custom(bot)
        out = []
        v['drawer_fronts'].each_with_index do |f, i|
          n = i + 1
          box = v['drawer_boxes'][i]
          wall_h = box['height'] - bot
          z0 = box['z']
          out << c.panel("drawer_#{n}_front", "Drawer #{n} front", :drawer_front, [r, -ft, f['z']],
                         [c.w - 2 * r, ft, f['height']], :y, :x, c.front_mat)
          out << c.panel("drawer_#{n}_bottom", "Drawer #{n} bottom", :drawer_box, [x0, 0, z0], [bw, bd, bot], :z, nil, bottom_mat)
          out << c.panel("drawer_#{n}_side_left", "Drawer #{n} left side", :drawer_box, [x0, 0, z0 + bot], [st, bd, wall_h], :x, :y, c.box_mat)
          out << c.panel("drawer_#{n}_side_right", "Drawer #{n} right side", :drawer_box, [x0 + bw - st, 0, z0 + bot], [st, bd, wall_h], :x, :y, c.box_mat)
          out << c.panel("drawer_#{n}_box_front", "Drawer #{n} box front", :drawer_box, [x0 + st, 0, z0 + bot], [bw - 2 * st, st, wall_h], :y, :x, c.box_mat)
          out << c.panel("drawer_#{n}_box_back", "Drawer #{n} box back", :drawer_box, [x0 + st, bd - st, z0 + bot], [bw - 2 * st, st, wall_h], :y, :x, c.box_mat)
        end
        out
      end
    end
  end
end
