"""Dev-only verifier: decodes ASCII '1'/'0' QR matrices (from Ruby) with OpenCV.
Usage: python3 qr_decode.py < file   (cases separated by a line '---', each case: expected line then matrix)"""
import sys
import cv2
import numpy as np

blocks = sys.stdin.read().split('\n---\n')
bad = 0
for blk in blocks:
    lines = blk.strip('\n').split('\n')
    expected, rows = lines[0], lines[1:]
    n = len(rows)
    img = np.ones((n + 8, n + 8), dtype=np.uint8) * 255
    for r, row in enumerate(rows):
        for c, ch in enumerate(row):
            if ch == '1':
                img[r + 4, c + 4] = 0
    img = cv2.resize(img, None, fx=10, fy=10, interpolation=cv2.INTER_NEAREST)
    val, _, _ = cv2.QRCodeDetector().detectAndDecode(img)
    ok = val == expected
    bad += 0 if ok else 1
    print(('OK  ' if ok else 'FAIL'), 'v%d' % ((n - 17) // 4), len(expected.encode()), 'bytes', '' if ok else repr(val))
sys.exit(1 if bad else 0)
