# frozen_string_literal: true

require_relative '../core/corner_layout'

module CabinetCraft
  module Interface
    # Corner layouts: a corner cabinet (or none) plus a run along each of two walls, planned together (see CornerLayout).
    # Mixed into Controller; it relies on the controller's run helpers (run_items, preview, in_operation, restretch_job ...).
    module LayoutCommands
      DEFAULT_SIDE = [].freeze

      # Pure calculation, nothing is changed in the model.
      def plan_corner(spec)
        s = layout_spec(spec)
        plan = CornerLayout.plan(s['wall_a'], s['wall_b'], kind: s['kind'], depth: s['depth'], clearance: s['clearance'], corner: s['corner'])
        run_a = side_plan(plan, 'a', s['run_a'])
        run_b = side_plan(plan, 'b', s['run_b'])
        issues = plan['issues'] + [run_a, run_b].compact.flat_map { |r| r['ok'] ? [] : r['issues'] }
        rects = CornerLayout.rectangles(plan, run_a ? run_a['widths'] : [], run_b ? run_b['widths'] : [])
        { 'ok' => plan['ok'] && [run_a, run_b].compact.all? { |r| r['ok'] }, 'issues' => issues, 'layout' => plan, 'run_a' => run_a, 'run_b' => run_b,
          'rects' => rects, 'overlaps' => CornerLayout.overlapping(rects) }
      rescue ArgumentError, TypeError => e
        { 'ok' => false, 'issues' => [e.message], 'layout' => nil, 'run_a' => nil, 'run_b' => nil, 'rects' => [], 'overlaps' => [] }
      end

      # Creates the corner cabinet and both runs in one undo step and remembers the layout. Nothing is created if anything is invalid.
      def create_corner_layout(spec)
        s = layout_spec(spec)
        plan = plan_corner(spec)
        raise ArgumentError, plan['issues'].first.to_s unless plan['ok']

        lay = plan['layout']
        corner = prepare_corner(s, lay)
        runs = { 'a' => prepare_side(s['run_a'], plan['run_a'], s['depth']), 'b' => prepare_side(s['run_b'], plan['run_b'], s['depth']) }
        created = { 'corner' => nil, 'a' => [], 'b' => [] }
        layout = nil
        in_operation('CabinetCraft: Create corner layout', reidentify: false) do
          reidentify_duplicates
          ox = (s['origin'] || [Scene::Registry.next_x_mm(model), 0.0])[0]
          oy = (s['origin'] || [0.0, 0.0])[1]
          created['corner'] = place_one(corner[0], corner[1], lay['corner']['frame'], ox, oy) if corner
          created_a = place_side(runs['a'], plan['run_a'], lay['a']['start'], :a, lay, ox, oy)
          created_b = place_side(runs['b'], plan['run_b'], lay['b']['start'], :b, lay, ox, oy)
          created['a'] = created_a[:cabinets]
          created['b'] = created_b[:cabinets]
          snapshot_materials
          snapshot_templates
          layout = CornerLayout::Record.new(id: SecureRandom.uuid, name: next_layout_name, kind: lay['kind'], wall_a: s['wall_a'], wall_b: s['wall_b'], depth: s['depth'],
                                            clearance: s['clearance'], origin: [ox, oy], corner_cabinet_id: created['corner']&.fetch('id', nil),
                                            run_a_id: created_a[:run_id], run_b_id: created_b[:run_id])
          save_layout(layout)
        end
        { 'ok' => true, 'created' => created, 'layout' => layout_summary(layout), 'plan' => plan }
      end

      def layouts_state
        { 'layouts' => stored_layouts.map { |l| layout_summary(l) } }
      end

      def unlink_layout(layout_id)
        all = project_store.layouts
        raise ArgumentError, 'That layout no longer exists' unless all.key?(layout_id)

        in_operation('CabinetCraft: Unlink corner layout', reidentify: false) do
          all.delete(layout_id)
          project_store.layouts = all
        end
        layouts_state
      end

      # Re-plans both runs for new wall lengths (nil keeps the current one). One undo step. The corner cabinet keeps its size (edit it
      # normally); the runs follow its current size. mode: 'keep' / 'reset' for manual overrides, as in `update`.
      def restretch_layout(layout_id, wall_a = nil, wall_b = nil, mode = nil)
        rec = stored_layouts.find { |l| l.id == layout_id } or raise ArgumentError, 'That layout no longer exists'
        rec = rec.with_walls(wall_a.nil? || wall_a.to_s.strip.empty? ? rec.wall_a : wall_a, wall_b.nil? || wall_b.to_s.strip.empty? ? rec.wall_b : wall_b)
        corner_group, corner = layout_corner(rec)
        plan = CornerLayout.plan(rec.wall_a, rec.wall_b, kind: rec.kind, depth: rec.depth, clearance: rec.clearance, corner: corner_dims(rec, corner))
        raise ArgumentError, plan['issues'].first.to_s unless plan['ok']

        ox, oy = rec.origin
        jobs = []
        jobs << restretch_job(rec.run_a_id, plan['a']['length'], nil, mode, base: ox + plan['a']['start']) if rec.run_a_id
        jobs << restretch_job(rec.run_b_id, plan['b']['length'], nil, mode, base: oy + plan['b']['start']) if rec.run_b_id
        pending = jobs.select { |j| j.key?('needs_confirmation') }
        return { 'ok' => false, 'updated' => false, 'needs_confirmation' => true, 'affected' => pending.flat_map { |j| j['affected'] } } if pending.any?

        in_operation('CabinetCraft: Resize corner layout', reidentify: false) do
          align_corner(corner_group, rec, ox, oy)
          jobs.each { |j| apply_restretch(j) }
          save_layout(rec)
        end
        { 'ok' => true, 'updated' => true, 'layout' => layout_summary(rec), 'plan' => plan }
      end

      def stored_layouts
        project_store.layouts.values.filter_map { |raw| CornerLayout::Record.from_h(raw) }
      end

      def save_layout(rec)
        all = project_store.layouts
        all[rec.id] = rec.to_h
        project_store.layouts = all
      end

      def next_layout_name
        used = stored_layouts.filter_map { |l| l.name[/\AL(\d+)\z/, 1]&.to_i }
        format('L%<n>02d', n: (used.max || 0) + 1)
      end

      def layout_summary(rec)
        group, corner = rec.corner_cabinet_id ? Scene::Registry.find(model, rec.corner_cabinet_id) : nil
        runs = stored_runs.to_h { |r| [r.id, r] }
        a = rec.run_a_id && runs[rec.run_a_id] ? run_summary(runs[rec.run_a_id]) : nil
        b = rec.run_b_id && runs[rec.run_b_id] ? run_summary(runs[rec.run_b_id]) : nil
        corner_ok = rec.kind == 'none' || !group.nil?
        { 'id' => rec.id, 'name' => rec.name, 'kind' => rec.kind, 'wall_a' => rec.wall_a, 'wall_b' => rec.wall_b, 'depth' => rec.depth, 'clearance' => rec.clearance,
          'corner' => rec.kind == 'none' ? nil : { 'cabinet_id' => rec.corner_cabinet_id, 'label' => corner&.label, 'present' => !group.nil? },
          'run_a' => a, 'run_b' => b,
          'in_sync' => corner_ok && [a, b].compact.all? { |r| r['in_sync'] } && (rec.run_a_id.nil? || !a.nil?) && (rec.run_b_id.nil? || !b.nil?) }
      end

      private

      def layout_spec(raw)
        raise ArgumentError, 'Layout details are missing' unless raw.is_a?(Hash)

        s = raw.transform_keys(&:to_s)
        corner = (s['corner'] || {}).transform_keys(&:to_s)
        { 'wall_a' => s['wall_a'], 'wall_b' => s['wall_b'], 'kind' => s['kind'] || 'none', 'depth' => s['depth'] || CornerLayout::DEFAULT_DEPTH,
          'clearance' => s['clearance'] || CornerLayout::DEFAULT_CLEARANCE, 'corner' => corner, 'run_a' => s['run_a'] || DEFAULT_SIDE, 'run_b' => s['run_b'] || DEFAULT_SIDE,
          'origin' => s['origin'].is_a?(Array) && s['origin'].size == 2 ? s['origin'].map { |v| Float(v) } : nil }
      end

      # RunPlanner plan for one side, or nil when the side has no cabinets.
      def side_plan(plan, side, items)
        return nil if items.nil? || items.empty?
        return { 'ok' => false, 'widths' => [], 'issues' => plan['issues'] } unless plan['ok']

        RunPlanner.plan(plan[side]['length'], run_items(items).map { |i| i.slice('fixed', 'width', 'min', 'max') })
      end

      def schema_keys(type)
        (Library.schema_for(type) || []).map { |f| f['key'] }
      end

      # [type, params] for the corner cabinet, with the layout's sizes written into the template's own parameters.
      def prepare_corner(s, lay)
        return nil if s['kind'] == 'none'

        type = s['corner']['type'].to_s
        raise ArgumentError, 'Choose a corner cabinet type' if type.empty?
        raise ArgumentError, "Unknown cabinet type '#{type}'" unless Library.entry(type)

        keys = schema_keys(type)
        needed = s['kind'] == 'blind' ? %w[width] : %w[width_a width_b]
        missing = needed - keys
        raise ArgumentError, "'#{type}' has no #{missing.join(' / ')} parameter: it cannot be used as a #{s['kind'].tr('_', '-')} corner cabinet" if missing.any?

        params = (s['corner']['params'] || {}).transform_keys(&:to_s)
        sizes = s['kind'] == 'blind' ? { 'width' => lay['corner']['width'] } : { 'width_a' => lay['corner']['width_a'], 'width_b' => lay['corner']['width_b'] }
        sizes['depth'] = lay['depth'] if keys.include?('depth')
        sizes['blind_right'] = '1' if s['kind'] == 'blind' && keys.include?('blind_right') # blind side towards the corner
        prepared_cabinet(type, params.merge(sizes), 'The corner cabinet')
      end

      def prepare_side(items, run_plan, depth)
        return [] unless run_plan

        run_items(items).each_with_index.map do |it, n|
          extra = schema_keys(it['type']).include?('depth') ? { 'depth' => depth } : {}
          prepared_cabinet(it['type'], (it['params'] || {}).merge(extra).merge('width' => run_plan['widths'][n]), "Cabinet #{n + 1} (#{it['type']})")
        end
      end

      def prepared_cabinet(type, params, who)
        prev = preview(type, params)
        raise ArgumentError, "#{who}: #{prev['issues'].find { |i| i['severity'] == 'error' }&.fetch('message', nil) || 'invalid'}" unless prev['ok']

        [type, prev['params']]
      end

      def frame_transformation(frame, ox, oy)
        Geom::Transformation.new(Geom::Point3d.new(Units.to_sketchup(ox + frame['origin'][0]), Units.to_sketchup(oy + frame['origin'][1]), 0),
                                 Geom::Vector3d.new(frame['x_axis'][0], frame['x_axis'][1], 0), Geom::Vector3d.new(frame['y_axis'][0], frame['y_axis'][1], 0))
      end

      def place_one(type, params, frame, ox, oy)
        cabinet = Cabinet.build(type: type, params: params, label: Scene::Registry.next_label(model))
        Generators::CabinetGenerator.create(model.entities, cabinet, frame_transformation(frame, ox, oy))
        cabinet.summary
      end

      # Creates the cabinets of one run and stores the run. Returns { cabinets:, run_id: }.
      def place_side(prepared, run_plan, start, side, lay, ox, oy)
        return { cabinets: [], run_id: nil } if prepared.empty?

        pos = start
        cabinets = prepared.each_with_index.map do |(type, params), n|
          w = run_plan['widths'][n]
          frame = side == :a ? CornerLayout.frame_a(pos, w, lay['depth']) : CornerLayout.frame_b(pos, w, lay['depth'])
          pos += w
          place_one(type, params, frame, ox, oy)
        end
        items = prepared.each_with_index.map { |_, n| { 'cabinet_id' => cabinets[n]['id'], 'fixed' => false, 'min' => RunPlanner::DEFAULT_MIN, 'max' => RunPlanner::DEFAULT_MAX } }
        run = Run.build(name: next_run_name, length: lay[side.to_s]['length'], items: items, axis: side == :a ? 'x' : 'y')
        save_run(run)
        { cabinets: cabinets, run_id: run.id }
      end

      def layout_corner(rec)
        return [nil, nil] if rec.kind == 'none'

        entry = Scene::Registry.find_entry(model, rec.corner_cabinet_id.to_s)
        raise ArgumentError, 'The corner cabinet of this layout is no longer in the model: unlink the layout and create it again' unless entry
        raise ArgumentError, "#{entry.cabinet.label} is inside another group or component: corner layouts can only move cabinets at the top level of the model" if entry.nested?

        [entry.entity, entry.cabinet]
      end

      def corner_dims(rec, cab)
        case rec.kind
        when 'blind' then { 'width' => cab.params['width'] }
        when 'l_shaped' then { 'width_a' => cab.params['width_a'], 'width_b' => cab.params['width_b'] }
        else {}
        end
      end

      # A blind cabinet is turned 180 degrees, so when its width changes it grows towards -X: slide it back against wall B.
      def align_corner(group, rec, ox, _oy)
        return unless group && rec.kind == 'blind'

        delta = Units.to_sketchup(ox - Units.from_sketchup(group.bounds.min.x))
        group.transform!(Geom::Transformation.translation(Geom::Vector3d.new(delta, 0, 0))) if delta.abs > 1e-9
      end
    end
  end
end
