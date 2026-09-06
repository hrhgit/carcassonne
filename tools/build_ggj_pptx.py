"""生成青菱沃野 GGJ 答辩 PPT（≤3 页）。"""
import os
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR
from pptx.enum.shapes import MSO_SHAPE
from PIL import Image

# ---------- 调色板（来自游戏内 HUD：青葱田野） ----------
DEEP_GREEN = RGBColor(0x14, 0x3C, 0x2C)   # 深墨绿（背景）
MEADOW = RGBColor(0x7E, 0xCF, 0x91)       # 草绿（强调）
WATER = RGBColor(0x56, 0xA8, 0xC7)        # 水蓝
WARM = RGBColor(0xED, 0x9B, 0x70)         # 暖橙（玩家 2）
PARCH = RGBColor(0xFA, 0xF5, 0xE6)        # 暖白（卡片底）
INK = RGBColor(0x1B, 0x29, 0x22)          # 深墨（正文）
MUTED = RGBColor(0x6B, 0x7B, 0x71)        # 灰绿（次要文本）

PROJECT_ROOT = r"E:\_workSpace\_game\tablegame"
SCREENSHOT = os.path.join(PROJECT_ROOT, "artifacts", "tile_placement_preview_3d.png")
OUT_DIR = os.path.join(PROJECT_ROOT, "artifacts")
OUT_PPTX = os.path.join(OUT_DIR, "青菱沃野_GGJ答辩.pptx")

# 16:9 标准幻灯片
SLIDE_W = Inches(13.333)
SLIDE_H = Inches(7.5)

prs = Presentation()
prs.slide_width = SLIDE_W
prs.slide_height = SLIDE_H

BLANK = prs.slide_layouts[6]


def fill(shape, rgb):
    shape.fill.solid()
    shape.fill.fore_color.rgb = rgb
    shape.line.fill.background()


def add_text(slide, x, y, w, h, text, *, size=18, bold=False, color=INK,
             align=PP_ALIGN.LEFT, anchor=MSO_ANCHOR.TOP, font="Microsoft YaHei",
             line_spacing=1.2):
    tb = slide.shapes.add_textbox(x, y, w, h)
    tf = tb.text_frame
    tf.word_wrap = True
    tf.margin_left = Emu(0)
    tf.margin_right = Emu(0)
    tf.margin_top = Emu(0)
    tf.margin_bottom = Emu(0)
    tf.vertical_anchor = anchor
    lines = text.split("\n")
    for i, line in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.alignment = align
        p.line_spacing = line_spacing
        r = p.add_run()
        r.text = line
        f = r.font
        f.name = font
        f.size = Pt(size)
        f.bold = bold
        f.color.rgb = color
    return tb


def add_rect(slide, x, y, w, h, color):
    s = slide.shapes.add_shape(MSO_SHAPE.RECTANGLE, x, y, w, h)
    fill(s, color)
    return s


def add_round_rect(slide, x, y, w, h, color, line_color=None):
    s = slide.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, x, y, w, h)
    s.adjustments[0] = 0.08
    fill(s, color)
    if line_color is None:
        s.line.fill.background()
    else:
        s.line.color.rgb = line_color
        s.line.width = Pt(1.0)
    return s


def add_image_cover(slide, path, x, y, w, h):
    """保持比例，把图片完整塞入 (x,y,w,h)。"""
    img = Image.open(path)
    iw, ih = img.size
    box_w, box_h = w, h
    scale = min(box_w / iw, box_h / ih)
    new_w = int(iw * scale)
    new_h = int(ih * scale)
    cx = x + (box_w - new_w) // 2
    cy = y + (box_h - new_h) // 2
    return slide.shapes.add_picture(path, cx, cy, new_w, new_h)


# ============================================================
# 第 1 页 — 封面
# ============================================================
s1 = prs.slides.add_slide(BLANK)
# 全幅深墨绿背景
add_rect(s1, 0, 0, SLIDE_W, SLIDE_H, DEEP_GREEN)

# 左侧色块：游戏名大字 + 副标题 + 队名 + 成员
add_rect(s1, 0, 0, Inches(6.4), SLIDE_H, DEEP_GREEN)
# 装饰条（左侧）
add_rect(s1, Inches(0.7), Inches(1.0), Inches(0.12), Inches(5.5), MEADOW)
add_rect(s1, Inches(0.9), Inches(2.3), Inches(0.06), Inches(0.6), WATER)

# 游戏名（中文）
add_text(s1, Inches(1.0), Inches(1.0), Inches(5.4), Inches(1.5),
         "青菱沃野", size=72, bold=True, color=PARCH,
         font="Microsoft YaHei")
# 英文名
add_text(s1, Inches(1.0), Inches(2.05), Inches(5.4), Inches(0.6),
         "Qingling Meadow", size=22, color=MEADOW, font="Calibri")
