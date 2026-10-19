#!/usr/bin/env python3
"""NotchPod's icon: a notch with eyes over two caption lines, on a 16x16 pixel
grid, scaled with nearest-neighbor. Usage: pixel_icon.py <dir>.iconset"""
import struct, sys, zlib

ART = """
................
.#KKKKKKKKKKKK#.
.##KKKKKKKKKK##.
.##KKKKKKKKKK##.
.##KKWWKKWWKK##.
.##KKWWKKWWKK##.
.##KKKKKKKKKK##.
.###KKKKKKKK###.
.##############.
.##############.
.##############.
.##DDDDDDDDDD##.
.##############.
.####GGGGGG####.
.##############.
................
"""
COLORS = {
    "#": (244, 242, 236),  # off-white body
    "K": (17, 17, 22),     # the notch
    "W": (255, 255, 255),  # eyes
    "D": (17, 17, 22),     # caption: original
    "G": (150, 148, 144),  # caption: translation, quieter
}
GRID = [list(row) for row in ART.strip("\n").split("\n")]
for y, x in [(1, 1), (1, 14), (14, 1), (14, 14)]:  # pixel-rounded corners
    GRID[y][x] = "."

def png(path, scale):
    size = 16 * scale
    rows = b"".join(
        b"\0" + b"".join(bytes(COLORS[c] + (255,)) if c != "." else bytes(4)
                         for c in (GRID[y // scale][x // scale] for x in range(size)))
        for y in range(size))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))

if __name__ == "__main__":
    out = sys.argv[1]
    for name, scale in [("16x16", 1), ("16x16@2x", 2), ("32x32", 2), ("32x32@2x", 4), ("128x128", 8),
                        ("128x128@2x", 16), ("256x256", 16), ("256x256@2x", 32), ("512x512", 32), ("512x512@2x", 64)]:
        png(f"{out}/icon_{name}.png", scale)
