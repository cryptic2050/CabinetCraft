"""Dev-only: parses DXF files with ezdxf and compares them with an expected JSON summary.
stdin: JSON {"files": [{"path":..., "parts": n, "holes": [[layer, x, y, radius], ...]}]}"""
import json, sys
import ezdxf
from ezdxf import recover

spec = json.load(sys.stdin)
bad = 0
for f in spec['files']:
    try:
        doc = ezdxf.readfile(f['path'])
    except Exception as e:  # noqa
        print('UNREADABLE', f['path'], e); bad += 1; continue
    auditor = doc.audit()
    msp = doc.modelspace()
    parts = [e for e in msp if e.dxftype() == 'POLYLINE' and e.dxf.layer == 'PART_OUTLINE']
    circles = sorted((c.dxf.layer, round(c.dxf.center.x, 3), round(c.dxf.center.y, 3), round(c.dxf.radius, 3)) for c in msp if c.dxftype() == 'CIRCLE')
    want = sorted((l, round(x, 3), round(y, 3), round(r, 3)) for l, x, y, r in f['holes'])
    ok = len(parts) == f['parts'] and circles == want and not auditor.has_errors
    closed = all(p.is_closed for p in parts)
    layers_ok = all(c[0] in doc.layers for c in circles)
    print('OK  ' if ok and closed and layers_ok else 'FAIL', f['path'].split('/')[-1], 'parts', len(parts), '/', f['parts'], 'circles', len(circles), '/', len(want), 'audit errors', len(auditor.errors))
    bad += 0 if ok and closed and layers_ok else 1
sys.exit(1 if bad else 0)
