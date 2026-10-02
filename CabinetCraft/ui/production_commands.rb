# frozen_string_literal: true

module CabinetCraft
  module Interface
    # Production progress (cut / banded / drilled / assembled per part). Mixed into Controller. The record is stored in the model.
    module ProductionCommands
      def production_state
        rows, ops = production_inputs
        sum = Manufacturing::Production.summary(rows, project_store.production, ops)
        sum.merge('stage_labels' => Manufacturing::Production::LABELS, 'stage_order' => Manufacturing::Production::STAGES)
      end

      # Marks one part. stage: cut / banded / drilled / assembled. done false clears it.
      def set_part_stage(part_uid, stage, done = true)
        mark_parts('CabinetCraft: Production status', stage, done) { |rows| rows.select { |r| r['part_uid'] == part_uid }.tap { |l| raise ArgumentError, 'Unknown part' if l.empty? } }
      end

      # Marks every part of a cabinet that the stage applies to.
      def set_cabinet_stage(cabinet_id, stage, done = true)
        mark_parts('CabinetCraft: Production status', stage, done) { |rows| rows.select { |r| r['cabinet_id'] == cabinet_id }.tap { |l| raise ArgumentError, 'That cabinet no longer exists in the model' if l.empty? } }
      end

      # Marks every part placed on one nested sheet (e.g. "all parts of sheet 2 are cut").
      def set_sheet_stage(material, sheet_index, stage, done = true)
        m = nest['materials'].find { |x| x['material'] == material } or raise ArgumentError, 'Unknown material'
        sh = m['sheets'][sheet_index.to_i] or raise ArgumentError, 'Unknown sheet'
        uids = sh['placements'].map { |p| p['uid'] }
        mark_parts('CabinetCraft: Production status', stage, done) { |rows| rows.select { |r| uids.include?(r['part_uid']) } }
      end

      private

      def production_inputs
        cabs = project_cabinets
        rows = Manufacturing::PartsList.build(cabs)
        ops = Manufacturing::Machining.for_project(cabs)['ops'].group_by { |o| o['part_uid'] }
        [rows, ops]
      end

      # Parts to which the stage does not apply (e.g. "banded" for an unbanded part) are skipped, not marked.
      def mark_parts(operation, stage, done)
        raise ArgumentError, "Unknown stage '#{stage}'" unless Manufacturing::Production::STAGES.include?(stage)

        rows, ops = production_inputs
        targets = yield(rows).select { |r| Manufacturing::Production.applicable(r, ops).include?(stage) }
        state = project_store.production
        targets.each { |r| state = Manufacturing::Production.mark(state, r, stage, done) }
        in_operation(operation, reidentify: false) { project_store.production = state }
        production_state.merge('marked' => targets.size)
      end
    end
  end
end
