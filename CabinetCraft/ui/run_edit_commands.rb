# frozen_string_literal: true

module CabinetCraft
  module Interface
    # Editing the membership of a linked run: recreate deleted cabinets, add a cabinet at a position, remove one.
    # Mixed into Controller; relies on its run helpers (stored_runs, run_summary, stretch_prepare, stretch_apply, along ...).
    module RunEditCommands
      # Recreates the cabinets of a run that were deleted from the model, as they were (type and parameters are stored with the run),
      # at the positions the plan gives them, with the same orientation as a surviving member. One undo step.
      def repair_run(run_id)
        run = find_run!(run_id)
        entries = member_entries(run)
        missing = entries.each_index.select { |n| entries[n].nil? }
        raise ArgumentError, "Nothing to repair: every cabinet of #{run.name} is in the model" if missing.empty?
        raise ArgumentError, "Every cabinet of #{run.name} is gone: there is nothing to line the new ones up with. Unlink the run and create it again" if missing.size == entries.size

        refuse_nested!(entries.compact)
        plan = run.plan
        raise ArgumentError, plan['issues'].first.to_s unless plan['ok']

        no_snapshot = missing.find { |n| run.items[n]['type'].to_s.empty? || !run.items[n]['params'].is_a?(Hash) }
        raise ArgumentError, "Cabinet #{no_snapshot + 1} of #{run.name} cannot be recreated: it was saved before runs remembered their cabinets (re-plan the run once to record them, then repair)" if no_snapshot

        ref = reference_entry(entries)
        base = run_base(run, entries, plan)
        prepared = missing.to_h { |n| [n, prepared_cabinet(run.items[n]['type'], run.items[n]['params'].merge('width' => plan['widths'][n]), "Cabinet #{n + 1} of #{run.name}")] }
        items = run.items.map(&:dup)
        in_operation('CabinetCraft: Repair run', reidentify: false) do
          missing.each do |n|
            type, params = prepared[n]
            cab = Cabinet.build(type: type, params: params, label: Scene::Registry.next_label(model))
            place_like(ref.entity, cab, base + plan['widths'].first(n).sum, run.axis, run.dir)
            items[n] = items[n].merge('cabinet_id' => cab.id, 'params' => params)
          end
          snapshot_materials
          snapshot_templates
          save_run(run.with_items(items))
        end
        { 'ok' => true, 'repaired' => missing.size, 'runs' => runs_state['runs'] }
      end

      # Adds a cabinet at `index` (0 = start of the row) and re-plans the row at the same wall length. spec: { 'type', 'params', 'fixed',
      # 'width', 'min', 'max', 'filler' } as for a new run. mode: 'keep' / 'reset' for overrides the new widths would change.
      def add_to_run(run_id, index, spec, mode = nil)
        run = find_run!(run_id)
        entries = member_entries(run)
        raise ArgumentError, "A cabinet of #{run.name} is no longer in the model: repair the run first" if entries.any?(&:nil?)

        refuse_nested!(entries)
        index = Integer(index)
        raise ArgumentError, "Position must be between 0 and #{run.items.size}" unless index.between?(0, run.items.size)

        item = run_items([spec]).first
        planned = insert_at(run.planner_items, index, planner_item(item))
        plan = RunPlanner.plan(run.length, planned)
        raise ArgumentError, plan['issues'].first.to_s unless plan['ok']

        old_plan = run.plan
        existing_widths = plan['widths'].dup.tap { |w| w.delete_at(index) }
        members = entries.map { |e| [e.entity, e.cabinet] }
        prepared = stretch_prepare(members, existing_widths, mode)
        return prepared if prepared.is_a?(Hash)

        type, params = prepared_cabinet(item['type'], (item['params'] || {}).merge('width' => plan['widths'][index]), 'The new cabinet')
        base = run_base(run, entries, old_plan)
        ref = reference_entry(entries)
        created = nil
        in_operation('CabinetCraft: Add cabinet to run', reidentify: false) do
          reidentify_duplicates
          cab = Cabinet.build(type: type, params: params, label: Scene::Registry.next_label(model))
          group = place_like(ref.entity, cab, base + plan['widths'].first(index).sum, run.axis, run.dir)
          created = cab.summary
          new_item = run_item(item, cab.id, plan['widths'][index], params)
          items = insert_at(run.items, index, new_item)
          all = insert_at(prepared, index, [group, nil, plan['widths'][index]])
          stretch_apply(all, base, run.axis, run.dir)
          snapshot_materials
          snapshot_templates
          updated = run.with_items(items)
          snaps = all.each_with_index.map { |(g, new_cab, _), n| n == index ? params : (new_cab || members[n - (n > index ? 1 : 0)][1]).params }
          save_run(updated.with_params(snaps).with_types(items.each_index.map { |n| n == index ? type : members[n - (n > index ? 1 : 0)][1].type }))
        end
        { 'ok' => true, 'created' => created, 'plan' => plan, 'runs' => runs_state['runs'] }
      end

      # Takes the cabinet at `index` out of the run and re-plans the others at the same wall length. With erase the cabinet is also
      # deleted from the model; otherwise it stays where it is, no longer part of the run.
      def remove_from_run(run_id, index, erase = false, mode = nil)
        run = find_run!(run_id)
        entries = member_entries(run)
        index = Integer(index)
        raise ArgumentError, "There is no cabinet #{index + 1} in #{run.name}" unless index.between?(0, run.items.size - 1)
        raise ArgumentError, "#{run.name} would be empty: unlink the run instead" if run.items.size == 1

        refuse_nested!(entries.compact)
        old_plan = run.plan
        removed = entries[index]
        rest_entries = entries.each_index.reject { |n| n == index }.map { |n| entries[n] }
        raise ArgumentError, "A cabinet of #{run.name} is no longer in the model: repair the run first" if rest_entries.any?(&:nil?)

        items = run.items.each_with_index.reject { |_, n| n == index }.map(&:first)
        plan = RunPlanner.plan(run.length, items.map { |i| planner_item(i) })
        raise ArgumentError, plan['issues'].first.to_s unless plan['ok']

        members = rest_entries.map { |e| [e.entity, e.cabinet] }
        prepared = stretch_prepare(members, plan['widths'], mode)
        return prepared if prepared.is_a?(Hash)

        base = run_base(run, entries, old_plan)
        in_operation('CabinetCraft: Remove cabinet from run', reidentify: false) do
          removed.entity.erase! if erase && removed
          stretch_apply(prepared, base, run.axis, run.dir)
          snaps = prepared.each_with_index.map { |(_, new_cab, _), n| (new_cab || members[n][1]).params }
          save_run(run.with_items(items).with_params(snaps))
        end
        { 'ok' => true, 'removed' => removed&.cabinet&.label, 'erased' => erase && !removed.nil?, 'plan' => plan, 'runs' => runs_state['runs'] }
      end

      private

      def find_run!(run_id)
        stored_runs.find { |r| r.id == run_id } or raise ArgumentError, 'That run no longer exists'
      end

      # One Registry entry (or nil when the cabinet is gone) per run item.
      def member_entries(run)
        run.items.map { |i| Scene::Registry.find_entry(model, i['cabinet_id']) }
      end

      def refuse_nested!(entries)
        nested = entries.find(&:nested?)
        raise ArgumentError, "#{nested.cabinet.label} is inside another group or component: runs can only move cabinets at the top level of the model" if nested
      end

      def reference_entry(entries)
        entries.compact.first
      end

      def insert_at(list, index, value)
        list.dup.tap { |l| l.insert(index, value) }
      end

      # Where the first cabinet of the row starts along the run's axis: the first surviving member's position minus the planned widths before it.
      def run_base(run, entries, plan)
        n = entries.index { |e| !e.nil? }
        along(entries[n].entity, run.axis, run.dir) - plan['widths'].first(n).sum
      end

      def prepared_cabinet(type, params, who)
        prev = preview(type, params)
        raise ArgumentError, "#{who}: #{prev['issues'].find { |i| i['severity'] == 'error' }&.fetch('message', nil) || 'invalid'}" unless prev['ok']

        [type, prev['params']]
      end

      # Creates the cabinet's group with the same orientation as `neighbor` and slides it so its start along the row (`axis`, advancing in `dir`) is `position` mm,
      # its start across the row and its floor level match the neighbour's.
      def place_like(neighbor, cabinet, position, axis, dir = 1)
        t = neighbor.transformation
        rotation = Geom::Transformation.new(Geom::Point3d.new(0, 0, 0), t.xaxis, t.yaxis)
        group = Generators::CabinetGenerator.create(model.entities, cabinet, rotation)
        other = axis == 'x' ? 'y' : 'x'
        slide(group, axis, dir * (position - along(group, axis, dir)))
        slide(group, other, min_along(neighbor, other) - min_along(group, other))
        slide(group, 'z', min_along(neighbor, 'z') - min_along(group, 'z'))
        group
      end

      def min_along(group, axis)
        Units.from_sketchup(group.bounds.min.send(axis.to_sym))
      end

      def slide(group, axis, delta_mm)
        return if delta_mm.abs < 1e-9

        d = Units.to_sketchup(delta_mm)
        v = { 'x' => Geom::Vector3d.new(d, 0, 0), 'y' => Geom::Vector3d.new(0, d, 0), 'z' => Geom::Vector3d.new(0, 0, d) }.fetch(axis)
        group.transform!(Geom::Transformation.translation(v))
      end
    end
  end
end
