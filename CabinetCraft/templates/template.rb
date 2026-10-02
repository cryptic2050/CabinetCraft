# frozen_string_literal: true

require 'json'
require_relative 'expression'
require_relative '../core/material'
require_relative '../core/hardware'
require_relative '../core/panel'
require_relative '../core/rules'

module CabinetCraft
  module Templates
    # A user-defined parametric cabinet. Pure data (JSON) + formulas in the Expression language; no code runs.
    #
    #   { "format": "cabinetcraft-template", "version": 1, "name": "...", "category": "CUSTOM", "description": "",
    #     "parameters":  [{ "key", "label", "type": length|int|toggle|material|hardware, "default", "min", "max", "group", "note",
    #                       "role": carcass|back (material), "category": hinge|... (hardware) }],
    #     "derived":     [{ "name", "expr", "label" }],            # computed in order, shown to the user
    #     "constraints": [{ "expr", "message", "severity": error|warning }],  # expr must be true (non-zero)
    #     "panels":      [{ "key", "name", "role", "material": <material parameter key | material id>,
    #                       "size": [ex, ey, ez], "origin": [x, y, z], "thickness_axis": "x|y|z", "grain_axis": "x|y|z|null",
    #                       "repeat": <expr>, "if": <expr>, "edges": { "front": <expr>, ... }, "grooved_into": [keys] }],
    #     "hardware":    [{ "id": <hardware id | "$parameter">, "qty": <expr>, "part": <panel key | "cabinet">, "repeat": <expr>, "detail": "" }] }
    #
    # Axes: x = width (left to right), y = depth (front to back), z = height; `size` is the extent along x, y, z and
    # `origin` the minimum corner. Inside `repeat` the variables `i` (0-based) and `n` (the count) are available.
    # A material parameter `m` also provides the variable `m_t` (its thickness).
    class Template
      FORMAT = 'cabinetcraft-template'
      FORMAT_VERSION = 1
      ROLES = %w[side bottom top back brace shelf fixed_shelf divider toe_kick door drawer_front drawer_box panel].freeze
      PARAM_TYPES = %w[length int toggle material hardware].freeze
      KEY = /\A[a-z][a-z0-9_]{0,29}\z/.freeze
      RESERVED = %w[i n] + Expression::FUNCTIONS.keys
      AXES = %w[x y z].freeze
      LIMITS = { parameters: 40, derived: 60, constraints: 30, panels: 40, hardware: 40, generated_panels: 200, repeat: 60, extent: 10_000.0 }.freeze

      class Invalid < StandardError
        attr_reader :errors

        def initialize(errors)
          @errors = errors
          super(errors.first(5).join('; '))
        end
      end

      Build = Struct.new(:result, :panels, :hardware)

      attr_reader :id, :name, :category, :description, :parameters, :derived, :constraints, :panel_specs, :hardware_specs

      def self.from_json(text)
        from_h(JSON.parse(text))
      rescue JSON::ParserError => e
        raise Invalid, ["Not valid JSON: #{e.message[0, 100]}"]
      end

      # Validates and returns a Template; raises Invalid with every problem found (each prefixed with where it is).
      def self.from_h(raw, id: nil)
        errs = []
        t = new(raw, id, errs)
        raise Invalid, errs unless errs.empty?

        t
      end

      def initialize(raw, id, errs)
        @errs = errs
        unless raw.is_a?(Hash)
          errs << 'A template must be a JSON object'
          return
        end
        @id = id || raw['id']
        @name = str(raw['name'], 60, 'name', required: true)
        @category = str(raw['category'] || 'CUSTOM', 40, 'category', required: true).to_s.upcase
        @description = str(raw['description'] || '', 500, 'description').to_s
        @parameters = parse_parameters(raw['parameters'])
        @known = parameter_vars
        @derived = parse_derived(raw['derived'])
        @constraints = parse_constraints(raw['constraints'])
        @panel_specs = parse_panels(raw['panels'])
        @hardware_specs = parse_hardware(raw['hardware'])
        trial if errs.empty?
      end

      # --- Serialisation ---------------------------------------------------------------------------
      def to_h
        { 'format' => FORMAT, 'version' => FORMAT_VERSION, 'id' => id, 'name' => name, 'category' => category, 'description' => description,
          'parameters' => parameters, 'derived' => derived.map { |d| d.reject { |k, _| k == 'ast' } },
          'constraints' => constraints.map { |c| c.reject { |k, _| k == 'ast' } },
          'panels' => panel_specs.map { |p| strip_ast(p) }, 'hardware' => hardware_specs.map { |h| strip_ast(h) } }
      end

      def type
        id
      end

      # Parameter schema in the same format as Parameter.schema, so the UI form is generated the same way.
      def schema
        parameters.map do |p|
          f = { 'key' => p['key'], 'label' => p['label'], 'group' => p['group'], 'note' => p['note'] }.compact
          case p['type']
          when 'length' then f.merge('type' => 'length', 'default' => p['default'].to_f, 'min' => p['min'].to_f, 'max' => p['max'].to_f)
          when 'int' then f.merge('type' => 'int', 'default' => p['default'].to_i, 'min' => p['min'].to_i, 'max' => p['max'].to_i)
          when 'toggle' then f.merge('type' => 'enum', 'default' => p['default'].to_i.to_s, 'options' => [{ 'value' => '1', 'label' => 'Yes' }, { 'value' => '0', 'label' => 'No' }])
          when 'material'
            mats = p['role'] == 'back' ? Material.back_materials : Material.carcass
            f.merge('type' => 'enum', 'open' => true, 'default' => p['default'], 'options' => mats.map { |m| { 'value' => m.id, 'label' => m.name } })
          when 'hardware'
            f.merge('type' => 'enum', 'open' => true, 'default' => p['default'],
                    'options' => Hardware.by_category(p['category']).map { |h| { 'value' => h.id, 'label' => h.name } })
          end
        end
      end

      def defaults
        schema.to_h { |f| [f['key'], f['default']] }
      end

      # --- Building ----------------------------------------------------------------------------------
      # params: validated, string-keyed. Returns Build(result, panels, hardware items). Never raises for bad data:
      # problems become issues and an empty panel list.
      def build(params)
        issues = []
        vars = {}
        fail_with = ->(key, msg) { issues << Rules::Issue.new(:error, key, msg) }
        parameters.each do |p|
          v = params[p['key']]
          case p['type']
          when 'length', 'int', 'toggle' then vars[p['key']] = v.to_f
          when 'material'
            m = Material.find(v)
            return failed(vars, issues, p['key'], "Material '#{v}' (#{p['label']}) is not in the material library") unless m

            vars["#{p['key']}_t"] = m.thickness
          end
        end
        values = vars.dup
        derived.each do |d|
          vars[d['name']] = Expression.evaluate(d['ast'], vars)
          values[d['name']] = vars[d['name']].round(3)
        rescue Expression::EvalError => e
          return failed(values, issues, d['name'], "#{d['label'] || d['name']}: #{e.message}")
        end
        constraints.each do |c|
          next unless Expression.evaluate(c['ast'], vars).zero?

          issues << Rules::Issue.new(c['severity'].to_sym, nil, c['message'])
        rescue Expression::EvalError => e
          fail_with.call(nil, "Constraint '#{c['message']}': #{e.message}")
        end
        values = values.transform_values { |x| x.is_a?(Float) ? x.round(3) : x }
        return Build.new(Rules::Result.new(values, issues), [], []) if issues.any? { |i| i.severity == :error }

        panels = build_panels(params, vars, issues)
        hardware = build_hardware(params, vars, issues)
        Build.new(Rules::Result.new(values, issues), issues.any? { |i| i.severity == :error } ? [] : panels, hardware)
      end

      private

      def failed(values, issues, key, msg)
        issues << Rules::Issue.new(:error, key, msg)
        Build.new(Rules::Result.new(values, issues), [], [])
      end

      def build_panels(params, vars, issues)
        out = []
        panel_specs.each do |s|
          next if s['if'] && Expression.evaluate(s['if_ast'], vars).zero?

          count = s['repeat'] ? Expression.evaluate(s['repeat_ast'], vars).floor : nil
          if count && !count.between?(0, LIMITS[:repeat])
            issues << Rules::Issue.new(:error, s['key'], "#{s['name']}: repeat count #{count} is outside 0-#{LIMITS[:repeat]}")
            next
          end
          (count ? count.times.to_a : [nil]).each do |i|
            v = i ? vars.merge('i' => i.to_f, 'n' => count.to_f) : vars
            out << make_panel(s, v, i, params, issues)
          end
        end
        issues << Rules::Issue.new(:error, nil, "Too many parts (#{out.size}; limit #{LIMITS[:generated_panels]})") if out.size > LIMITS[:generated_panels]
        out.compact
      rescue Expression::EvalError => e
        issues << Rules::Issue.new(:error, nil, "Panel formula: #{e.message}")
        []
      end

      def make_panel(spec, v, i, params, issues)
        size = spec['size_ast'].map { |a| Expression.evaluate(a, v) }
        origin = spec['origin_ast'].map { |a| Expression.evaluate(a, v) }
        key = i ? "#{spec['key']}_#{i + 1}" : spec['key']
        pname = spec['name'].gsub('{i}', i ? (i + 1).to_s : '')
        if size.any? { |s| s <= 0 || s > LIMITS[:extent] } || origin.any? { |o| o.abs > LIMITS[:extent] }
          issues << Rules::Issue.new(:error, spec['key'], "#{pname}: size #{size.map { |s| s.round(2) }.join(' x ')} is not a valid panel")
          return nil
        end
        mat = spec['material_param'] ? Material.find(params[spec['material_param']]) : Material.find(spec['material'])
        unless mat
          issues << Rules::Issue.new(:error, spec['key'], "#{pname}: material is not in the library")
          return nil
        end
        edges = spec['edges_ast'].transform_values { |a| Expression.evaluate(a, v) }.select { |_, mm| mm.positive? }.transform_keys(&:to_sym)
        Panel.new(key: key, name: pname, role: spec['role'].to_sym, origin: origin, size: size, thickness_axis: spec['thickness_axis'].to_sym,
                  grain_axis: spec['grain_axis']&.to_sym, material_id: mat.id, material_label: mat.name,
                  grooved_into: spec['grooved_into'], edges: edges)
      rescue ArgumentError => e
        issues << Rules::Issue.new(:error, spec['key'], "#{spec['name']}: #{e.message}")
        nil
      end

      def build_hardware(params, vars, issues)
        out = []
        hardware_specs.each do |h|
          hid = h['id'].start_with?('$') ? params[h['id'][1..]] : h['id']
          loops = h['repeat'] ? Expression.evaluate(h['repeat_ast'], vars).floor.clamp(0, LIMITS[:repeat]).times.to_a : [nil]
          loops.each do |i|
            v = i ? vars.merge('i' => i.to_f, 'n' => loops.size.to_f) : vars
            qty = Expression.evaluate(h['qty_ast'], v).round
            next if qty <= 0

            item = Hardware.find(hid)
            issues << Rules::Issue.new(:warning, nil, "Hardware '#{hid}' is not in the library") unless item
            key = h['part'] == 'cabinet' ? 'cabinet' : (i ? "#{h['part']}_#{i + 1}" : h['part'])
            out << { 'hardware_id' => hid, 'name' => Hardware.name_of(hid), 'category' => item&.category || 'unknown', 'qty' => qty,
                     'part_key' => key, 'detail' => h['detail'] }
          end
        end
        out
      rescue Expression::EvalError => e
        issues << Rules::Issue.new(:error, nil, "Hardware formula: #{e.message}")
        []
      end

      # --- Validation ---------------------------------------------------------------------------------
      def err(where, msg)
        @errs << "#{where}: #{msg}"
        nil
      end

      def str(v, max, where, required: false)
        s = v.to_s.strip
        return err(where, 'is required') if required && s.empty?

        err(where, "is longer than #{max} characters") if s.size > max
        s[0, max]
      end

      def list(v, where, max)
        return [] if v.nil?
        return (err(where, 'must be a list') || []) unless v.is_a?(Array)

        err(where, "has more than #{max} entries") if v.size > max
        v.first(max)
      end

      def valid_name?(k, where)
        return err(where, "'#{k}' must be lower-case letters, digits or _ (start with a letter, at most 30)") unless k.to_s.match?(KEY)
        return err(where, "'#{k}' is a reserved word") if RESERVED.include?(k)

        true
      end

      def parse_parameters(raw)
        seen = []
        list(raw, 'parameters', LIMITS[:parameters]).each_with_index.filter_map do |p, i|
          w = "parameters[#{i + 1}]"
          next err(w, 'must be an object') unless p.is_a?(Hash)
          next unless valid_name?(p['key'], w)

          err(w, "key '#{p['key']}' is used twice") if seen.include?(p['key'])
          seen << p['key']
          type = p['type']
          next err(w, "type must be one of #{PARAM_TYPES.join(', ')}") unless PARAM_TYPES.include?(type)

          out = { 'key' => p['key'], 'label' => str(p['label'] || p['key'], 60, "#{w}.label"), 'type' => type, 'group' => str(p['group'] || 'PARAMETERS', 30, "#{w}.group").to_s.upcase,
                  'note' => (p['note'].to_s.strip.empty? ? nil : str(p['note'], 200, "#{w}.note")) }.compact
          param_details(p, out, w)
          out
        end
      end

      def param_details(p, out, w)
        case out['type']
        when 'length', 'int'
          lo, hi, d = [p['min'], p['max'], p['default']].map { |x| Float(x) rescue nil } # rubocop:disable Style/RescueModifier
          return err(w, 'needs numeric min, max and default') if [lo, hi, d].any?(&:nil?)
          return err(w, 'min must be below max') unless lo < hi
          return err(w, 'default must lie between min and max') unless d.between?(lo, hi)
          return err(w, 'an int parameter needs whole numbers') if out['type'] == 'int' && [lo, hi, d].any? { |x| x != x.round }

          out.merge!('min' => lo, 'max' => hi, 'default' => d)
        when 'toggle'
          d = p['default'].to_s
          return err(w, 'default must be 0 or 1') unless %w[0 1].include?(d)

          out['default'] = d.to_i
        when 'material'
          role = p['role'] == 'back' ? 'back' : 'carcass'
          d = p['default'].to_s
          return err(w, "default material '#{d}' is not in the library") unless Material.exist?(d)

          out.merge!('role' => role, 'default' => d)
        when 'hardware'
          cat = p['category'].to_s
          return err(w, "category must be one of #{Hardware::CATEGORIES.keys.join(', ')}") unless Hardware::CATEGORIES.key?(cat)

          d = p['default'].to_s
          return err(w, "default hardware '#{d}' is not in the library") unless Hardware.find(d)

          out.merge!('category' => cat, 'default' => d)
        end
      end

      def parameter_vars
        parameters.flat_map { |p| p['type'] == 'material' ? [p['key'], "#{p['key']}_t"] : (p['type'] == 'hardware' ? [] : [p['key']]) }
      end

      # Parses an expression and checks every variable it reads is defined. Returns the AST or nil (after recording errors).
      def expr(text, where, known)
        ast = Expression.parse(text)
        unknown = Expression.variables(ast).uniq - known
        return err(where, "uses undefined variable#{unknown.size > 1 ? 's' : ''} #{unknown.join(', ')}") unless unknown.empty?

        ast
      rescue Expression::ParseError => e
        err(where, e.message)
      end

      def parse_derived(raw)
        names = []
        list(raw, 'derived', LIMITS[:derived]).each_with_index.filter_map do |d, i|
          w = "derived[#{i + 1}]"
          next err(w, 'must be an object') unless d.is_a?(Hash)
          next unless valid_name?(d['name'], w)

          err(w, "name '#{d['name']}' is already a parameter or derived value") if @known.include?(d['name']) || names.include?(d['name'])
          ast = expr(d['expr'], "#{w}.expr", @known + names)
          names << d['name']
          next unless ast

          { 'name' => d['name'], 'label' => str(d['label'] || d['name'], 60, "#{w}.label"), 'expr' => d['expr'].to_s, 'ast' => ast }
        end.tap { @known += names }
      end

      def parse_constraints(raw)
        list(raw, 'constraints', LIMITS[:constraints]).each_with_index.filter_map do |c, i|
          w = "constraints[#{i + 1}]"
          next err(w, 'must be an object') unless c.is_a?(Hash)

          ast = expr(c['expr'], "#{w}.expr", @known)
          msg = str(c['message'], 160, "#{w}.message", required: true)
          sev = c['severity'].to_s.empty? ? 'error' : c['severity'].to_s
          next err(w, "severity must be error or warning") unless %w[error warning].include?(sev)
          next unless ast && msg

          { 'expr' => c['expr'].to_s, 'message' => msg, 'severity' => sev, 'ast' => ast }
        end
      end

      def parse_panels(raw)
        keys = []
        list(raw, 'panels', LIMITS[:panels]).each_with_index.filter_map do |p, i|
          w = "panels[#{i + 1}]"
          next err(w, 'must be an object') unless p.is_a?(Hash)
          next unless valid_name?(p['key'], w)

          err(w, "key '#{p['key']}' is used twice") if keys.include?(p['key'])
          keys << p['key']
          panel_spec(p, w, keys)
        end
      end

      def panel_spec(p, w, keys)
        known = @known + (p['repeat'] ? %w[i n] : [])
        s = { 'key' => p['key'], 'name' => str(p['name'] || p['key'], 60, "#{w}.name"), 'role' => p['role'].to_s }
        err(w, "role must be one of #{ROLES.join(', ')}") unless ROLES.include?(s['role'])
        mat = p['material'].to_s
        if parameters.any? { |x| x['key'] == mat && x['type'] == 'material' } then s['material_param'] = mat
        elsif Material.exist?(mat) then s['material'] = mat
        else err("#{w}.material", "'#{mat}' is neither a material parameter nor a library material")
        end
        s['material'] ||= mat
        %w[size origin].each do |k|
          arr = p[k]
          if arr.is_a?(Array) && arr.size == 3
            asts = arr.each_with_index.map { |e, j| expr(e, "#{w}.#{k}[#{AXES[j]}]", known) }
            s[k] = arr.map(&:to_s)
            s["#{k}_ast"] = asts
          else
            err("#{w}.#{k}", 'must be a list of 3 formulas (x, y, z)')
          end
        end
        s['thickness_axis'] = p['thickness_axis'].to_s
        err("#{w}.thickness_axis", 'must be x, y or z') unless AXES.include?(s['thickness_axis'])
        ga = p['grain_axis']
        err("#{w}.grain_axis", 'must be x, y, z or null') unless ga.nil? || AXES.include?(ga.to_s)
        s['grain_axis'] = ga&.to_s
        %w[repeat if].each do |k|
          next if p[k].nil? || p[k].to_s.strip.empty?

          s[k] = p[k].to_s
          s["#{k}_ast"] = expr(p[k], "#{w}.#{k}", k == 'repeat' ? @known : known)
        end
        s['edges'] = {}
        s['edges_ast'] = {}
        (p['edges'] || {}).each do |face, e|
          next err("#{w}.edges", "unknown face '#{face}'") unless Panel::FACES.key?(face.to_sym)
          next err("#{w}.edges", "'#{face}' is not an edge of a part whose thickness runs along #{s['thickness_axis']}") if Panel::FACES[face.to_sym][0].to_s == s['thickness_axis']

          s['edges'][face] = e.to_s
          s['edges_ast'][face] = expr(e, "#{w}.edges.#{face}", known)
        end
        s['grooved_into'] = Array(p['grooved_into']).map(&:to_s)
        s
      end

      def parse_hardware(raw)
        panel_keys = (panel_specs || []).map { |s| s['key'] } + ['cabinet']
        list(raw, 'hardware', LIMITS[:hardware]).each_with_index.filter_map do |h, i|
          w = "hardware[#{i + 1}]"
          next err(w, 'must be an object') unless h.is_a?(Hash)

          id = h['id'].to_s
          if id.start_with?('$')
            err(w, "'#{id}' is not a hardware parameter") unless parameters.any? { |p| p['key'] == id[1..] && p['type'] == 'hardware' }
          else
            err(w, "hardware '#{id}' is not in the library") unless Hardware.find(id)
          end
          err(w, "part '#{h['part']}' is not a panel key or 'cabinet'") unless panel_keys.include?(h['part'].to_s)
          known = @known + (h['repeat'] ? %w[i n] : [])
          s = { 'id' => id, 'part' => h['part'].to_s, 'detail' => str(h['detail'] || '', 120, "#{w}.detail").to_s }
          s['qty'] = h['qty'].to_s
          s['qty_ast'] = expr(h['qty'], "#{w}.qty", known)
          if h['repeat'] && !h['repeat'].to_s.strip.empty?
            s['repeat'] = h['repeat'].to_s
            s['repeat_ast'] = expr(h['repeat'], "#{w}.repeat", @known)
          end
          s
        end
      end

      def strip_ast(h)
        h.reject { |k, _| k.end_with?('_ast') }
      end

      # Builds once with the defaults: a template that cannot even produce its default cabinet is rejected.
      def trial
        b = build(defaults)
        b.result.errors.each { |e| @errs << "Default values do not build: #{e.message}" }
        @errs << 'The template produces no parts' if b.result.ok? && b.panels.empty?
      end
    end
  end
end
