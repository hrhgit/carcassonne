class_name TilePlaceholder
extends Node2D

# 极简占位渲染：4 条弧围出 5 段
# —— 4 条弧，每条弧对应正方形的一条边
#    弧的端点 = 该边的两个顶点（起点、终点都是顶点）
#    弧的圆心 = 在该边的法线方向外侧，半径让圆正好过两顶点
#    弧 = 圆的一段 90° 短弧，在正方形内部凸向中心
# —— 5 段：
#    · 4 个弓形（每弓形 = 弧线 + 边线围成），对应正方形的 4 条边
#    · 1 个中心菱形（4 条弧最靠近中心的 4 点围出，旋转 45°）
# —— 配色：
#    · 弓形按对应边地形着色（绿=地 / 灰=空 / 蓝=水 / 沙=岸）
#    · 中心菱形按 center_kind 着色
#    · 4 条弧线 = 边色压暗，作为分段边界

const DESIGN_HALF := 120.0
const BOW := DESIGN_HALF * 0.5                          # 弧顶（弓深）到对应边的距离 = 半边长的一半
# 圆心 = 该边外侧延长线上，圆心到正方形中心的距离 ARC_K，半径 ARC_R 让圆恰好过该边两个顶点
# 推导：设圆心 (0, -ARC_K)，顶点 (±HALF, -HALF)，弧顶 y = -ARC_K + ARC_R = -HALF + BOW
#   → ARC_K = HALF + (HALF² - BOW²) / (2·BOW) ；ARC_R = √(HALF² + (ARC_K-HALF)²)
const ARC_K := DESIGN_HALF + (DESIGN_HALF * DESIGN_HALF - BOW * BOW) / (2.0 * BOW)
const ARC_R := sqrt(DESIGN_HALF * DESIGN_HALF + (ARC_K - DESIGN_HALF) * (ARC_K - DESIGN_HALF))
const ARC_SEGMENTS := 28
const ARC_WIDTH := 3.5

const BORDER_COLOR := Color("#3d362c")                     # 文字描边
const TEXT_COLOR := Color("#1d1a14")
const IR_COLOR := Color("#f5d54a")                         # IR 灌溉修饰

# 中心地形配色
const CENTER_COLORS := {
	TileDefinition.CenterKind.EMPTY: Color("#bdb6a8"),
	TileDefinition.CenterKind.LAND:  Color("#9bc864"),
	TileDefinition.CenterKind.LAKE:  Color("#3a7bc8"),
	TileDefinition.CenterKind.RIVER: Color("#5aa9c8"),
}

# 边基础地形配色
const EDGE_COLORS := {
	TileDefinition.EdgeKind.EMPTY: Color("#bdb6a8"),
	TileDefinition.EdgeKind.LAND:  Color("#7eb845"),
	TileDefinition.EdgeKind.WATER: Color("#3a7bc8"),
	TileDefinition.EdgeKind.RIVER: Color("#5aa9c8"),
	TileDefinition.EdgeKind.BANK:  Color("#c4a06b"),
}


func _arc_color_for(kind: int) -> Color:
	var c: Color = EDGE_COLORS.get(kind, Color("#bdb6a8"))
	return c.darkened(0.30)


var definition: TileDefinition
var quarter_turns := 0


func set_definition(def: TileDefinition, q := 0) -> void:
	definition = def
	quarter_turns = q
	queue_redraw()


