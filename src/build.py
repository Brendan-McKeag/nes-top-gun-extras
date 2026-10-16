#!/usr/bin/env python3
"""Build the Top Gun (NES) Extras patch.

Usage:
    python src/build.py "Top Gun (USA) (Rev 1).nes"

Needs Python 3 and cc65 (ca65 + ld65) on the PATH. Writes to build/:
    TopGun_USA_Rev1_Extras_v<version>.nes   patched ROM (for testing; do not distribute)
    TopGun_USA_Rev1_Extras_v<version>.ips   IPS patch
    TopGun_USA_Rev1_Extras_v<version>.bps   BPS patch (checks the source ROM first)
"""
import hashlib
import os
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, 'build')

VERSION = '1.0'
NAME = 'TopGun_USA_Rev1_Extras_v' + VERSION

# Top Gun (USA) (Rev 1), with its 16-byte iNES header
ROM_SHA1 = '6e233846ca3bb2f50b0176cc31f5cd9667a635f5'

FREE_START = 0xED80     # unused $FF padding in the fixed bank
FREE_END = 0xF800       # DPCM samples start here


def off7(addr):
    """File offset of a fixed-bank (bank 7, $C000-$FFFF) CPU address."""
    return 0x10 + 7 * 0x4000 + (addr - 0xC000)


def assemble():
    os.makedirs(OUT, exist_ok=True)
    obj = os.path.join(OUT, 'extras.o')
    binf = os.path.join(OUT, 'extras.bin')
    lbl = os.path.join(OUT, 'extras.lbl')
    subprocess.check_call(['ca65', '-g', os.path.join(HERE, 'topgun_extras.s'),
                           '-o', obj, '-l', os.path.join(OUT, 'extras.lst')])
    subprocess.check_call(['ld65', '-C', os.path.join(HERE, 'extras.cfg'),
                           '-o', binf, '-Ln', lbl, obj])
    labels = {}
    for line in open(lbl):
        p = line.split()
        labels[p[2].lstrip('.')] = int(p[1], 16)
    return open(binf, 'rb').read(), labels


def make_ips(orig, new):
    # Records are merged across short unchanged gaps so no record splits
    # in the middle of a code block.
    out = bytearray(b'PATCH')
    i = 0
    while i < len(orig):
        if orig[i] == new[i]:
            i += 1
            continue
        j = last = i
        while j < len(orig) and j - i < 0xFFFF:
            if orig[j] != new[j]:
                last = j
            elif j - last > 8:
                break
            j += 1
        n = last - i + 1
        assert i != 0x454F46          # offset that would read as "EOF"
        out += i.to_bytes(3, 'big') + n.to_bytes(2, 'big') + new[i:i + n]
        i = last + 1
    out += b'EOF'
    return bytes(out)


def apply_ips(orig, patch):
    t = bytearray(orig)
    k = 5
    while patch[k:k + 3] != b'EOF':
        a = int.from_bytes(patch[k:k + 3], 'big')
        n = int.from_bytes(patch[k + 3:k + 5], 'big')
        t[a:a + n] = patch[k + 5:k + 5 + n]
        k += 5 + n
    return bytes(t)


def _bps_num(n):
    out = bytearray()
    while True:
        x = n & 0x7F
        n >>= 7
        if n == 0:
            out.append(0x80 | x)
            return out
        out.append(x)
        n -= 1


def make_bps(orig, new):
    # Only SourceRead and TargetRead commands; sizes match, so this is enough.
    assert len(orig) == len(new)
    out = bytearray(b'BPS1')
    out += _bps_num(len(orig)) + _bps_num(len(new)) + _bps_num(0)
    i = 0
    while i < len(new):
        same = orig[i] == new[i]
        j = i
        while j < len(new) and (orig[j] == new[j]) == same:
            j += 1
        n = j - i
        out += _bps_num(((n - 1) << 2) | (0 if same else 1))
        if not same:
            out += new[i:j]
        i = j
    out += zlib.crc32(orig).to_bytes(4, 'little')
    out += zlib.crc32(new).to_bytes(4, 'little')
    out += zlib.crc32(bytes(out)).to_bytes(4, 'little')
    return bytes(out)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    orig = open(sys.argv[1], 'rb').read()
    if hashlib.sha1(orig).hexdigest() != ROM_SHA1:
        sys.exit('That file is not Top Gun (USA) (Rev 1) with an iNES header '
                 '(SHA-1 %s).' % ROM_SHA1)

    code, lbl = assemble()
    r = bytearray(orig)
    o = off7(FREE_START)
    assert FREE_START + len(code) <= FREE_END, 'code overruns the free space'
    assert all(b == 0xFF for b in r[o:o + len(code)]), 'free space is not free'
    r[o:o + len(code)] = code

    def hook(addr, new, expect):
        p = off7(addr)
        assert r[p:p + len(expect)] == bytes(expect), \
            'unexpected bytes at $%04X' % addr
        r[p:p + len(new)] = bytes(new)

    w = lambda a: [a & 0xFF, a >> 8]
    hook(0xC010, [0x4C] + w(lbl['NewDispatch']), [0xA5, 0x18, 0x20])  # LDA $18 / JSR $C4BF
    hook(0xC3DA, [0x4C] + w(lbl['MenuStart']), [0xA9, 0x03, 0x4C])    # LDA #3 / JMP $C0CB
    hook(0xC3DF, [0x4C] + w(lbl['MenuSelect']), [0xE6, 0x22, 0xA9])   # INC $22 / LDA #2
    hook(0xEAC6, [0x20] + w(lbl['ViewerPad']), [0x20, 0x6C, 0xC3])    # JSR $C36C
    hook(0xCE69, [0x20] + w(lbl['RecDemoHook']), [0x20, 0x6F, 0xCE])  # JSR $CE6F
    new = bytes(r)

    ips = make_ips(orig, new)
    assert apply_ips(orig, ips) == new
    bps = make_bps(orig, new)

    for ext, data in (('.nes', new), ('.ips', ips), ('.bps', bps)):
        open(os.path.join(OUT, NAME + ext), 'wb').write(data)
    print('code %d bytes at $%04X-$%04X; IPS %d bytes; BPS %d bytes'
          % (len(code), FREE_START, FREE_START + len(code) - 1, len(ips), len(bps)))
    print('patched ROM SHA-1 %s' % hashlib.sha1(new).hexdigest())


if __name__ == '__main__':
    main()
