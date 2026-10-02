# frozen_string_literal: true

module CabinetCraft
  module Exporters
    # Draws Manufacturing::Assembly.view output (oblique exploded / assembled view) as a standalone SVG.
    module AssemblySvg
      BASE = [201, 180, 138].freeze

      module_function

      def esc(s)
        s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end

      # '#rrggbb' lightened (+) or darkened (-) by `shade`.
      def shaded(shade)
        '#' + BASE.map { |c| (shade.positive? ? c + (255 - c) * shade : c * (1 + shade)).round.clamp(0, 255).to_s(16).rjust(2, '0') }.join
      end

      def svg(view, width_px: 640)
        x0, y0, x1, y1 = view['bounds']
        pad = [x1 - x0, y1 - y0].max * 0.04
        vw = x1 - x0 + 2 * pad
        vh = y1 - y0 + 2 * pad
        fs = [vw, vh].max / 55.0
        flip = ->(pt) { [(pt[0] - x0 + pad).round(2), (y1 - pt[1] + pad).round(2)] } # SVG y grows downwards
        body = view['boxes'].map do |b|
          faces = b['faces'].map do |f|
            pts = f['points'].map { |pt| flip.call(pt).join(',') }.join(' ')
            %(<polygon points="#{pts}" fill="#{shaded(f['shade'])}" stroke="#2b2b2b" stroke-width="#{(fs / 14).round(2)}" stroke-linejoin="round"/>)
          end.join
          ax, ay = flip.call(b['anchor'])
          num = %(<circle cx="#{ax}" cy="#{ay}" r="#{(fs * 0.85).round(2)}" fill="#fff" stroke="#222" stroke-width="#{(fs / 14).round(2)}"/><text x="#{ax}" y="#{(ay + fs * 0.33).round(2)}" font-size="#{(fs * 0.95).round(2)}" text-anchor="middle" font-family="Helvetica,Arial,sans-serif" fill="#111">#{b['seq']}</text>)
          %(<g data-part="#{esc(b['part_id'])}"><title>#{b['seq']}: #{esc(b['part_id'])} #{esc(b['name'])}</title>#{faces}#{num}</g>)
        end.join
        %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{vw.round(2)} #{vh.round(2)}" width="#{width_px}" role="img" aria-label="Assembly view"><rect width="100%" height="100%" fill="#f4f1ea"/>#{body}</svg>)
      end
    end
  end
end
