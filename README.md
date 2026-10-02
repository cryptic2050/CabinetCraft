# CabinetCraft Pro

Parametric cabinet design to manufacturing data inside SketchUp. Original code; not derived from any other plugin.

**Latest additions:** linked cabinet runs with filler strips, corner layouts (blind / L-shaped, left or right hand, changeable), wall / tall /
wardrobe / vanity / TV / filler templates, a project DASHBOARD, cost estimation, assembly drawings, production tracking per part, CNC tabs
and machine travel limits, offcut tracking, a wider nesting search, model-colouring VIEW modes (by part kind, grain, edges, overrides,
production status, presentation), nested/component cabinet discovery, and an in-SketchUp self test.

**Also added:** *editable materials* (custom materials and edits of built-in ones: thickness, sheet size, price, supplier, grain, colour,
texture, waste, edge-band options; stored in the model too), *manual dimension overrides* per part (AUTO / MANUAL OVERRIDE; you are asked
before a parameter change would alter an overridden size), and *PDF export* of the parts list, cutting list, labels (21 per A4) and
nesting sheets with cut sequences.

**Phase 5 adds** machining data (shelf pins, hinge cups and plates, handle holes, side-mount runner holes, cam / dowel / confirmat joints,
custom drilling patterns), drilling feasibility checks, DXF / SVG output per nested sheet, and a CNC post-processor framework:
machine profiles with tool tables, ISO and GRBL-style posts, and user-defined text-template posts. G-code export is blocked while the
CNC check has errors.

**Phase 4 adds** sheet nesting (grain, kerf, trim, spacing; sheet preview with drag-to-move and part locks; real cut sequence when the
layout allows it), production labels with a unique QR code per part, and a pre-production check that compares the data *and* the
SketchUp geometry (deleted or hand-edited parts, scaled or overlapping cabinets, duplicate IDs, missing hardware, nesting failures);
clicking an issue selects it in the model.

**Phase 3 adds** edge banding (rule-based per panel), a hardware library with custom items and rule-based placement
(hinge count by door height from an editable table, handles, runners, connectors, shelf pins, feet), a project-wide parts list
(sort / filter / search) and a cutting list (identical parts grouped, area, banding and hardware totals), exportable as CSV,
Excel-compatible CSV and JSON. Everything is derived from cabinet parameters, so editing a cabinet updates every report.

**Phase 2 adds** slab doors, drawers (front + box), toe kick, vertical dividers and per-compartment shelves, plus presets
(single/double door, 3/4 drawer, drawer-over-door, open shelf). Doors and drawer fronts sit in front of the carcass depth `D`,
and overall height `H` includes the toe kick.

**Phase 1 delivers:** the extension skeleton, dashboard, one parametric **base cabinet** (bottom, sides, back, rails,
shelves), a rule-based dimension engine, stable IDs + attribute metadata, and live regeneration of just the edited cabinet.
See `docs/ARCHITECTURE.md` for the full design and the IMPLEMENTED / PLANNED table.

## Install (SketchUp 2017+, Windows/macOS)

Option A - copy: put `cabinetcraft_pro.rb` **and** the `CabinetCraft/` folder in SketchUp's Plugins folder
(Windows `%APPDATA%\SketchUp\SketchUp 20xx\SketchUp\Plugins`, macOS `~/Library/Application Support/SketchUp 20xx/SketchUp/Plugins`), restart SketchUp.

Option B - package: `zip -r cabinetcraft_pro.rbz cabinetcraft_pro.rb CabinetCraft`, then
*Extensions > Extension Manager > Install Extension*.

Open it from the **CabinetCraft Pro** toolbar button or *Extensions > CabinetCraft Pro*.

## Use

1. CABINETS > *Configure & create* on a base cabinet preset.
2. PARAMETERS: set width/height/depth etc. (defaults 600 x 757 x 562), press **CREATE**.
3. Edit any value afterwards: only that cabinet is regenerated (one Undo step per change). Select a cabinet in the model to edit it.
4. PARTS lists every part of every cabinet; REPORTS shows the cutting list; HARDWARE manages the library and hinge rules.
   Export buttons ask where to save the file (PDF, CSV, Excel CSV, JSON).
   MATERIALS: edit sheet sizes/prices or add your own board; the cabinets using it update. In PARAMETERS (an existing cabinet),
   **ADVANCED PARTS** lets you override a part's length, width, thickness, position, material or edge banding.
5. NESTING: set kerf/trim and press NEST MATERIAL. Drag a part to move and lock it (orange outline); click a part to rotate, unlock
   or send it to another sheet. LABELS: preview, print the HTML sheet, or paste a scanned code to find a part. PROJECT: set the
   project name and read the pre-production check; click an issue to select it.
6. CNC: review machining data, pick or define a machine (tool table, origin, units) and post, press **Check**, then export G-code,
   DXF or SVG (one file per sheet). **Set the nesting kerf to at least the router diameter first.**

Construction profile **Standard** is self-consistent (overall height = bottom + sides). **Specification example**
reproduces the numbers in the product brief (sides 742, back 581x695, rail 564x100); those numbers stack to 760 mm, not 757 mm,
and the engine warns about it.

## Tests

```
./run_tests.sh      # needs only Ruby >= 3.0
```
Covers nesting (random layouts checked for bounds, kerf, grain and cut-sequence soundness), the QR encoder (cross-checked against
a reference implementation when Python + qrcode are installed), validation, labels, and the dimension engine (widths 600/800/900/1200, materials 18/16/15, 1-3 doors, 0/1/2/4 shelves, back thicknesses,
panel overlap/bounds invariants, the brief's exact example), parameter validation, units, and - against a small SketchUp **mock** -
the generator, registry, controller, undo operations and duplicate-ID repair.

## Known limitations

The full, honest register (FIXED / MITIGATED / OPEN / CANNOT FIX, with reasons) is in **`docs/LIMITATIONS.md`**. The ones that matter most:

* **Not yet run inside real SketchUp.** Everything is tested against a mock. Run **Extensions > CabinetCraft Pro > Run self test** first; it checks the real API calls the extension relies on (and leaves your model unchanged).
* **G-code is generated, not verified on a machine.** Dry-run before cutting.
* **Nesting is a heuristic**, never claimed optimal. Assembly steps and explode directions are rule-based, not a manufacturer procedure.
* Machining, hinge, drawer and construction constants are common defaults, not your hardware's data sheet; they are editable.
* Not built: shaker / raised / glass doors, Lamello and undermount-runner machining, horizontal edge boring output, outside corners and non-90-degree walls, door-swing simulation.
