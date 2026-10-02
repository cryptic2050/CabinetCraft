# frozen_string_literal: true

module CabinetCraft
  module Exporters
    # CSV output. Cells that start with = + - @ are prefixed with an apostrophe so
    # spreadsheets cannot interpret user-entered text (e.g. custom hardware names) as formulas.
    module CsvExporter
      BOM = "﻿"

      module_function

      # rows: array of hashes; columns: [[key, header], ...]. excel: UTF-8 BOM, CRLF, explicit separator hint.
      def render(rows, columns, excel: false)
        eol = excel ? "\r\n" : "\n"
        lines = []
        lines << 'sep=,' if excel
        lines << columns.map { |_, h| cell(h) }.join(',')
        rows.each { |r| lines << columns.map { |k, _| cell(r[k]) }.join(',') }
        (excel ? BOM : '') + lines.join(eol) + eol
      end

      def cell(value)
        s = value.is_a?(Numeric) ? value.to_s : value.to_s
        s = "'#{s}" if !value.is_a?(Numeric) && s.match?(/\A[=+\-@\t\r]/)
        s.match?(/[",\r\n]/) ? %("#{s.gsub('"', '""')}") : s
      end
    end
  end
end
