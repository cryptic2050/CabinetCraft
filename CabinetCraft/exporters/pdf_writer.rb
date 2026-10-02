# frozen_string_literal: true

module CabinetCraft
  module Exporters
    # Minimal dependency-free PDF 1.4 writer (SketchUp's Ruby ships no PDF library).
    # Vector graphics and the standard Helvetica / Helvetica-Bold / Courier fonts only (no embedding needed).
    # Coordinates are millimetres with the origin at the TOP-LEFT of the page, y growing downwards.
    #
    # Text is limited to Windows-1252 characters; anything else is replaced with '?'.
    class PdfDocument
      MM = 72.0 / 25.4
      SIZES = { 'a4' => [210.0, 297.0], 'a4_landscape' => [297.0, 210.0] }.freeze

      # Helvetica / Helvetica-Bold advance widths (1/1000 em) for ASCII 32..126.
      HELV = [278, 278, 355, 556, 556, 889, 667, 191, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556,
              278, 278, 584, 584, 584, 556, 1015, 667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778, 667, 778, 722, 667,
              611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556, 333, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833,
              556, 556, 556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584].freeze
      HELV_BOLD = [278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278, 556, 556, 556, 556, 556, 556, 556, 556, 556, 556,
                   333, 333, 584, 584, 584, 611, 975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778, 667, 778, 722, 667,
                   611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556, 333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889,
                   611, 611, 611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584].freeze
      FONTS = { regular: 'F1', bold: 'F2', mono: 'F3' }.freeze

      def self.text_width_mm(text, size, font = :regular)
        units = text.to_s.each_char.sum do |ch|
          o = ch.ord
          if font == :mono then 600
          elsif o.between?(32, 126) then (font == :bold ? HELV_BOLD : HELV)[o - 32]
          else 556 # accented / symbol characters: a reasonable average
          end
        end
        units * size / 1000.0 / MM
      end

      # Shortens text with an ellipsis so it fits `max_mm`.
      def self.fit(text, size, font, max_mm)
        t = text.to_s
        return t if text_width_mm(t, size, font) <= max_mm

        t = t[0...-1] while !t.empty? && text_width_mm("#{t}...", size, font) > max_mm
        "#{t}..."
      end

      class Page
        attr_reader :width, :height, :ops

        def initialize(width, height)
          @width = width
          @height = height
          @ops = []
        end

        def y(v)
          (@height - v) * MM
        end

        def x(v)
          v * MM
        end

        def color_ops(stroke, fill)
          [fill && "#{rgb(fill)} rg", stroke && "#{rgb(stroke)} RG"].compact.join(' ')
        end

        def rgb(c)
          c = c.delete('#')
          c.scan(/../).map { |h| format('%.3f', h.to_i(16) / 255.0) }.join(' ')
        end

        # rotate: 90 writes the text bottom-to-top starting at (x, y).
        def text(x, y, str, size: 9, font: :regular, align: :left, color: '000000', rotate: 0)
          s = PdfDocument.encode(str)
          w = PdfDocument.text_width_mm(str, size, font)
          x -= w if align == :right && rotate.zero?
          x -= w / 2 if align == :center && rotate.zero?
          pos = rotate == 90 ? "0 1 -1 0 #{format('%.3f', self.x(x))} #{format('%.3f', self.y(y))} Tm" : "#{format('%.3f', self.x(x))} #{format('%.3f', self.y(y))} Td"
          @ops << "BT #{rgb(color)} rg /#{FONTS[font]} #{format('%.2f', size)} Tf #{pos} (#{s}) Tj ET"
        end

        def line(x1, y1, x2, y2, width: 0.25, color: '000000', dash: nil)
          d = dash ? "[#{dash.map { |v| format('%.2f', v * MM) }.join(' ')}] 0 d" : '[] 0 d'
          @ops << "q #{rgb(color)} RG #{format('%.3f', width * MM)} w #{d} #{format('%.3f', x(x1))} #{format('%.3f', y(y1))} m #{format('%.3f', x(x2))} #{format('%.3f', y(y2))} l S Q"
        end

        def rect(x0, y0, w, h, stroke: '000000', fill: nil, width: 0.25, dash: nil)
          paint = fill && stroke ? 'B' : fill ? 'f' : 'S'
          d = dash ? "[#{dash.map { |v| format('%.2f', v * MM) }.join(' ')}] 0 d" : '[] 0 d'
          @ops << "q #{color_ops(stroke, fill)} #{format('%.3f', width * MM)} w #{d} #{format('%.3f', x(x0))} #{format('%.3f', y(y0 + h))} #{format('%.3f', w * MM)} #{format('%.3f', h * MM)} re #{paint} Q"
        end

        def circle(cx, cy, r, stroke: '000000', fill: nil, width: 0.2)
          k = 0.5522847498 * r
          pts = [[cx + r, cy], [cx + r, cy + k, cx + k, cy + r, cx, cy + r], [cx - k, cy + r, cx - r, cy + k, cx - r, cy],
                 [cx - r, cy - k, cx - k, cy - r, cx, cy - r], [cx + k, cy - r, cx + r, cy - k, cx + r, cy]]
          path = +"#{format('%.3f', x(pts[0][0]))} #{format('%.3f', y(pts[0][1]))} m "
          pts[1..].each { |c| path << c.each_slice(2).map { |px, py| "#{format('%.3f', x(px))} #{format('%.3f', y(py))}" }.join(' ') << ' c ' }
          paint = fill && stroke ? 'B' : fill ? 'f' : 'S'
          @ops << "q #{color_ops(stroke, fill)} #{format('%.3f', width * MM)} w #{path}h #{paint} Q"
        end

        # QR matrix (array of boolean rows) drawn as vector squares, `size` mm wide including the quiet zone.
        def qr(matrix, x0, y0, size, quiet: 1)
          n = matrix.size + 2 * quiet
          cell = size / n.to_f
          @ops << "q 0 0 0 rg"
          matrix.each_with_index do |row, r|
            c = 0
            while c < row.size
              if row[c]
                start = c
                c += 1 while c < row.size && row[c]
                @ops << "#{format('%.3f', x(x0 + (start + quiet) * cell))} #{format('%.3f', y(y0 + (r + quiet + 1) * cell))} #{format('%.3f', (c - start) * cell * MM)} #{format('%.3f', cell * MM)} re f"
              else
                c += 1
              end
            end
          end
          @ops << 'Q'
        end

        # Clips following drawing to a rectangle until restore_clip.
        def clip(x0, y0, w, h)
          @ops << "q #{format('%.3f', x(x0))} #{format('%.3f', y(y0 + h))} #{format('%.3f', w * MM)} #{format('%.3f', h * MM)} re W n"
        end

        def restore_clip
          @ops << 'Q'
        end
      end

      def self.encode(str)
        s = str.to_s.gsub(/[\u0000-\u001f]/, ' ').encode('Windows-1252', invalid: :replace, undef: :replace, replace: '?')
        s.b.gsub(/[\\()]/) { |c| "\\#{c}" }
      end

      attr_reader :pages

      def initialize(title:, author: 'CabinetCraft Pro', created: Time.now.utc)
        @title = title
        @author = author
        @created = created
        @pages = []
      end

      def add_page(size = 'a4')
        w, h = SIZES.fetch(size)
        page = Page.new(w, h)
        @pages << page
        page
      end

      # Called as footer.call(page, index, total) for every page at render time.
      def render(&footer)
        raise 'A PDF needs at least one page' if @pages.empty?

        objs = [] # index i holds object number i + 1
        objs[0] = nil # catalog (filled below)
        objs[1] = nil # pages
        objs[2] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'
        objs[3] = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>'
        objs[4] = '<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>'
        info_no = 6
        objs[5] = "<< /Title #{utf16(@title)} /Author #{utf16(@author)} /Producer (CabinetCraft Pro) /CreationDate (D:#{@created.strftime('%Y%m%d%H%M%S')}Z) >>"
        kids = []
        @pages.each_with_index do |page, i|
          footer&.call(page, i, @pages.size)
          content = page.ops.join("\n").b
          content_no = objs.size + 2
          page_no = objs.size + 1
          kids << "#{page_no} 0 R"
          objs << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{format('%.2f', page.width * MM)} #{format('%.2f', page.height * MM)}] " \
                  "/Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> >> /Contents #{content_no} 0 R >>"
          objs << [content.bytesize, content]
        end
        objs[0] = '<< /Type /Catalog /Pages 2 0 R >>'
        objs[1] = "<< /Type /Pages /Kids [#{kids.join(' ')}] /Count #{@pages.size} >>"

        out = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
        offsets = []
        objs.each_with_index do |o, i|
          offsets << out.bytesize
          out << "#{i + 1} 0 obj\n".b
          if o.is_a?(Array)
            out << "<< /Length #{o[0]} >>\nstream\n".b << o[1] << "\nendstream".b
          else
            out << o.b
          end
          out << "\nendobj\n".b
        end
        xref = out.bytesize
        out << "xref\n0 #{objs.size + 1}\n0000000000 65535 f \n".b
        offsets.each { |off| out << format("%010d 00000 n \n", off).b }
        out << "trailer\n<< /Size #{objs.size + 1} /Root 1 0 R /Info #{info_no} 0 R >>\nstartxref\n#{xref}\n%%EOF\n".b
        out
      end

      private

      def utf16(str)
        "<FEFF#{str.to_s.encode('UTF-16BE').unpack1('H*')}>"
      end
    end

    # Flowing report on top of PdfDocument: headings, paragraphs and auto-paginating tables, with a page header
    # (title, project, date) and a "Page x of y" footer.
    class PdfReport
      MARGIN = 14.0
      HEADER_H = 12.0
      FOOTER_H = 9.0

      attr_reader :doc, :page, :cursor

      def initialize(title:, project:, size: 'a4', created: Time.now.utc)
        @title = title
        @project = project
        @size = size
        @created = created
        @doc = PdfDocument.new(title: "#{title} - #{project}", created: created)
        new_page
      end

      def width
        @page.width
      end

      def content_width
        width - 2 * MARGIN
      end

      def bottom
        @page.height - MARGIN - FOOTER_H
      end

      def new_page
        @page = @doc.add_page(@size)
        @cursor = MARGIN + HEADER_H
      end

      def ensure_space(h)
        new_page if @cursor + h > bottom
      end

      def heading(text, size: 13)
        ensure_space(size * 0.9)
        @page.text(MARGIN, @cursor + size * 0.35, text, size: size, font: :bold)
        @cursor += size * 0.5 + 3
      end

      def paragraph(text, size: 8.5, color: '444444')
        lines = wrap(text, size, content_width)
        lines.each do |l|
          ensure_space(size * 0.5)
          @page.text(MARGIN, @cursor + size * 0.32, l, size: size, color: color)
          @cursor += size * 0.46
        end
        @cursor += 2
      end

      def spacer(h = 3)
        @cursor += h
      end

      def wrap(text, size, max)
        lines = []
        text.to_s.split("\n").each do |para|
          line = +''
          para.split(' ').each do |w|
            cand = line.empty? ? w : "#{line} #{w}"
            if PdfDocument.text_width_mm(cand, size) > max && !line.empty?
              lines << line
              line = w
            else
              line = cand
            end
          end
          lines << line
        end
        lines
      end

      # columns: [{ 'title' =>, 'width' => weight, 'align' => :left|:right|:center }]; rows: arrays of strings.
      def table(columns, rows, size: 7.5, row_h: 5.0)
        total = columns.sum { |c| c['width'] }.to_f
        widths = columns.map { |c| c['width'] / total * content_width }
        draw_header = lambda do
          ensure_space(row_h * 2)
          @page.rect(MARGIN, @cursor, content_width, row_h, stroke: nil, fill: 'e6e8eb')
          x = MARGIN
          columns.each_with_index do |c, i|
            cell(x, widths[i], @cursor, c['title'], size, c['align'], :bold)
            x += widths[i]
          end
          @cursor += row_h
        end
        draw_header.call
        rows.each_with_index do |row, ri|
          if @cursor + row_h > bottom
            new_page
            draw_header.call
          end
          @page.rect(MARGIN, @cursor, content_width, row_h, stroke: nil, fill: 'f6f7f8') if ri.odd?
          x = MARGIN
          columns.each_with_index do |c, i|
            cell(x, widths[i], @cursor, row[i], size, c['align'], :regular)
            x += widths[i]
          end
          @cursor += row_h
        end
        @page.line(MARGIN, @cursor, MARGIN + content_width, @cursor, width: 0.2, color: '999999')
        @cursor += 3
      end

      def cell(x, w, y, text, size, align, font)
        pad = 1.2
        t = PdfDocument.fit(text.to_s, size, font, w - 2 * pad)
        ty = y + 3.5
        case align
        when :right then @page.text(x + w - pad, ty, t, size: size, font: font, align: :right)
        when :center then @page.text(x + w / 2, ty, t, size: size, font: font, align: :center)
        else @page.text(x + pad, ty, t, size: size, font: font)
        end
      end

      def render
        date = @created.strftime('%Y-%m-%d')
        @doc.render do |pg, i, n|
          pg.text(MARGIN, MARGIN, @title, size: 10, font: :bold)
          pg.text(width - MARGIN, MARGIN, "#{@project}  |  #{date}", size: 8, align: :right, color: '555555')
          pg.line(MARGIN, MARGIN + 3, width - MARGIN, MARGIN + 3, width: 0.3, color: '888888')
          pg.text(MARGIN, pg.height - MARGIN + 2, 'CabinetCraft Pro - all dimensions in mm', size: 7, color: '777777')
          pg.text(width - MARGIN, pg.height - MARGIN + 2, "Page #{i + 1} of #{n}", size: 7, align: :right, color: '777777')
        end
      end
    end
  end
end
