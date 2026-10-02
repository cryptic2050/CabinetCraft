# frozen_string_literal: true

require 'json'
require_relative 'hardware'
require_relative '../manufacturing/cnc_posts'

module CabinetCraft
  # User configuration for machining and CNC: drilling-system constants, custom
  # drilling patterns, machine profiles (with tool tables) and custom post-processors.
  # Persisted through a store (SketchUp defaults in production, memory in tests).
  class MachiningConfig
    # Millimetres unless noted. Defaults follow the common 32 mm system - confirm against your hardware.
    DEFAULT_SETTINGS = {
      'joint_inset' => 50.0,
      'shelf_pin_dia' => 5.0, 'shelf_pin_depth' => 12.0, 'shelf_pin_inset' => 17.0, 'shelf_pin_below' => 3.0,
      'hinge_cup_dia' => 35.0, 'hinge_cup_depth' => 12.5, 'hinge_cup_edge' => 22.5,
      'hinge_plate_setback' => 37.0, 'hinge_plate_pitch' => 32.0, 'hinge_plate_dia' => 5.0, 'hinge_plate_depth' => 12.0,
      'handle_spacing' => 128.0, 'handle_dia' => 5.0,
      'runner_front_hole' => 37.0, 'runner_hole_pitch' => 32.0, 'runner_hole_count' => 3, 'runner_dia' => 5.0, 'runner_depth' => 12.0,
      'cam_dia' => 15.0, 'cam_depth' => 12.5, 'cam_distance' => 34.0, 'cam_bore_dia' => 8.0,
      'bolt_hole_dia' => 8.0, 'bolt_hole_depth' => 12.0,
      'dowel_dia' => 8.0, 'dowel_edge_depth' => 25.0, 'dowel_face_depth' => 12.0,
      'confirmat_pilot_dia' => 5.0, 'confirmat_pilot_depth' => 50.0, 'confirmat_clear_dia' => 7.0
    }.freeze

    PATTERN_ROLES = %w[side bottom back brace shelf fixed_shelf divider toe_kick door drawer_front drawer_box].freeze

    # Hold-down tabs on the cut-out pass (off by default). Width and spacing are measured along the cutting path.
    TAB_DEFAULTS = { 'tabs' => false, 'tab_width' => 10.0, 'tab_height' => 3.0, 'tab_spacing' => 500.0 }.freeze
    # Machine travel: a program for a sheet that does not fit in X / Y, or a board too thick for the spindle travel, cannot run.
    TRAVEL_DEFAULTS = { 'bed_x' => 3050.0, 'bed_y' => 1550.0, 'bed_z' => 150.0 }.freeze
    MACHINE_EXTRAS = TAB_DEFAULTS.merge(TRAVEL_DEFAULTS).freeze

    DEFAULT_MACHINE = {
      'id' => 'default_router', 'name' => 'Generic 3-axis router (mm)', 'post' => 'iso', 'units' => 'mm',
      'origin' => 'bottom_left', 'z_zero' => 'material_top', 'spindle_rpm' => 18_000, 'feed_cut' => 5000.0,
      'feed_plunge' => 1500.0, 'feed_drill' => 1500.0, 'safe_z' => 15.0, 'pass_depth' => 9.0, 'cut_extra' => 0.3,
      'decimals' => 3, 'line_numbers' => false, 'canned_cycles' => true,
      'tabs' => false, 'tab_width' => 10.0, 'tab_height' => 3.0, 'tab_spacing' => 500.0,
      'bed_x' => 3050.0, 'bed_y' => 1550.0, 'bed_z' => 150.0,
      'tools' => [
        { 'number' => 1, 'kind' => 'router', 'diameter' => 8.0 },
        { 'number' => 2, 'kind' => 'drill', 'diameter' => 5.0 }, { 'number' => 3, 'kind' => 'drill', 'diameter' => 7.0 },
        { 'number' => 4, 'kind' => 'drill', 'diameter' => 8.0 }, { 'number' => 5, 'kind' => 'drill', 'diameter' => 15.0 },
        { 'number' => 6, 'kind' => 'drill', 'diameter' => 35.0 }
      ]
    }.freeze

    attr_reader :settings, :patterns, :posts

    def initialize(store = Hardware::MemoryStore.new)
      @store = store
      @settings = DEFAULT_SETTINGS.dup
      @patterns = []
      @machines = []
      @posts = []
      @active = DEFAULT_MACHINE['id']
      load
    end

    # --- Drilling-system settings -----------------------------------------------------------
    def set_setting(key, value)
      raise ArgumentError, "Unknown setting '#{key}'" unless DEFAULT_SETTINGS.key?(key)

      v = Float(value)
      raise ArgumentError, "#{key} must be positive" unless v.positive?

      @settings[key] = DEFAULT_SETTINGS[key].is_a?(Integer) ? v.round : v
      save
    end

    # --- Custom drilling patterns -------------------------------------------------------------
    # holes: [{ 'x' =>, 'y' =>, 'dia' =>, 'depth' => }] measured from the part's minimum corner
    # (x along its length, y along its width), drilled into face 'a' or 'b'.
    def add_pattern(name:, role:, side:, holes:)
      name = name.to_s.strip
      raise ArgumentError, 'Pattern name is required' if name.empty?
      raise ArgumentError, "Unknown part type '#{role}'" unless PATTERN_ROLES.include?(role)
      raise ArgumentError, "Face must be 'a' or 'b'" unless %w[a b].include?(side)

      clean = Array(holes).map do |h|
        x = Float(h['x']); y = Float(h['y']); d = Float(h['dia']); z = Float(h['depth'])
        raise ArgumentError, 'Hole diameter and depth must be positive' unless d.positive? && z.positive?
        raise ArgumentError, 'Hole positions must not be negative' if x.negative? || y.negative?

        { 'x' => x, 'y' => y, 'dia' => d, 'depth' => z }
      end
      raise ArgumentError, 'A pattern needs at least one hole' if clean.empty?
      raise ArgumentError, 'A pattern can have at most 50 holes' if clean.size > 50

      n = (@patterns.filter_map { |p| p['id'][/\Apattern_(\d+)\z/, 1]&.to_i }.max || 0) + 1
      pat = { 'id' => "pattern_#{n}", 'name' => name, 'role' => role, 'side' => side, 'holes' => clean }
      @patterns << pat
      save
      pat
    end

    def delete_pattern(id)
      before = @patterns.size
      @patterns.reject! { |p| p['id'] == id }
      save
      @patterns.size < before
    end

    # --- Machines -----------------------------------------------------------------------------
    def machines
      [DEFAULT_MACHINE] + @machines
    end

    def machine(id = @active)
      machines.find { |m| m['id'] == id } || DEFAULT_MACHINE
    end

    def active_machine_id
      machines.any? { |m| m['id'] == @active } ? @active : DEFAULT_MACHINE['id']
    end

    def select_machine(id)
      raise ArgumentError, 'Unknown machine' unless machines.any? { |m| m['id'] == id }

      @active = id
      save
    end

    # Adds a machine (no id) or updates a custom one (with id). The built-in default is read-only.
    def save_machine(raw)
      m = normalize_machine(raw)
      if raw['id'].to_s.empty?
        n = (@machines.filter_map { |x| x['id'][/\Amachine_(\d+)\z/, 1]&.to_i }.max || 0) + 1
        m['id'] = "machine_#{n}"
        @machines << m
      else
        raise ArgumentError, 'The built-in machine cannot be edited - save a copy' if raw['id'] == DEFAULT_MACHINE['id']

        idx = @machines.index { |x| x['id'] == raw['id'] } or raise ArgumentError, 'Unknown machine'
        m['id'] = raw['id']
        @machines[idx] = m
      end
      @active = m['id']
      save
      m
    end

    def delete_machine(id)
      raise ArgumentError, 'The built-in machine cannot be deleted' if id == DEFAULT_MACHINE['id']

      ok = !@machines.reject! { |m| m['id'] == id }.nil?
      @active = DEFAULT_MACHINE['id'] if @active == id
      save
      ok
    end

    def normalize_machine(raw)
      num = lambda do |k, lo, hi|
        v = Float(raw[k])
        raise ArgumentError, "#{k} must be between #{lo} and #{hi}" unless v.between?(lo, hi)

        v
      end
      name = raw['name'].to_s.strip
      raise ArgumentError, 'Machine name is required' if name.empty?

      enum = lambda do |k, allowed|
        raise ArgumentError, "#{k} must be one of #{allowed.join(', ')}" unless allowed.include?(raw[k])

        raw[k]
      end
      raise ArgumentError, "Unknown post-processor '#{raw['post']}'" unless CabinetCraft::Manufacturing::CncPosts.exist?(raw['post'], @posts)

      tools = Array(raw['tools']).map do |t|
        { 'number' => Integer(t['number']), 'kind' => enum_val(t['kind'], %w[router drill]), 'diameter' => Float(t['diameter']) }
      end
      raise ArgumentError, 'Tool numbers must be 1-99 and unique' unless tools.all? { |t| t['number'].between?(1, 99) } && tools.map { |t| t['number'] }.uniq.size == tools.size
      raise ArgumentError, 'Tool diameters must be positive' unless tools.all? { |t| t['diameter'].positive? }
      raise ArgumentError, 'At least one router tool is required to cut the parts out' unless tools.any? { |t| t['kind'] == 'router' }

      {
        'name' => name[0, 60], 'post' => raw['post'], 'units' => enum.call('units', %w[mm in]),
        'origin' => enum.call('origin', %w[bottom_left bottom_right top_left top_right]),
        'z_zero' => enum.call('z_zero', %w[material_top spoilboard]),
        'spindle_rpm' => num.call('spindle_rpm', 1000, 30_000).round, 'feed_cut' => num.call('feed_cut', 100, 30_000),
        'feed_plunge' => num.call('feed_plunge', 50, 10_000), 'feed_drill' => num.call('feed_drill', 50, 10_000),
        'safe_z' => num.call('safe_z', 2, 100), 'pass_depth' => num.call('pass_depth', 1, 30), 'cut_extra' => num.call('cut_extra', 0, 3),
        'decimals' => num.call('decimals', 1, 5).round, 'line_numbers' => raw['line_numbers'] ? true : false,
        'canned_cycles' => raw['canned_cycles'] ? true : false, 'tools' => tools.sort_by { |t| t['number'] }
      }.merge(normalize_tabs(raw)).merge(normalize_travel(raw))
    end

    # Machines saved before tabs existed have no tab keys: they keep the defaults (tabs off).
    def normalize_tabs(raw)
      out = { 'tabs' => raw['tabs'] ? true : false }
      { 'tab_width' => [2.0, 50.0], 'tab_height' => [0.5, 10.0], 'tab_spacing' => [100.0, 3000.0] }.each do |k, (lo, hi)|
        v = raw[k].nil? || raw[k].to_s.empty? ? TAB_DEFAULTS[k] : Float(raw[k])
        raise ArgumentError, "#{k} must be between #{lo} and #{hi}" unless v.between?(lo, hi)

        out[k] = v
      end
      out
    rescue TypeError
      raise ArgumentError, 'Tab settings must be numbers'
    end

    def normalize_travel(raw)
      { 'bed_x' => [300.0, 10_000.0], 'bed_y' => [300.0, 5000.0], 'bed_z' => [20.0, 500.0] }.to_h do |k, (lo, hi)|
        v = raw[k].nil? || raw[k].to_s.empty? ? TRAVEL_DEFAULTS[k] : Float(raw[k])
        raise ArgumentError, "#{k} must be between #{lo} and #{hi}" unless v.between?(lo, hi)

        [k, v]
      end
    rescue TypeError
      raise ArgumentError, 'Machine travel must be numbers'
    end

    def enum_val(v, allowed)
      raise ArgumentError, "Tool type must be one of #{allowed.join(', ')}" unless allowed.include?(v)

      v
    end

    # --- Custom post-processors ----------------------------------------------------------------
    def save_post(id:, name:, templates:, extension: 'nc')
      name = name.to_s.strip
      raise ArgumentError, 'Post name is required' if name.empty?
      raise ArgumentError, 'Extension must be 1-5 letters or digits' unless extension.to_s.match?(/\A[a-z0-9]{1,5}\z/i)

      clean = CabinetCraft::Manufacturing::CncPosts.validate_templates(templates)
      if id.to_s.empty?
        n = (@posts.filter_map { |p| p['id'][/\Apost_(\d+)\z/, 1]&.to_i }.max || 0) + 1
        post = { 'id' => "post_#{n}", 'name' => name[0, 60], 'templates' => clean, 'extension' => extension.to_s.downcase }
        @posts << post
      else
        post = @posts.find { |p| p['id'] == id } or raise ArgumentError, 'Unknown post-processor'
        post.merge!('name' => name[0, 60], 'templates' => clean, 'extension' => extension.to_s.downcase)
      end
      save
      post
    end

    def delete_post(id)
      raise ArgumentError, "In use by machine '#{@machines.find { |m| m['post'] == id }['name']}'" if @machines.any? { |m| m['post'] == id }

      ok = !@posts.reject! { |p| p['id'] == id }.nil?
      save
      ok
    end

    private

    def save
      @store.write(JSON.generate('settings' => @settings, 'patterns' => @patterns, 'machines' => @machines, 'posts' => @posts, 'active' => @active))
    end

    def load
      raw = @store.read
      return if raw.nil? || raw.to_s.empty?

      d = JSON.parse(raw)
      @settings = DEFAULT_SETTINGS.merge((d['settings'] || {}).select { |k, v| DEFAULT_SETTINGS.key?(k) && v.is_a?(Numeric) })
      @patterns = Array(d['patterns'])
      @posts = Array(d['posts'])
      @machines = Array(d['machines']).map { |m| raise ArgumentError, 'bad machine' unless m.is_a?(Hash) && m['id'] && m['tools']; MACHINE_EXTRAS.merge(m) }
      @active = d['active'] || DEFAULT_MACHINE['id']
    rescue JSON::ParserError, ArgumentError, TypeError
      @settings = DEFAULT_SETTINGS.dup # corrupt settings must never block the plugin
      @patterns = []
      @machines = []
      @posts = []
      @active = DEFAULT_MACHINE['id']
    end

    class << self
      attr_writer :current

      def current
        @current ||= new
      end
    end
  end
end
