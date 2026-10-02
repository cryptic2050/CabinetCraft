# frozen_string_literal: true

module CabinetCraft
  module Validation
    # Feasibility of drilling operations (panel-local coordinates, see Manufacturing::Machining).
    module MachiningChecker
      MIN_WEB = 2.0        # mm of material that must remain under a blind hole
      MIN_EDGE_LAND = 3.0  # mm between a hole and the part edge (warning below this)

      module_function

      def issue(severity, op, message)
        { 'severity' => severity, 'code' => 'impossible_drilling', 'message' => "#{op['part_id']}: #{message}",
          'cabinet_id' => op['cabinet_id'], 'cabinet_label' => op['cabinet_label'], 'part_key' => op['part_key'], 'part_id' => op['part_id'] }
      end

      def check(ops)
        out = []
        ops.each { |op| out.concat(op['target'] == 'face' ? check_face(op) : check_edge(op)) }
        out.concat(check_overlaps(ops))
        out
      end

      def check_face(op)
        out = []
        r = op['dia'] / 2.0
        l = op['part_length']
        w = op['part_width']
        t = op['part_thickness']
        label = "#{op['kind'].tr('_', ' ')} Ø#{op['dia']} at (#{op['x'].round(1)}, #{op['y'].round(1)})"
        if op['x'] - r < -1e-6 || op['x'] + r > l + 1e-6 || op['y'] - r < -1e-6 || op['y'] + r > w + 1e-6
          out << issue('error', op, "#{label} falls outside the #{l.round(1)} x #{w.round(1)} part")
        elsif [op['x'] - r, l - op['x'] - r, op['y'] - r, w - op['y'] - r].min < MIN_EDGE_LAND
          out << issue('warning', op, "#{label} is within #{MIN_EDGE_LAND} mm of the part edge")
        end
        if op['depth'] > t + 1e-6
          out << issue('error', op, "#{label} is #{op['depth']} mm deep in a #{t} mm part")
        elsif !op['through'] && op['depth'] > t - MIN_WEB
          out << issue('error', op, "#{label} (#{op['depth']} mm deep) leaves under #{MIN_WEB} mm in a #{t} mm part")
        end
        out
      end

      def check_edge(op)
        out = []
        t = op['part_thickness']
        r = op['dia'] / 2.0
        run = op['edge'].start_with?('L') ? op['part_length'] : op['part_width'] # extent along the edge
        into = op['edge'].start_with?('L') ? op['part_width'] : op['part_length'] # extent the bore travels through
        label = "edge bore Ø#{op['dia']} on #{op['edge']} at #{op['along'].round(1)}"
        out << issue('error', op, "#{label} is too large for a #{t} mm thick part") if op['dia'] > t - 4.0
        out << issue('error', op, "#{label} is #{op['depth']} mm deep but the part is only #{into.round(1)} mm across") if op['depth'] > into + 1e-6
        out << issue('error', op, "#{label} falls outside the edge (#{run.round(1)} mm long)") if op['along'] - r < -1e-6 || op['along'] + r > run + 1e-6
        out
      end

      def check_overlaps(ops)
        out = []
        ops.group_by { |o| o['target'] == 'face' ? [o['part_uid'], 'f', o['side']] : [o['part_uid'], 'e', o['edge']] }.each_value do |g|
          g.combination(2).each do |a, b|
            gap = if a['target'] == 'face'
                    Math.hypot(a['x'] - b['x'], a['y'] - b['y'])
                  else
                    (a['along'] - b['along']).abs
                  end
            next unless gap < (a['dia'] + b['dia']) / 2.0 - 1e-6

            out << issue('error', a, "#{a['kind'].tr('_', ' ')} Ø#{a['dia']} overlaps #{b['kind'].tr('_', ' ')} Ø#{b['dia']}")
          end
        end
        out
      end
    end
  end
end