func _draw() -> void:
	if definition == null:
		return

	var s := DESIGN_HALF
	var center_color: Color = CENTER_COLORS.get(definition.center_kind, Color("#bdb6a8"))

	var edge_kinds := []
	for world_edge in range(4):
		edge_kinds.append(definition.edge_kind_at(world_edge, quarter_turns))

	# 1) 整块底色 = 中心色（覆盖中心区 + 4 角，避免缝隙）
	draw_rect(Rect2(-s, -s, s * 2.0, s * 2.0), center_color)

	# 2) 4 个弓形（边区域）
	#    每弓形 = 边的两个顶点 + 该边的弧（90° 短弧，向中心凸）
	#    4 条边的圆心分别在该边外侧：(0,-ARC_K)/(ARC_K,0)/(0,ARC_K)/(-ARC_K,0)
	_fill_edge_wedge(Vector2(-s, -s), Vector2( s, -s), Vector2(0,    -ARC_K), EDGE_COLORS.get(edge_kinds[0], Color("#bdb6a8")))
	_fill_edge_wedge(Vector2( s, -s), Vector2( s,  s), Vector2( ARC_K, 0),    EDGE_COLORS.get(edge_kinds[1], Color("#bdb6a8")))
	_fill_edge_wedge(Vector2( s,  s), Vector2(-s,  s), Vector2(0,     ARC_K), EDGE_COLORS.get(edge_kinds[2], Color("#bdb6a8")))
	_fill_edge_wedge(Vector2(-s,  s), Vector2(-s, -s), Vector2(-ARC_K, 0),    EDGE_COLORS.get(edge_kinds[3], Color("#bdb6a8")))

	# 3) 4 条弧线（分段边界）
	_stroke_edge_arc(Vector2( s, -s), Vector2(-s, -s), Vector2(0,    -ARC_K), _arc_color_for(edge_kinds[0]))
	_stroke_edge_arc(Vector2( s,  s), Vector2( s, -s), Vector2( ARC_K, 0),    _arc_color_for(edge_kinds[1]))
	_stroke_edge_arc(Vector2(-s,  s), Vector2( s,  s), Vector2(0,     ARC_K), _arc_color_for(edge_kinds[2]))
	_stroke_edge_arc(Vector2(-s, -s), Vector2(-s,  s), Vector2(-ARC_K, 0),    _arc_color_for(edge_kinds[3]))

	# 4) IR 灌溉修饰：在对应边外侧点一个小亮黄点
	for world_edge in range(4):
		if not definition.ir_at(world_edge, quarter_turns):
			continue
		var dot_pos := Vector2.ZERO
		match world_edge:
			TileDefinition.Edge.NORTH: dot_pos = Vector2(0, -s + 6.0)
			TileDefinition.Edge.EAST:  dot_pos = Vector2(s - 6.0, 0)
			TileDefinition.Edge.SOUTH: dot_pos = Vector2(0, s - 6.0)
			TileDefinition.Edge.WEST:  dot_pos = Vector2(-s + 6.0, 0)
		draw_circle(dot_pos, 5.0, IR_COLOR)
		draw_arc(dot_pos, 5.0, 0, TAU, 12, BORDER_COLOR, 1.0, true)

	# 5) 河流地块标记（4 角红方块）
	if definition.is_river_tile:
		var sq := 14.0
		draw_rect(Rect2(-s + 4.0, -s + 4.0, sq, sq), Color("#c43030"))
		draw_rect(Rect2( s - 4.0 - sq, -s + 4.0, sq, sq), Color("#c43030"))
		draw_rect(Rect2(-s + 4.0,  s - 4.0 - sq, sq, sq), Color("#c43030"))
		draw_rect(Rect2( s - 4.0 - sq,  s - 4.0 - sq, sq, sq), Color("#c43030"))

	# 6) 中心文字
	var font := ThemeDB.fallback_font
	if font != null:
		var label := definition.display_name
		var font_size := 13
		var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		for dx in [-1, 1]:
			for dy in [-1, 1]:
				draw_string(font, Vector2(-text_size.x * 0.5 + dx, 4.0 + dy), label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color(1, 1, 1, 0.7))
		draw_string(font, Vector2(-text_size.x * 0.5, 4.0), label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, TEXT_COLOR)


# 填充一个"边弓形"：poly = [边的两个顶点] + [弧线采样点]
# 弧线从 p2 沿 90° 短弧走到 p1（在正方形内部凸向中心）
func _fill_edge_wedge(p1: Vector2, p2: Vector2, arc_center: Vector2, color: Color) -> void:
	var pts := ARC_SEGMENTS
	var poly := PackedVector2Array()
	poly.append(p1)
	poly.append(p2)
	var angle_p1 := (p1 - arc_center).angle()
	var angle_p2 := (p2 - arc_center).angle()
	# 从 angle_p2 走到 angle_p1 的方向（取短弧）
	var diff := angle_p1 - angle_p2
	while diff > PI: diff -= TAU
	while diff < -PI: diff += TAU
	for i in range(1, pts):
		var t := float(i) / float(pts)
		var a := angle_p2 + diff * t
		poly.append(arc_center + Vector2(cos(a), sin(a)) * ARC_R)
	draw_colored_polygon(poly, color)


# 沿 90° 短弧画线段（从 p2 到 p1 的弧）
func _stroke_edge_arc(p1: Vector2, p2: Vector2, arc_center: Vector2, color: Color) -> void:
	var pts := ARC_SEGMENTS
	var angle_p1 := (p1 - arc_center).angle()
	var angle_p2 := (p2 - arc_center).angle()
	var diff := angle_p1 - angle_p2
	while diff > PI: diff -= TAU
	while diff < -PI: diff += TAU
	var prev_a := angle_p2
	for i in range(1, pts + 1):
		var t := float(i) / float(pts)
		var a := angle_p2 + diff * t
		var prev_pt := arc_center + Vector2(cos(prev_a), sin(prev_a)) * ARC_R
		var cur_pt := arc_center + Vector2(cos(a), sin(a)) * ARC_R
		draw_line(prev_pt, cur_pt, color, ARC_WIDTH)
		prev_a = a
