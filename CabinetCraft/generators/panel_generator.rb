# frozen_string_literal: true

require_relative '../core/panel'
require_relative '../core/material'
require_relative '../core/construction'

module CabinetCraft
  module Generators
    # Turns rule-engine output into positioned Panel objects. No SketchUp calls.
    # Phase 1 carcass: bottom, two sides, back, rails, evenly spaced shelves.
    module PanelGenerator
      module_function

      def generate(params, values)
        profile  = Construction.fetch(params['construction'])
        material = Material.fetch(params['material'])
        w = params['width'].to_f
        t = values['thickness']
        bt = values['back_thickness']
        side_h = values['side_height']
        d = params['depth'].to_f
        mid = material.id
        mlabel = material.name

        panels = []
        panels << Panel.new(key: 'bottom', name: 'Bottom', role: :bottom,
                            origin: [0, 0, 0], size: [w, d, t], thickness_axis: :z,
                            grain_axis: :x, material_id: mid, material_label: mlabel)
        panels << Panel.new(key: 'side_left', name: 'Left side', role: :side,
                            origin: [0, 0, t], size: [t, d, side_h], thickness_axis: :x,
                            grain_axis: :z, material_id: mid, material_label: mlabel)
        panels << Panel.new(key: 'side_right', name: 'Right side', role: :side,
                            origin: [w - t, 0, t], size: [t, d, side_h], thickness_axis: :x,
                            grain_axis: :z, material_id: mid, material_label: mlabel)
        panels << Panel.new(key: 'back', name: 'Back', role: :back,
                            origin: [t - profile[:groove_depth], values['back_y'], t],
                            size: [values['back_width'], bt, values['back_height']],
                            thickness_axis: :y, grain_axis: nil,
                            material_id: "back_#{bt}", material_label: Material.back_label(bt),
                            grooved_into: %w[side_left side_right])

        brace_z = t + side_h - t
        panels << brace_panel('brace_front', 'Front rail', [t, 0, brace_z], values, mid, mlabel)
        if values['brace_count'] >= 2
          panels << brace_panel('brace_rear', 'Rear rail',
                                [t, values['back_y'] - values['brace_depth'], brace_z], values, mid, mlabel)
        end

        values['shelf_count'].times do |i|
          z = t + values['shelf_gap'] * (i + 1) + t * i
          panels << Panel.new(key: "shelf_#{i + 1}", name: "Shelf #{i + 1}", role: :shelf,
                              origin: [t + profile[:shelf_side_clearance], profile[:shelf_front_setback], z],
                              size: [values['shelf_width'], values['shelf_depth'], t],
                              thickness_axis: :z, grain_axis: :x, material_id: mid, material_label: mlabel)
        end
        panels
      end

      def brace_panel(key, name, origin, values, mid, mlabel)
        Panel.new(key: key, name: name, role: :brace, origin: origin,
                  size: [values['brace_width'], values['brace_depth'], values['thickness']],
                  thickness_axis: :z, grain_axis: :x, material_id: mid, material_label: mlabel)
      end
    end
  end
end
