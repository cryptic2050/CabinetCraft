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

      ALL = { 'open_shelf_unit' => OPEN_SHELF_UNIT, 'floating_tv_unit' => FLOATING_TV_UNIT,
              'l_shaped_corner_base' => L_SHAPED_CORNER_BASE, 'blind_corner_base' => BLIND_CORNER_BASE }.freeze
    end
  end
end
