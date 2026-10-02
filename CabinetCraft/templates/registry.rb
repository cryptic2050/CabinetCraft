# frozen_string_literal: true

require 'json'
require_relative 'template'
require_relative 'examples'
require_relative '../core/parameter'

module CabinetCraft
  # User templates and presets, persisted per user (SketchUp defaults) and mirrored in the model (snapshot).
  module Templates
    # Library entries added by the user:
    #  * template: a custom parametric cabinet (id "tpl_N"), see Template
    #  * preset:   a saved parameter set of a built-in cabinet (id "preset_N")
    class Config
      MAX_TEMPLATES = 100
      MAX_PRESETS = 100

      def initialize(store = Hardware::MemoryStore.new)
        @store = store
        @raw = []      # validated template hashes (Template#to_h)
        @presets = []  # { 'id', 'name', 'category', 'description', 'base_type', 'defaults' }
        load
      end

      def templates
        @templates ||= @raw.filter_map do |h|
          Template.from_h(h, id: h['id'])
        rescue Template::Invalid
          nil # a template that no longer validates (e.g. its material was deleted) is hidden, not fatal
        end
      end

      def presets
        @presets.map(&:dup)
      end

      def find_template(id)
        templates.find { |t| t.id == id }
      end

      def find_preset(id)
        @presets.find { |p| p['id'] == id }
      end

      # source: JSON text or Hash. A blank id creates a new template; an existing id replaces it.
      def save_template(source, id = nil)
        raw = source.is_a?(String) ? JSON.parse(source) : source
        raise Template::Invalid, ['A template must be a JSON object'] unless raw.is_a?(Hash)

        id = id.to_s
        if id.empty?
          raise ArgumentError, "At most #{MAX_TEMPLATES} templates" if @raw.size >= MAX_TEMPLATES

          n = (@raw.filter_map { |h| h['id'][/\Atpl_(\d+)\z/, 1]&.to_i }.max || 0) + 1
          id = "tpl_#{n}"
        elsif @raw.none? { |h| h['id'] == id }
          raise ArgumentError, 'Unknown template'
        end
        t = Template.from_h(raw, id: id)
        dup_name = templates.find { |x| x.name == t.name && x.id != id }
        raise ArgumentError, "A template called '#{t.name}' already exists" if dup_name

        idx = @raw.index { |h| h['id'] == id }
        idx ? @raw[idx] = t.to_h : @raw << t.to_h
        @templates = nil
        save
        t
      rescue JSON::ParserError => e
        raise Template::Invalid, ["Not valid JSON: #{e.message[0, 100]}"]
      end

      def delete_template(id)
        ok = !@raw.reject! { |h| h['id'] == id }.nil?
        @templates = nil
        save
        ok
      end

      def save_preset(name:, category:, description:, base_type:, params:)
        name = name.to_s.strip
        raise ArgumentError, 'Name is required' if name.empty?
        raise ArgumentError, 'Name can be at most 60 characters' if name.size > 60
        raise ArgumentError, "A cabinet type called '#{name}' already exists" if Library.entries.any? { |e| e['name'] == name }
        raise ArgumentError, "Presets can only be based on built-in cabinets (not '#{base_type}')" unless Library::ENTRIES.any? { |e| e['type'] == base_type } || find_preset(base_type)
        raise ArgumentError, "At most #{MAX_PRESETS} presets" if @presets.size >= MAX_PRESETS

        clean, errors = Parameter.coerce(params)
        raise ArgumentError, errors.first['message'] unless errors.empty?

        n = (@presets.filter_map { |p| p['id'][/\Apreset_(\d+)\z/, 1]&.to_i }.max || 0) + 1
        base = find_preset(base_type)&.fetch('base_type') || base_type
        preset = { 'id' => "preset_#{n}", 'name' => name, 'category' => category.to_s.strip.empty? ? 'CUSTOM' : category.to_s.strip.upcase[0, 40],
                   'description' => description.to_s.strip[0, 300], 'base_type' => base, 'defaults' => clean }
        @presets << preset
        save
        preset
      end

      def delete_preset(id)
        ok = !@presets.reject! { |p| p['id'] == id }.nil?
        save
        ok
      end

      def snapshot
        { 'templates' => @raw, 'presets' => @presets }
      end

      # Adds templates / presets from a model snapshot that this machine does not have. Returns how many were added.
      # Entries that fail validation are skipped: a model file is never trusted.
      def import_missing(snap)
        return 0 unless snap.is_a?(Hash)

        added = 0
        Array(snap['templates']).each do |h|
          next unless h.is_a?(Hash) && h['id'].to_s.match?(/\Atpl_\d+\z/) && @raw.none? { |x| x['id'] == h['id'] }

          t = Template.from_h(h, id: h['id'])
          next if templates.any? { |x| x.name == t.name }

          @raw << t.to_h
          @templates = nil
          added += 1
        rescue Template::Invalid
          next
        end
        Array(snap['presets']).each do |p|
          next unless p.is_a?(Hash) && p['id'].to_s.match?(/\Apreset_\d+\z/) && !find_preset(p['id'])

          clean, errors = Parameter.coerce(p['defaults'])
          next unless errors.empty? && p['name'].to_s.strip != '' && Library::ENTRIES.any? { |e| e['type'] == p['base_type'] }

          @presets << { 'id' => p['id'], 'name' => p['name'].to_s[0, 60], 'category' => p['category'].to_s[0, 40], 'description' => p['description'].to_s[0, 300],
                        'base_type' => p['base_type'], 'defaults' => clean }
          added += 1
        end
        save if added.positive?
        added
      end

      private

      def save
        @store.write(JSON.generate('templates' => @raw, 'presets' => @presets))
      end

      def load
        raw = @store.read
        return if raw.nil? || raw.to_s.empty?

        d = JSON.parse(raw)
        @raw = Array(d['templates']).select { |h| h.is_a?(Hash) && h['id'] }
        @presets = Array(d['presets']).select { |p| p.is_a?(Hash) && p['id'] && p['defaults'].is_a?(Hash) }
      rescue StandardError
        @raw = []
        @presets = []
      end
    end

    class << self
      attr_writer :config

      def config
        @config ||= Config.new
      end

      def template_type?(type)
        type.to_s.start_with?('tpl_')
      end

      def find(type)
        template_type?(type) ? config.find_template(type) : nil
      end
    end
  end
end
