# frozen_string_literal: true

module CabinetCraft
  # One production panel plus its position in cabinet-local space.
  #
  # Cabinet-local axes (millimetres): x = width (left -> right),
  # y = depth (front -> back), z = height (up). `origin` is the minimum corner.
  #
  # Dimension convention: `length` is the longer in-plane dimension and `width`
  # the shorter one (standard cutting-list convention); `thickness` is the
  # dimension along `thickness_axis`.
  class Panel
    AXES = %i[x y z].freeze

    attr_reader :key, :name, :role, :origin, :size, :thickness_axis, :grain_axis,
                :material_id, :material_label, :grooved_into

    def initialize(key:, name:, role:, origin:, size:, thickness_axis:, material_id:, material_label:,
                   grain_axis: nil, grooved_into: [])
      @key = key
      @name = name
      @role = role
      @origin = origin.map(&:to_f).freeze # [x, y, z]
      @size = size.map(&:to_f).freeze     # [dx, dy, dz]
      @thickness_axis = thickness_axis
      @grain_axis = grain_axis
      @material_id = material_id
      @material_label = material_label
      @grooved_into = grooved_into.freeze # keys of panels this one is housed in (allowed to overlap)
    end

    def size_on(axis)
      @size[AXES.index(axis)]
    end

    def thickness
      size_on(thickness_axis)
    end

    # In-plane axes ordered longest first (ties keep x, y, z order).
    def plane_axes
      (AXES - [thickness_axis]).each_with_index.sort_by { |a, i| [-size_on(a), i] }.map(&:first)
    end

    def length
      size_on(plane_axes[0])
    end

    def width
      size_on(plane_axes[1])
    end

    # :length, :width or :none - grain direction relative to the panel's length.
    def grain
      return :none if grain_axis.nil?

      case grain_axis
      when plane_axes[0] then :length
      when plane_axes[1] then :width
      else :none
      end
    end

    def min_corner
      @origin
    end

    def max_corner
      @origin.zip(@size).map { |o, s| o + s }
    end

    # True if the interiors of the two panels intersect (touching faces do not count).
    def overlaps?(other, tolerance = 1e-6)
      3.times.all? do |i|
        min_corner[i] < other.max_corner[i] - tolerance && max_corner[i] > other.min_corner[i] + tolerance
      end
    end

    def to_h(part_id:, cabinet_id:)
      {
        'part_id' => part_id,
        'part_uid' => "#{cabinet_id}:#{key}",
        'key' => key,
        'name' => name,
        'role' => role.to_s,
        'length' => length.round(3),
        'width' => width.round(3),
        'thickness' => thickness.round(3),
        'material' => material_label,
        'grain' => grain.to_s,
        'qty' => 1
      }
    end
  end
end
