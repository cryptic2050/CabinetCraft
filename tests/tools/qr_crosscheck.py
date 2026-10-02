"""Dev-only: checks that Ruby QR matrices equal the python-qrcode reference for some mask. Reads blocks from stdin."""
import sys, qrcode
from qrcode.util import QRData, MODE_8BIT_BYTE
blocks = sys.stdin.read().split('\n---\n')
bad = 0
for blk in blocks:
    lines = blk.strip('\n').split('\n'); text, rows = lines[0], lines[1:]
    mine = [[ch == '1' for ch in r] for r in rows]
    found = None
    for mask in range(8):
        qr = qrcode.QRCode(error_correction=qrcode.constants.ERROR_CORRECT_M, border=0, mask_pattern=mask)
        qr.add_data(QRData(text, mode=MODE_8BIT_BYTE)); qr.make(fit=True)
        if qr.get_matrix() == mine: found = mask; break
    if found is None: bad += 1; print('NO MATCHING MASK, len', len(text))
print(len(blocks), 'payloads;', bad, 'with no identical reference matrix')
