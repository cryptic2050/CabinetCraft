# frozen_string_literal: true

require 'json'

module CabinetCraft
  # Hardware library + user configuration (custom items and placement rules).
  module Hardware
    CATEGORIES = {
      'hinge' => 'Hinge', 'runner' => 'Drawer runner', 'connector' => 'Connector', 'handle' => 'Handle',
      'shelf_pin' => 'Shelf pin', 'leg' => 'Leg / foot', 'lock' => 'Lock'
    }.freeze

    Item = Struct.new(:id, :name, :category, :price, :supplier, :custom, :companions, keyword_init: true) do
      def to_h
        { 'id' => id, 'name' => name, 'category' => category, 'price' => price, 'supplier' => supplier,
          'custom' => custom, 'companions' => companions }
      end
    end

    def self.item(id, name, category, companions = {})
      Item.new(id: id, name: name, category: category, price: nil, supplier: nil, custom: false, companions: companions)
    end

    BUILT_IN = [
      item('hinge_standard', 'Standard concealed hinge', 'hinge'),
      item('hinge_soft_close', 'Soft-close hinge', 'hinge'),
      item('hinge_push_open', 'Push-to-open hinge', 'hinge'),
      item('runner_side_mount', 'Side-mount runner', 'runner'),
      item('runner_undermount', 'Undermount runner', 'runner'),
      item('runner_soft_close', 'Soft-close runner', 'runner'),
      item('runner_push_open', 'Push-to-open runner', 'runner'),
      item('cam_lock', 'Cam lock', 'connector', { 'dowel' => 1 }), # each cam needs a dowel
      item('dowel', 'Dowel', 'connector'),
      item('confirmat', 'Confirmat screw', 'connector'),
      item('lamello', 'Lamello', 'connector'),
      item('mortise_tenon', 'Mortise and tenon', 'connector'),
      item('handle_bar', 'Bar handle', 'handle'),
      item('shelf_pin', 'Shelf pin', 'shelf_pin'),
      item('cabinet_leg', 'Cabinet leg', 'leg'),
      item('adjustable_foot', 'Adjustable foot', 'leg'),
      item('lock_cam', 'Cam lock (door lock)', 'lock')
    ].freeze

    DEFAULT_HINGE_RULES = [
      { 'min_height' => 0.0, 'count' => 2 }, { 'min_height' => 900.0, 'count' => 3 }, { 'min_height' => 1200.0, 'count' => 4 }
    ].freeze

    # Placement settings in mm / counts.
    DEFAULT_SETTINGS = {
      'hinge_inset' => 100.0, 'connector_spacing' => 200.0, 'shelf_pins_per_shelf' => 4,
      'handle_inset' => 50.0, 'handle_top_offset' => 100.0
    }.freeze

    class MemoryStore
      def initialize
        @data = nil
      end

      def read
        @data
      end

      def write(json)
        @data = json
      end
    end

    # Custom hardware + hinge rules + placement settings, persisted through a store
    # (SketchUp defaults in production, memory in tests).
    class Config
      attr_reader :hinge_rules, :settings

      def initialize(store = MemoryStore.new)
        @store = store
        @custom = []
        @hinge_rules = DEFAULT_HINGE_RULES.map(&:dup)
        @settings = DEFAULT_SETTINGS.dup
        load
      end

      def custom_items
        @custom.dup
      end

      def add_custom(name:, category:, price: nil, supplier: nil)
        name = name.to_s.strip
        raise ArgumentError, 'Name is required' if name.empty?
        raise ArgumentError, "Unknown category '#{category}'" unless CATEGORIES.key?(category)

        price = price.to_s.empty? ? nil : Float(price)
        raise ArgumentError, 'Price cannot be negative' if price&.negative?

        n = (@custom.filter_map { |i| i.id[/\Acustom_(\d+)\z/, 1]&.to_i }.max || 0) + 1
        it = Item.new(id: "custom_#{n}", name: name, category: category, price: price,
                      supplier: supplier.to_s.strip.then { |s| s.empty? ? nil : s }, custom: true, companions: {})
        @custom << it
        save
        it
      end

      def delete_custom(id)
        before = @custom.size
        @custom.reject! { |i| i.id == id }
        save
        @custom.size < before
      end

      # rows: [{ 'min_height' => mm, 'count' => n }, ...]; first row must start at 0.
      def hinge_rules=(rows)
        clean = rows.map { |r| { 'min_height' => Float(r['min_height']), 'count' => Integer(r['count']) } }
        raise ArgumentError, 'At least one hinge rule is required' if clean.empty?
        raise ArgumentError, 'The first rule must start at height 0' unless clean.first['min_height'].zero?
        raise ArgumentError, 'Rule heights must increase' unless clean.each_cons(2).all? { |a, b| b['min_height'] > a['min_height'] }
        raise ArgumentError, 'Hinge count must be between 1 and 10' unless clean.all? { |r| r['count'].between?(1, 10) }

        @hinge_rules = clean
        save
      end

      def set_setting(key, value)
        raise ArgumentError, "Unknown setting '#{key}'" unless DEFAULT_SETTINGS.key?(key)

        v = Float(value)
        raise ArgumentError, "#{key} must be positive" unless v.positive?

        @settings[key] = DEFAULT_SETTINGS[key].is_a?(Integer) ? v.round : v
        save
      end

      # Number of hinges for a door of the given height: the last rule whose
      # min_height is <= height.
      def hinge_count(height)
        @hinge_rules.select { |r| r['min_height'] <= height }.last['count']
      end

      private

      def save
        @store.write(JSON.generate('custom' => @custom.map(&:to_h), 'hinge_rules' => @hinge_rules, 'settings' => @settings))
      end

      def load
        raw = @store.read
        return if raw.nil? || raw.to_s.empty?

        data = JSON.parse(raw)
        @custom = Array(data['custom']).map do |h|
          Item.new(id: h['id'], name: h['name'], category: h['category'], price: h['price'], supplier: h['supplier'],
                   custom: true, companions: {})
        end
        self.hinge_rules = data['hinge_rules'] if data['hinge_rules']
        @settings = DEFAULT_SETTINGS.merge((data['settings'] || {}).select { |k, _| DEFAULT_SETTINGS.key?(k) })
      rescue JSON::ParserError, ArgumentError, TypeError, KeyError
        # Corrupt settings must never break the plugin: fall back to defaults.
        @custom = []
        @hinge_rules = DEFAULT_HINGE_RULES.map(&:dup)
        @settings = DEFAULT_SETTINGS.dup
      end
    end

    class << self
      attr_writer :config

      def config
        @config ||= Config.new
      end

      def all
        BUILT_IN + config.custom_items
      end

      def by_category(cat)
        all.select { |i| i.category == cat }
      end

      def find(id)
        all.find { |i| i.id == id }
      end

      # Name for display; unknown ids (e.g. custom item missing on this machine) stay visible.
      def name_of(id)
        find(id)&.name || "Unknown hardware (#{id})"
      end
    end
  end
end
