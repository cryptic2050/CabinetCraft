# frozen_string_literal: true

require 'time'

module CabinetCraft
  module Manufacturing
    # Production progress per part. The record lives in the model (ProjectStore#production), keyed by part uid, and carries the part's
    # size when each stage was recorded: a part that changed size afterwards no longer counts as done (it has to be cut again).
    #
    # Stages: cut (on the saw / router), banded (edge banding applied), drilled (machining done), assembled (fitted into its cabinet).
    # "banded" only applies to parts that have edge banding and "drilled" only to parts that have machining operations.
    module Production
      STAGES = %w[cut banded drilled assembled].freeze
      LABELS = { 'cut' => 'Cut', 'banded' => 'Edge banded', 'drilled' => 'Drilled', 'assembled' => 'Assembled' }.freeze

      module_function

      def signature(row)
        "#{row['length'].to_f.round(1)}x#{row['width'].to_f.round(1)}x#{row['thickness'].to_f.round(1)}"
      end

      # Which stages apply to a part. ops_by_uid: { part_uid => [ops] }
      def applicable(row, ops_by_uid)
        stages = %w[cut]
        stages << 'banded' unless row['edge_codes'].nil? || row['edge_codes'].empty?
        stages << 'drilled' if ops_by_uid.key?(row['part_uid'])
        stages << 'assembled'
        stages
      end

      # Stage -> done?, for one part. Records whose size no longer matches are ignored.
      def done_stages(row, state)
        rec = state[row['part_uid']]
        return {} unless rec.is_a?(Hash) && rec['sig'] == signature(row) && rec['stages'].is_a?(Hash)

        rec['stages'].select { |s, at| STAGES.include?(s) && at.is_a?(String) }.transform_values { true }
      end

      # New state with `stage` set or cleared for one part. Pure: the old state is not changed.
      def mark(state, row, stage, done, now = Time.now.utc)
        raise ArgumentError, "Unknown stage '#{stage}' (use #{STAGES.join(', ')})" unless STAGES.include?(stage)

        out = state.dup
        sig = signature(row)
        rec = out[row['part_uid']]
        stages = rec.is_a?(Hash) && rec['sig'] == sig && rec['stages'].is_a?(Hash) ? rec['stages'].dup : {}
        done ? stages[stage] = now.iso8601 : stages.delete(stage)
        stages.empty? ? out.delete(row['part_uid']) : out[row['part_uid']] = { 'sig' => sig, 'stages' => stages }
        out
      end

      # rows: parts list rows; state: the stored record. Records for parts that no longer exist are ignored.
      def summary(rows, state, ops_by_uid)
        stage_totals = STAGES.to_h { |s| [s, { 'done' => 0, 'total' => 0 }] }
        cabinets = {}
        rows.each do |r|
          done = done_stages(r, state)
          app = applicable(r, ops_by_uid)
          c = (cabinets[r['cabinet_id']] ||= { 'cabinet_id' => r['cabinet_id'], 'label' => r['cabinet_label'], 'parts' => 0,
                                               'stages' => STAGES.to_h { |s| [s, { 'done' => 0, 'total' => 0 }] } })
          c['parts'] += 1
          app.each do |s|
            [stage_totals[s], c['stages'][s]].each do |t|
              t['total'] += 1
              t['done'] += 1 if done[s]
            end
          end
        end
        total = stage_totals.values.sum { |t| t['total'] }
        done = stage_totals.values.sum { |t| t['done'] }
        { 'stages' => stage_totals, 'cabinets' => cabinets.values.sort_by { |c| c['label'].to_s },
          'progress' => total.zero? ? 0.0 : (done * 100.0 / total).round(1), 'parts' => rows.size,
          'complete_parts' => rows.count { |r| (applicable(r, ops_by_uid) - done_stages(r, state).keys).empty? } }
      end

      # The state of one part, for the scan lookup.
      def part_status(row, state, ops_by_uid)
        done = done_stages(row, state)
        app = applicable(row, ops_by_uid)
        STAGES.map { |s| { 'stage' => s, 'label' => LABELS[s], 'applies' => app.include?(s), 'done' => done[s] ? true : false } }
      end
    end
  end
end
