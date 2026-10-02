# CabinetCraft Pro - technical architecture

Principle: **one source of truth**. The cabinet's parameters (stored on the SketchUp group
as attributes) are the master. Geometry, parts, labels, nesting and CNC data are *derived*
from them and never edited independently.

```
parameters ──> Rules (dimension engine) ──> PanelGenerator ──> Panel list ──┬─> SketchUp geometry (CabinetGenerator)
 (attributes)    pure, no SketchUp          pure, no SketchUp                ├─> parts list / cutting list   (Phase 3)
                                                                             ├─> nesting, labels, QR         (Phase 4)
                                                                             └─> machining, DXF, post-proc.  (Phase 5)
```

## Layers and rules

| Layer | Folder | May call SketchUp API? | Tested how |
|---|---|---|---|
| Domain (units, params, materials, construction profiles, rules, panels, cabinet) | `core/`, `generators/panel_generator.rb` | **No** | plain Ruby unit tests |
| Scene (attributes, registry, geometry) | `scene/`, `generators/cabinet_generator.rb` | Yes | mock-SketchUp tests + manual in SketchUp |
| Interface (controller, dialog, HTML) | `ui/` | Controller: only via `Sketchup.active_model`; dialog: `::UI` | mock tests + headless browser smoke test |

* Internal unit: **millimetres**. Converted only at the UI edge and at the SketchUp API (inches).
* Parameters are string-keyed hashes (JSON / attribute friendly).
* Namespaces `Scene` and `Interface` deliberately avoid shadowing `::Sketchup` and `::UI`.
* Construction rules are **data** (`core/construction.rb` profiles); the engine has no cabinet-specific constants.

## Identity

* `cabinet_id` = UUID (stable). `cabinet_label` = `B01`... (for people/labels).
* Part: `part_uid` = `<cabinet_id>:<panel key>` (stable across regeneration); `part_id` = `B01-SIDE_LEFT`.
* Copies of a cabinet (move+copy) duplicate the id; the controller detects this and re-identifies the copy.

## Incremental regeneration

`Controller#update` rebuilds **only the one cabinet group** that changed, inside one undo step, preserving its
transform. No-op edits (identical parameters) do not touch the model.

## Vertical layout and fronts (Phase 2)

```
z=0 .. toe          plinth board (set back toe_kick_depth)
toe .. toe+t        bottom panel (full width), sides stand on it
 top zone           drawers (full width; boxes run on runner_clearance each side)
 fixed shelf        only when drawers AND doors are combined
 lower zone         doors in front; shelves + vertical dividers inside
doors / drawer fronts sit at y < 0 (in front of the carcass depth D)
```
Overall height H includes the toe kick. Door height = zone height - 2 reveals. Drawers-only cabinets split the carcass height
equally. When drawers fill the cabinet, shelves/dividers are ignored *with a warning*.

## Folder layout

```
cabinetcraft/
  cabinetcraft_pro.rb            loader (registers the extension)
  CabinetCraft/
    main.rb                      toolbar + menu
    core/        units parameter material construction rules panel cabinet library
    generators/  panel_generator (pure)  cabinet_generator (SketchUp geometry)
    scene/       attributes registry
    ui/          controller dialog dashboard.html/.css/.js
    resources/   cabinet.svg
    manufacturing/ validation/ exporters/ libraries/ utilities/   (empty: reserved for Phases 3-6)
  tests/         test_rules  test_parameter_units_cabinet  test_scene  mock_sketchup  ui_bridge (dev harness)
  run_tests.sh
```

## Status by phase

| Phase | Feature | Status |
|---|---|---|
| 1 | Extension loader, toolbar, menu | IMPLEMENTED (untested in real SketchUp) |
| 1 | Dashboard (dark UI, 10 sections) | IMPLEMENTED for PROJECT, CABINETS, PARAMETERS, MATERIALS, PARTS, SETTINGS; others are labelled roadmap pages |
| 1 | Base cabinet generator (bottom, sides, back, rails, shelves) | IMPLEMENTED |
| 1 | Rule engine, validation, door-width calculation, unit display switch | IMPLEMENTED |
| 1 | Attribute metadata + stable IDs, live update of one cabinet | IMPLEMENTED |
| 2 | Slab doors (full overlay), widths from reveals/gaps, front material | IMPLEMENTED |
| 2 | Drawers: fronts + 5-part boxes (front, back, 2 sides, bottom), equal split or drawers-over-doors | IMPLEMENTED (geometry and dimensions; runner *hardware* data is Phase 3) |
| 2 | Toe kick (raises carcass, plinth board) | IMPLEMENTED (board only: no plinth legs/brackets) |
| 2 | Vertical dividers, per-compartment shelves, fixed shelf under drawers | IMPLEMENTED |
| 2 | Library presets (single/double door, 3/4 drawer, drawer-over-door, open shelf) | IMPLEMENTED (presets of one generator) |
| 2 | Shaker / raised-panel / glass / aluminium doors, door-profile library | PLANNED - slab only |
| 2 | Drawer slide types, hinge/handle placement | PLANNED (Phase 3 hardware) |
| 1 | Material editing, prices, custom materials | PLANNED - library is read-only (not part of this Phase 2 slice) |
| 1 | Manual dimension overrides ("AUTO" / "MANUAL OVERRIDE") | PLANNED (not yet built). Part keys are stable so overrides can be keyed to them |
| 2-6 | hardware, edge banding, cutting list, nesting, labels/QR, validation suite, machining, DXF, CNC, templates, standards, costs, assembly | PLANNED |
| - | All other library cabinets (wall, tall, wardrobe, vanity, TV, corner...) | PLANNED - listed, not selectable |
| - | PLACEHOLDER | none: no control exists that does nothing |
