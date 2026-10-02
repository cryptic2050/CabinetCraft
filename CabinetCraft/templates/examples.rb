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

      ALL = { 'open_shelf_unit' => OPEN_SHELF_UNIT, 'floating_tv_unit' => FLOATING_TV_UNIT }.freeze
    end
  end
end
