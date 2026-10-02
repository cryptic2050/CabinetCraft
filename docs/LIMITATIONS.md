# Limitations register

Every limitation CabinetCraft Pro is known to have, with what was done about it.
Status words: **FIXED** (no longer a limitation), **MITIGATED** (reduced, a residue remains and is described),
**OPEN** (deliberately not built; reason given), **CANNOT FIX** (not something code can solve).

## 1. Verification (the biggest one)

| Limitation | Status | Detail |
|---|---|---|
| All SketchUp-facing code has only been run against a mock | **MITIGATED** | I cannot run SketchUp here. Added **Extensions > CabinetCraft Pro > Run self test** (also SETTINGS > Self test): it executes the real API calls the extension relies on (extrude, bounds, attributes, `transform!` composition, rotated transformations, `make_unique`, `clear!`, component instances, material alpha, `erase!`, a generated cabinet measured against its part list, registry lookup) inside an operation that is aborted, and lists every check that behaves differently from what the code assumes. The same self test runs against the mock in the test suite, so the mock and the checks stay aligned. **Please run it once in SketchUp and send me any FAIL line.** |
| G-code / DXF not verified on a machine | **CANNOT FIX** | A built-in simulator checks the generated program (travel, depth, tab logic), and DXF was verified with `ezdxf`. Only a dry run on your router proves it. |
| Construction constants (back position, drawer clearances, hinge insets, 32 mm system values) are my defaults | **MITIGATED** | All editable (company standards, HARDWARE, CNC > Drilling system). They are common values, not your factory's; confirm them. |

## 2. Platform

| Limitation | Status | Detail |
|---|---|---|
| Toolbar icon was SVG only | **FIXED** | PNG icons (16/24/32) are used on SketchUp before 2016. |
| SketchUp older than 2017 fails obscurely | **FIXED** | The loader shows a clear message and does not load (HtmlDialog needs 2017+). |
| Selection sync bound to the model open when the dialog opened | **FIXED** | An app observer re-attaches the selection observer, creates a fresh controller (its caches belong to the old model) and reloads the page when another model is opened, created or activated. Untestable outside SketchUp; covered by the mock only for loading. |
| Only top-level groups were scanned for cabinets; components unsupported | **FIXED** | Discovery is recursive (groups and component instances, depth 8), uses world-space boxes, and handles cabinets inside other groups. |
| Custom hardware stored per machine only | **FIXED** | Snapshotted into the model and restored where missing. Unit prices travel with it. |
| Custom materials, templates | **FIXED** | Snapshotted into the model likewise. |

## 3. Cabinet design

| Limitation | Status | Detail |
|---|---|---|
| Only base cabinets | **FIXED** | Bundled templates: wall, tall, wardrobe, vanity, TV base, filler strip, L-shaped corner base, blind corner base, open shelf unit (14 in all, installed with one click). |
| Doors: slab only | **OPEN** | Shaker / raised-panel / glass need panel-profile geometry and router profiles. Not built. |
| Drawer boxes: simple 5-panel, no grooves; depth snaps to 50 mm steps | **OPEN** | The step and clearances are editable standards; grooves are not modelled. |
| Toe kick is a single board | **OPEN** | Legs/feet are in the hardware library and counted, not modelled. |
| Dividers span only the door/open zone; equal shelves per compartment | **OPEN** | Use a custom template for anything else. |
| Overrides do not move *other* parts | **MITIGATED** | By design (a manual size is a manual size). The pre-production check reports overlaps/drilling breaks the override causes. |

## 4. Runs and corners

| Limitation | Status | Detail |
|---|---|---|
| Runs could not be edited after creation; deleted members unrecoverable | **FIXED** | Add, remove, repair (re-create a deleted member from its stored spec), pin, unlink, re-stretch. |
| No filler strips | **FIXED** | Filler members (20-150 mm, sized last by the planner). |
| Rotated cabinets unsupported | **FIXED** | Runs follow the first cabinet's axis and direction; run B is turned 90 degrees. |
| Left-handed corners only | **FIXED** | Left/right hand, both for blind and L-shaped. |
| Corner kind of an existing layout could not change | **FIXED** | "Change corner" re-plans with the new kind in one undo step. |
| Door-swing / blind-panel clearance unchecked | **MITIGATED** | Conservative warnings (door width, blind panel vs depth) plus a corrected blind default (600 mm). Real swing depends on hinge and handle hardware, so these are checks, not a simulation. |
| Outside corners; walls not at 90 degrees | **OPEN** | Different geometry (mitres, angled returns). Not built. |
| Wall/tall units in a corner | **MITIGATED** | Usable as corner members via templates; no dedicated corner-wall logic. |

