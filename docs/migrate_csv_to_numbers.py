#!/usr/bin/env python
"""
把 data/tiles_classic.csv（旧：英文字段名）转成全数字编码版本。
保留：id (英文 slug), display_name (中文), notes (中文备注)。
其余：card_type, N/E/S/W, center, water_subnets, land_subnets 全部数字。

编码：
- card_type: 0=starter, 1=tile, 2=river
- edge:      0=EMPTY 1=LAND 2=WATER 3=RIVER 4=BANK
- center:    0=EMPTY 1=LAND 2=LAKE 3=RIVER
- subnet:    bitmask N=1 E=2 S=4 W=8; 多个子网用 ; 分隔
             例: NESW -> 15; "W;N" -> 8;1
"""

import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "data" / "tiles_classic.csv"

CARD_TYPE_MAP = {"starter": 0, "tile": 1, "river": 2}
EDGE_MAP = {"EMPTY": 0, "LAND": 1, "WATER": 2, "RIVER": 3, "BANK": 4}
CENTER_MAP = {"EMPTY": 0, "LAND": 1, "LAKE": 2, "RIVER": 3}
LETTER_BIT = {"N": 1, "E": 2, "S": 4, "W": 8}


def encode_subnet(raw: str) -> str:
    """把 'NESW' / 'W;N' 这种字母串转成 '15' / '8;1'。空 -> ''。"""
    raw = (raw or "").strip()
    if not raw:
        return ""
    out_groups = []
    for group in raw.split(";"):
        group = group.strip()
        if not group:
            continue
        mask = 0
        for ch in group.upper():
            mask |= LETTER_BIT[ch]
        if mask:
            out_groups.append(str(mask))
    return ";".join(out_groups)


def main() -> int:
    if not SRC.exists():
        print(f"missing: {SRC}", file=sys.stderr)
        return 1

    with SRC.open("r", encoding="utf-8", newline="") as f:
        rows = list(csv.reader(f))

    if not rows:
        print("empty csv", file=sys.stderr)
        return 1

    # 找到 header 行（首行非 # 起算就是 header）
    header_idx = 0
    while header_idx < len(rows) and rows[header_idx][0].startswith("#"):
        header_idx += 1
    if header_idx >= len(rows):
        print("no header", file=sys.stderr)
        return 1
    header = rows[header_idx]
    body = [r for r in rows[header_idx + 1 :] if r and any(c.strip() for c in r)]

    col = {name: i for i, name in enumerate(header)}
    need = ["id", "display_name", "card_type", "count", "N", "E", "S", "W",
            "N_ir", "E_ir", "S_ir", "W_ir", "center", "is_river_tile",
            "water_subnets", "land_subnets", "prefab_scene", "prefab_rotation",
            "visual_seed", "initial_growth", "notes"]
    missing = [k for k in need if k not in col]
    if missing:
        print(f"missing columns: {missing}", file=sys.stderr)
        return 2

    out_lines = []
    out_lines.append("# 数字编码 - 一目了然，只填数字")
    out_lines.append("# card_type: 0=starter, 1=tile, 2=river")
    out_lines.append("# edge (N/E/S/W): 0=EMPTY 1=LAND 2=WATER 3=RIVER 4=BANK")
    out_lines.append("# center: 0=EMPTY 1=LAND 2=LAKE 3=RIVER")
    out_lines.append("# water_subnets / land_subnets: bitmask N=1 E=2 S=4 W=8; 多子网用 ; 分隔")
    out_lines.append("# 例: 单子网 NESW 写 15; 多子网 W+N 写 8;1")
    out_lines.append(",".join(header))

    for r in body:
        # 跳过比 header 短的行（保留防御）
        if len(r) < len(header):
            continue
        ct = CARD_TYPE_MAP.get(r[col["card_type"]].strip(), 1)
        n = EDGE_MAP.get(r[col["N"]].strip(), 0)
        e = EDGE_MAP.get(r[col["E"]].strip(), 0)
        s = EDGE_MAP.get(r[col["S"]].strip(), 0)
        w = EDGE_MAP.get(r[col["W"]].strip(), 0)
        ctr = CENTER_MAP.get(r[col["center"]].strip(), 0)
        ws = encode_subnet(r[col["water_subnets"]])
        ls = encode_subnet(r[col["land_subnets"]])

        new = list(r)
        new[col["card_type"]] = str(ct)
        new[col["N"]] = str(n)
        new[col["E"]] = str(e)
        new[col["S"]] = str(s)
        new[col["W"]] = str(w)
        new[col["center"]] = str(ctr)
        new[col["water_subnets"]] = ws
        new[col["land_subnets"]] = ls
        # 修剪尾随空字段里残留的逗号
        out_lines.append(",".join(new))

    # 写回原文件
    with SRC.open("w", encoding="utf-8", newline="") as f:
        f.write("\n".join(out_lines) + "\n")
    print(f"OK: wrote {SRC.name} ({len(body)} rows)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
