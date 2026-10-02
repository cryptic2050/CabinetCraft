# CabinetCraft Pro (Phases 1-5 + materials, overrides, PDF)

Parametric cabinet design to manufacturing data inside SketchUp. Original code; not derived from any other plugin.

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

* **Not yet run inside real SketchUp.** The SketchUp-facing code is tested only against a mock; expect to fix small API issues on first run.
* Toolbar icon is SVG (SketchUp 2016+); older builds need PNG.
* Only top-level groups are scanned for cabinets; making a cabinet a Component or nesting it in another group is unsupported.
* Back-panel Z/Y positions and the rule constants in `core/construction.rb` are my assumptions (the brief gave results, not rules); confirm them against your factory standard.
* Selection sync is bound to the model open when the dialog opened (re-open the dialog after switching models on macOS).
* Doors are plain slab doors only; no profiles (shaker, raised panel, glass), no hinges or handles, no opening direction.
* Drawer boxes are simple 5-panel boxes (bottom under the walls); no runner hardware data or grooves yet. Box depth snaps down to a multiple of 50 mm.
* Toe kick is a single plinth board; no legs or brackets.
* Dividers span only the door/open zone; shelves are evenly spaced and the same count in every compartment.
* Rule constants for drawers (clearance 13 mm, box lift 10 mm, height deduction 40 mm, 50 mm depth steps) are my assumptions - check them against your runners.
* Nesting is a **heuristic, not optimal** (guillotine best-area-fit, best of 4 orderings). Sheet grain is assumed to run along the sheet
  length; one sheet size per material (optional global override); leftover offcuts are not tracked; parts are only ever nested whole.
* A manually arranged layout may not be cuttable with edge-to-edge cuts; the cut sequence is then withheld and the UI says why.
* The cutting-list sheet count (REPORTS) remains an area estimate; NESTING shows the real placed-sheet count.
* **G-code is generated, not verified on any machine.** Simulate and dry-run before cutting. No tabs / onion skin or hold-down logic,
  no cutter compensation (the offset path is explicit), no tool-path simulation. Only vertical holes are machined; horizontal edge
  bores (cam / dowel / confirmat edge holes) are listed but excluded. Face-B holes need a second program (underside), assuming the sheet
  is turned over about its short edge (X mirrored).
* Machining defaults (32 mm system: 37 mm setback, 5 mm pin holes, 35 mm cups at 22.5 mm, 15 mm cams at 34 mm, 128 mm handle spacing...)
  are common values, **not** your hardware's data sheet: confirm and edit them in CNC > Drilling system.
* Lamello / mortise-and-tenon connectors and undermount runners have no machining pattern yet (a warning says so).
* QR codes hold a part identifier only (`CC1|<cabinet id>|<part key>`); they need an external scanner and the "Identify a part" box
  to resolve them. Drawings / assembly steps / production status behind a scan are not implemented.
* Validation checks drilling feasibility but not machine travel limits, clamps or tool-path simulation. Part-geometry edits are detected to 0.2 mm. Selecting a
  part from an issue opens its cabinet group for editing.
* Edge banding: finished sizes only (band thickness not deducted); fixed rules per part role, no per-edge manual editing yet.
* Hardware: quantities and text positions only - no drilling coordinates, prices not used yet, locks are in the library but never placed automatically.
* Handle position rules (50 mm from the free edge, 100 mm below the top), hinge inset (100 mm), connector spacing (200 mm) are my defaults - editable in HARDWARE.
* Custom hardware is stored per user (SketchUp defaults), not inside the .skp; opening a model on another machine shows "Unknown hardware" warnings for custom items.
* Editing parts directly in the PARTS table and the Notes column are not implemented (use ADVANCED PARTS for overrides).
* Overrides: sizes are set along the part's own length / width / thickness axes as generated. Hardware counts, machining and reports
  follow the overridden parts, but the rules that position *other* parts (e.g. where a shelf sits) still use the automatic sizes: an
  override can make parts overlap or break drilling, and the pre-production check will say so.
* Materials: the back material is chosen by thickness unless you pick one explicitly. Texture images are applied best-effort (a missing
  file is ignored). Custom materials travel with the model (restored on another machine if missing there).
* PDF: dimensions are always millimetres; the writer supports Windows-1252 text only (other characters print as "?"); labels are laid
  out for 63.5 x 38.1 mm sheets (use the HTML export for other sizes).
* Phase 6 so far: custom templates, company standards and cost estimation are implemented. Assembly documentation is implemented too (ASSEMBLY tab: rule-based steps, assembled and exploded drawings, EXPLODE / ASSEMBLE buttons that move the parts in the SketchUp model reversibly, assembly PDF).
* Cost figures are estimates from your own prices; anything unpriced is reported as a warning and counted as 0. Material cost follows the nested sheet count, and the nesting is a heuristic, not proven optimal.
* Cost settings are stored in the model. Hardware unit prices are stored per machine (HARDWARE tab), so another machine opening the .skp needs the same prices entered.

* Assembly steps come from part roles in a standard carcass-first order; they are not a manufacturer-verified procedure. Custom-template parts with unknown roles go into a generic step. The exploded view uses fixed directions per role (generic 'away from centre' for unknown roles, which can overlap), and the drawings use approximate painter's-order depth sorting. While a cabinet is exploded, the model check warns and skips its overlap test.
* Runs (RUNS tab) size and place ordinary cabinets and are remembered in the model, so the wall length can be changed later (re-plan resizes and re-places every member, one undo step). The row is placed along the model X axis from the first cabinet, so rotated cabinets are not supported. Deleted members cannot be restored (unlink and recreate); you cannot add or remove cabinets in an existing run. A leftover gap is reported, not filled; there is no filler-strip cabinet yet. Widths are rounded to 1 mm.
