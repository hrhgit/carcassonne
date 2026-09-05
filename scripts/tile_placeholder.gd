class_name TilePlaceholder
extends Node2D

# 极简占位渲染：每个正方形用 4 条弧线分成 5 段
# —— 4 条角弧线（每角 1/4 圆，r = s * 0.45）把方块切成：
#     4 个角落小区域 + 1 个中心区域
# —— 每个角落区域按对应边着色（NW=N、NE=E、SE=S、SW=W）
# —— 中心区域按 center_kind 着色
# —— 4 条弧线本身就是蓝线（水路基础设施视觉符号）

const DESIGN_HALF := 120.0
const ARC_RADIUS := DESIGN_HALF * 0.45    # 角弧半径
const ARC_POINTS := 28                     # 弧线采样点数
const POLY_POINTS := 18                    # 角落多边形采样数
const ARC_COLOR := Color("#3a7bc8")        # 蓝线（水路）
const ARC_WIDTH := 3.0
const IR_COLOR := Color("#f5d54a")         # IR 灌溉修饰
const BORDER_COLOR := Color("#3d362c")     # 文字描边
const TEXT_COLOR := Color("#1d1a14")

# 中心地形配色：绿/灰/蓝
const CENTER_COLORS := {
	TileDefinition.CenterKind.EMPTY: Color("#bdb6a8"),
	TileDefinition.CenterKind.LAND:  Color("#9bc864"),
	TileDefinition.CenterKind.LAKE:  Color("#3a7bc8"),
	TileDefinition.CenterKind.RIVER: Color("#5aa9c8"),
}

# 边基础地形配色
const EDGE_COLORS := {
	TileDefinition.EdgeKind.EMPTY: Color("#bdb6a8"),   # 灰空地
	TileDefinition.EdgeKind.LAND:  Color("#7eb845"),   # 绿地
	TileDefinition.EdgeKind.WATER: Color("#3a7bc8"),   # 蓝水
	TileDefinition.EdgeKind.RIVER: Color("#5aa9c8"),   # 浅蓝河
	TileDefinition.EdgeKind.BANK:  Color("#c4a06b"),   # 沙岸
}

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
	var r := ARC_RADIUS
	var pts := ARC_POINTS
	var center_color := CENTER_COLORS.get(definition.center_kind, Color("#bdb6a8"))

	# 1) 整块底色：先铺中心色（后面 4 个角落会叠在角上）
	draw_rect(Rect2(-s, -s, s * 2.0, s * 2.0), center_color)

	# 2) 4 个角落区域：每个对应一个边的颜色
	#    NW = N 边 · NE = E 边 · SE = S 边 · SW = W 边
	var edge_kinds := []
	for world_edge in range(4):
		edge_kinds.append(definition.edge_kind_at(world_edge, quarter_turns))

	_draw_corner_wedge(Vector2(-s, -s), 0.0,        PI * 0.5, EDGE_COLORS.get(edge_kinds[0], Color("#bdb6a8")))
	_draw_corner_wedge(Vector2( s, -s), PI * 0.5,  PI,        EDGE_COLORS.get(edge_kinds[1], Color("#bdb6a8")))
	_draw_corner_wedge(Vector2( s,  s), PI,        PI * 1.5,  EDGE_COLORS.get(edge_kinds[2], Color("#bdb6a8")))
	_draw_corner_wedge(Vector2(-s,  s), PI * 1.5,  PI * 2.0,  EDGE_COLORS.get(edge_kinds[3], Color("#bdb6a8")))

	# 3) 4 条蓝弧（水路视觉符号）
	draw_arc(Vector2(-s, -s), r, 0.0,       PI * 0.5, pts, ARC_COLOR, ARC_WIDTH, true)
	draw_arc(Vector2( s, -s), r, PI * 0.5, PI,       pts, ARC_COLOR, ARC_WIDTH, true)
	draw_arc(Vector2( s,  s), r, PI,       PI * 1.5, pts, ARC_COLOR, ARC_WIDTH, true)
	draw_arc(Vector2(-s,  s), r, PI * 1.5, PI * 2.0, pts, ARC_COLOR, ARC_WIDTH, true)

	# 4) IR 灌溉修饰：在对应边外侧点一个小亮黄点（指示有 IR）
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

	# 5) 中心文字：地块名
	var font := ThemeDB.fallback_font
	if font != null:
		var label := definition.display_name
		var font_size := 13
		var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		# 描边（4 个方向各画一次）
		for dx in [-1, 1]:
			for dy in [-1, 1]:
				draw_string(font, Vector2(-text_size.x * 0.5 + dx, 4.0 + dy), label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color(1, 1, 1, 0.7))
		draw_string(font, Vector2(-text_size.x * 0.5, 4.0), label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, TEXT_COLOR)

	# 6) 河流地块标记（角点红方块）
	if definition.is_river_tile:
		var sq := 14.0
		draw_rect(Rect2(-s + 4.0, -s + 4.0, sq, sq), Color("#c43030"))
		draw_rect(Rect2( s - 4.0 - sq, -s + 4.0, sq, sq), Color("#c43030"))
		draw_rect(Rect2(-s + 4.0,  s - 4.0 - sq, sq, sq), Color("#c43030"))
		draw_rect(Rect2( s - 4.0 - sq,  s - 4.0 - sq, sq, sq), Color("#c43030"))


# 角落楔形：从 corner_pos 出发，沿一段圆弧回到 corner_pos 旁的两条边
func _draw_corner_wedge(corner_pos: Vector2, start_angle: float, end_angle: float, color: Color) -> void:
	var r := ARC_RADIUS
	var pts := POLY_POINTS
	var poly := PackedVector2Array()
	poly.append(corner_pos)
	for i in range(pts + 1):
		var t := float(i) / float(pts)
		var angle := start_angle + t * (end_angle - start_angle)
		poly.append(corner_pos + Vector2(cos(angle), sin(angle)) * r)
	draw_colored_polygon(poly, color)