# frozen_string_literal: true

module CabinetCraft
  module Exporters
    # Self-contained printable label sheet (open in any browser, print or "save as PDF").
    module LabelHtml
      module_function

      def esc(s)
        s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;')
      end

      def render(labels, width_mm: 70, height_mm: 40)
        cards = labels.map do |l|
          <<~LABEL
            <div class="label"><div class="txt">
              <div class="proj">#{esc(l['project'])}</div>
              <div class="part">#{esc(l['cabinet'])} &middot; #{esc(l['part'])}</div>
              <div class="id">#{esc(l['part_id'])}</div>
              <div class="dim">#{esc(l['dimensions'])} mm &nbsp; &times;#{esc(l['qty'])}</div>
              <div>#{esc(l['material'])}</div>
              <div>Grain: #{esc(l['grain'])} &middot; Edge: #{esc(l['edge_banding'])}</div>
              <div class="pos">#{esc(l['position'])}</div>#{l['override'].to_s.empty? ? '' : %(<div class="ovr">#{esc(l['override'])}</div>)}
            </div><div class="qr">#{l['qr_svg']}</div></div>
          LABEL
        end
        <<~HTML
          <!doctype html><html><head><meta charset="utf-8"><title>CabinetCraft labels</title><style>
          @page{margin:6mm}body{margin:0;font:7.5pt/1.25 Arial,Helvetica,sans-serif;color:#000}
          .label{box-sizing:border-box;width:#{width_mm}mm;height:#{height_mm}mm;border:0.3mm solid #000;padding:1.5mm;display:inline-flex;gap:1.5mm;margin:0 1mm 1mm 0;overflow:hidden;break-inside:avoid;vertical-align:top}
          .txt{flex:1;min-width:0}.qr{width:#{(height_mm * 0.55).round}mm;flex:none}.qr svg{width:100%;height:auto;display:block}
          .proj{font-size:6pt;text-transform:uppercase;letter-spacing:.05em}.part{font-weight:bold;font-size:9pt}.id{font-family:monospace}.dim{font-weight:bold;font-size:10pt}.pos{font-size:6pt;color:#333}.ovr{font-size:6pt;font-weight:bold;border:0.2mm solid #000;display:inline-block;padding:0 1mm}
          </style></head><body>#{cards.join}</body></html>
        HTML
      end
    end
  end
end