# 一句话玩法
add_text(s1, Inches(1.0), Inches(2.85), Inches(5.4), Inches(1.4),
         "拼地块、种植物、养水网\n把一片湿地围垦成你的满园春色",
         size=20, color=PARCH, line_spacing=1.4)

# 队名
add_text(s1, Inches(1.0), Inches(4.6), Inches(5.4), Inches(0.45),
         "队名", size=14, color=WATER)
add_text(s1, Inches(1.0), Inches(4.95), Inches(5.4), Inches(0.6),
         "没起名", size=32, bold=True, color=MEADOW)

# 成员
add_text(s1, Inches(1.0), Inches(5.85), Inches(5.4), Inches(0.45),
         "团队成员", size=14, color=WATER)
add_text(s1, Inches(1.0), Inches(6.2), Inches(5.4), Inches(0.5),
         "白坚　·　路人甲", size=20, color=PARCH)

# 右侧：游戏截图（完整 16:9 + 留黑边）
add_image_cover(s1, SCREENSHOT,
                Inches(6.9), Inches(0.5),
                Inches(6.0), Inches(6.5))

# 右下角小字水印
add_text(s1, Inches(6.9), Inches(7.05), Inches(6.0), Inches(0.3),
         "实机截图 · 青菱沃野 / Qingling Meadow", size=10,
         color=MUTED, align=PP_ALIGN.RIGHT)

# ============================================================
# 第 2 页 — 核心玩法
# ============================================================
s2 = prs.slides.add_slide(BLANK)
add_rect(s2, 0, 0, SLIDE_W, SLIDE_H, PARCH)

# 顶栏
add_rect(s2, 0, 0, SLIDE_W, Inches(0.9), DEEP_GREEN)
add_rect(s2, Inches(0.6), Inches(0.18), Inches(0.1), Inches(0.55), MEADOW)
add_text(s2, Inches(0.85), Inches(0.15), Inches(8), Inches(0.6),
         "核心玩法 · Core Gameplay", size=26, bold=True, color=PARCH)
add_text(s2, Inches(0.85), Inches(0.55), Inches(8), Inches(0.4),
         "拼接 → 种植 → 自动扩张 → 供水结算 → 终局计分",
         size=13, color=MEADOW)

# 左侧：截图
add_round_rect(s2, Inches(0.6), Inches(1.25), Inches(7.3), Inches(5.95),
               DEEP_GREEN)
add_image_cover(s2, SCREENSHOT,
                Inches(0.75), Inches(1.4),
                Inches(7.0), Inches(5.65))

# 右侧：玩法要点
x0 = Inches(8.25)
y0 = Inches(1.25)
items = [
    ("1. 地块拼接",
     "方形地块以 90° 旋转落子；\n土地边 / 水口 / 空地边按类型匹配",
     MEADOW),
    ("2. 种植 & 扩张",
     "每回合在本回合新地块上种植\n一次；相邻土地连通时植物自动扩张",
     WATER),
    ("3. 驱逐机制",
     "同一片土地里：树 > 花 > 草；\n高级驱逐低级，同级共存",
     WARM),
    ("4. 供水结算",
     "灌溉接口 × 2 = 供水量；\n土地全封闭时按种植先后分水",
     RGBColor(0xC6, 0xB2, 0x6F)),
    ("5. 终局计分",
     "草 1 / 花 2 / 树 4；\n未封闭花树 × 0.5；同级竞争按株数裁决",
     RGBColor(0x9B, 0x6B, 0xC4)),
]

row_h = Inches(1.13)
for i, (title, body, dot) in enumerate(items):
    yy = y0 + row_h * i
    add_round_rect(s2, x0, yy, Inches(4.55), row_h - Inches(0.13),
                   RGBColor(0xFF, 0xFF, 0xFF), line_color=RGBColor(0xE3, 0xDC, 0xC9))
    # 圆点
    dot_s = s2.shapes.add_shape(MSO_SHAPE.OVAL,
                                 x0 + Inches(0.15),
                                 yy + Inches(0.18),
                                 Inches(0.18), Inches(0.18))
    fill(dot_s, dot)
    add_text(s2, x0 + Inches(0.5), yy + Inches(0.10),
             Inches(4.0), Inches(0.4),
             title, size=15, bold=True, color=DEEP_GREEN)
    add_text(s2, x0 + Inches(0.5), yy + Inches(0.5),
             Inches(4.0), Inches(0.55),
             body, size=11, color=MUTED, line_spacing=1.25)

# ============================================================
# 第 3 页 — 资料 / 链接页
# ============================================================
s3 = prs.slides.add_slide(BLANK)
add_rect(s3, 0, 0, SLIDE_W, SLIDE_H, PARCH)

# 顶栏
add_rect(s3, 0, 0, SLIDE_W, Inches(0.9), DEEP_GREEN)
add_rect(s3, Inches(0.6), Inches(0.18), Inches(0.1), Inches(0.55), MEADOW)
add_text(s3, Inches(0.85), Inches(0.15), Inches(8), Inches(0.6),
         "项目资料 & 链接", size=26, bold=True, color=PARCH)
