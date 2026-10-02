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

## Phase 3: edge banding, hardware, parts and cutting lists

* **Edge banding** (`core/edge_banding.rb`): rules map panel role -> visible faces. Carcass panels get the front edge
  (`edge_carcass`, default 1 mm); doors/drawer fronts get all four edges (`edge_front`, default 2 mm); hidden parts get none.
  Edges are stored on the panel as cabinet faces and reported as cutting-list codes L1/L2 (along length) and W1/W2 (along width).
  Dimensions are *finished* sizes - band thickness is not deducted.
* **Hardware** (`core/hardware.rb`, `core/hardware_rules.rb`): built-in library + user-defined custom items and rules persisted
  per user via `Sketchup.write_default` (`scene/settings_store.rb`). Placement is **derived on demand** and never stored in the
  model, so changing a door height or a hinge rule updates every cabinet at once. Rules: hinge count by door height (table),
  hinge cup positions, handles (doors + drawer fronts), one runner set per drawer, connectors per joint (length / spacing,
  min 2; cam locks add a dowel each), 4 shelf pins per shelf, feet when there is a toe kick.
* **Parts / cutting list** (`manufacturing/`): derived from `Cabinet#part_rows` of every cabinet in the model - no second copy
  of the data exists. Cutting list groups identical parts (material, kind, size to 0.1 mm, grain, edging) and totals area,
  band metres and hardware. Sheet counts are an **area estimate, not nesting**.
* **Exporters** (`exporters/`): CSV, Excel-compatible CSV (UTF-8 BOM, CRLF, `sep=,` hint), JSON. Text cells beginning with
  `= + - @` are prefixed with `'` so spreadsheets cannot run them as formulas.
* Part attributes in the model hold only scalar, stable values (IDs, size, material, edge text). Hardware text is recomputed.

## Phase 4: nesting, labels / QR, validation

* **Nesting** (`manufacturing/nesting.rb`): guillotine bin packing, best-area-fit, shorter-leftover-axis splits; four part
  orderings are tried and the best kept (fewest unplaced, fewest sheets, biggest reusable offcut). **A heuristic - optimality is not
  claimed or checked.** Rules: grain runs along the sheet length (parts with directional grain never rotate against it; non-grain
  materials such as MDF/HDF may rotate), kerf + extra spacing between parts, edge trim, one nest per material. Part rows are the
  input, so nesting always reflects the current model.
* **Locks / manual moves**: dragging a part in the sheet preview validates (bounds, trim, kerf clearance, grain) and *locks* it.
  Locks live in the .skp (`CabinetCraft_Project` model attributes), keyed by part UID plus a size signature. Re-nesting keeps locked
  parts fixed and packs the rest around them; a lock whose part changed size or no longer fits is released and reported.
* **Cut sequence** (`manufacturing/cut_sequence.rb`): derived from the final layout by finding edge-to-edge cuts whose kerf slot
  crosses no part. If none exists (possible with manual layouts) the UI says so instead of inventing a sequence.
* **Labels / QR** (`manufacturing/labels.rb`, `utilities/qr_code.rb`, `exporters/label_html.rb`): one label per part. The QR holds
  only `CC1|<cabinet uuid>|<part key>`; `Controller#lookup_part` resolves it against the live model. The QR encoder is original code
  (byte mode, level M, versions 1-10); it was verified module-for-module against the python-qrcode reference for all payload lengths
  1-213 (`tests/tools/qr_crosscheck.py`, dev only). Printable output is HTML (print / save as PDF from a browser).
* **Validation** (`validation/`, `scene/model_checker.rb`): pure checks (impossible geometry, missing panels, invalid sizes,
  missing material/hardware/edge banding, grain, duplicate cabinet/part IDs, overlapping parts classified as door/drawer
  collisions, clearances, nesting failures) plus model checks against the real SketchUp geometry (deleted parts, hand-edited part
  geometry, scaled cabinets, missing/wrong IDs, overlapping cabinets). Every issue carries cabinet/part so the UI can select it;
  selecting a part opens its cabinet for editing.

## Phase 5: machining, DXF, CNC

* **Machining data** (`manufacturing/machining.rb`): drilling operations derived from parameters in *panel-local* coordinates
  (x along the part length, y along its width from the min corner; face `a` = max side of the thickness axis, `b` = min side; edge
  bores carry an edge code L1/L2/W1/W2 and a position along it). Implemented: shelf pins, hinge cups + plate holes, handle holes,
  side-mount runner holes, cam / dowel / confirmat joints, user-defined patterns. Joint counts and positions come from the same
  functions as the hardware list, and a test asserts both always agree. Not implemented (reported as warnings, never skipped
  silently): lamello / mortise slots, undermount and other runner patterns, runner holes on the drawer box.
