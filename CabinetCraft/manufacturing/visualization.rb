# frozen_string_literal: true

module CabinetCraft
  module Manufacturing
    # Visualization modes: which colour each part of the model is shown in. Pure classification; Scene::Visualization applies the colours
    # to the part groups in the SketchUp model (reversibly: the 'material' mode restores each part's real material).
    #
    # Modes: material (real materials), role (kind of part), grain (grain direction), edges (edge banding), overrides (manual overrides),
    # status (production progress), cabinet (one colour per cabinet) and presentation (fronts in their real material, the carcass see-through).
    module Visualization
      MODES = {
        'material' => 'Real materials',
        'role' => 'Kind of part',
        'grain' => 'Grain direction',
        'edges' => 'Edge banding',
        'overrides' => 'Manual overrides',
        'status' => 'Production progress',
        'cabinet' => 'By cabinet',
        'grainsets' => 'Matching-grain sets',
        'presentation' => 'Presentation (see-through carcass)'
      }.freeze

      # Categorical slots in a fixed order (never cycled), colour-vision safe on a dark background; see the dashboard colours.
      PALETTE = %w[#3987e5 #d95926 #199e70 #c98500 #d55181 #9085e9 #66b5c9 #b0a24a].freeze
      NEUTRAL = '#8d8f94'
      GOOD = '#0ca30c'
      WARN = '#fab219'
      CARCASS_ALPHA = 0.28

      ROLE_GROUPS = {
        'Structure (sides, bottom, top, rails, dividers)' => %i[side bottom top brace divider fixed_shelf toe_kick],
        'Shelves' => %i[shelf], 'Back' => %i[back], 'Fronts (doors, drawer fronts)' => %i[door drawer_front], 'Drawer boxes' => %i[drawer_box]
      }.freeze
      ROLE_OTHER = 'Other parts'
      FRONT_ROLES = %i[door drawer_front].freeze

      module_function

      def modes
        MODES
      end

      # cabinets: Cabinet list. production: Production state hash (only used by 'status'); ops_by_uid for the applicable stages.
      # => { 'mode', 'parts' => { part_uid => { 'key', 'label', 'color', 'alpha' } }, 'legend' => [{ 'label', 'color', 'count' }] }
      def assign(mode, cabinets, production: {}, ops_by_uid: {}, grain_sets: {})
        raise ArgumentError, "Unknown visualization mode '#{mode}' (use #{MODES.keys.join(', ')})" unless MODES.key?(mode)

        parts = {}
        cabinets.each_with_index do |cab, ci|
          rows = cab.part_rows.to_h { |r| [r['key'], r] }
          cab.panels.each do |panel|
            row = rows[panel.key]
            parts[row['part_uid']] = classify(mode, cab, panel, row, ci, production, ops_by_uid, grain_sets)
          end
        end
        colour(mode, parts)
      end

      # Raw classification: { 'key' => category id, 'label' => text, 'alpha' => nil | 0..1 } (colours are assigned afterwards, in a fixed order).
      def classify(mode, cab, panel, row, index, production, ops_by_uid, grain_sets = {})
        case mode
        when 'material' then { 'key' => row['material_id'], 'label' => row['material'], 'real' => true }
        when 'role' then role_class(panel)
        when 'grain' then { 'key' => row['grain'], 'label' => { 'length' => 'Grain along the length', 'width' => 'Grain along the width', 'none' => 'No grain direction' }.fetch(row['grain'], row['grain']) }
        when 'edges' then edge_class(panel)
        when 'overrides' then panel.overridden.empty? ? { 'key' => 'auto', 'label' => 'Automatic' } : { 'key' => 'manual', 'label' => 'Manually overridden' }
        when 'status' then status_class(row, production, ops_by_uid)
        when 'grainsets' then grain_set_class(grain_sets[row['part_uid']])
        when 'cabinet' then { 'key' => "cabinet:#{index}", 'label' => cab.label }
        when 'presentation' then FRONT_ROLES.include?(panel.role) ? { 'key' => 'front', 'label' => 'Fronts (real material)', 'real' => true } : { 'key' => 'carcass', 'label' => 'Carcass (see-through)', 'alpha' => CARCASS_ALPHA }
        end
      end

      def grain_set_class(label)
        return { 'key' => 'none', 'label' => 'Not in a set' } unless label

        set = label[/\A[A-Z]+/]
        { 'key' => "set:#{set}", 'label' => "Set #{set}" }
      end

      def role_class(panel)
        label = ROLE_GROUPS.find { |_, roles| roles.include?(panel.role) }&.first || ROLE_OTHER
        { 'key' => label, 'label' => label }
      end

      def edge_class(panel)
        return { 'key' => 'none', 'label' => 'No edge banding' } if panel.edges.empty?

        thick = panel.edges.values.uniq.sort
        thick.size == 1 ? { 'key' => "t#{thick.first}", 'label' => "#{format('%g', thick.first)} mm band" } : { 'key' => 'mixed', 'label' => 'Mixed band thicknesses' }
      end

      def status_class(row, production, ops_by_uid)
        applies = Production.applicable(row, ops_by_uid)
        done = Production.done_stages(row, production)
        return { 'key' => 'complete', 'label' => 'All steps done' } if (applies - done.keys).empty?

        done.empty? ? { 'key' => 'todo', 'label' => 'Not started' } : { 'key' => 'partial', 'label' => 'In progress' }
      end

      # Assigns colours in a fixed order per mode (so a legend entry keeps its colour whatever else is present) and builds the legend.
      def colour(mode, parts)
        labels = parts.values.map { |p| [p['key'], p['label']] }.uniq
        order = category_order(mode, labels)
        fixed = FIXED_ORDER[mode]
        # fixed-order modes colour by the category's own position, so a colour never depends on which other categories are present
        colours = order.each_with_index.to_h { |(key, _), i| [key, category_colour(mode, key, fixed ? (fixed.index(key) || fixed.size) : i)] }
        out = parts.transform_values { |p| p.merge('color' => colours[p['key']]) }
        legend = order.map do |key, label|
          sample = parts.values.find { |p| p['key'] == key }
          { 'label' => label, 'color' => colours[key], 'count' => parts.values.count { |p| p['key'] == key }, 'alpha' => sample['alpha'], 'real' => sample['real'] ? true : false }
        end
        { 'mode' => mode, 'parts' => out, 'legend' => legend }
      end

      FIXED_ORDER = {
        'role' => ROLE_GROUPS.keys + [ROLE_OTHER],
        'grain' => %w[length width none],
        'overrides' => %w[auto manual],
        'status' => %w[todo partial complete],
        'presentation' => %w[front carcass]
      }.freeze

      def edge_colour(key)
        return NEUTRAL if key == 'none'
        return PALETTE[6] if key == 'mixed'

        PALETTE[BAND_SLOT.fetch(key.delete_prefix('t').to_f, 7)]
      end

      def category_order(mode, labels)
        fixed = FIXED_ORDER[mode]
        return labels.sort_by { |key, label| [label.to_s, key.to_s] } unless fixed

        labels.sort_by { |key, _| [fixed.index(key) || fixed.size, key.to_s] }
      end

      # Edge band colours follow the thickness itself (so 1 mm is always the same colour), mixed bands have their own.
      BAND_SLOT = { 0.4 => 0, 0.5 => 0, 0.8 => 1, 1.0 => 2, 1.5 => 3, 2.0 => 4, 3.0 => 5 }.freeze

      def category_colour(mode, key, index)
        case mode
        when 'material' then Material.find(key)&.color || NEUTRAL
        when 'edges' then edge_colour(key)
        when 'status' then { 'todo' => NEUTRAL, 'partial' => WARN, 'complete' => GOOD }.fetch(key, NEUTRAL)
        when 'grainsets' then key == 'none' ? NEUTRAL : PALETTE[key.delete_prefix('set:').each_char.sum { |c| c.ord - 65 } % PALETTE.size]
        when 'overrides' then key == 'manual' ? PALETTE[1] : NEUTRAL
        when 'presentation' then key == 'carcass' ? '#c9ccd2' : PALETTE[0]
        else PALETTE[index % PALETTE.size]
        end
      end
    end
  end
end
