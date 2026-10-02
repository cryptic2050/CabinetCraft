# frozen_string_literal: true

module CabinetCraft
  module Templates
    # Example templates users can install and edit. They also serve as documentation of the format.
    module Examples
      OPEN_SHELF_UNIT = {
        'name' => 'Open shelf unit', 'category' => 'CUSTOM',
        'description' => 'Bookcase: two full-height sides, top, bottom, evenly spaced shelves and a back.',
        'parameters' => [
          { 'key' => 'width', 'label' => 'Width', 'type' => 'length', 'default' => 800, 'min' => 300, 'max' => 2400, 'group' => 'DIMENSIONS' },
          { 'key' => 'height', 'label' => 'Height', 'type' => 'length', 'default' => 1800, 'min' => 300, 'max' => 2400, 'group' => 'DIMENSIONS' },
          { 'key' => 'depth', 'label' => 'Depth', 'type' => 'length', 'default' => 300, 'min' => 150, 'max' => 600, 'group' => 'DIMENSIONS' },
          { 'key' => 'board', 'label' => 'Board material', 'type' => 'material', 'default' => 'mdf_18', 'group' => 'MATERIAL' },
          { 'key' => 'back', 'label' => 'Back material', 'type' => 'material', 'role' => 'back', 'default' => 'hdf_3', 'group' => 'MATERIAL' },
          { 'key' => 'shelves', 'label' => 'Shelves', 'type' => 'int', 'default' => 3, 'min' => 0, 'max' => 10, 'group' => 'CARCASS' },
          { 'key' => 'edge', 'label' => 'Edge band', 'type' => 'length', 'default' => 1, 'min' => 0, 'max' => 3, 'group' => 'EDGE BANDING' }
        ],
        'derived' => [
          { 'name' => 'inner_w', 'label' => 'Internal width', 'expr' => 'width - 2 * board_t' },
          { 'name' => 'gap', 'label' => 'Opening between shelves', 'expr' => '(height - board_t * (shelves + 2)) / (shelves + 1)' },
          { 'name' => 'shelf_d', 'label' => 'Shelf depth', 'expr' => 'depth - back_t' }
        ],
        'constraints' => [
          { 'expr' => 'gap >= 100', 'message' => 'Shelves are less than 100 mm apart', 'severity' => 'error' },
          { 'expr' => 'width / depth <= 8', 'message' => 'Very wide for its depth; consider a centre support', 'severity' => 'warning' }
        ],
        'panels' => [
          { 'key' => 'side_left', 'name' => 'Left side', 'role' => 'side', 'material' => 'board', 'size' => ['board_t', 'depth', 'height'], 'origin' => ['0', '0', '0'],
            'thickness_axis' => 'x', 'grain_axis' => 'z', 'edges' => { 'front' => 'edge' } },
          { 'key' => 'side_right', 'name' => 'Right side', 'role' => 'side', 'material' => 'board', 'size' => ['board_t', 'depth', 'height'], 'origin' => ['width - board_t', '0', '0'],
            'thickness_axis' => 'x', 'grain_axis' => 'z', 'edges' => { 'front' => 'edge' } },
          { 'key' => 'bottom', 'name' => 'Bottom', 'role' => 'bottom', 'material' => 'board', 'size' => ['inner_w', 'depth', 'board_t'], 'origin' => ['board_t', '0', '0'],
            'thickness_axis' => 'z', 'grain_axis' => 'x', 'edges' => { 'front' => 'edge' } },
          { 'key' => 'top', 'name' => 'Top', 'role' => 'top', 'material' => 'board', 'size' => ['inner_w', 'depth', 'board_t'], 'origin' => ['board_t', '0', 'height - board_t'],
            'thickness_axis' => 'z', 'grain_axis' => 'x', 'edges' => { 'front' => 'edge' } },
          { 'key' => 'shelf', 'name' => 'Shelf {i}', 'role' => 'shelf', 'material' => 'board', 'repeat' => 'shelves', 'size' => ['inner_w', 'shelf_d', 'board_t'],
            'origin' => ['board_t', '0', 'board_t + gap * (i + 1) + board_t * i'], 'thickness_axis' => 'z', 'grain_axis' => 'x', 'edges' => { 'front' => 'edge' } },
          { 'key' => 'back', 'name' => 'Back', 'role' => 'back', 'material' => 'back', 'size' => ['inner_w', 'back_t', 'height - 2 * board_t'], 'origin' => ['board_t', 'depth - back_t', 'board_t'],
            'thickness_axis' => 'y', 'grain_axis' => nil }
        ],
        'hardware' => [
          { 'id' => 'dowel', 'qty' => '4', 'part' => 'shelf', 'repeat' => 'shelves', 'detail' => '4 dowels per shelf' },
          { 'id' => 'confirmat', 'qty' => '8', 'part' => 'cabinet', 'detail' => 'top and bottom to sides' }
        ]
      }.freeze

      FLOATING_TV_UNIT = {
        'name' => 'Floating TV unit', 'category' => 'TV UNITS',
        'description' => 'Wall-hung box with optional vertical dividers and an optional flap door.',
        'parameters' => [
          { 'key' => 'width', 'label' => 'Width', 'type' => 'length', 'default' => 1800, 'min' => 600, 'max' => 3000, 'group' => 'DIMENSIONS' },
          { 'key' => 'height', 'label' => 'Height', 'type' => 'length', 'default' => 350, 'min' => 200, 'max' => 800, 'group' => 'DIMENSIONS' },
          { 'key' => 'depth', 'label' => 'Depth', 'type' => 'length', 'default' => 400, 'min' => 200, 'max' => 600, 'group' => 'DIMENSIONS' },
          { 'key' => 'board', 'label' => 'Board material', 'type' => 'material', 'default' => 'ply_18', 'group' => 'MATERIAL' },
          { 'key' => 'front', 'label' => 'Door material', 'type' => 'material', 'default' => 'mdf_18', 'group' => 'MATERIAL' },
          { 'key' => 'dividers', 'label' => 'Vertical dividers', 'type' => 'int', 'default' => 2, 'min' => 0, 'max' => 6, 'group' => 'CARCASS' },
          { 'key' => 'flap', 'label' => 'Flap door', 'type' => 'toggle', 'default' => 1, 'group' => 'FRONTS' },
          { 'key' => 'hinge', 'label' => 'Hinge', 'type' => 'hardware', 'category' => 'hinge', 'default' => 'hinge_soft_close', 'group' => 'HARDWARE' }
        ],
        'derived' => [
          { 'name' => 'inner_w', 'label' => 'Internal width', 'expr' => 'width - 2 * board_t' },
          { 'name' => 'bay', 'label' => 'Bay width', 'expr' => '(inner_w - dividers * board_t) / (dividers + 1)' }
        ],
        'constraints' => [{ 'expr' => 'bay >= 150', 'message' => 'Bays are narrower than 150 mm', 'severity' => 'error' }],
        'panels' => [
          { 'key' => 'top', 'name' => 'Top', 'role' => 'top', 'material' => 'board', 'size' => ['width', 'depth', 'board_t'], 'origin' => ['0', '0', 'height - board_t'], 'thickness_axis' => 'z', 'grain_axis' => 'x' },
          { 'key' => 'bottom', 'name' => 'Bottom', 'role' => 'bottom', 'material' => 'board', 'size' => ['width', 'depth', 'board_t'], 'origin' => ['0', '0', '0'], 'thickness_axis' => 'z', 'grain_axis' => 'x' },
          { 'key' => 'side_left', 'name' => 'Left side', 'role' => 'side', 'material' => 'board', 'size' => ['board_t', 'depth', 'height - 2 * board_t'], 'origin' => ['0', '0', 'board_t'], 'thickness_axis' => 'x', 'grain_axis' => 'y' },
          { 'key' => 'side_right', 'name' => 'Right side', 'role' => 'side', 'material' => 'board', 'size' => ['board_t', 'depth', 'height - 2 * board_t'], 'origin' => ['width - board_t', '0', 'board_t'], 'thickness_axis' => 'x', 'grain_axis' => 'y' },
          { 'key' => 'divider', 'name' => 'Divider {i}', 'role' => 'divider', 'material' => 'board', 'repeat' => 'dividers', 'size' => ['board_t', 'depth', 'height - 2 * board_t'],
            'origin' => ['board_t + bay * (i + 1) + board_t * i', '0', 'board_t'], 'thickness_axis' => 'x', 'grain_axis' => 'y' },
          { 'key' => 'flap_door', 'name' => 'Flap door', 'role' => 'door', 'material' => 'front', 'if' => 'flap', 'size' => ['width', 'front_t', 'height'], 'origin' => ['0', '-front_t', '0'],
            'thickness_axis' => 'y', 'grain_axis' => 'x', 'edges' => { 'top' => '2', 'bottom' => '2', 'left' => '2', 'right' => '2' } }
        ],
        'hardware' => [
          { 'id' => '$hinge', 'qty' => 'if(flap, 3, 0)', 'part' => 'flap_door', 'detail' => 'hinges along the top edge' }
        ]
      }.freeze

      # L-shaped corner base. Frame: the back corner is the origin, arm A runs along +x (wall A at y = 0) and arm B along +y
      # (wall B at x = 0). Both fronts face into the room. Two rectangular bottoms and two backs (no mitred or angled boards).
      # There is no toe kick: it stands on feet or a separate plinth.
      L_SHAPED_CORNER_BASE = {
        'name' => 'L-shaped corner base', 'category' => 'CORNER',
        'description' => 'Corner base cabinet with two arms at 90 degrees, one door per arm. Place it at the inner corner of two walls: arm A along +X, arm B along +Y.',
        'parameters' => [
          { 'key' => 'width_a', 'label' => 'Arm A length (along wall A)', 'type' => 'length', 'default' => 900, 'min' => 600, 'max' => 1400, 'group' => 'DIMENSIONS' },
          { 'key' => 'width_b', 'label' => 'Arm B length (along wall B)', 'type' => 'length', 'default' => 900, 'min' => 600, 'max' => 1400, 'group' => 'DIMENSIONS' },
          { 'key' => 'depth', 'label' => 'Depth of both arms', 'type' => 'length', 'default' => 560, 'min' => 300, 'max' => 700, 'group' => 'DIMENSIONS' },
          { 'key' => 'height', 'label' => 'Carcass height', 'type' => 'length', 'default' => 720, 'min' => 300, 'max' => 1000, 'group' => 'DIMENSIONS' },
          { 'key' => 'toe', 'label' => 'Height above floor (feet)', 'type' => 'length', 'default' => 100, 'min' => 0, 'max' => 200, 'group' => 'DIMENSIONS' },
          { 'key' => 'board', 'label' => 'Board material', 'type' => 'material', 'default' => 'mdf_18', 'group' => 'MATERIAL' },
          { 'key' => 'back', 'label' => 'Back material', 'type' => 'material', 'role' => 'back', 'default' => 'hdf_3', 'group' => 'MATERIAL' },
          { 'key' => 'front', 'label' => 'Door material', 'type' => 'material', 'default' => 'mdf_18', 'group' => 'MATERIAL' },
          { 'key' => 'hinge', 'label' => 'Hinge', 'type' => 'hardware', 'category' => 'hinge', 'default' => 'hinge_standard', 'group' => 'HARDWARE' },
          { 'key' => 'edge', 'label' => 'Edge band', 'type' => 'length', 'default' => 1, 'min' => 0, 'max' => 3, 'group' => 'EDGE BANDING' }
        ],
        'derived' => [
          { 'name' => 'door_a_w', 'label' => 'Door A width', 'expr' => 'width_a - depth' },
          { 'name' => 'door_b_w', 'label' => 'Door B width', 'expr' => 'width_b - depth - front_t' },
          { 'name' => 'door_h', 'label' => 'Door height', 'expr' => 'height - 4' }
        ],
        'constraints' => [
          { 'expr' => 'door_a_w >= 250', 'message' => 'Arm A is too short for a door: increase its length or reduce the depth', 'severity' => 'error' },
          { 'expr' => 'door_b_w >= 250', 'message' => 'Arm B is too short for a door: increase its length or reduce the depth', 'severity' => 'error' }
        ],
        'panels' => [
          { 'key' => 'bottom_a', 'name' => 'Bottom A', 'role' => 'bottom', 'material' => 'board', 'size' => ['width_a', 'depth', 'board_t'], 'origin' => ['0', '0', 'toe'],
            'thickness_axis' => 'z', 'grain_axis' => 'x' },
          { 'key' => 'bottom_b', 'name' => 'Bottom B', 'role' => 'bottom', 'material' => 'board', 'size' => ['depth', 'width_b - depth', 'board_t'], 'origin' => ['0', 'depth', 'toe'],
            'thickness_axis' => 'z', 'grain_axis' => 'y' },
          { 'key' => 'end_a', 'name' => 'End panel A', 'role' => 'side', 'material' => 'board', 'size' => ['board_t', 'depth', 'height - board_t'],
            'origin' => ['width_a - board_t', '0', 'toe + board_t'], 'thickness_axis' => 'x', 'grain_axis' => 'z', 'edges' => { 'front' => 'edge' } },
          { 'key' => 'end_b', 'name' => 'End panel B', 'role' => 'side', 'material' => 'board', 'size' => ['depth', 'board_t', 'height - board_t'],
            'origin' => ['0', 'width_b - board_t', 'toe + board_t'], 'thickness_axis' => 'y', 'grain_axis' => 'z', 'edges' => { 'right' => 'edge' } },
          { 'key' => 'back_a', 'name' => 'Back A', 'role' => 'back', 'material' => 'back', 'size' => ['width_a - board_t', 'back_t', 'height - board_t'],
            'origin' => ['0', '0', 'toe + board_t'], 'thickness_axis' => 'y', 'grain_axis' => nil },
          { 'key' => 'back_b', 'name' => 'Back B', 'role' => 'back', 'material' => 'back', 'size' => ['back_t', 'width_b - board_t - back_t', 'height - board_t'],
            'origin' => ['0', 'back_t', 'toe + board_t'], 'thickness_axis' => 'x', 'grain_axis' => nil },
          { 'key' => 'door_a', 'name' => 'Door A', 'role' => 'door', 'material' => 'front', 'size' => ['door_a_w', 'front_t', 'door_h'], 'origin' => ['depth', 'depth', 'toe + 2'],
            'thickness_axis' => 'y', 'grain_axis' => 'z', 'edges' => { 'left' => '2', 'right' => '2', 'top' => '2', 'bottom' => '2' } },
          { 'key' => 'door_b', 'name' => 'Door B', 'role' => 'door', 'material' => 'front', 'size' => ['front_t', 'door_b_w', 'door_h'], 'origin' => ['depth', 'depth + front_t', 'toe + 2'],
            'thickness_axis' => 'x', 'grain_axis' => 'z', 'edges' => { 'front' => '2', 'back' => '2', 'top' => '2', 'bottom' => '2' } }
        ],
        'hardware' => [
          { 'id' => '$hinge', 'qty' => 'if(height > 900, 3, 2)', 'part' => 'door_a', 'detail' => 'hinges on door A' },
          { 'id' => '$hinge', 'qty' => 'if(height > 900, 3, 2)', 'part' => 'door_b', 'detail' => 'hinges on door B' },
          { 'id' => 'confirmat', 'qty' => '8', 'part' => 'cabinet', 'detail' => 'end panels and bottoms' }
        ]
      }.freeze

      # Blind corner base: a normal base cabinet whose front is split into a door (the accessible part) and a fixed blind panel.
      # The blind part sits behind the neighbouring run, so only the door width is usable.
      BLIND_CORNER_BASE = {
        'name' => 'Blind corner base', 'category' => 'CORNER',
        'description' => 'Base cabinet with a fixed blind panel on one side that tucks behind the neighbouring run, and a door on the other.',
        'parameters' => [
          { 'key' => 'width', 'label' => 'Width', 'type' => 'length', 'default' => 900, 'min' => 600, 'max' => 1400, 'group' => 'DIMENSIONS' },
          { 'key' => 'blind', 'label' => 'Blind panel width', 'type' => 'length', 'default' => 350, 'min' => 100, 'max' => 800, 'group' => 'DIMENSIONS' },
          { 'key' => 'blind_right', 'label' => 'Blind panel on the right', 'type' => 'toggle', 'default' => 1, 'group' => 'DIMENSIONS' },
          { 'key' => 'depth', 'label' => 'Depth', 'type' => 'length', 'default' => 560, 'min' => 300, 'max' => 700, 'group' => 'DIMENSIONS' },
          { 'key' => 'height', 'label' => 'Carcass height', 'type' => 'length', 'default' => 720, 'min' => 300, 'max' => 1000, 'group' => 'DIMENSIONS' },
          { 'key' => 'toe', 'label' => 'Height above floor (feet)', 'type' => 'length', 'default' => 100, 'min' => 0, 'max' => 200, 'group' => 'DIMENSIONS' },
          { 'key' => 'shelves', 'label' => 'Shelves', 'type' => 'int', 'default' => 1, 'min' => 0, 'max' => 4, 'group' => 'CARCASS' },
          { 'key' => 'board', 'label' => 'Board material', 'type' => 'material', 'default' => 'mdf_18', 'group' => 'MATERIAL' },
          { 'key' => 'back', 'label' => 'Back material', 'type' => 'material', 'role' => 'back', 'default' => 'hdf_3', 'group' => 'MATERIAL' },
          { 'key' => 'front', 'label' => 'Front material', 'type' => 'material', 'default' => 'mdf_18', 'group' => 'MATERIAL' },
          { 'key' => 'hinge', 'label' => 'Hinge', 'type' => 'hardware', 'category' => 'hinge', 'default' => 'hinge_standard', 'group' => 'HARDWARE' },
          { 'key' => 'edge', 'label' => 'Edge band', 'type' => 'length', 'default' => 1, 'min' => 0, 'max' => 3, 'group' => 'EDGE BANDING' }
        ],
        'derived' => [
          { 'name' => 'inner_w', 'label' => 'Internal width', 'expr' => 'width - 2 * board_t' },
          { 'name' => 'door_w', 'label' => 'Door width', 'expr' => 'width - blind - 3' },
          { 'name' => 'door_h', 'label' => 'Front height', 'expr' => 'height - 4' },
          { 'name' => 'shelf_d', 'label' => 'Shelf depth', 'expr' => 'depth - back_t' }
        ],
        'constraints' => [
          { 'expr' => 'door_w >= 250', 'message' => 'The door would be narrower than 250 mm: reduce the blind panel or widen the cabinet', 'severity' => 'error' },
          { 'expr' => 'blind <= width / 2', 'message' => 'The blind panel is wider than half the cabinet', 'severity' => 'warning' }
        ],
        'panels' => [
          { 'key' => 'bottom', 'name' => 'Bottom', 'role' => 'bottom', 'material' => 'board', 'size' => ['width', 'depth', 'board_t'], 'origin' => ['0', '0', 'toe'],
            'thickness_axis' => 'z', 'grain_axis' => 'x', 'edges' => { 'front' => 'edge' } },
          { 'key' => 'side_left', 'name' => 'Left side', 'role' => 'side', 'material' => 'board', 'size' => ['board_t', 'depth', 'height - board_t'],
            'origin' => ['0', '0', 'toe + board_t'], 'thickness_axis' => 'x', 'grain_axis' => 'z', 'edges' => { 'front' => 'edge' } },
          { 'key' => 'side_right', 'name' => 'Right side', 'role' => 'side', 'material' => 'board', 'size' => ['board_t', 'depth', 'height - board_t'],
            'origin' => ['width - board_t', '0', 'toe + board_t'], 'thickness_axis' => 'x', 'grain_axis' => 'z', 'edges' => { 'front' => 'edge' } },
          { 'key' => 'back', 'name' => 'Back', 'role' => 'back', 'material' => 'back', 'size' => ['inner_w', 'back_t', 'height - board_t'],
            'origin' => ['board_t', 'depth - back_t', 'toe + board_t'], 'thickness_axis' => 'y', 'grain_axis' => nil },
          { 'key' => 'shelf', 'name' => 'Shelf {i}', 'role' => 'shelf', 'material' => 'board', 'repeat' => 'shelves', 'size' => ['inner_w', 'shelf_d', 'board_t'],
            'origin' => ['board_t', '0', 'toe + board_t + (height - board_t) * (i + 1) / (shelves + 1) - board_t / 2'], 'thickness_axis' => 'z', 'grain_axis' => 'x', 'edges' => { 'front' => 'edge' } },
          { 'key' => 'door', 'name' => 'Door', 'role' => 'door', 'material' => 'front', 'size' => ['door_w', 'front_t', 'door_h'],
            'origin' => ['if(blind_right, 0, blind) + 1.5', '-front_t', 'toe + 2'], 'thickness_axis' => 'y', 'grain_axis' => 'z',
            'edges' => { 'left' => '2', 'right' => '2', 'top' => '2', 'bottom' => '2' } },
          { 'key' => 'blind_panel', 'name' => 'Blind panel', 'role' => 'panel', 'material' => 'front', 'size' => ['blind', 'front_t', 'door_h'],
            'origin' => ['if(blind_right, width - blind, 0)', '-front_t', 'toe + 2'], 'thickness_axis' => 'y', 'grain_axis' => 'z',
            'edges' => { 'left' => '2', 'right' => '2', 'top' => '2', 'bottom' => '2' } }
        ],
        'hardware' => [
          { 'id' => '$hinge', 'qty' => 'if(height > 900, 3, 2)', 'part' => 'door', 'detail' => 'hinges on the door' },
          { 'id' => 'confirmat', 'qty' => '8', 'part' => 'cabinet', 'detail' => 'sides and bottom' }
        ]
      }.freeze

      # --- Bundled cabinets: wall, tall, wardrobe, vanity, TV base -------------------------------------------------------------------
      # Helpers keep the JSON-like definitions short. They return plain Hashes, exactly what a user template file would contain.
      def self.length(key, label, default, min, max, group = 'DIMENSIONS')
        { 'key' => key, 'label' => label, 'type' => 'length', 'default' => default, 'min' => min, 'max' => max, 'group' => group }
      end

      def self.count(key, label, default, min, max, group = 'CARCASS')
        { 'key' => key, 'label' => label, 'type' => 'int', 'default' => default, 'min' => min, 'max' => max, 'group' => group }
      end

      def self.materials
        [{ 'key' => 'board', 'label' => 'Board material', 'type' => 'material', 'default' => 'mdf_18', 'group' => 'MATERIAL' },
         { 'key' => 'back', 'label' => 'Back material', 'type' => 'material', 'role' => 'back', 'default' => 'hdf_3', 'group' => 'MATERIAL' },
         { 'key' => 'front', 'label' => 'Door material', 'type' => 'material', 'default' => 'mdf_18', 'group' => 'MATERIAL' }]
      end

      def self.fittings
        [{ 'key' => 'hinge', 'label' => 'Hinge', 'type' => 'hardware', 'category' => 'hinge', 'default' => 'hinge_standard', 'group' => 'HARDWARE' },
         { 'key' => 'handle', 'label' => 'Handle', 'type' => 'hardware', 'category' => 'handle', 'default' => 'handle_bar', 'group' => 'HARDWARE' },
         { 'key' => 'edge', 'label' => 'Edge band', 'type' => 'length', 'default' => 1, 'min' => 0, 'max' => 3, 'group' => 'EDGE BANDING' }]
      end

      def self.panel(key, name, role, material, size, origin, axis, grain, edges = nil, extra = {})
        { 'key' => key, 'name' => name, 'role' => role, 'material' => material, 'size' => size, 'origin' => origin, 'thickness_axis' => axis, 'grain_axis' => grain }
          .merge(edges ? { 'edges' => edges } : {}).merge(extra)
      end

      # `z0` is the height of the carcass bottom above the floor ('toe' or '0'); `h` the carcass height.
      def self.carcass(z0, h, front_edge: true)
        fe = front_edge ? { 'front' => 'edge' } : nil
        [panel('side_left', 'Left side', 'side', 'board', ['board_t', 'depth', h], ['0', '0', z0], 'x', 'z', fe),
         panel('side_right', 'Right side', 'side', 'board', ['board_t', 'depth', h], ['width - board_t', '0', z0], 'x', 'z', fe),
         panel('bottom', 'Bottom', 'bottom', 'board', ['inner_w', 'depth', 'board_t'], ['board_t', '0', z0], 'z', 'x', fe),
         panel('back', 'Back', 'back', 'back', ['inner_w', 'back_t', "#{h} - 2 * board_t"], ['board_t', 'depth - back_t', "#{z0} + board_t"], 'y', nil)]
      end

      def self.doors(count, z0, h_expr)
        panel('door', 'Door {i}', 'door', 'front', ['door_w', 'front_t', h_expr], ["1.5 + i * (door_w + 3)", '-front_t', "#{z0} + 1.5"], 'y', 'z',
              { 'left' => '2', 'right' => '2', 'top' => '2', 'bottom' => '2' }, 'repeat' => count)
      end

      HINGES = 'if(door_h > 1800, 5, if(door_h > 1200, 4, if(door_h > 900, 3, 2)))'

      WALL_CABINET = {
        'name' => 'Wall cabinet', 'category' => 'WALL CABINETS',
        'description' => 'Wall-hung cabinet with 0, 1 or 2 doors, adjustable shelves and a hanging rail. Doors 0 gives an open wall cabinet.',
        'parameters' => [length('width', 'Width', 600, 200, 1200), length('height', 'Height', 720, 200, 1200), length('depth', 'Depth', 320, 150, 600),
                         count('doors', 'Doors', 1, 0, 2, 'FRONTS'), count('shelves', 'Shelves', 1, 0, 5)] + materials + fittings,
        'derived' => [{ 'name' => 'inner_w', 'label' => 'Internal width', 'expr' => 'width - 2 * board_t' },
                      { 'name' => 'door_w', 'label' => 'Door width', 'expr' => 'width / max(doors, 1) - 3' },
                      { 'name' => 'door_h', 'label' => 'Door height', 'expr' => 'height - 3' },
                      { 'name' => 'gap', 'label' => 'Space between shelves', 'expr' => '(height - 2 * board_t - shelves * board_t) / (shelves + 1)' }],
        'constraints' => [{ 'expr' => 'doors == 0 || door_w >= 150', 'message' => 'Each door would be narrower than 150 mm', 'severity' => 'error' },
                          { 'expr' => 'gap >= 80', 'message' => 'Shelves are less than 80 mm apart', 'severity' => 'error' },
                          { 'expr' => 'depth <= width * 1.5', 'message' => 'Unusually deep for its width', 'severity' => 'warning' }],
        'panels' => carcass('0', 'height', front_edge: true) + [
          panel('top', 'Top', 'top', 'board', ['inner_w', 'depth', 'board_t'], ['board_t', '0', 'height - board_t'], 'z', 'x', { 'front' => 'edge' }),
          panel('rail', 'Hanging rail', 'brace', 'board', ['inner_w', 'board_t', '100'], ['board_t', 'depth - back_t - board_t', 'height - board_t - 100'], 'y', 'x'),
          panel('shelf', 'Shelf {i}', 'shelf', 'board', ['inner_w', 'depth - back_t - board_t - 2', 'board_t'], ['board_t', '0', 'board_t + gap * (i + 1) + board_t * i'], 'z', 'x', { 'front' => 'edge' }, 'repeat' => 'shelves'), # stops short of the hanging rail
          doors('doors', '0', 'door_h')
        ],
        'hardware' => [{ 'id' => '$hinge', 'qty' => HINGES, 'part' => 'door', 'repeat' => 'doors', 'detail' => 'hinges per door' },
                       { 'id' => '$handle', 'qty' => '1', 'part' => 'door', 'repeat' => 'doors', 'detail' => 'handle' },
                       { 'id' => 'shelf_pin', 'qty' => '4', 'part' => 'shelf', 'repeat' => 'shelves', 'detail' => 'adjustable shelf' },
                       { 'id' => 'confirmat', 'qty' => '8', 'part' => 'cabinet', 'detail' => 'top and bottom to sides' }]
      }.freeze

      TALL_CABINET = {
        'name' => 'Tall cabinet', 'category' => 'TALL CABINETS',
        'description' => 'Full-height cabinet (pantry / utility) on feet. Doors: 0 open, 1 one full-height door, 2 a lower and an upper door split at the given height.',
        'parameters' => [length('width', 'Width', 600, 300, 1200), length('height', 'Carcass height', 2000, 1000, 2600), length('depth', 'Depth', 560, 250, 700),
                         length('toe', 'Height above floor (feet)', 100, 0, 200), count('doors', 'Doors (0, 1 or 2)', 2, 0, 2, 'FRONTS'),
                         length('split', 'Lower door height (2 doors)', 1000, 300, 2000, 'FRONTS'), count('shelves', 'Shelves', 4, 0, 12)] + materials + fittings,
        'derived' => [{ 'name' => 'inner_w', 'label' => 'Internal width', 'expr' => 'width - 2 * board_t' },
                      { 'name' => 'door_w', 'label' => 'Door width', 'expr' => 'width - 3' },
                      { 'name' => 'lower_h', 'label' => 'Lower door height', 'expr' => 'split - 2' },
                      { 'name' => 'upper_h', 'label' => 'Upper door height', 'expr' => 'height - split - 2' },
                      { 'name' => 'gap', 'label' => 'Space between shelves', 'expr' => '(height - 2 * board_t - shelves * board_t) / (shelves + 1)' }],
        'constraints' => [{ 'expr' => 'doors != 2 || (split >= 300 && height - split >= 300)', 'message' => 'Both doors must be at least 300 mm high', 'severity' => 'error' },
                          { 'expr' => 'gap >= 100', 'message' => 'Shelves are less than 100 mm apart', 'severity' => 'error' },
                          { 'expr' => 'height / width <= 5', 'message' => 'Very tall for its width: anchor it to the wall', 'severity' => 'warning' }],
        'panels' => carcass('toe', 'height', front_edge: true) + [
          panel('top', 'Top', 'top', 'board', ['inner_w', 'depth', 'board_t'], ['board_t', '0', 'toe + height - board_t'], 'z', 'x', { 'front' => 'edge' }),
          panel('shelf', 'Shelf {i}', 'shelf', 'board', ['inner_w', 'depth - back_t - 5', 'board_t'], ['board_t', '0', 'toe + board_t + gap * (i + 1) + board_t * i'], 'z', 'x', { 'front' => 'edge' }, 'repeat' => 'shelves'),
          panel('door_full', 'Door', 'door', 'front', ['door_w', 'front_t', 'height - 3'], ['1.5', '-front_t', 'toe + 1.5'], 'y', 'z', { 'left' => '2', 'right' => '2', 'top' => '2', 'bottom' => '2' }, 'if' => 'doors == 1'),
          panel('door_lower', 'Lower door', 'door', 'front', ['door_w', 'front_t', 'lower_h'], ['1.5', '-front_t', 'toe + 1.5'], 'y', 'z', { 'left' => '2', 'right' => '2', 'top' => '2', 'bottom' => '2' }, 'if' => 'doors == 2'),
          panel('door_upper', 'Upper door', 'door', 'front', ['door_w', 'front_t', 'upper_h'], ['1.5', '-front_t', 'toe + split + 0.5'], 'y', 'z', { 'left' => '2', 'right' => '2', 'top' => '2', 'bottom' => '2' }, 'if' => 'doors == 2')
        ],
        'hardware' => [{ 'id' => '$hinge', 'qty' => 'if(doors == 1, if(height - 3 > 1800, 5, if(height - 3 > 1200, 4, 3)), 0)', 'part' => 'door_full', 'detail' => 'hinges, full-height door' },
                       { 'id' => '$hinge', 'qty' => 'if(doors == 2, if(lower_h > 900, 3, 2), 0)', 'part' => 'door_lower', 'detail' => 'hinges, lower door' },
                       { 'id' => '$hinge', 'qty' => 'if(doors == 2, if(upper_h > 900, 3, 2), 0)', 'part' => 'door_upper', 'detail' => 'hinges, upper door' },
                       { 'id' => '$handle', 'qty' => 'if(doors == 1, 1, 0)', 'part' => 'door_full', 'detail' => 'handle' },
                       { 'id' => '$handle', 'qty' => 'if(doors == 2, 1, 0)', 'part' => 'door_lower', 'detail' => 'handle' },
                       { 'id' => '$handle', 'qty' => 'if(doors == 2, 1, 0)', 'part' => 'door_upper', 'detail' => 'handle' },
                       { 'id' => 'shelf_pin', 'qty' => '4', 'part' => 'shelf', 'repeat' => 'shelves', 'detail' => 'adjustable shelf' },
                       { 'id' => 'confirmat', 'qty' => '10', 'part' => 'cabinet', 'detail' => 'top and bottom to sides' }]
      }.freeze

      WARDROBE = {
        'name' => 'Wardrobe', 'category' => 'WARDROBES',
        'description' => 'Wardrobe carcass on feet with vertical dividers (sections), the same number of shelves in every section, and hinged doors across the front (0 doors = open wardrobe). Hanging rails are not included.',
        'parameters' => [length('width', 'Width', 1200, 500, 3000), length('height', 'Carcass height', 2200, 1200, 2700), length('depth', 'Depth', 580, 300, 800),
                         length('toe', 'Height above floor (feet)', 80, 0, 200), count('dividers', 'Vertical dividers', 1, 0, 5), count('shelves', 'Shelves per section', 3, 0, 8),
                         count('doors', 'Hinged doors', 2, 0, 6, 'FRONTS')] + materials + fittings,
        'derived' => [{ 'name' => 'inner_w', 'label' => 'Internal width', 'expr' => 'width - 2 * board_t' },
                      { 'name' => 'bay_w', 'label' => 'Section width', 'expr' => '(inner_w - dividers * board_t) / (dividers + 1)' },
                      { 'name' => 'door_w', 'label' => 'Door width', 'expr' => 'width / max(doors, 1) - 3' },
                      { 'name' => 'door_h', 'label' => 'Door height', 'expr' => 'height - 3' },
                      { 'name' => 'gap', 'label' => 'Space between shelves', 'expr' => '(height - 2 * board_t - shelves * board_t) / (shelves + 1)' }],
        'constraints' => [{ 'expr' => 'bay_w >= 200', 'message' => 'Sections are narrower than 200 mm', 'severity' => 'error' },
                          { 'expr' => 'bay_w <= 1000', 'message' => 'Sections wider than 1000 mm: shelves will sag, add a divider', 'severity' => 'warning' },
                          { 'expr' => 'doors == 0 || door_w >= 200', 'message' => 'Each door would be narrower than 200 mm', 'severity' => 'error' },
                          { 'expr' => 'doors == 0 || door_w <= 650', 'message' => 'Doors wider than 650 mm are heavy and may warp: add doors', 'severity' => 'warning' },
                          { 'expr' => 'gap >= 150', 'message' => 'Shelves are less than 150 mm apart', 'severity' => 'error' }],
        'panels' => carcass('toe', 'height', front_edge: true) + [
          panel('top', 'Top', 'top', 'board', ['inner_w', 'depth', 'board_t'], ['board_t', '0', 'toe + height - board_t'], 'z', 'x', { 'front' => 'edge' }),
          panel('divider', 'Divider {i}', 'divider', 'board', ['board_t', 'depth - back_t', 'height - 2 * board_t'], ['board_t + bay_w * (i + 1) + board_t * i', '0', 'toe + board_t'], 'x', 'z', { 'front' => 'edge' }, 'repeat' => 'dividers'),
          panel('shelf', 'Shelf {i}', 'shelf', 'board', ['bay_w', 'depth - back_t - 5', 'board_t'],
                ['board_t + floor(i / max(shelves, 1)) * (bay_w + board_t)', '0', 'toe + board_t + gap * (i % max(shelves, 1) + 1) + board_t * (i % max(shelves, 1))'], 'z', 'x', { 'front' => 'edge' },
                'repeat' => 'shelves * (dividers + 1)'),
          doors('doors', 'toe', 'door_h')
        ],
        'hardware' => [{ 'id' => '$hinge', 'qty' => HINGES, 'part' => 'door', 'repeat' => 'doors', 'detail' => 'hinges per door' },
                       { 'id' => '$handle', 'qty' => '1', 'part' => 'door', 'repeat' => 'doors', 'detail' => 'handle' },
                       { 'id' => 'shelf_pin', 'qty' => '4', 'part' => 'shelf', 'repeat' => 'shelves * (dividers + 1)', 'detail' => 'adjustable shelf' },
                       { 'id' => 'confirmat', 'qty' => '12 + 4 * dividers', 'part' => 'cabinet', 'detail' => 'top, bottom and dividers' }]
      }.freeze

      VANITY_UNIT = {
        'name' => 'Vanity unit', 'category' => 'VANITIES',
        'description' => 'Bathroom vanity base with an open back for plumbing (two rails instead of a top panel and a back), 0-3 doors and an optional shelf. 0 doors gives an open vanity; a wide unit with 2 doors is a double vanity.',
        'parameters' => [length('width', 'Width', 800, 400, 2000), length('height', 'Carcass height', 550, 300, 900), length('depth', 'Depth', 460, 250, 650),
                         length('toe', 'Height above floor (feet)', 150, 0, 300), count('doors', 'Doors', 2, 0, 3, 'FRONTS'),
                         { 'key' => 'shelf', 'label' => 'Shelf', 'type' => 'toggle', 'default' => 1, 'group' => 'CARCASS' }] + materials + fittings,
        'derived' => [{ 'name' => 'inner_w', 'label' => 'Internal width', 'expr' => 'width - 2 * board_t' },
                      { 'name' => 'door_w', 'label' => 'Door width', 'expr' => 'width / max(doors, 1) - 3' },
                      { 'name' => 'door_h', 'label' => 'Door height', 'expr' => 'height - 3' }],
        'constraints' => [{ 'expr' => 'doors == 0 || door_w >= 150', 'message' => 'Each door would be narrower than 150 mm', 'severity' => 'error' }],
        'panels' => [
          panel('side_left', 'Left side', 'side', 'board', ['board_t', 'depth', 'height'], ['0', '0', 'toe'], 'x', 'z', { 'front' => 'edge' }),
          panel('side_right', 'Right side', 'side', 'board', ['board_t', 'depth', 'height'], ['width - board_t', '0', 'toe'], 'x', 'z', { 'front' => 'edge' }),
          panel('bottom', 'Bottom', 'bottom', 'board', ['inner_w', 'depth', 'board_t'], ['board_t', '0', 'toe'], 'z', 'x', { 'front' => 'edge' }),
          panel('rail_front', 'Front rail', 'brace', 'board', ['inner_w', '100', 'board_t'], ['board_t', '0', 'toe + height - board_t'], 'z', 'x'),
          panel('rail_back', 'Rear rail', 'brace', 'board', ['inner_w', '100', 'board_t'], ['board_t', 'depth - 100', 'toe + height - board_t'], 'z', 'x'),
          panel('shelf', 'Shelf', 'shelf', 'board', ['inner_w', 'depth - 20', 'board_t'], ['board_t', '0', 'toe + height / 2'], 'z', 'x', { 'front' => 'edge' }, 'if' => 'shelf'),
          doors('doors', 'toe', 'door_h')
        ],
        'hardware' => [{ 'id' => '$hinge', 'qty' => 'if(door_h > 900, 3, 2)', 'part' => 'door', 'repeat' => 'doors', 'detail' => 'hinges per door' },
                       { 'id' => '$handle', 'qty' => '1', 'part' => 'door', 'repeat' => 'doors', 'detail' => 'handle' },
                       { 'id' => 'shelf_pin', 'qty' => 'if(shelf, 4, 0)', 'part' => 'shelf', 'detail' => 'shelf' },
                       { 'id' => 'confirmat', 'qty' => '8', 'part' => 'cabinet', 'detail' => 'sides to bottom and rails' }]
      }.freeze

      TV_BASE_CABINET = {
        'name' => 'TV base cabinet', 'category' => 'TV UNITS',
        'description' => 'Low media cabinet on feet with vertical dividers, one fixed shelf and 0-4 doors. 0 doors gives an open media unit.',
        'parameters' => [length('width', 'Width', 1600, 600, 3000), length('height', 'Carcass height', 450, 250, 800), length('depth', 'Depth', 400, 250, 600),
                         length('toe', 'Height above floor (feet)', 100, 0, 200), count('dividers', 'Vertical dividers', 1, 0, 6), count('doors', 'Doors', 2, 0, 4, 'FRONTS'),
                         { 'key' => 'shelf', 'label' => 'Shelf in every section', 'type' => 'toggle', 'default' => 1, 'group' => 'CARCASS' }] + materials + fittings,
        'derived' => [{ 'name' => 'inner_w', 'label' => 'Internal width', 'expr' => 'width - 2 * board_t' },
                      { 'name' => 'bay_w', 'label' => 'Section width', 'expr' => '(inner_w - dividers * board_t) / (dividers + 1)' },
                      { 'name' => 'door_w', 'label' => 'Door width', 'expr' => 'width / max(doors, 1) - 3' },
                      { 'name' => 'door_h', 'label' => 'Door height', 'expr' => 'height - 3' }],
        'constraints' => [{ 'expr' => 'bay_w >= 200', 'message' => 'Sections are narrower than 200 mm', 'severity' => 'error' },
                          { 'expr' => 'doors == 0 || door_w >= 200', 'message' => 'Each door would be narrower than 200 mm', 'severity' => 'error' }],
        'panels' => carcass('toe', 'height', front_edge: true) + [
          panel('top', 'Top', 'top', 'board', ['inner_w', 'depth', 'board_t'], ['board_t', '0', 'toe + height - board_t'], 'z', 'x', { 'front' => 'edge' }),
          panel('divider', 'Divider {i}', 'divider', 'board', ['board_t', 'depth - back_t', 'height - 2 * board_t'], ['board_t + bay_w * (i + 1) + board_t * i', '0', 'toe + board_t'], 'x', 'z', { 'front' => 'edge' }, 'repeat' => 'dividers'),
          panel('shelf', 'Shelf {i}', 'shelf', 'board', ['bay_w', 'depth - back_t - 5', 'board_t'], ['board_t + i * (bay_w + board_t)', '0', 'toe + height / 2'], 'z', 'x', { 'front' => 'edge' },
                'repeat' => 'if(shelf, dividers + 1, 0)'),
          doors('doors', 'toe', 'door_h')
        ],
        'hardware' => [{ 'id' => '$hinge', 'qty' => 'if(door_h > 900, 3, 2)', 'part' => 'door', 'repeat' => 'doors', 'detail' => 'hinges per door' },
                       { 'id' => '$handle', 'qty' => '1', 'part' => 'door', 'repeat' => 'doors', 'detail' => 'handle' },
                       { 'id' => 'shelf_pin', 'qty' => '4', 'part' => 'shelf', 'repeat' => 'if(shelf, dividers + 1, 0)', 'detail' => 'adjustable shelf' },
                       { 'id' => 'confirmat', 'qty' => '8 + 4 * dividers', 'part' => 'cabinet', 'detail' => 'top, bottom and dividers' }]
      }.freeze

      ALL = { 'open_shelf_unit' => OPEN_SHELF_UNIT, 'floating_tv_unit' => FLOATING_TV_UNIT,
              'l_shaped_corner_base' => L_SHAPED_CORNER_BASE, 'blind_corner_base' => BLIND_CORNER_BASE,
              'wall_cabinet' => WALL_CABINET, 'tall_cabinet' => TALL_CABINET, 'wardrobe' => WARDROBE, 'vanity_unit' => VANITY_UNIT,
              'tv_base_cabinet' => TV_BASE_CABINET }.freeze
    end
  end
end
