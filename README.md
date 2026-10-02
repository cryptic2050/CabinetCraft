# CabinetCraft Pro (Phase 1)

Parametric cabinet design to manufacturing data inside SketchUp. Original code; not derived from any other plugin.

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

1. CABINETS > *Configure & create* on "Base cabinet".
2. PARAMETERS: set width/height/depth etc. (defaults 600 x 757 x 562), press **CREATE**.
3. Edit any value afterwards: only that cabinet is regenerated (one Undo step per change). Select a cabinet in the model to edit it.
4. PARTS shows the generated panels and dimensions.

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
* Doors/drawers/toe kick, overrides, materials editing, and everything in Phases 2-6 are not implemented.
