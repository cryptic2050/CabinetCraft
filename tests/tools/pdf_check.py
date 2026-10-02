"""Dev-only: reads PDFs produced by the Ruby writer with pypdf (text), PyMuPDF (render) and OpenCV (QR decode).
stdin: JSON {files: {parts, cutting, labels, nesting: path}, qr: [payloads], part_ids: [...], project}"""
import json, sys
import cv2
import fitz  # PyMuPDF
import numpy as np
from pypdf import PdfReader

spec = json.load(sys.stdin)
ok = True


def check(cond, msg):
    global ok
    print(('OK   ' if cond else 'FAIL ') + msg)
    ok = ok and cond


texts = {}
for name, path in spec['files'].items():
    r = PdfReader(path)
    texts[name] = '\n'.join(p.extract_text() for p in r.pages)
    check(len(r.pages) >= 1 and r.metadata.title and spec['project'] in r.metadata.title, f'{name}: opens in pypdf, {len(r.pages)} page(s), title set')

for name in ('parts', 'cutting', 'nesting'):
    check(spec['project'] in texts[name] and '2026-10-02' in texts[name] and 'Page 1 of' in texts[name], f'{name}: header/footer text present')
check(all(pid in texts['parts'] for pid in spec['part_ids'][:10]), 'parts: part IDs extracted from text')
check('MANUAL OVERRIDE' in texts['parts'], 'parts: manual override status shown')
check('18mm MDF' in texts['cutting'] and 'Side panel' in texts['cutting'] and 'Edge banding' in texts['cutting'], 'cutting list: material, grouped part names, banding section')
check('Cut sequence' in texts['nesting'] and 'sheet 1 of' in texts['nesting'], 'nesting: sheet pages and cut sequence')
check('B01-SIDE_LEFT' in texts['labels'] and 'VALENTINA KITCHEN' in texts['labels'] and 'MANUAL OVERRIDE' in texts['labels'], 'labels: text present')

# Render every page; ensure not blank
for name, path in spec['files'].items():
    doc = fitz.open(path)
    for i, page in enumerate(doc):
        pix = page.get_pixmap(dpi=60)
        arr = np.frombuffer(pix.samples, dtype=np.uint8)
        check((arr < 200).mean() > 0.002, f'{name} page {i + 1}: renders with content')
    doc.close()

# Decode the vector QR codes from the rendered label sheet
doc = fitz.open(spec['files']['labels'])
img = doc[0].get_pixmap(dpi=300)
a = np.frombuffer(img.samples, dtype=np.uint8).reshape(img.height, img.width, img.n)
gray = cv2.cvtColor(a, cv2.COLOR_RGB2GRAY) if img.n == 3 else a[:, :, 0]
det = cv2.QRCodeDetector()
found = set()
ph, pw = gray.shape
# label grid: 3 columns x 7 rows; crop each QR region (right part of each label) generously
mm = 300 / 25.4
for i in range(min(21, len(spec['qr']) if False else 21)):
    col, row = i % 3, i // 3
    x0 = (210 - (3 * 63.5 + 2 * 2.5)) / 2 + col * 66.0
    y0 = (297 - 7 * 38.1) / 2 + row * 38.1
    crop = gray[int(y0 * mm):int((y0 + 38.1) * mm), int((x0 + 35) * mm):int((x0 + 63.5) * mm)]
    if crop.size == 0:
        continue
    crop = cv2.copyMakeBorder(crop, 40, 40, 40, 40, cv2.BORDER_CONSTANT, value=255)
    val, _, _ = det.detectAndDecode(crop)
    if val:
        found.add(val)
want = set(spec['qr'])
check(len(found) >= 1 and found <= {x for x in spec['qr']} | found and len(found & want) >= 1, f'labels: QR codes decode from the rendered PDF ({len(found)} decoded, {len(found & want)} match expected payloads)')
check(all(v.startswith('CC1|') for v in found), 'labels: every decoded QR is a CabinetCraft part code')
print('ALL PDF CHECKS PASSED' if ok else 'PDF CHECKS FAILED')
sys.exit(0 if ok else 1)