add_text(s3, Inches(0.85), Inches(0.55), Inches(8), Inches(0.4),
         "GGJ 页面 · 试玩 · 视频 · 工程文档",
         size=13, color=MEADOW)

# 三张链接卡片
cards = [
    ("GGJ 项目页面", "Global Game Jam 上的项目主页\n含游戏介绍、玩法说明与团队信息",
     "🔗",
     RGBColor(0xFF, 0xB8, 0x6B)),
    ("试玩链接", "Web 试玩 / 可执行文件下载\n（依平台提供 build artifact）",
     "▶",
     RGBColor(0x56, 0xA8, 0xC7)),
    ("视频链接", "演示视频 / 实机游玩录像\n（依平台上传）",
     "🎬",
     RGBColor(0x9B, 0x6B, 0xC4)),
]

card_w = Inches(4.0)
card_h = Inches(2.4)
gap = Inches(0.25)
total = card_w * 3 + gap * 2
start_x = (SLIDE_W - total) // 2
cy = Inches(1.55)

for i, (title, body, icon, accent) in enumerate(cards):
    cx = start_x + (card_w + gap) * i
    add_round_rect(s3, cx, cy, card_w, card_h, RGBColor(0xFF, 0xFF, 0xFF),
                   line_color=RGBColor(0xE3, 0xDC, 0xC9))
    # 顶部色条
    add_rect(s3, cx, cy, card_w, Inches(0.12), accent)
    # 图标圆
    icon_s = s3.shapes.add_shape(MSO_SHAPE.OVAL,
                                  cx + Inches(0.3),
                                  cy + Inches(0.4),
                                  Inches(0.7), Inches(0.7))
    fill(icon_s, accent)
    add_text(s3, cx + Inches(0.3), cy + Inches(0.5),
             Inches(0.7), Inches(0.5),
             icon, size=24, color=RGBColor(0xFF, 0xFF, 0xFF),
             align=PP_ALIGN.CENTER)
    # 标题
    add_text(s3, cx + Inches(1.15), cy + Inches(0.45),
             card_w - Inches(1.3), Inches(0.6),
             title, size=18, bold=True, color=DEEP_GREEN)
    # 说明
    add_text(s3, cx + Inches(0.3), cy + Inches(1.25),
             card_w - Inches(0.6), Inches(0.7),
             body, size=12, color=MUTED, line_spacing=1.35)
    # 链接占位
    add_round_rect(s3, cx + Inches(0.3), cy + Inches(1.85),
                   card_w - Inches(0.6), Inches(0.4),
                   RGBColor(0xF4, 0xEF, 0xDF))
    add_text(s3, cx + Inches(0.4), cy + Inches(1.88),
             card_w - Inches(0.7), Inches(0.4),
             "链接：待补 / To be added",
             size=11, color=MUTED)

# 底部工程信息条
add_round_rect(s3, Inches(0.6), Inches(4.4),
               Inches(12.13), Inches(2.7),
               RGBColor(0xFF, 0xFF, 0xFF),
               line_color=RGBColor(0xE3, 0xDC, 0xC9))
add_rect(s3, Inches(0.6), Inches(4.4), Inches(0.14), Inches(2.7), MEADOW)
add_text(s3, Inches(0.95), Inches(4.55), Inches(11), Inches(0.5),
         "工程与文档", size=18, bold=True, color=DEEP_GREEN)

info = [
    ("游戏名",      "青菱沃野 / Qingling Meadow"),
    ("队名",        "没起名"),
    ("成员",        "白坚　·　路人甲"),
    ("技术栈",      "Godot 4.6.1 · GDScript · 3D 低多边形地块"),
    ("规则文档",    "docs/规则书.md（v0.2-draft-r17）"),
    ("玩家手册",    "docs/玩家手册.md"),
]
for i, (k, v) in enumerate(info):
    row = i // 2
    col = i % 2
    bx = Inches(1.05) + Inches(5.7) * col
    by = Inches(5.1) + Inches(0.65) * row
    add_text(s3, bx, by, Inches(1.5), Inches(0.4),
             k, size=12, color=MUTED)
    add_text(s3, bx + Inches(1.5), by, Inches(4.0), Inches(0.4),
             v, size=14, bold=True, color=INK)

# 右下：截图与文件位置
add_text(s3, Inches(7.4), Inches(6.5), Inches(5.0), Inches(0.4),
         "游戏截图：artifacts/gameplay_screenshot.png", size=10,
         color=MUTED, align=PP_ALIGN.RIGHT)
add_text(s3, Inches(7.4), Inches(6.75), Inches(5.0), Inches(0.4),
         "工程根目录：E:\\_workSpace\\_game\\tablegame", size=10,
         color=MUTED, align=PP_ALIGN.RIGHT)

# 保存
os.makedirs(OUT_DIR, exist_ok=True)
prs.save(OUT_PPTX)
print(f"Saved: {OUT_PPTX}")
print(f"Slides: {len(prs.slides)}")