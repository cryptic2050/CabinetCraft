# frozen_string_literal: true

module CabinetCraft
  module Exporters
    # DXF R12 (AC1009) writer: widely supported by CAD/CAM packages. One file per nested sheet, millimetres,
    # origin at the sheet's bottom-left corner, everything seen from face A.
    #
    # Layers: SHEET, TRIM, PART_OUTLINE, LABELS, and DRILL_<A|B>_D<dia>_<Z<depth>|THRU> (one per distinct hole).
    # Face-B holes are drawn at their top-view positions, NOT mirrored: flip the part to machine them.
    # Horizontal edge bores are not drawn (they are not router operations).
    module DxfExporter
      module_function

      def layer_name(hole)
        n = ->(v) { (v == v.round ? v.round.to_s : v.to_s).tr('.', '-') }
        "DRILL_#{hole['side'].upcase}_D#{n.call(hole['dia'])}_#{hole['through'] ? 'THRU' : 'Z' + n.call(hole['depth'])}"
      end

      def clean(text)
        text.to_s.gsub(/[^A-Za-z0-9 _\-.:#\/+]/, ' ')[0, 60]
      end

      # material: nesting result entry; sheet: one of its sheets; holes: Cnc.sheet_holes output
      def sheet(material, sheet, holes)
        layers = { 'SHEET' => 8, 'TRIM' => 8, 'PART_OUTLINE' => 7, 'LABELS' => 3 }
        holes.each { |h| layers[layer_name(h)] ||= (h['side'] == 'a' ? 1 : 5) }
        e = []
        poly = lambda do |layer, pts, closed = true|
          e << [0, 'POLYLINE'] << [8, layer] << [66, 1] << [70, closed ? 1 : 0]
          pts.each { |x, y| e << [0, 'VERTEX'] << [8, layer] << [10, x] << [20, y] << [30, 0.0] }
          e << [0, 'SEQEND'] << [8, layer]
        end
        rect = ->(x, y, w, h) { [[x, y], [x + w, y], [x + w, y + h], [x, y + h]] }
        poly.call('SHEET', rect.call(0, 0, material['sheet_length'], material['sheet_width']))
        t = material['trim']
        poly.call('TRIM', rect.call(t, t, material['sheet_length'] - 2 * t, material['sheet_width'] - 2 * t)) if t.positive?
        sheet['placements'].each do |p|
          poly.call('PART_OUTLINE', rect.call(p['x'], p['y'], p['w'], p['h']))
          e << [0, 'TEXT'] << [8, 'LABELS'] << [10, p['x'] + 3] << [20, p['y'] + 3] << [30, 0.0] << [40, 12.0] << [1, clean(p['part_id'])]
        end
        holes.each { |h| e << [0, 'CIRCLE'] << [8, layer_name(h)] << [10, h['x']] << [20, h['y']] << [30, 0.0] << [40, h['dia'] / 2.0] }

        out = []
        out << [0, 'SECTION'] << [2, 'HEADER'] << [9, '$ACADVER'] << [1, 'AC1009'] << [0, 'ENDSEC']
        out << [0, 'SECTION'] << [2, 'TABLES']
        out << [0, 'TABLE'] << [2, 'LTYPE'] << [70, 1] << [0, 'LTYPE'] << [2, 'CONTINUOUS'] << [70, 0] << [3, 'Solid line'] << [72, 65] << [73, 0] << [40, 0.0] << [0, 'ENDTAB']
        out << [0, 'TABLE'] << [2, 'LAYER'] << [70, layers.size + 1]
        out << [0, 'LAYER'] << [2, '0'] << [70, 0] << [62, 7] << [6, 'CONTINUOUS']
        layers.each { |name, color| out << [0, 'LAYER'] << [2, name] << [70, 0] << [62, color] << [6, 'CONTINUOUS'] }
        out << [0, 'ENDTAB'] << [0, 'ENDSEC']
        out << [0, 'SECTION'] << [2, 'ENTITIES']
        out.concat(e)
        out << [0, 'ENDSEC'] << [0, 'EOF']
        out.map { |c, v| "#{c}\n#{v.is_a?(Float) ? format('%.4f', v) : v}" }.join("\n") + "\n"
      end
    end
  end
end
