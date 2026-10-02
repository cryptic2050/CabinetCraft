# frozen_string_literal: true

require 'securerandom'
require_relative 'run_planner'

module CabinetCraft
  # A linked run: cabinets laid side by side along a wall, remembered so the whole row can be re-planned (Quick Stretch).
  # Stored in the model (ProjectStore#runs). Cabinets stay ordinary cabinets; the run only knows their ids, the wall length and
  # the per-cabinet rules (fixed width, or min / max). The cabinet data in the model remains the source of truth for sizes.
  class Run
    ITEM_KEYS = %w[cabinet_id fixed width min max].freeze
    AXES = %w[x y].freeze # the model axis the cabinets advance along (a run along the second wall of a corner uses y)

    attr_reader :id, :name, :length, :items, :axis

    def initialize(id:, name:, length:, items:, axis: 'x')
      raise ArgumentError, "Run axis must be one of #{AXES.join(', ')}" unless AXES.include?(axis)

      @id = id
      @name = name
      @length = length
      @items = items.freeze
      @axis = axis
    end

    def self.build(name:, length:, items:, axis: 'x')
      new(id: SecureRandom.uuid, name: name, length: Float(length), items: items.map { |i| clean_item(i) }, axis: axis)
    end

    # Untrusted data (it comes from the model file): returns nil unless it is usable.
    def self.from_h(raw)
      return nil unless raw.is_a?(Hash) && raw['id'].is_a?(String) && raw['items'].is_a?(Array) && !raw['items'].empty?

      new(id: raw['id'], name: raw['name'].to_s[0, 40], length: Float(raw['length']), items: raw['items'].map { |i| clean_item(i) }, axis: raw['axis'] || 'x')
    rescue ArgumentError, TypeError
      nil
    end

    def self.clean_item(raw)
      h = raw.transform_keys(&:to_s)
      raise ArgumentError, 'A run cabinet needs a cabinet id' if h['cabinet_id'].to_s.empty?

      fixed = h['fixed'] ? true : false
      out = { 'cabinet_id' => h['cabinet_id'].to_s, 'fixed' => fixed,
              'min' => Float(h['min'] || RunPlanner::DEFAULT_MIN), 'max' => Float(h['max'] || RunPlanner::DEFAULT_MAX) }
      out['width'] = Float(h['width']) if h['width'] && !h['width'].to_s.empty?
      raise ArgumentError, 'A fixed run cabinet needs a width' if fixed && !out.key?('width')

      out
    end

    def to_h
      { 'id' => id, 'name' => name, 'length' => length, 'axis' => axis, 'items' => items }
    end

    def member_ids
      items.map { |i| i['cabinet_id'] }
    end

    def planner_items(overrides = nil)
      list = overrides || items
      list.map { |i| { 'fixed' => i['fixed'], 'width' => i['width'], 'min' => i['min'], 'max' => i['max'] } }
    end

    def plan(length = self.length, overrides = nil)
      RunPlanner.plan(length, planner_items(overrides))
    end

    # Copy with a new length and, optionally, new per-cabinet rules (index-aligned list of partial hashes).
    def with(length: nil, rules: nil)
      new_items = items.each_with_index.map do |item, n|
        rule = rules && rules[n]
        rule ? self.class.clean_item(item.merge(rule.transform_keys(&:to_s).slice('fixed', 'width', 'min', 'max').compact)) : item
      end
      self.class.new(id: id, name: name, length: length ? Float(length) : self.length, items: new_items, axis: axis)
    end
  end
end
