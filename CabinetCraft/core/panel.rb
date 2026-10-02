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

    # Cabinet-local face names -> [axis, side].
    FACES = {
      left: %i[x min], right: %i[x max], front: %i[y min], back: %i[y max], bottom: %i[z min], top: %i[z max]
    }.freeze

    GENERIC_NAMES = {
      'side' => 'Side panel', 'bottom' => 'Bottom', 'back' => 'Back', 'brace_front' => 'Front rail',
      'brace_rear' => 'Rear rail', 'shelf' => 'Shelf', 'zone_shelf' => 'Fixed shelf', 'divider' => 'Divider',
      'toe_kick' => 'Toe kick', 'door' => 'Door', 'drawer_front' => 'Drawer front', 'drawer_side' => 'Drawer side',
      'drawer_box_front' => 'Drawer box front', 'drawer_box_back' => 'Drawer box back', 'drawer_bottom' => 'Drawer bottom'
    }.freeze

    attr_reader :key, :name, :role, :origin, :size, :thickness_axis, :grain_axis,
                :material_id, :material_label, :grooved_into, :edges, :overridden

    def initialize(key:, name:, role:, origin:, size:, thickness_axis:, material_id:, material_label:,
                   grain_axis: nil, grooved_into: [], edges: {}, overridden: [])
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
      @edges = validate_edges(edges).freeze # { face name => band thickness mm }
      @overridden = overridden.freeze       # names of manually overridden fields (empty = AUTO)
    end

    def status
      overridden.empty? ? 'AUTO' : 'MANUAL OVERRIDE'
    end

    # Copy with some attributes replaced; nil keeps the current value (an empty edges hash is a real value).
    def with(size: nil, origin: nil, material: nil, edges: nil, overridden: nil)
      self.class.new(key: key, name: name, role: role, origin: origin || self.origin, size: size || self.size, thickness_axis: thickness_axis,
                     material_id: material ? material.id : material_id, material_label: material ? material.name : material_label,
                     grain_axis: grain_axis, grooved_into: grooved_into, edges: edges.nil? ? self.edges : edges,
                     overridden: overridden.nil? ? self.overridden : overridden)
    end

    def with_edges(new_edges)
      with(edges: new_edges)
    end

    # Name shared by identical parts, e.g. 'drawer_2_side_left' -> 'Drawer side'.
    def generic_name
      k = key.sub(/\Adrawer_\d+_/, 'drawer_').gsub(/_c\d+/, '').sub(/_\d+\z/, '').sub(/_(left|right)\z/, '')
      GENERIC_NAMES.fetch(k, name)
    end

    # Cutting-list edge code for a cabinet face: L1/L2 run along the panel length
    # (they sit on the min/max of the width axis), W1/W2 along the width.
    def edge_code(face)
      axis, side = FACES.fetch(face)
      n = side == :min ? '1' : '2'
      axis == plane_axes[1] ? "L#{n}" : "W#{n}"
    end

    # Cabinet-local point -> panel-local [lx, ly, lz]: lx along the length axis, ly along the width axis,
    # lz through the thickness, all measured from the panel's minimum corner. Face :a is lz = thickness, :b is lz = 0.
    def to_local(point)
      la, wa = plane_axes
      [point[AXES.index(la)] - origin[AXES.index(la)],
       point[AXES.index(wa)] - origin[AXES.index(wa)],
       point[AXES.index(thickness_axis)] - origin[AXES.index(thickness_axis)]]
    end

    # Where the part sits, measured from the cabinet's left-front-bottom corner.
    def assembly_position
      "x #{origin[0].round(1)} / y #{origin[1].round(1)} / z #{origin[2].round(1)} mm"
    end

    # { 'L1' => 1.0, ... } for banded edges only.
    def edge_codes
      edges.to_h { |face, mm| [edge_code(face), mm] }.sort.to_h
    end

    def edge_text
      return '-' if edges.empty?

      edge_codes.map { |code, mm| "#{code} #{mm}mm" }.join(', ')
    end

    # { band thickness => metres of banding } for this single panel.
    def edge_lengths
      edges.each_with_object(Hash.new(0.0)) do |(face, mm), acc|
        acc[mm] += (edge_code(face).start_with?('L') ? length : width)
      end
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
        'material_id' => material_id,
        'generic_name' => generic_name,
        'grain' => grain.to_s,
        'edge_codes' => edge_codes,
        'edge_text' => edge_text,
        'position' => assembly_position,
        'status' => status,
        'qty' => 1
      }
    end

    private

    def validate_edges(edges)
      edges.each_key do |face|
        axis, = FACES.fetch(face) { raise ArgumentError, "unknown face #{face.inspect}" }
        raise ArgumentError, "face #{face} is not an edge of #{key}" if axis == thickness_axis
      end
      edges.select { |_, mm| mm.to_f.positive? }.transform_values(&:to_f)
    end
  end
end
