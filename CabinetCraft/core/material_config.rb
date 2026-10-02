# frozen_string_literal: true

require 'json'
require_relative 'hardware'

module CabinetCraft
  # User-defined materials and overrides of built-in ones. Persisted through a store (SketchUp defaults
  # in production, memory in tests). All input is validated; nothing invalid is ever stored.
  class MaterialConfig
    OVERRIDABLE = %w[price supplier sheet_length sheet_width waste_allowance color texture edge_options grain].freeze

    attr_reader :custom, :overrides

    def initialize(store = Hardware::MemoryStore.new)
      @store = store
      @custom = []      # array of attribute hashes (string keys)
      @overrides = {}   # built-in id => { field => value }
      load
    end

    def custom_materials
      @custom.map { |h| build(h) }
    end

    def apply_override(material)
      ov = @overrides[material.id]
      return material unless ov

      material.with(ov.transform_keys(&:to_sym).tap { |h| h[:grain] = h[:grain].to_sym if h[:grain] })
    end

    # raw: string-keyed fields from the UI. No 'id' (or blank) creates a custom material; a custom id updates it;
    # a built-in id stores overrides of the overridable fields only. Returns the resulting Material.
    def save(raw)
      id = raw['id'].to_s
      if Material::BUILT_IN_BY_ID.key?(id)
        ov = clean(raw, custom: false, base: Material::BUILT_IN_BY_ID[id])
        @overrides[id] = ov.slice(*OVERRIDABLE)
        save_store
        return Material.find(id)
      end

      fields = clean(raw, custom: true, base: id.empty? ? nil : @custom.find { |h| h['id'] == id })
      if id.empty?
        n = (@custom.filter_map { |h| h['id'][/\Amat_custom_(\d+)\z/, 1]&.to_i }.max || 0) + 1
        fields['id'] = "mat_custom_#{n}"
        @custom << fields
      else
        idx = @custom.index { |h| h['id'] == id } or raise ArgumentError, 'Unknown material'
        fields['id'] = id
        @custom[idx] = fields
      end
      save_store
      build(fields)
    end

    def delete(id)
      raise ArgumentError, 'Built-in materials cannot be deleted (you can reset their overrides)' if Material::BUILT_IN_BY_ID.key?(id)

      ok = !@custom.reject! { |h| h['id'] == id }.nil?
      save_store
      ok
    end

    def reset_override(id)
      ok = !@overrides.delete(id).nil?
      save_store
      ok
    end

    # Adds custom materials from a model snapshot that this machine does not know yet. Returns the number added.
    def import_missing(snapshot)
      added = 0
      Array(snapshot['custom']).each do |h|
        next unless h.is_a?(Hash)
        next if @custom.any? { |c| c['id'] == h['id'] } || Material::BUILT_IN_BY_ID.key?(h['id'])
        next unless h['id'].to_s.match?(/\Amat_custom_\d+\z/)

        begin
          @custom << clean(h, custom: true, base: nil).merge('id' => h['id'].to_s)
          added += 1
        rescue ArgumentError, TypeError
          next # a malformed entry in a model file is skipped, never trusted
        end
      end
      (snapshot['overrides'].is_a?(Hash) ? snapshot['overrides'] : {}).each do |id, ov|
        next if @overrides.key?(id) || !Material::BUILT_IN_BY_ID.key?(id) || !ov.is_a?(Hash)

        begin
          @overrides[id] = clean(ov.merge('id' => id), custom: false, base: Material::BUILT_IN_BY_ID[id]).slice(*OVERRIDABLE)
          added += 1
        rescue ArgumentError, TypeError
          next
        end
      end
      save_store if added.positive?
      added
    end

    def snapshot
      { 'custom' => @custom, 'overrides' => @overrides }
    end

    private

    def build(h)
      Material.new(id: h['id'], name: h['name'], thickness: h['thickness'], color: h['color'], role: h['role'], grain: h['grain'],
                   sheet_length: h['sheet_length'], sheet_width: h['sheet_width'], price: h['price'], supplier: h['supplier'],
                   waste_allowance: h['waste_allowance'], texture: h['texture'], edge_options: h['edge_options'], custom: true)
    end

    def num(raw, key, lo, hi, label)
      v = Float(raw[key])
      raise ArgumentError, "#{label} must be between #{lo} and #{hi}" unless v.between?(lo, hi)

      v
    rescue ArgumentError, TypeError => e
      raise ArgumentError, e.message.start_with?(label) ? e.message : "#{label} must be a number between #{lo} and #{hi}"
    end

    def blank?(v)
      v.nil? || v.to_s.strip.empty?
    end

    # Validated field hash (string keys). `base` supplies values for fields not present in `raw`.
    def clean(raw, custom:, base:)
      base_h = base.is_a?(Material) ? base.to_h : (base || {})
      get = ->(k) { raw.key?(k) ? raw[k] : base_h[k] }
      src = raw.merge(OVERRIDABLE.to_h { |k| [k, get.call(k)] }).merge('name' => get.call('name'), 'thickness' => get.call('thickness'), 'role' => get.call('role'))
      out = {}
      if custom
        name = src['name'].to_s.strip
        raise ArgumentError, 'Name is required' if name.empty?
        raise ArgumentError, 'Name can be at most 60 characters' if name.size > 60
        taken = Material::BUILT_IN.map(&:name) + @custom.map { |h| h['name'] }
        raise ArgumentError, "A material called '#{name}' already exists" if (taken - [base_h['name']]).include?(name)

        out['name'] = name
        out['thickness'] = num(src, 'thickness', 1, 50, 'Thickness')
        raise ArgumentError, "Role must be 'carcass' or 'back'" unless %w[carcass back].include?(src['role'].to_s)

        out['role'] = src['role'].to_s
      end
      out['sheet_length'] = num(src, 'sheet_length', 300, 6000, 'Sheet length')
      out['sheet_width'] = num(src, 'sheet_width', 300, 3000, 'Sheet width')
      raise ArgumentError, "Grain must be one of #{Material::GRAINS.join(', ')}" unless Material::GRAINS.include?(src['grain'].to_s)

      out['grain'] = src['grain'].to_s
      out['price'] = blank?(src['price']) ? nil : num(src, 'price', 0, 1_000_000, 'Price')
      out['waste_allowance'] = blank?(src['waste_allowance']) ? nil : num(src, 'waste_allowance', 0, 50, 'Waste allowance')
      out['supplier'] = blank?(src['supplier']) ? nil : src['supplier'].to_s.strip[0, 80]
      color = src['color'].to_s.strip
      raise ArgumentError, 'Colour must look like #aabbcc' unless color.match?(/\A#[0-9a-fA-F]{6}\z/)

      out['color'] = color.downcase
      tex = src['texture'].to_s.strip
      raise ArgumentError, 'Texture path is too long' if tex.size > 260
      raise ArgumentError, 'Texture path contains invalid characters' if tex.match?(/[\x00-\x1f]/)

      out['texture'] = tex.empty? ? nil : tex
      out['edge_options'] = edge_options(src['edge_options'])
      out
    end

    def edge_options(v)
      list = v.is_a?(String) ? v.split(/[ ,;]+/).reject(&:empty?) : Array(v)
      vals = list.map { |x| Float(x) }.uniq.sort
      raise ArgumentError, 'Edge-band options must be between 0.1 and 5 mm' unless vals.all? { |x| x.between?(0.1, 5) }
      raise ArgumentError, 'At most 6 edge-band options' if vals.size > 6

      vals.empty? ? Material::DEFAULT_EDGE_OPTIONS : vals
    rescue ArgumentError, TypeError => e
      raise ArgumentError, e.message.include?('Edge-band') || e.message.include?('At most') ? e.message : 'Edge-band options must be numbers (e.g. 0.4, 1, 2)'
    end

    def save_store
      @store.write(JSON.generate('custom' => @custom, 'overrides' => @overrides))
    end

    def load
      raw = @store.read
      return if raw.nil? || raw.to_s.empty?

      d = JSON.parse(raw)
      @custom = Array(d['custom']).select { |h| h.is_a?(Hash) && h['id'] && h['thickness'] }
      @overrides = (d['overrides'] || {}).select { |id, h| h.is_a?(Hash) && Material::BUILT_IN_BY_ID.key?(id) }
      @custom.each { |h| build(h) } # fail early on malformed entries
    rescue StandardError
      @custom = [] # corrupt data of any kind must never block the plugin
      @overrides = {}
    end
  end
end
