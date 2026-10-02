# frozen_string_literal: true

require_relative 'pdf_writer'
require_relative '../utilities/qr_code'

module CabinetCraft
  module Exporters
    # PDF documents built from the same derived data as the on-screen reports (nothing is stored separately).
    module PdfReports
      GRAIN = { 'length' => 'along length', 'width' => 'along width', 'none' => 'none' }.freeze
      LABEL_W = 63.5 # 3 x 7 labels per A4 sheet (a common 21-up label size)
      LABEL_H = 38.1

      module_function

      def num(v)
        v == v.round ? v.round.to_s : v.round(1).to_s
      end

      def left(title, width)
        { 'title' => title, 'width' => width, 'align' => :left }
      end

      def right(title, width)
        { 'title' => title, 'width' => width, 'align' => :right }
      end

      # rows: Manufacturing::PartsList.build output
      def parts_list(rows, project:, created: Time.now.utc)
        r = PdfReport.new(title: 'Parts list', project: project, size: 'a4_landscape', created: created)
        cabs = rows.map { |x| x['cabinet_label'] }.uniq.size
        r.paragraph("#{rows.size} parts in #{cabs} cabinet#{cabs == 1 ? '' : 's'}. Length is the longer side. Dimensions are finished sizes (edge band thickness is not deducted).")
        cols = [left('Part ID', 38), left('Cabinet', 12), left('Part', 26), right('Length', 12), right('Width', 12), right('Thk', 8), right('Qty', 7),
                left('Material', 24), left('Grain', 17), left('Edge banding', 30), left('Hardware', 46), left('Status', 28)]
        r.table(cols, rows.map do |x|
          [x['part_id'], x['cabinet_label'], x['name'], num(x['length']), num(x['width']), num(x['thickness']), x['qty'].to_s, x['material'],
           GRAIN.fetch(x['grain'], x['grain']), x['edge_text'], x['hardware'], x['status']]
        end)
        r.render
      end

      # list: Manufacturing::CuttingList.build output
      def cutting_list(list, project:, created: Time.now.utc)
        r = PdfReport.new(title: 'Cutting list', project: project, created: created)
        r.paragraph("#{list['part_count']} parts in #{list['cabinet_count']} cabinet#{list['cabinet_count'] == 1 ? '' : 's'}. Identical parts are grouped. #{list['estimate_note']}")
        list['materials'].each do |m|
          r.heading(m['material'], size: 11)
          cost = m['estimated_cost'] ? "  |  about #{m['estimated_cost']} at #{m['price']} per sheet" : ''
          r.paragraph("#{m['part_count']} parts  |  #{m['area_m2']} m2  |  sheet #{num(m['sheet_length'])} x #{num(m['sheet_width'])}  |  about #{m['estimated_sheets']} sheet#{m['estimated_sheets'] == 1 ? '' : 's'} (#{num(m['waste_pct'])}% waste)#{cost}")
          r.table([left('Part', 30), right('Length', 15), right('Width', 15), right('Qty', 10), left('Grain', 22), left('Edge banding', 38), left('Cabinets', 32)],
                  m['groups'].map { |g| [g['name'], num(g['length']), num(g['width']), g['qty'].to_s, GRAIN.fetch(g['grain'], g['grain']), g['edge_text'], g['cabinets']] })
        end
        unless list['edge_banding'].empty?
          r.heading('Edge banding', size: 11)
          r.table([left('Band thickness', 30), right('Length (m)', 20)], list['edge_banding'].map { |b| ["#{b['thickness']} mm", b['length_m'].to_s] })
        end
        unless list['hardware'].empty?
          r.heading('Hardware', size: 11)
          r.table([left('Item', 60), left('Category', 30), right('Qty', 15)], list['hardware'].map { |h| [h['name'], h['category'], h['qty'].to_s] })
        end
        r.render
      end

      # labels: Manufacturing::Labels.build(..., qr: false) rows
      def labels(labels, project:, created: Time.now.utc)
        doc = PdfDocument.new(title: "Labels - #{project}", created: created)
        cols = 3
        rows_per = 7
        gap_x = 2.5
        x0 = (210 - (cols * LABEL_W + (cols - 1) * gap_x)) / 2
        y0 = (297 - rows_per * LABEL_H) / 2
        labels.each_slice(cols * rows_per) do |chunk|
          pg = doc.add_page('a4')
          chunk.each_with_index do |l, i|
            x = x0 + (i % cols) * (LABEL_W + gap_x)
            y = y0 + (i / cols) * LABEL_H
            label(pg, l, x, y)
          end
        end
        doc.add_page('a4').text(105, 150, 'No labels', align: :center) if labels.empty?
        doc.render
      end

      def label(pg, l, x, y)
        pg.rect(x, y, LABEL_W, LABEL_H, stroke: '000000', width: 0.25)
        qr = 25.0
        tw = LABEL_W - qr - 5
        pg.text(x + 2, y + 4, PdfDocument.fit(l['project'].to_s.upcase, 5.5, :regular, tw), size: 5.5, color: '444444')
        pg.text(x + 2, y + 8, PdfDocument.fit("#{l['cabinet']} - #{l['part']}", 8, :bold, tw), size: 8, font: :bold)
        pg.text(x + 2, y + 12, PdfDocument.fit(l['part_id'], 7, :mono, tw), size: 7, font: :mono)
        pg.text(x + 2, y + 17.5, PdfDocument.fit("#{l['dimensions']} mm  x#{l['qty']}", 9, :bold, tw), size: 9, font: :bold)
        pg.text(x + 2, y + 21.5, PdfDocument.fit(l['material'], 6.5, :regular, tw), size: 6.5)
        pg.text(x + 2, y + 25, PdfDocument.fit("Grain: #{l['grain']}", 6, :regular, tw), size: 6)
        pg.text(x + 2, y + 28.3, PdfDocument.fit("Edge: #{l['edge_banding']}", 6, :regular, tw), size: 6)
        pg.text(x + 2, y + 31.6, PdfDocument.fit(l['position'].to_s, 5.5, :regular, tw), size: 5.5, color: '444444')
        pg.text(x + 2, y + 35, 'MANUAL OVERRIDE', size: 5.5, font: :bold) unless l['override'].to_s.empty?
        pg.qr(QrCode.encode(l['qr_payload']), x + LABEL_W - qr - 1.5, y + 2, qr)
        pg.text(x + LABEL_W - qr / 2 - 1.5, y + LABEL_H - 2, 'scan to identify', size: 4.5, align: :center, color: '555555')
      end

      def money(cur, v)
        s = format('%.2f', v)
        s = s.sub(/(\d)(?=(\d{3})+\.)/, '\\1,') while s.match?(/\d{4}\./)
        "#{cur}#{s}"
      end

      # est: Controller#cost_estimate (enabled). INTERNAL: shows costs and margin.
      def costing(est, project:, created: Time.now.utc)
        r = PdfReport.new(title: 'Cost estimate (internal)', project: project, created: created)
        c = est['currency']
        m = ->(v) { money(c, v) }
        r.paragraph('Internal document: it shows costs and margin. Use the quotation for clients. All figures are estimates.')
        r.heading('Summary', size: 11)
        r.table([left('Item', 60), right("Amount (#{c})", 30)], [
                  ['Materials', m.call(est['materials_total'])], ['Edge banding', m.call(est['edge_total'])], ['Hardware', m.call(est['hardware_total'])],
                  ["CNC (#{est['cnc']['sheets']} sheets, #{est['cnc']['holes']} holes)", m.call(est['cnc']['cost'])],
                  ["Labour (#{num(est['labour']['hours'])} h)", m.call(est['labour']['cost'])], ['Manufacturing cost', m.call(est['manufacturing_cost'])],
                  ['Transport', m.call(est['transport'])], ['Installation', m.call(est['installation'])], ['TOTAL COST', m.call(est['total_cost'])],
                  ["Profit margin #{num(est['margin_pct'])}% of the selling price", m.call(est['profit'])], ['SELLING PRICE', m.call(est['selling_price'])]
                ])
        r.heading('Materials', size: 11)
        r.table([left('Material', 50), right('Sheets', 14), right('Per sheet', 20), right('Cost', 22), left('Basis', 40)],
                est['materials'].map { |l| [l['material'], l['sheets'].to_s, l['sheet_price'] ? m.call(l['sheet_price']) : 'NOT PRICED', m.call(l['cost']), l['basis']] })
        unless est['edge_banding'].empty?
          r.heading('Edge banding', size: 11)
          r.table([left('Thickness', 24), right('Metres', 18), right('With waste', 22), right('Per metre', 22), right('Cost', 22)],
                  est['edge_banding'].map { |l| ["#{num(l['thickness'])} mm", num(l['metres']), num(l['metres_with_waste']), m.call(l['price_per_m']), m.call(l['cost'])] })
        end
        unless est['hardware'].empty?
          r.heading('Hardware', size: 11)
          r.table([left('Item', 70), right('Qty', 12), right('Unit price', 22), right('Cost', 22)],
                  est['hardware'].map { |l| [l['name'], l['qty'].to_s, l['unit_price'] ? m.call(l['unit_price']) : 'NOT PRICED', m.call(l['cost'])] })
        end
        r.heading('Per cabinet', size: 11)
        r.table([left('Cabinet', 18), right('Materials', 18), right('Edge', 14), right('Hardware', 18), right('CNC', 14), right('Labour', 16), right('Cost', 18), right('Price', 18)],
                est['per_cabinet'].map { |x| [x['label'], m.call(x['material']), m.call(x['edge_banding']), m.call(x['hardware']), m.call(x['cnc']), m.call(x['labour']), m.call(x['cost']), m.call(x['price'])] })
        r.paragraph('Per-cabinet figures include allocated shares of installation, transport and CNC. Materials and CNC sheets are shared by part area, transport by volume.')
        unless est['warnings'].empty?
          r.heading('Warnings', size: 11)
          est['warnings'].each { |w| r.paragraph(w, color: 'aa5500') }
        end
        r.render
      end

      # CLIENT-FACING: selling prices only. No costs, margin or manufacturing detail.
      def quote(est, project:, cabinets:, created: Time.now.utc, type_names: {})
        r = PdfReport.new(title: 'Quotation', project: project, created: created)
        c = est['currency']
        r.paragraph("Estimate for #{project}, prepared #{created.strftime('%Y-%m-%d')}. Prices are estimates based on the current design.", color: '000000')
        by_id = cabinets.to_h { |x| [x.id, x] }
        rows = est['per_cabinet'].map do |x|
          cab = by_id[x['cabinet_id']]
          dims = x['width'] && x['height'] && x['depth'] ? "#{num(x['width'])} x #{num(x['height'])} x #{num(x['depth'])} mm" : ''
          mat = cab&.part_rows&.first&.fetch('material', nil)
          [x['label'], type_names[x['type']] || x['type'], [dims, mat].reject { |t| t.to_s.empty? }.join('  |  '), money(c, x['price'])]
        end
        r.table([left('Item', 12), left('Cabinet', 40), left('Details', 70), right("Price (#{c})", 24)], rows, size: 8.5, row_h: 6.5)
        r.spacer(2)
        r.heading("Total: #{money(c, est['selling_price'])}", size: 13)
        r.render
      end

      def hue_color(label)
        h = label.to_s.each_char.reduce(0) { |a, c| (a * 31 + c.ord) % 360 }
        s = 0.45
        l = 0.80
        c = (1 - (2 * l - 1).abs) * s
        x = c * (1 - ((h / 60.0) % 2 - 1).abs)
        m = l - c / 2
        r, g, b = case (h / 60).floor % 6
                  when 0 then [c, x, 0] when 1 then [x, c, 0] when 2 then [0, c, x]
                  when 3 then [0, x, c] when 4 then [x, 0, c] else [c, 0, x]
                  end
        format('%02x%02x%02x', ((r + m) * 255).round, ((g + m) * 255).round, ((b + m) * 255).round)
      end

      # nest: Controller#nest result
      def nesting(nest, project:, created: Time.now.utc)
        r = PdfReport.new(title: 'Nesting', project: project, size: 'a4_landscape', created: created)
        t = nest['totals']
        r.paragraph("#{t['total_sheets']} sheets  |  utilization #{t['utilization']}%  |  used #{(t['used_area'] / 1e6).round(2)} m2, waste #{(t['waste_area'] / 1e6).round(2)} m2" \
                    "#{t['unplaced'].positive? ? "  |  #{t['unplaced']} PARTS DO NOT FIT" : ''}\n" \
                    'Layouts come from a heuristic (guillotine best-area-fit), not an optimal solver. Grain runs along the sheet length unless stated.')
        first = true
        nest['materials'].each do |m|
          m['unplaced'].each { |u| r.paragraph("DOES NOT FIT: #{u['part_id']} (#{num(u['length'])} x #{num(u['width'])}) on #{m['material']} sheets", color: 'aa0000') }
          m['sheets'].reject { |s| s['placements'].empty? }.each do |sh|
            r.new_page unless first
            first = false
            r.heading("#{m['material']} - sheet #{sh['index'] + 1} of #{m['sheets'].size}", size: 12)
            r.paragraph("#{num(m['sheet_length'])} x #{num(m['sheet_width'])} mm  |  kerf #{num(m['kerf'])}, trim #{num(m['trim'])}  |  utilization #{sh['utilization']}%  |  #{sh['placements'].size} parts" \
                        "#{m['grain_free'] ? '  |  no grain (parts may rotate)' : "  |  grain along sheet #{m['grain_axis']}"}")
            sheet_drawing(r, m, sh)
            r.ensure_space(34) # keep the heading together with the first rows of its table
            r.heading('Parts on this sheet', size: 10)
            r.table([left('Part ID', 30), left('Part', 38), right('Size', 24), right('X', 14), right('Y', 14), left('Rotated', 14), left('Locked', 14)],
                    sh['placements'].map { |p| [p['part_id'], p['name'], "#{num(p['w'])} x #{num(p['h'])}", num(p['x']), num(p['y']), p['rotated'] ? 'yes' : 'no', p['locked'] ? 'yes' : ''] })
            cut_sequence(r, sh)
          end
        end
        r.render
      end

      def sheet_drawing(r, m, sh)
        sl = m['sheet_length']
        sw = m['sheet_width']
        scale = [r.content_width / sl, 112.0 / sw].min
        ox = PdfReport::MARGIN
        oy = r.cursor
        pg = r.page
        pg.rect(ox, oy, sl * scale, sw * scale, stroke: '000000', fill: 'f1ece0', width: 0.4)
        pg.rect(ox + m['trim'] * scale, oy + m['trim'] * scale, (sl - 2 * m['trim']) * scale, (sw - 2 * m['trim']) * scale, stroke: '999999', width: 0.15, dash: [1.2, 0.8])
        sh['placements'].each do |p|
          x = ox + p['x'] * scale
          y = oy + (sw - p['y'] - p['h']) * scale
          w = p['w'] * scale
          h = p['h'] * scale
          pg.rect(x, y, w, h, stroke: p['locked'] ? 'd98c00' : '333333', fill: hue_color(p['cabinet_label']), width: p['locked'] ? 0.6 : 0.2)
          fs = [[w / 14.0 * 2.2, 6.5].min, 3.6].max
          id_w = PdfDocument.text_width_mm(p['part_id'], fs)
          if w >= id_w + 1 && h >= fs * 0.9 * 2.1
            pg.text(x + 0.8, y + fs * 0.42, p['part_id'], size: fs)
            pg.text(x + 0.8, y + fs * 0.42 + fs * 0.4, "#{num(p['w'])} x #{num(p['h'])}", size: fs * 0.85, color: '333333') if h >= fs * 0.9 * 3.2
          elsif h >= id_w + 1 && w >= fs * 0.9 * 1.3
            pg.text(x + fs * 0.45, y + h - 0.8, p['part_id'], size: fs, rotate: 90)
          end
        end
        r.spacer(sw * scale + 4)
      end

      def cut_sequence(r, sh)
        cs = sh['cut_sequence']
        r.ensure_space(30)
        r.heading('Cut sequence', size: 10)
        unless cs['ok']
          r.paragraph("#{cs['reason']}.")
          return
        end
        rows = cs['steps'].map do |s|
          if s['type'] == 'part'
            [s['step'].to_s, "Part #{s['part_id']}", '']
          else
            [s['step'].to_s, s['axis'] == 'horizontal' ? "Cut along the length at Y = #{num(s['position'])}" : "Cut across at X = #{num(s['position'])}", "#{num(s['from'])} to #{num(s['to'])}"]
          end
        end
        r.table([right('Step', 10), left('Action', 90), left('Span', 40)], rows)
        r.paragraph('Positions are measured from the sheet bottom-left corner. Edge trim is cut first.')
      end
    end
  end
end
