# CabinetCraft Pro (Phases 1-3)

Parametric cabinet design to manufacturing data inside SketchUp. Original code; not derived from any other plugin.

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
   Export buttons ask where to save the file.

Construction profile **Standard** is self-consistent (overall height = bottom + sides). **Specification example**
reproduces the numbers in the product brief (sides 742, back 581x695, rail 564x100); those numbers stack to 760 mm, not 757 mm,
and the engine warns about it.

## Tests

```
./run_tests.sh      # needs only Ruby >= 3.0
```
Covers the dimension engine (widths 600/800/900/1200, materials 18/16/15, 1-3 doors, 0/1/2/4 shelves, back thicknesses,
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
* Sheet counts in the cutting list are an area-based estimate (area + 10% waste), **not** a nesting result.
* Edge banding: finished sizes only (band thickness not deducted); fixed rules per part role, no per-edge manual editing yet.
* Hardware: quantities and text positions only - no drilling coordinates, prices not used yet, locks are in the library but never placed automatically.
* Handle position rules (50 mm from the free edge, 100 mm below the top), hinge inset (100 mm), connector spacing (200 mm) are my defaults - editable in HARDWARE.
* Custom hardware is stored per user (SketchUp defaults), not inside the .skp; opening a model on another machine shows "Unknown hardware" warnings for custom items.
* PDF export, editing parts in the table, and the Notes column are not implemented.
* Manual dimension overrides, editable materials and everything in Phases 4-6 are not implemented.