## 5. Manufacturing

| Limitation | Status | Detail |
|---|---|---|
| Nesting is a heuristic | **MITIGATED, CANNOT FIX** | Optimal nesting is NP-hard. The search is now far wider than the first version (4 orders x 3 fit rules x 2 split rules plus seeded perturbations; never worse than the old result by construction; 538 to 526 sheets on a 76-problem benchmark). It is still **not** claimed optimal. |
| Offcuts not tracked | **FIXED** | Merged free rectangles above a configurable minimum are listed and drawn. |
| Cutting-list sheet count was an area estimate | **FIXED** | It now uses the real nested sheet count. |
| No tabs / hold-down | **FIXED** | Tabs on the final pass (configurable width/height/count), small-part warning adapts. |
| Machine travel limits not checked | **FIXED** | Per-machine limits checked in CNC check; export blocked on violation. |
| Kerf < router diameter ("NOT READY") | **FIXED** | "Match nesting to the router" sets spacing from the active tool. |
| Production status behind a QR scan | **FIXED** | Per-part stages (cut, banded, drilled, assembled) with size signatures, shown on lookup and in the dashboard. Opening drawings from a scan is still **OPEN** (a QR holds only an identifier; a scanner app is needed). |
| Horizontal edge bores not machined | **OPEN** | Needs a horizontal boring head; listed and excluded, with a warning. |
| Lamello / mortise and undermount-runner patterns | **OPEN** | Manufacturer-specific; inventing coordinates would be wrong. They would also need a new slot operation type. Warning shown. |
| Cutter compensation / tool-path simulation beyond the built-in checker | **OPEN** | Offset paths are explicit; the simulator checks the program, not collisions with clamps. |
| Face-B holes need a second program | **OPEN** | Assumes the sheet is turned about its short edge. |
| Sheet grain assumed along sheet length; one size per material | **OPEN** | A global override exists. |
| PDF text Windows-1252 only | **MITIGATED** | Common accented Latin and symbols are transliterated instead of printing `?`; other scripts still degrade. |
| Labels laid out for 63.5 x 38.1 mm | **OPEN** | HTML export for other sizes. |

## 6. Reporting and costing

| Limitation | Status | Detail |
|---|---|---|
| Prices not used | **FIXED** | Full costing (materials by sheets, banding, hardware, CNC, labour, margin) with per-cabinet allocation that sums exactly. Unpriced items are warnings counted as 0. |
| Hinges / handles not modelled | **FIXED** | Rule-based quantities, positions and drilling for hinges (by door height), handles, runners, connectors, pins. |
| Assembly steps are generic | **MITIGATED** | Rule-based by part role in carcass-first order, **not** a manufacturer procedure. Drawings now use an exact painter's order (0 of 2000 ray-checks wrong versus 56 for the old sort). Unknown roles go to a generic step and explode "away from centre". |
| No at-a-glance project status | **FIXED** | DASHBOARD tab. |
| No visual check of the model by data | **FIXED** | VIEW tab: colour by material, part kind, grain, edge banding, overrides, production status, cabinet; presentation mode with a see-through carcass. One undo step; mode saved in the model; real materials restored exactly. |
| PARTS table not editable, no Notes column | **OPEN** | Edits go through parameters or ADVANCED PARTS overrides, by design (one source of truth). |

## 7. Honest bottom line

* Everything above marked FIXED is covered by automated tests on the mock (about 600 tests, hundreds of thousands of assertions) and, for the page, headless-browser smoke tests.
* Nothing has been run in real SketchUp. Run the self test first; expect small API fixes.
* G-code and drilling data must be dry-run before production.
* Nesting and assembly sequences are rule-based aids, not guarantees.
