# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'run_planner'

module CabinetCraft
  # A linked run: cabinets laid side by side along a wall, remembered so the whole row can be re-planned (Quick Stretch).
  # Stored in the model (ProjectStore#runs). Cabinets stay ordinary cabinets; the run only knows their ids, the wall length and
  # the per-cabinet rules (fixed width, or min / max). The cabinet data in the model remains the source of truth for sizes.
  class Run
    ITEM_KEYS = %w[cabinet_id fixed width min max].freeze
    AXES = %w[x y].freeze # the model axis the cabinets advance along (a run along the second wall of a corner uses y)

    DIRS = [1, -1].freeze # +1: the row advances towards +X / +Y; -1 towards -X / -Y (run A of a right-hand corner layout)

    attr_reader :id, :name, :length, :items, :axis, :dir

    def initialize(id:, name:, length:, items:, axis: 'x', dir: 1)
      raise ArgumentError, "Run axis must be one of #{AXES.join(', ')}" unless AXES.include?(axis)
      raise ArgumentError, 'Run direction must be 1 or -1' unless DIRS.include?(dir)

      @id = id
      @name = name
      @length = length
      @items = items.freeze
      @axis = axis
      @dir = dir
    end

    def self.build(name:, length:, items:, axis: 'x', dir: 1)
      new(id: SecureRandom.uuid, name: name, length: Float(length), items: items.map { |i| clean_item(i) }, axis: axis, dir: dir)
    end

    # Untrusted data (it comes from the model file): returns nil unless it is usable.
    def self.from_h(raw)
      return nil unless raw.is_a?(Hash) && raw['id'].is_a?(String) && raw['items'].is_a?(Array) && !raw['items'].empty?

      new(id: raw['id'], name: raw['name'].to_s[0, 40], length: Float(raw['length']), items: raw['items'].map { |i| clean_item(i) }, axis: raw['axis'] || 'x', dir: raw['dir'] || 1)
    rescue ArgumentError, TypeError
      nil
    end

    # type and params are a snapshot of the cabinet (so a deleted member can be recreated); filler items are sized last (see RunPlanner).
    def self.clean_item(raw)
      h = raw.transform_keys(&:to_s)
      raise ArgumentError, 'A run cabinet needs a cabinet id' if h['cabinet_id'].to_s.empty?

      filler = h['filler'] ? true : false
      fixed = !filler && h['fixed'] ? true : false
      lo = filler ? RunPlanner::FILLER_MIN : RunPlanner::DEFAULT_MIN
      hi = filler ? RunPlanner::FILLER_MAX : RunPlanner::DEFAULT_MAX
      out = { 'cabinet_id' => h['cabinet_id'].to_s, 'fixed' => fixed, 'min' => Float(h['min'] || lo), 'max' => Float(h['max'] || hi) }
      out['filler'] = true if filler
      out['width'] = Float(h['width']) if h['width'] && !h['width'].to_s.empty?
      out['type'] = h['type'].to_s[0, 80] unless h['type'].to_s.empty?
      out['params'] = JSON.parse(JSON.generate(h['params'])) if h['params'].is_a?(Hash)
      raise ArgumentError, 'A fixed run cabinet needs a width' if fixed && !out.key?('width')

      out
    end

    def to_h
      { 'id' => id, 'name' => name, 'length' => length, 'axis' => axis, 'dir' => dir, 'items' => items }
    end

    def member_ids
      items.map { |i| i['cabinet_id'] }
    end

    # Copy with new cabinet snapshots (index-aligned list of params hashes; nil keeps the old one).
    def with_params(list)
      self.class.new(id: id, name: name, length: length, axis: axis, dir: dir, items: items.each_with_index.map { |item, n| list[n] ? item.merge('params' => JSON.parse(JSON.generate(list[n]))) : item })
    end

    # Copy with each item's cabinet type set (index-aligned list).
    def with_types(list)
      self.class.new(id: id, name: name, length: length, axis: axis, dir: dir, items: items.each_with_index.map { |item, n| list[n] ? item.merge('type' => list[n]) : item })
    end

    # Copy with a different list of items (members added or removed), keeping identity, name, length and axis.
    def with_items(new_items)
      self.class.new(id: id, name: name, length: length, axis: axis, dir: dir, items: new_items.map { |i| self.class.clean_item(i) })
    end

    def planner_items(overrides = nil)
      list = overrides || items
      list.map { |i| { 'fixed' => i['fixed'], 'width' => i['width'], 'min' => i['min'], 'max' => i['max'], 'filler' => i['filler'] } }
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
      self.class.new(id: id, name: name, length: length ? Float(length) : self.length, items: new_items, axis: axis, dir: dir)
    end
  end
end
