# frozen_string_literal: true

require 'json'
require 'time'

module CabinetCraft
  module Exporters
    # Structured, versioned project JSON for backup and transfer.
    module JsonExporter
      FORMAT = 'cabinetcraft-project'
      FORMAT_VERSION = 1

      module_function

      def project(cabinets, cutting_list)
        JSON.pretty_generate(
          'format' => FORMAT, 'format_version' => FORMAT_VERSION, 'generated_at' => Time.now.utc.iso8601, 'units' => 'mm',
          'cabinets' => cabinets.map do |c|
            c.summary.merge('created_at' => c.created_at, 'parts' => c.part_rows, 'hardware' => c.hardware)
          end,
          'cutting_list' => cutting_list
        )
      end

      def data(rows)
        JSON.pretty_generate('format' => FORMAT, 'format_version' => FORMAT_VERSION, 'units' => 'mm', 'rows' => rows)
      end
    end
  end
end
