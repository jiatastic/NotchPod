#!/usr/bin/env python3
"""NotchPod's pixel-art icon: a notch with a face, wearing headphones, over two
caption lines. Drawn on a 32x32 grid, scaled with nearest-neighbor. No deps."""
import struct, sys, zlib

N = 32
C = {
    "bg": (255, 196, 150), "bg2": (255, 172, 128), "bar": (46, 40, 62),
    "notch": (14, 14, 18), "white": (255, 255, 255), "blush": (255, 110, 145),
    "band": (245, 245, 250), "cup": (255, 79, 109), "cupl": (255, 150, 170),
    "cap": (255, 255, 255), "cap2": (120, 90, 110), "wave": (122, 62, 157),
}
grid = [[None] * N for _ in range(N)]

def inside_round(x, y, x0, y0, x1, y1, r):
    if not (x0 <= x <= x1 and y0 <= y <= y1): return False
    cx = min(max(x, x0 + r), x1 - r); cy = min(max(y, y0 + r), y1 - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r + r * 0.6

def fill(x0, y0, x1, y1, color, r=0):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if r == 0 or inside_round(x, y, x0, y0, x1, y1, r): grid[y][x] = color

def px(points, color):
    for x, y in points: grid[y][x] = color

# Icon body, menu bar, notch.
fill(1, 1, 30, 30, "bg", 7)
for y in range(16, 31):
    for x in range(N):
        if grid[y][x] == "bg": grid[y][x] = "bg2"
for y in range(1, 5):
    for x in range(N):
        if grid[y][x]: grid[y][x] = "bar"
fill(8, 1, 23, 18, "notch", 4); fill(8, 1, 23, 8, "notch")
# Face: tall white eyes, blush, tiny smile.
fill(12, 9, 13, 11, "white"); fill(18, 9, 19, 11, "white")
px([(10, 13), (11, 13), (20, 13), (21, 13)], "blush")
px([(14, 13), (15, 14), (16, 14), (17, 13)], "white")
# Headphones: band over the top, cups on the notch's cheeks.
px([(x, 2) for x in range(8, 24)] + [(7, 3), (24, 3)] + [(6, y) for y in range(4, 10)] + [(25, y) for y in range(4, 10)], "band")
fill(4, 10, 7, 15, "cup", 1); fill(24, 10, 27, 15, "cup", 1)
px([(5, 11), (5, 12), (26, 11), (26, 12)], "cupl")
# A subtitle box: one bright line, one quieter translation line.
fill(6, 21, 25, 28, "notch", 2)
fill(9, 23, 22, 23, "cap")
fill(11, 26, 20, 26, "cap2")

def png(path, scale):
    size = N * scale
    rows = []
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            c = grid[y // scale][x // scale]
            row += bytes(C[c] + (255,)) if c else bytes(4)
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 9)
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", raw) + chunk(b"IEND", b""))

if __name__ == "__main__":
    out = sys.argv[1]
    for name, scale in [("icon_16x16", 1), ("icon_32x32", 1), ("icon_16x16@2x", 1), ("icon_32x32@2x", 2),
                        ("icon_128x128", 4), ("icon_128x128@2x", 8), ("icon_256x256", 8),
                        ("icon_256x256@2x", 16), ("icon_512x512", 16), ("icon_512x512@2x", 32)]:
        png(f"{out}/{name}.png", scale)
