#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用 Pillow 模拟 Godot 的 4 弧线 + 5 段 tile_placeholder.gd 渲染（新设计）。

新设计：
- 4 条弧，每条弧对应正方形的一条边
- 弧的端点 = 该边的两个顶点
- 弧的圆心 = 该边外侧延长线（沿法线方向外侧 2×半边长），半径让圆过两顶点
- 弧 = 90° 短弧，在正方形内部凸向中心
- 4 条弧围出 5 段：4 个弓形（每弓形 = 弧线 + 边线）+ 1 个中心菱形
"""
from PIL import Image, ImageDraw
import math
import os

OUT = "docs/tile_placeholder_preview.png"
os.makedirs(os.path.dirname(OUT), exist_ok=True)

S = 240
HALF = S // 2
BOW = HALF * 0.5
ARC_K = HALF + (HALF * HALF - BOW * BOW) / (2.0 * BOW)
ARC_R = math.sqrt(HALF * HALF + (ARC_K - HALF) * (ARC_K - HALF))
ARC_SEGMENTS = 28
ARC_WIDTH = 4

# 配色（按 Godot 端定义）
EDGE_COLORS = {
    "EMPTY": (189, 182, 168),  # 灰空地
    "LAND":  (126, 184, 69),   # 绿地
    "WATER": (58, 123, 200),   # 蓝水
    "RIVER": (90, 169, 200),   # 浅蓝河
    "BANK":  (196, 160, 107),  # 沙岸
}
CENTER_COLORS = {
    "EMPTY": (189, 182, 168),
    "LAND":  (155, 200, 100),
    "LAKE":  (58, 123, 200),
    "RIVER": (90, 169, 200),
}


def arc_color_for(kind):
    """边色压暗 30%，作为弧线颜色。"""
    r, g, b = EDGE_COLORS[kind]
    return (int(r * 0.7), int(g * 0.7), int(b * 0.7))


def short_arc_points(p1, p2, arc_center, n=ARC_SEGMENTS):
    """从 p2 到 p1 沿 90° 短弧采样（向中心凸的方向）。"""
    dx1, dy1 = p1[0] - arc_center[0], p1[1] - arc_center[1]
    dx2, dy2 = p2[0] - arc_center[0], p2[1] - arc_center[1]
    a1 = math.atan2(dy1, dx1)
    a2 = math.atan2(dy2, dx2)
    diff = a1 - a2
    while diff > math.pi: diff -= 2 * math.pi
    while diff < -math.pi: diff += 2 * math.pi
    pts = []
    for i in range(n + 1):
        t = i / n
        a = a2 + diff * t
        pts.append((arc_center[0] + math.cos(a) * ARC_R,
                    arc_center[1] + math.sin(a) * ARC_R))
    return pts


def draw_tile(edge_kinds, center_kind):
    """edge_kinds: [N, E, S, W], center_kind: str"""
    img = Image.new("RGB", (S, S), (245, 240, 228))
    draw = ImageDraw.Draw(img)

    # PIL 使用左上角原点，center = (HALF, HALF)
    cx, cy = HALF, HALF

    # 顶点（顺时针 NW, NE, SE, SW）
    NW = (cx - HALF, cy - HALF)
    NE = (cx + HALF, cy - HALF)
    SE = (cx + HALF, cy + HALF)
    SW = (cx - HALF, cy + HALF)

    # 4 条弧的圆心（在该边外侧 2×半边长处）
    arc_centers = [
        (cx,        cy - ARC_K),  # N 弧
        (cx + ARC_K, cy),          # E 弧
        (cx,        cy + ARC_K),  # S 弧
        (cx - ARC_K, cy),          # W 弧
    ]
    # 每条弧对应的两个顶点（p1, p2）和边色
    arcs = [
        (NE, NW, edge_kinds[0], arc_centers[0]),  # N
        (SE, NE, edge_kinds[1], arc_centers[1]),  # E
        (SW, SE, edge_kinds[2], arc_centers[2]),  # S
        (NW, SW, edge_kinds[3], arc_centers[3]),  # W
    ]

    # 1) 整块底色 = 中心色（覆盖中心区 + 4 角，消除空白缝隙）
    draw.rectangle([0, 0, S, S], fill=CENTER_COLORS[center_kind])

    # 2) 4 个弓形（边区域）：poly = [p1, p2] + 弧采样点
    for (p1, p2, kind, ac) in arcs:
        arc_pts = short_arc_points(p1, p2, ac)
        poly = [p1, p2] + arc_pts[1:-1]   # 去掉端点（与 p1/p2 重合）
        poly.append(p1)  # 闭合
        draw.polygon(poly, fill=EDGE_COLORS[kind])

    # 3) 4 条弧线（边色压暗）
    for (p1, p2, kind, ac) in arcs:
        arc_pts = short_arc_points(p1, p2, ac)
        for i in range(len(arc_pts) - 1):
            draw.line([arc_pts[i], arc_pts[i + 1]],
                      fill=arc_color_for(kind), width=ARC_WIDTH)

    # 4) 文字标签
    label = f"{center_kind}·{','.join(edge_kinds)}"
    draw.text((8, HALF - 6), label, fill=(29, 26, 20))

    return img


# 12 个代表性地块
tiles = [
    (["LAND",  "LAND",  "LAND",  "LAND"],  "LAND"),    # 全地
    (["LAND",  "WATER", "LAND",  "LAND"],  "LAND"),    # 单边水
    (["LAND",  "RIVER", "LAND",  "WATER"], "RIVER"),   # 河混合
    (["BANK",  "BANK",  "BANK",  "BANK"],  "LAKE"),    # 中心湖
    (["EMPTY", "EMPTY", "EMPTY", "EMPTY"], "EMPTY"),   # 全空
    (["LAND",  "LAND",  "WATER", "WATER"], "LAKE"),    # 2 边水
    (["LAND",  "LAND",  "LAND",  "WATER"], "LAND"),    # 单边水
    (["RIVER", "LAND",  "RIVER", "LAND"],  "RIVER"),   # 河交叉
    (["BANK",  "WATER", "BANK",  "LAND"],  "RIVER"),   # 河岸
    (["LAND",  "LAND",  "LAND",  "BANK"],  "LAND"),
    (["LAND",  "WATER", "LAND",  "BANK"],  "LAKE"),
    (["BANK",  "WATER", "WATER", "BANK"],  "RIVER"),
]

cols = 4
rows = math.ceil(len(tiles) / cols)
grid_w = cols * S
grid_h = rows * S
grid = Image.new("RGB", (grid_w, grid_h), (255, 255, 255))

for idx, (edges, center) in enumerate(tiles):
    r = idx // cols
    c = idx % cols
    tile_img = draw_tile(edges, center)
    grid.paste(tile_img, (c * S, r * S))

grid.save(OUT)
print(f"OK: {OUT} ({os.path.getsize(OUT)} bytes, {grid_w}x{grid_h})")
