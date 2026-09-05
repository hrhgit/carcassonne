class_name TilePlaceholder
extends Node2D

# 占位渲染：当 tile 在 CSV 中没指定 prefab_scene 时使用
# 在 240x240 设计空间内绘制：背景 + 4 条边色带 + 中心填色 + 文字标签

const OUTER_RECT := Rect2(-120.0, -120.0, 240.0, 240.0)
const EDGE_BAND := 36.0  # 边色带宽度
const CENTER_RECT := Rect2(-84.0, -84.0, 168.0, 168.0)

# 中心地形配色
const CENTER_COLORS := {
	TileDefinition.CenterKind.EMPTY: Color("#a8a39a"),
	TileDefinition.CenterKind.LAND:  Color("#9bc864"),
	TileDefinition.CenterKind.LAKE:  Color("#3a7bc8"),
	TileDefinition.CenterKind.RIVER: Color("#5aa9c8"),
}

# 边基础地形配色
const EDGE_COLORS := {
	TileDefinition.EdgeKind.EMPTY: Color("#7d7770"),
	TileDefinition.EdgeKind.LAND:  Color("#7eb845"),
	TileDefinition.EdgeKind.WATER: Color("#3a7bc8"),
	TileDefinition.EdgeKind.RIVER: Color("#2a6c8c"),
	TileDefinition.EdgeKind.BANK:  Color("#c4a06b"),
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

	# 背景：深色木框
	draw_rect(OUTER_RECT, Color("#5a3618"))
	draw_rect(OUTER_RECT.grow(-4.0), Color("#e2ad6a"))

	# 中心地形填色
	var center_color: Color = CENTER_COLORS.get(definition.center_kind, Color("#a8a39a"))
	draw_rect(CENTER_RECT, center_color)

	# 4 条边色带（根据定义旋转后取边）
	var half := 120.0
	var inner_half := 84.0
	for world_edge in range(4):
		var kind := definition.edge_kind_at(world_edge, quarter_turns)
		var color: Color = EDGE_COLORS.get(kind, Color("#7d7770"))
		var ir := definition.ir_at(world_edge, quarter_turns)

		match world_edge:
			TileDefinition.Edge.NORTH:
				draw_rect(Rect2(-inner_half, -half, EDGE_BAND * 2, half - inner_half), color)
			TileDefinition.Edge.EAST:
				draw_rect(Rect2(inner_half, -inner_half, half - inner_half, EDGE_BAND * 2), color)
			TileDefinition.Edge.SOUTH:
				draw_rect(Rect2(-inner_half, inner_half, EDGE_BAND * 2, half - inner_half), color)
			TileDefinition.Edge.WEST:
				draw_rect(Rect2(-half, -inner_half, half - inner_half, EDGE_BAND * 2), color)

		# IR 修饰：在对应边色带外侧加一道亮黄高亮
		if ir:
			match world_edge:
				TileDefinition.Edge.NORTH:
					draw_rect(Rect2(-inner_half - 4.0, -half, EDGE_BAND * 2 + 8.0, 6.0), Color("#f5d54a"))
				TileDefinition.Edge.EAST:
					draw_rect(Rect2(half - 6.0, -inner_half - 4.0, 6.0, EDGE_BAND * 2 + 8.0), Color("#f5d54a"))
				TileDefinition.Edge.SOUTH:
					draw_rect(Rect2(-inner_half - 4.0, half - 6.0, EDGE_BAND * 2 + 8.0, 6.0), Color("#f5d54a"))
				TileDefinition.Edge.WEST:
					draw_rect(Rect2(-half, -inner_half - 4.0, 6.0, EDGE_BAND * 2 + 8.0), Color("#f5d54a"))

	# 文字标签：地块名
	var font := ThemeDB.fallback_font
	if font != null:
		var label := definition.display_name
		var font_size := 18
		var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		draw_string(font, Vector2(-text_size.x * 0.5, 4.0), label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color("#1d1a14"))
		# 第二行：ID 摘要
		var sub := "%s [%s]" % [definition.id, definition.card_type]
		var sub_size := font.get_string_size(sub, HORIZONTAL_ALIGNMENT_CENTER, -1, 12)
		draw_string(font, Vector2(-sub_size.x * 0.5, 24.0), sub, HORIZONTAL_ALIGNMENT_CENTER, -1, 12, Color("#3d362c"))

	# 河流地块标记
	if definition.is_river_tile:
		draw_rect(Rect2(-112.0, -112.0, 16.0, 16.0), Color("#c43030"))
		draw_rect(Rect2(96.0, -112.0, 16.0, 16.0), Color("#c43030"))
		draw_rect(Rect2(-112.0, 96.0, 16.0, 16.0), Color("#c43030"))
		draw_rect(Rect2(96.0, 96.0, 16.0, 16.0), Color("#c43030"))