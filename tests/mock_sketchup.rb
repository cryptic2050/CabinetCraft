# frozen_string_literal: true

# A deliberately small stand-in for the parts of the SketchUp Ruby API that
# CabinetCraft calls. It lets us run the generator/registry/controller outside
# SketchUp. It is NOT a substitute for testing inside SketchUp.

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x = 0, y = 0, z = 0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def to_a
      [x, y, z]
    end
  end

  class Transformation
    attr_reader :origin
    attr_accessor :xscale, :yscale, :zscale

    def initialize(origin = Point3d.new)
      @origin = origin
      @xscale = @yscale = @zscale = 1.0
    end
  end
end

module Sketchup
  class Color
    attr_reader :rgb

    def initialize(r, g, b)
      @rgb = [r, g, b]
    end
  end

  class Material
    attr_accessor :color
    attr_reader :name

    def initialize(name)
      @name = name
    end
  end

  class Materials
    def initialize
      @h = {}
    end

    def [](name)
      @h[name]
    end

    def add(name)
      @h[name] = Material.new(name)
    end
  end

  class BoundingBox
    attr_reader :min, :max

    def initialize(pts)
      @min = Geom::Point3d.new(*pts.map(&:x).min.then { |x| [x, pts.map(&:y).min, pts.map(&:z).min] })
      @max = Geom::Point3d.new(*pts.map(&:x).max.then { |x| [x, pts.map(&:y).max, pts.map(&:z).max] })
    end
  end

  class Face
    attr_reader :pts, :extrusion

    def initialize(pts)
      @pts = pts
      @extrusion = nil
    end

    def normal
      a, b, c = pts
      u = [b.x - a.x, b.y - a.y, b.z - a.z]
      v = [c.x - a.x, c.y - a.y, c.z - a.z]
      n = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
      Struct.new(:x, :y, :z).new(*n)
    end

    def reverse!
      @pts = pts.reverse
    end

    def pushpull(dist)
      n = normal
      len = Math.sqrt(n.x**2 + n.y**2 + n.z**2)
      @extrusion = [n.x / len * dist, n.y / len * dist, n.z / len * dist]
    end

    def all_points
      return pts unless extrusion

      pts + pts.map { |p| Geom::Point3d.new(p.x + extrusion[0], p.y + extrusion[1], p.z + extrusion[2]) }
    end
  end

  class Entities
    include Enumerable

    def initialize(owner)
      @owner = owner
      @items = []
    end

    def each(&block)
      @items.each(&block)
    end

    def add_group
      g = Group.new(@owner.model, self)
      @items << g
      g
    end

    def add_face(pts)
      f = Face.new(pts)
      @items << f
      f
    end

    def clear!
      @items.clear
    end
  end

  class Group
    attr_reader :entities, :model, :transformation
    attr_accessor :name, :material

    def initialize(model, parent = nil)
      @model = model
      @parent = parent
      @entities = Entities.new(self)
      @attrs = Hash.new { |h, k| h[k] = {} }
      @transformation = Geom::Transformation.new
      @made_unique = 0
    end

    attr_reader :made_unique

    def make_unique
      @made_unique += 1
    end

    def entityID
      object_id
    end

    def erase!
      @parent&.instance_variable_get(:@items)&.delete_if { |e| e.equal?(self) }
    end

    def transform!(t)
      @transformation = t
    end

    def set_attribute(dict, key, value)
      @attrs[dict][key] = value
    end

    def get_attribute(dict, key, default = nil)
      @attrs.key?(dict) ? @attrs[dict].fetch(key, default) : default
    end

    def attribute_dictionary(dict)
      return nil unless @attrs.key?(dict)

      d = @attrs[dict]
      d.define_singleton_method(:each_pair) { |&b| each(&b) }
      d
    end

    def local_points
      entities.flat_map { |e| e.is_a?(Face) ? e.all_points : e.world_points }
    end

    def world_points
      o = transformation.origin
      local_points.map { |p| Geom::Point3d.new(p.x + o.x, p.y + o.y, p.z + o.z) }
    end

    def bounds
      BoundingBox.new(world_points)
    end

    # Copy as "move + copy" would (identical attributes, separate entities).
    def deep_copy
      g = Group.new(model)
      @attrs.each { |d, h| h.each { |k, v| g.set_attribute(d, k, v) } }
      g.transform!(transformation)
      entities.each do |e|
        c = g.entities.add_group
        e.entities.each { |f| c.entities.instance_variable_get(:@items) << f } if e.is_a?(Group)
      end
      g
    end
  end

  class Selection
    include Enumerable

    def initialize
      @items = []
    end

    def each(&block)
      @items.each(&block)
    end

    def clear
      @items.clear
    end

    def add(e)
      @items << e
    end

    def length
      @items.length
    end

    def first
      @items.first
    end
  end

  class View
    attr_reader :zoomed

    def zoom(e)
      @zoomed = e
    end
  end

  class Model
    attr_reader :entities, :materials, :selection, :active_view, :ops
    attr_accessor :active_path, :title

    def set_attribute(dict, key, value)
      (@attrs ||= {})[[dict, key]] = value
    end

    def get_attribute(dict, key, default = nil)
      (@attrs ||= {}).fetch([dict, key], default)
    end

    def find_entity_by_id(id)
      entities.find { |e| e.respond_to?(:entityID) && e.entityID == id }
    end

    def initialize
      @owner = Struct.new(:model).new(self)
      @entities = Entities.new(@owner)
      @materials = Materials.new
      @selection = Selection.new
      @active_view = View.new
      @ops = []
    end

    def start_operation(name, _disable_ui = true)
      @ops << [:start, name]
    end

    def commit_operation
      @ops << [:commit]
    end

    def abort_operation
      @ops << [:abort]
    end
  end

  def self.read_default(section, key, default = nil)
    (@defaults ||= {}).fetch([section, key], default)
  end

  def self.write_default(section, key, value)
    (@defaults ||= {})[[section, key]] = value
  end

  def self.active_model
    @active_model ||= Model.new
  end

  def self.reset_model!
    @active_model = Model.new
  end
end