* **Feasibility** (`validation/machining_checker.rb`): holes outside the part, blind holes that leave < 2 mm, bores too large for the
  board, overlapping holes. Through-holes are an explicit intent (handles, confirmat clearance), never inferred from depth.
* **CNC** (`manufacturing/cnc.rb`, `cnc_posts.rb`, `core/machining_config.rb`): machine profiles (units, origin, Z zero, feeds, tool
  table), a neutral event list, and posts: ISO (G81), GRBL-style (operator pauses, no canned cycles) and user-defined text-template
  posts (`{x} {y} {z} ...`, validated against a placeholder whitelist). Programs drill by tool (nearest-neighbour order) then cut
  outlines in passes with an explicitly offset path. The checker blocks G-code export on errors (missing drill tool, router wider than
  the nesting kerf, impossible drilling, unplaced parts). **Output is not verified on any machine**; every file says so.
* **Verification**: tests run the generated G-code text through a small interpreter and compare drilled positions / depths / tools,
  cut loops, origins, units, Z conventions and "no rapid XY inside the material" against an independent expectation. DXF files are
  parsed with ezdxf (dev only) and compared hole for hole.
* **Not generated**: tabs / onion skin, cutter compensation, horizontal boring, helical holes, simulation.

## Folder layout

```
cabinetcraft/
  cabinetcraft_pro.rb            loader (registers the extension)
  CabinetCraft/
    main.rb                      toolbar + menu
    core/        units parameter material construction rules panel cabinet library edge_banding hardware hardware_rules machining_config
    generators/  panel_generator (pure)  cabinet_generator (SketchUp geometry)
    scene/       attributes registry settings_store project_store model_checker
    manufacturing/ parts_list cutting_list nesting cut_sequence labels machining cnc cnc_posts
    exporters/   csv_exporter json_exporter label_html dxf_exporter svg_exporter
    utilities/   qr_code
    validation/  validator collision_checker machining_checker
    ui/          controller dialog dashboard.html/.css/.js
    resources/   cabinet.svg
    libraries/   (empty: reserved for later phases)
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
| 3 | Edge banding (rule-based, per edge, L1/L2/W1/W2 codes, banding metres) | IMPLEMENTED |
| 3 | Hardware library (hinges, runners, connectors, handles, shelf pins, legs, locks) + custom items | IMPLEMENTED |
| 3 | Rule-based placement: hinges by door height (editable table), handles, runners, connectors, shelf pins, feet | IMPLEMENTED (quantities + positions as text; no drilling coordinates yet) |
| 3 | Parts list: project-wide, sort / filter / search; export CSV, Excel CSV, JSON | IMPLEMENTED |
| 3 | Cutting list: grouped identical parts, area, sheet estimate, band + hardware totals; export | IMPLEMENTED (sheet count = estimate, not nesting) |
| 3 | PDF export, in-table editing of parts, per-edge manual banding, locks placement | PLANNED |
| 4 | Nesting: grain, kerf, trim, spacing, per-material, totals (sheets, area, used, waste, utilisation) | IMPLEMENTED (heuristic, not optimal) |
| 4 | Sheet preview, drag to move, lock / unlock, rotate, move to another sheet, cut sequence | IMPLEMENTED (cut sequence only when the layout is guillotine-cuttable) |
| 4 | Labels with unique QR per part; printable HTML; CSV / JSON; paste-a-code lookup | IMPLEMENTED |
| 4 | QR opening drawings, assembly steps, production status | PLANNED |
| 4 | Pre-production validation with click-to-select | IMPLEMENTED (drilling check not possible until Phase 5) |
| 4 | Direct PDF output (labels, nesting, cutting list) | PLANNED |
| 5 | Machining data: shelf pins, hinge cups/plates, handles, runners (side-mount), cam/dowel/confirmat, custom patterns | IMPLEMENTED |
| 5 | Drilling feasibility checks (in the pre-production validation) | IMPLEMENTED |
| 5 | DXF R12 per nested sheet; SVG; machining CSV / JSON | IMPLEMENTED (DXF verified with ezdxf) |
| 5 | CNC: machines + tool tables, ISO / GRBL / custom template posts, G-code per sheet, face-B underside program | IMPLEMENTED (unverified on real machines; no tabs) |
| 5 | Lamello / mortise machining, undermount runner holes, horizontal boring output, tabs, G41/G42, simulation | PLANNED |
| 6 | templates, standards, costs, assembly | PLANNED |
| - | All other library cabinets (wall, tall, wardrobe, vanity, TV, corner...) | PLANNED - listed, not selectable |
| - | PLACEHOLDER | none: no control exists that does nothing |
