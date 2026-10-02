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

    def transform(t)
      t.apply(self)
    end
  end

  class Vector3d
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

  # Affine stand-in (rotation by axes + translation, no scaling maths). Composition follows SketchUp:
  # group.transform!(t) applies t AFTER the group's existing transformation.
  class Transformation
    attr_reader :origin, :cols
    attr_accessor :xscale, :yscale, :zscale

    def self.translation(vector)
      new(Point3d.new(vector.x, vector.y, vector.z))
    end

    # Transformation.new(origin) is a pure translation; Transformation.new(origin, xaxis, yaxis) also rotates (z = x cross y).
    def initialize(origin = Point3d.new, xaxis = nil, yaxis = nil)
      @origin = origin
      ex = xaxis ? xaxis.to_a : [1.0, 0.0, 0.0]
      ey = yaxis ? yaxis.to_a : [0.0, 1.0, 0.0]
      ez = [ex[1] * ey[2] - ex[2] * ey[1], ex[2] * ey[0] - ex[0] * ey[2], ex[0] * ey[1] - ex[1] * ey[0]]
      @cols = [ex, ey, ez]
      @xscale = @yscale = @zscale = 1.0
    end

    def xaxis
      Vector3d.new(*cols[0])
    end

    def yaxis
      Vector3d.new(*cols[1])
    end

    def linear(v)
      3.times.map { |r| @cols[0][r] * v[0] + @cols[1][r] * v[1] + @cols[2][r] * v[2] }
    end

    def apply(point)
      l = linear(point.to_a)
      Point3d.new(l[0] + origin.x, l[1] + origin.y, l[2] + origin.z)
    end

    # self applied after other
    def *(other)
      o = apply(other.origin)
      self.class.new(o, Vector3d.new(*linear(other.cols[0])), Vector3d.new(*linear(other.cols[1])))
    end
  end
end

module Sketchup
  class SelectionObserver
    def initialize(*); end
  end

  class Color
    attr_reader :rgb

    def initialize(r, g, b)
      @rgb = [r, g, b]
    end
  end

  class Material
    attr_accessor :color, :alpha
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

    def add_instance(definition, transformation = nil)
      i = ComponentInstance.new(@owner.model, definition, self)
      i.transform!(transformation) if transformation
      @items << i
      i
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

  # Behaviour shared by groups and component instances (attributes, transformation, bounds).
  module EntityCore
    attr_reader :model, :transformation
    attr_accessor :name, :material

    def made_unique
      @made_unique
    end

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
      @transformation = t * @transformation
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

    def points_of(entities)
      entities.flat_map { |e| e.is_a?(Face) ? e.all_points : e.world_points }
    end

    def world_points
      local_points.map { |p| transformation.apply(p) }
    end

    def bounds
      BoundingBox.new(world_points)
    end

    def setup_entity(model, parent)
      @model = model
      @parent = parent
      @attrs = Hash.new { |h, k| h[k] = {} }
      @transformation = Geom::Transformation.new
      @made_unique = 0
    end
  end

  class Group
    include EntityCore
    attr_reader :entities

    def initialize(model, parent = nil)
      setup_entity(model, parent)
      @entities = Entities.new(self)
    end

    def local_points
      points_of(entities)
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

  class ComponentDefinition
    attr_reader :entities, :name

    def initialize(model, name)
      @name = name
      @entities = Entities.new(Struct.new(:model).new(model))
    end
  end

  # Like the real API: an instance has NO `entities` method; its contents are in `definition.entities`.
  class ComponentInstance
    include EntityCore
    attr_reader :definition

    def initialize(model, definition, parent = nil)
      setup_entity(model, parent)
      @definition = definition
    end

    def local_points
      points_of(definition.entities)
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

    def definitions
      @definitions ||= Struct.new(:model) do
        def add(name)
          ComponentDefinition.new(model, name)
        end
      end.new(self)
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
