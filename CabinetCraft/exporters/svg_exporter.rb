# frozen_string_literal: true

module CabinetCraft
  module Exporters
    # Standalone SVG of one nested sheet with its holes (top view, face A up, face-B holes dashed).
    module SvgExporter
      module_function

      def esc(s)
        s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end

      def sheet(material, sheet, holes, router_diameter: nil)
        sl = material['sheet_length']
        sw = material['sheet_width']
        fs = [sl / 110.0, 12].max
        parts = sheet['placements'].map do |p|
          y = sw - p['y'] - p['h']
          out = %(<rect x="#{p['x']}" y="#{y.round(2)}" width="#{p['w']}" height="#{p['h']}" fill="#3a6b5c" fill-opacity=".55" stroke="#9fd" stroke-width="#{(fs / 8).round(2)}"/>)
          if router_diameter
            r = router_diameter / 2.0
            out += %(<rect x="#{(p['x'] - r).round(2)}" y="#{(y - r).round(2)}" width="#{(p['w'] + router_diameter).round(2)}" height="#{(p['h'] + router_diameter).round(2)}" fill="none" stroke="#f0a030" stroke-width="#{(fs / 10).round(2)}" stroke-dasharray="#{fs} #{fs / 2}"/>)
          end
          label = p['w'] > fs * 8 && p['h'] > fs * 2 ? %(<text x="#{p['x'] + fs / 2}" y="#{(y + fs * 1.1).round(2)}" font-size="#{fs.round(1)}" fill="#fff">#{esc(p['part_id'])}</text>) : ''
          out + label
        end.join
        circles = holes.map do |h|
          col = h['side'] == 'a' ? '#ff6b6b' : '#6bb5ff'
          dash = h['side'] == 'b' ? %( stroke-dasharray="#{(fs / 4).round(2)}") : ''
          %(<circle cx="#{h['x']}" cy="#{(sw - h['y']).round(3)}" r="#{h['dia'] / 2.0}" fill="none" stroke="#{col}" stroke-width="#{(fs / 10).round(2)}"#{dash}><title>#{esc(h['part_id'])} #{esc(h['kind'])} D#{h['dia']} depth #{h['through'] ? 'through' : h['depth']}</title></circle>)
        end.join
        %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{sl} #{sw}" width="#{sl}mm" height="#{sw}mm"><rect width="#{sl}" height="#{sw}" fill="#1c1f25" stroke="#888"/>) +
          %(<rect x="#{material['trim']}" y="#{material['trim']}" width="#{sl - 2 * material['trim']}" height="#{sw - 2 * material['trim']}" fill="none" stroke="#667" stroke-dasharray="#{fs}"/>#{parts}#{circles}</svg>)
      end
    end
  end
end
