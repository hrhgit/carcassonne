class_name TileDefinition
extends Resource

enum Edge {
	NORTH,
	EAST,
	SOUTH,
	WEST,
}

# 5 种边基础地形
enum EdgeKind {
	EMPTY,   # 空地
	LAND,    # 土地
	WATER,   # 水口
	RIVER,   # 河流（仅河流地块持有）
	BANK,    # 河岸（仅河流地块持有）
}

# 4 种中心地形
enum CenterKind {
	EMPTY,
	LAND,
	LAKE,
	RIVER,
}

const EDGE_KIND_NAMES := ["EMPTY", "LAND", "WATER", "RIVER", "BANK"]
const CENTER_KIND_NAMES := ["EMPTY", "LAND", "LAKE", "RIVER"]

var id: StringName
var display_name := ""
var card_type := "tile"          # starter / tile / river
var count := 1
var edges := PackedInt32Array([EdgeKind.EMPTY, EdgeKind.EMPTY, EdgeKind.EMPTY, EdgeKind.EMPTY])
var ir_edges := PackedInt32Array([0, 0, 0, 0])  # 4 边各自的 IRRIGATION 修饰
var center_kind: int = CenterKind.EMPTY
var is_river_tile := false
# Kept for compatibility with the old visual-study nodes. The playable board
# deliberately never enables growth or planting in this milestone.
var starts_grown := false
var visual_seed := 0
var irrigated_land_edges := PackedInt32Array()
var visual_scene: PackedScene
var visual_rotation_quarters := 0
var notes := ""


func configure(
	new_id: StringName,
	new_display_name: String,
	new_card_type: String,
	new_count: int,
	new_edges: PackedInt32Array,
	new_ir_edges: PackedInt32Array,
	new_center: int,
	new_is_river_tile: bool,
	new_starts_grown: bool,
	new_visual_seed: int,
	new_irrigated_land_edges := PackedInt32Array(),
	new_visual_scene: PackedScene = null,
	new_visual_rotation_quarters := 0,
	new_notes: String = "",
) -> void:
	if new_edges.size() != 4:
		push_error("A tile definition must have exactly four edge values.")
		return
	for edge_kind in new_edges:
		if edge_kind < EdgeKind.EMPTY or edge_kind > EdgeKind.BANK:
			push_error("Tile definitions can only use EMPTY, LAND, WATER, RIVER, or BANK edge markers.")
			return
	if new_ir_edges.size() != 4:
		push_error("IRRIGATION flags must have exactly four entries.")
		return
	if new_center < CenterKind.EMPTY or new_center > CenterKind.RIVER:
		push_error("Center kind must be one of EMPTY / LAND / LAKE / RIVER.")
		return
	# IR 只能修饰 LAND / WATER
	for i in range(4):
		if new_ir_edges[i] == 1 and new_edges[i] != EdgeKind.LAND and new_edges[i] != EdgeKind.WATER:
			push_error("IRRIGATION can only mark LAND or WATER edges, got %s on edge %d." % [EDGE_KIND_NAMES[new_edges[i]], i])
			return
	id = new_id
	display_name = new_display_name
	card_type = new_card_type
	count = max(1, new_count)
	edges = new_edges.duplicate()
	ir_edges = new_ir_edges.duplicate()
	center_kind = new_center
	is_river_tile = new_is_river_tile
	starts_grown = new_starts_grown
	visual_seed = new_visual_seed
	irrigated_land_edges = new_irrigated_land_edges.duplicate()
	visual_scene = new_visual_scene
	visual_rotation_quarters = int(posmod(new_visual_rotation_quarters, 4))
	notes = new_notes
	if irrigated_land_edges.is_empty() and not edge_indices(EdgeKind.WATER).is_empty():
		# In this first placement-only slice every water route branches into each
		# land region. Storing the targets makes the invariant explicit in data.
		irrigated_land_edges = edge_indices(EdgeKind.LAND)
	if not has_valid_irrigation():
		push_error("Every water edge must route to at least one land edge on the same tile.")
	if is_river_tile and not validate_river_tile_invariant():
		push_error("River tile %s violates the RIVER/BANK-only invariant." % new_id)


func edge_indices(kind: int, quarter_turns := 0) -> PackedInt32Array:
	var indices := PackedInt32Array()
	for edge in range(4):
		if edge_kind_at(edge, quarter_turns) == kind:
			indices.append(edge)
	return indices


func land_edge_count() -> int:
	return edge_indices(EdgeKind.LAND).size()


func edge_kind_at(world_edge: int, quarter_turns := 0) -> int:
	if edges.size() != 4:
		return EdgeKind.EMPTY
	# A clockwise quarter turn moves the original north edge to the east, so a
	# world-space lookup reads the source edge in the opposite direction.
	var source_edge := int(posmod(world_edge - quarter_turns, 4))
	return edges[source_edge]


func ir_at(world_edge: int, quarter_turns := 0) -> bool:
	if ir_edges.size() != 4:
		return false
	var source_edge := int(posmod(world_edge - quarter_turns, 4))
	return ir_edges[source_edge] == 1


func has_valid_irrigation() -> bool:
	var water_edges := edge_indices(EdgeKind.WATER)
	if water_edges.is_empty():
		return true
	if irrigated_land_edges.is_empty():
		return false
	for land_edge in irrigated_land_edges:
		if land_edge < Edge.NORTH or land_edge > Edge.WEST:
			return false
		if edges[land_edge] != EdgeKind.LAND:
			return false
	return true


# 仅当数据完整且符合基本约束时视为可玩；visual_scene 可空（无美术走占位渲染）
func is_playable() -> bool:
	if edges.size() != 4:
		return false
	if not has_valid_irrigation():
		return false
	if is_river_tile and not validate_river_tile_invariant():
		return false
	return true


# 河流地块约束：每条边 RIVER 或 BANK，至少一条 RIVER，且不能有 IR 修饰
func validate_river_tile_invariant() -> bool:
	if not is_river_tile:
		return true
	for e in range(4):
		if edges[e] != EdgeKind.RIVER and edges[e] != EdgeKind.BANK:
			return false
	if edge_indices(EdgeKind.RIVER).is_empty():
		return false
	for i in range(4):
		if ir_edges[i] == 1:
			return false
	return true


static func edge_kind_label(kind: int) -> String:
	match kind:
		EdgeKind.LAND:
			return "土地"
		EdgeKind.WATER:
			return "水口"
		EdgeKind.RIVER:
			return "河流"
		EdgeKind.BANK:
			return "河岸"
		_:
			return "空地"


static func center_kind_label(kind: int) -> String:
	match kind:
		CenterKind.LAND:
			return "中心土地"
		CenterKind.LAKE:
			return "湖泊"
		CenterKind.RIVER:
			return "中心河流"
		_:
			return "空地中心"