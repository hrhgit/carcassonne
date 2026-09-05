#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用 Pillow 模拟 Godot 的 4 弧线 + 5 段 tile_placeholder.gd 渲染。
生成一张参考图，验证视觉效果是否合理。"""
from PIL import Image, ImageDraw
import math
import os

OUT = "docs/tile_placeholder_preview.png"
os.makedirs(os.path.dirname(OUT), exist_ok=True)

S = 240       # tile size (DESIGN_SIZE)
HALF = S // 2
ARC_R = int(HALF * 0.45)
ARC_WIDTH = 5
PTS = 28


# 模拟 EdgeKind → color
EDGE_COLORS = {
    "EMPTY": (189, 182, 168),  # gray
    "LAND":  (126, 184, 69),   # green
    "WATER": (58, 123, 200),   # blue
    "RIVER": (90, 169, 200),   # light blue
    "BANK":  (196, 160, 107),  # tan
}
CENTER_COLORS = {
    "EMPTY": (189, 182, 168),
    "LAND":  (155, 200, 100),
    "LAKE":  (58, 123, 200),
    "RIVER": (90, 169, 200),
}
ARC_COLOR = (58, 123, 200)


def draw_tile(edge_kinds, center_kind):
    """edge_kinds: [N, E, S, W], center_kind: str"""
    img = Image.new("RGB", (S, S), (245, 240, 228))
    draw = ImageDraw.Draw(img)

    # 1) Background: center color
    bg = CENTER_COLORS[center_kind]
    draw.rectangle([0, 0, S, S], fill=bg)

    # 2) 4 corner wedges
    # NW = (-HALF, -HALF) in centered coords; PIL uses top-left origin so it's (0, 0)
    # Order: NW=N, NE=E, SE=S, SW=W
    corners = [
        (0, 0, 0, math.pi * 0.5, edge_kinds[0]),       # NW → N
        (S, 0, math.pi * 0.5, math.pi, edge_kinds[1]), # NE → E
        (S, S, math.pi, math.pi * 1.5, edge_kinds[2]), # SE → S
        (0, S, math.pi * 1.5, math.pi * 2.0, edge_kinds[3]), # SW → W
    ]
    for (cx, cy, a0, a1, kind) in corners:
        color = EDGE_COLORS[kind]
        poly = [(cx, cy)]
        for i in range(PTS + 1):
            t = i / PTS
            a = a0 + t * (a1 - a0)
            px = cx + math.cos(a) * ARC_R
            py = cy + math.sin(a) * ARC_R
            poly.append((px, py))
        draw.polygon(poly, fill=color)

    # 3) 4 blue arcs (PIL arc: bbox = [cx-ARC_R, cy-ARC_R, cx+ARC_R, cy+ARC_R])
    for (cx, cy, a0, a1, _) in corners:
        bbox = [cx - ARC_R, cy - ARC_R, cx + ARC_R, cy + ARC_R]
        draw.arc(bbox, math.degrees(a0), math.degrees(a1), fill=tuple(int(c*0.72) for c in color), width=ARC_WIDTH)

    # 4) IR dots
    # (skip for the preview — would need IR data)

    # 5) Text label
    label = f"{center_kind}·{','.join(edge_kinds)}"
    draw.text((10, HALF - 6), label, fill=(29, 26, 20))

    return img


# Build a 4x3 grid of representative tiles
tiles = [
    (["LAND", "LAND", "LAND", "LAND"], "LAND"),    # plain land
    (["LAND", "WATER", "LAND", "LAND"], "LAND"),   # water east
    (["LAND", "RIVER", "LAND", "WATER"], "RIVER"), # mixed water
    (["BANK", "BANK", "BANK", "BANK"], "LAKE"),    # lake center
    (["EMPTY", "EMPTY", "EMPTY", "EMPTY"], "EMPTY"),  # empty
    (["LAND", "LAND", "WATER", "WATER"], "LAKE"),  # water on 2 sides
    (["LAND", "LAND", "LAND", "WATER"], "LAND"),   # partial water
    (["RIVER", "LAND", "RIVER", "LAND"], "RIVER"), # river crossings
    (["BANK", "WATER", "BANK", "LAND"], "RIVER"),  # river bank
    (["LAND", "LAND", "LAND", "BANK"], "LAND"),
    (["LAND", "WATER", "LAND", "BANK"], "LAKE"),
    (["BANK", "WATER", "WATER", "BANK"], "RIVER"),
]

cols = 4
rows = math.ceil(len(tiles) / cols)
cell_w = S
cell_h = S
grid_w = cols * cell_w
grid_h = rows * cell_h
grid = Image.new("RGB", (grid_w, grid_h), (255, 255, 255))

for idx, (edges, center) in enumerate(tiles):
    r = idx // cols
    c = idx % cols
    tile_img = draw_tile(edges, center)
    grid.paste(tile_img, (c * cell_w, r * cell_h))

grid.save(OUT)
print(f"OK: {OUT} ({os.path.getsize(OUT)} bytes, {grid_w}x{grid_h})")