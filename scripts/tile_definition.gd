class_name TileDefinition
extends Resource

enum Edge {
	NORTH,
	EAST,
	SOUTH,
	WEST,
}

# 4 种边基础地形
enum EdgeKind {
	EMPTY,   # 空地
	LAND,    # 土地
	WATER,   # 水口
	RIVER,   # 河流（仅河流地块持有）
}

# 3 种中心地形
enum CenterKind {
	EMPTY,
	LAND,
	RIVER,
}

# card_type 数值编码（CSV 用纯数字，避免英文 slug）
const CARD_STARTER := 0
const CARD_TILE := 1
const CARD_RIVER := 2

const EDGE_KIND_NAMES := ["EMPTY", "LAND", "WATER", "RIVER"]
const CENTER_KIND_NAMES := ["EMPTY", "LAND", "RIVER"]
const EDGE_LETTERS := ["N", "E", "S", "W"]

var id: StringName
var display_name := ""
var card_type: int = CARD_TILE   # 0=starter 1=tile 2=river
var count := 1
var edges := PackedInt32Array([EdgeKind.EMPTY, EdgeKind.EMPTY, EdgeKind.EMPTY, EdgeKind.EMPTY])
var ir_edges := PackedInt32Array([0, 0, 0, 0])  # 4 边各自的 IRRIGATION 修饰
var center_kind: int = CenterKind.EMPTY
var is_river_tile := false
# 河流开局牌堆的固定河尾。河头仍由 CARD_STARTER 的 starter_river 直接放上棋盘。
var river_setup_terminal := false

# 内部连通性（规则引擎 §3.3 依赖）：同一地块内哪些水边属于同一水网，
# 哪些陆边属于同一土地块（土地块）。
# - land_subnets: 数组，每个元素是一个包含若干边索引(0..3 用位掩码)的分组，
#   组内所有陆边在块内相互连通；LAND 中心自动并入所有 land 子网。
# - water_subnets: 数组，每个元素是同一水网的水边位掩码；水网只由 WATER 边连通构成。
var land_subnets: Array = []   # 元素为 int 位掩码（bit0=N bit1=E bit2=S bit3=W）
var water_subnets: Array = []  # 元素为 int 位掩码
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
	new_card_type: int,
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
	new_water_subnets: Array = [],
	new_land_subnets: Array = [],
	new_river_setup_terminal := false,
) -> void:
	if new_edges.size() != 4:
		push_error("A tile definition must have exactly four edge values.")
		return
	for edge_kind in new_edges:
		if edge_kind < EdgeKind.EMPTY or edge_kind > EdgeKind.RIVER:
			push_error("Tile definitions can only use EMPTY, LAND, WATER, or RIVER edge markers.")
			return
	if new_ir_edges.size() != 4:
		push_error("IRRIGATION flags must have exactly four entries.")
		return
	if new_center < CenterKind.EMPTY or new_center > CenterKind.RIVER:
		push_error("Center kind must be one of EMPTY / LAND / RIVER.")
		return
	# IR 只能修饰 LAND / WATER
	for i in range(4):
		if new_ir_edges[i] == 1 and new_edges[i] != EdgeKind.LAND and new_edges[i] != EdgeKind.WATER:
			push_error("IRRIGATION can only mark LAND or WATER edges, got %s on edge %d." % [EDGE_KIND_NAMES[new_edges[i]], i])
			return
	# 内部连通性子网合法性检查：
	# - 每个子网必须是 0..15 之间的位掩码；
	# - 子网内只能含与基础地形匹配的边（如 LAND 子网只能含 LAND / LAND_WITH_IRRIGATION 边，
	#   WATER 子网只能含 WATER / WATER_WITH_IRRIGATION 边）；
	# - 不重复声明同一边。
	var used_bits := 0
	for subnet in new_water_subnets:
		var mask := int(subnet)
		if mask < 0 or mask > 15:
			push_error("Water subnet mask out of range: %d" % mask)
			return
		for bit in range(4):
			if (mask & (1 << bit)) != 0:
				if new_edges[bit] != EdgeKind.WATER:
					push_error("Water subnet claims edge %d which is %s, not WATER." % [bit, EDGE_KIND_NAMES[new_edges[bit]]])
					return
				if (used_bits & (1 << bit)) != 0:
					push_error("Edge %d declared in multiple subnets." % bit)
					return
				used_bits |= (1 << bit)
	for subnet in new_land_subnets:
		var mask := int(subnet)
		if mask < 0 or mask > 15:
			push_error("Land subnet mask out of range: %d" % mask)
			return
		for bit in range(4):
			if (mask & (1 << bit)) != 0:
				if new_edges[bit] != EdgeKind.LAND:
					push_error("Land subnet claims edge %d which is %s, not LAND." % [bit, EDGE_KIND_NAMES[new_edges[bit]]])
					return
				if (used_bits & (1 << bit)) != 0:
					push_error("Edge %d declared in multiple subnets." % bit)
					return
				used_bits |= (1 << bit)
	id = new_id
	display_name = new_display_name
	card_type = new_card_type
	count = max(1, new_count)
	edges = new_edges.duplicate()
	ir_edges = new_ir_edges.duplicate()
	center_kind = new_center
	is_river_tile = new_is_river_tile
	river_setup_terminal = new_river_setup_terminal
	starts_grown = new_starts_grown
	visual_seed = new_visual_seed
	irrigated_land_edges = new_irrigated_land_edges.duplicate()
	visual_scene = new_visual_scene
	visual_rotation_quarters = int(posmod(new_visual_rotation_quarters, 4))
	notes = new_notes
	# 内部连通性：land_subnets / water_subnets 按位掩码数组存档。
	land_subnets = []
	for subnet in new_land_subnets:
		land_subnets.append(int(subnet))
	water_subnets = []
	for subnet in new_water_subnets:
		water_subnets.append(int(subnet))
	if irrigated_land_edges.is_empty() and not edge_indices(EdgeKind.WATER).is_empty():
		# In this first placement-only slice every water route branches into each
		# land region. Storing the targets makes the invariant explicit in data.
		irrigated_land_edges = edge_indices(EdgeKind.LAND)
	if not has_valid_irrigation():
		push_error("Every water edge must route to at least one land edge on the same tile.")
	if not validate_river_tile_invariant():
		push_error("River tile %s violates the CENTER_RIVER channel invariant." % new_id)


func edge_indices(kind: int, quarter_turns := 0) -> PackedInt32Array:
	var indices := PackedInt32Array()
	for edge in range(4):
		if edge_kind_at(edge, quarter_turns) == kind:
			indices.append(edge)
	return indices


func land_edge_count() -> int:
	return edge_indices(EdgeKind.LAND).size()


# §5.2（v17）：地块面积——单边土地（仅 1 条 land 边）算 0.5 格，其余（2/3/4 条）算 1 格。
# 用于"植物需水 = need × 面积"公式。
func land_area() -> float:
	var edge_count := land_edge_count()
	if edge_count <= 1:
		return 0.5
	return 1.0


# §5.1/§5.2：指定 land 子网（split 卡一格多块地时按"块"计）的 land 边数。
# 面积按该子网的边数判定：1 条边 = 0.5 格（center EMPTY 的每块地）；≥2 条边 = 1 格。
func land_subnet_edge_count(subnet_idx: int, quarter_turns := 0) -> int:
	var masks := land_subnet_masks(quarter_turns)
	if subnet_idx < 0 or subnet_idx >= masks.size():
		return 0
	var mask := int(masks[subnet_idx])
	var count := 0
	for edge in range(4):
		if (mask & edge_bitmask(edge)) != 0:
			count += 1
	return count


# §5.2：指定 land 子网的面积（0.5 或 1.0 格）。
func land_subnet_area(subnet_idx: int, quarter_turns := 0) -> float:
	return 0.5 if land_subnet_edge_count(subnet_idx, quarter_turns) <= 1 else 1.0


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
	# 纯水地块（无 LAND 边）合法：作为水网成员独立存在，不灌溉 land（§3.3.1）
	if edge_indices(EdgeKind.LAND).is_empty():
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
	if not validate_river_tile_invariant():
		return false
	return true


# 河流地块约束（§2.4.4）：中心强制 CENTER_RIVER；每条边只取 EMPTY / RIVER / WATER。
# RIVER 保持主河连通；WATER 是从主河两侧引出的普通细水路，按 WATER 水网连接。
# 至少 1 条 RIVER，且不能有 IR 修饰。任何 RIVER 标记都会强制走这套约束，避免普通地块伪造河流端口。
func validate_river_tile_invariant() -> bool:
	var uses_river_channel := center_kind == CenterKind.RIVER
	for e in range(4):
		if edges[e] == EdgeKind.RIVER:
			uses_river_channel = true
	if not uses_river_channel:
		return not is_river_tile
	if not is_river_tile:
		return false
	if center_kind != CenterKind.RIVER:
		return false
	for e in range(4):
		if edges[e] != EdgeKind.RIVER and edges[e] != EdgeKind.WATER and edges[e] != EdgeKind.EMPTY:
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
		_:
			return "空地"


static func center_kind_label(kind: int) -> String:
	match kind:
		CenterKind.LAND:
			return "中心土地"
		CenterKind.RIVER:
			return "中心河流"
		_:
			return "空地中心"


# === 内部连通性查询（规则引擎 §3.3 依赖） ===

# 单边的位掩码：edge ∈ {N,E,S,W} -> 1<<edge
static func edge_bitmask(edge: int) -> int:
	return 1 << int(edge)


# 返回边在指定旋转下属于哪个 land 子网索引（0..land_subnets.size()-1）；未命中返回 -1
func land_subnet_index_at(world_edge: int, quarter_turns := 0) -> int:
	var bit := edge_bitmask(world_edge)
	var source_edge := int(posmod(world_edge - quarter_turns, 4))
	var source_bit := edge_bitmask(source_edge)
	for i in range(land_subnets.size()):
		if int(land_subnets[i]) & source_bit:
			return i
	return -1


# 返回边在指定旋转下属于哪个 water 子网索引；未命中返回 -1
func water_subnet_index_at(world_edge: int, quarter_turns := 0) -> int:
	var source_edge := int(posmod(world_edge - quarter_turns, 4))
	var source_bit := edge_bitmask(source_edge)
	for i in range(water_subnets.size()):
		if int(water_subnets[i]) & source_bit:
			return i
	return -1


# 同一地块内两条边是否属于同一 land 子网
# 仅依赖 land_subnets 表 + 中心 LAND 规则（中心 LAND 自动并入所有 land 子网）。
func land_subnet_connected(edge_a: int, edge_b: int, quarter_turns := 0) -> bool:
	if edges[int(posmod(edge_a - quarter_turns, 4))] != EdgeKind.LAND:
		return false
	if edges[int(posmod(edge_b - quarter_turns, 4))] != EdgeKind.LAND:
		return false
	if center_kind == CenterKind.LAND:
		# §2.4.2：中心 LAND 把所有 land 边合并到同一个 land 区域
		return true
	var idx_a := land_subnet_index_at(edge_a, quarter_turns)
	var idx_b := land_subnet_index_at(edge_b, quarter_turns)
	if idx_a < 0 or idx_b < 0:
		return false
	return idx_a == idx_b


# 同一地块内两条边是否属于同一 water 子网（v17：水网仅由 WATER 边连通，中心不再入网）。
func water_subnet_connected(edge_a: int, edge_b: int, quarter_turns := 0) -> bool:
	var bit_a := edge_bitmask(int(posmod(edge_a - quarter_turns, 4)))
	var bit_b := edge_bitmask(int(posmod(edge_b - quarter_turns, 4)))
	for subnet in water_subnets:
		var mask := int(subnet)
		if (mask & bit_a) != 0 and (mask & bit_b) != 0:
			return true
	return false


# 给定旋转下，本地块的"land 子网位掩码集合"——含中心 LAND 自动并入规则。
# 返回值：Array[int]，每个元素是一个子网的合并位掩码（含中心 LAND 位）。
func land_subnet_masks(quarter_turns := 0) -> Array:
	var out: Array = []
	# 旋转后的边位掩码表
	var rotated_mask := 0
	for edge in range(4):
		if edges[int(posmod(edge - quarter_turns, 4))] == EdgeKind.LAND:
			rotated_mask |= edge_bitmask(edge)
	# 把每个子网旋转后映射为世界坐标系下的位掩码
	for subnet in land_subnets:
		var src := int(subnet)
		var rotated := 0
		for edge in range(4):
			if (src & edge_bitmask(edge)) != 0:
				# 原 edge 旋转后位于世界 (edge + quarter_turns) % 4
				var world_edge := int(posmod(edge + quarter_turns, 4))
				rotated |= edge_bitmask(world_edge)
		out.append(rotated)
	if center_kind == CenterKind.LAND:
		# §2.4.2：中心 LAND 自动把所有 land 子网合并成一个
		out.clear()
		out.append(rotated_mask)
	return out


# 给定旋转下，本地块的"water 子网位掩码集合"（v17：仅由 WATER 边连通构成，无中心并入）。
func water_subnet_masks(quarter_turns := 0) -> Array:
	var out: Array = []
	for subnet in water_subnets:
		var src := int(subnet)
		var rotated := 0
		for edge in range(4):
			if (src & edge_bitmask(edge)) != 0:
				var world_edge := int(posmod(edge + quarter_turns, 4))
				rotated |= edge_bitmask(world_edge)
		out.append(rotated)
	return out


# 判定该地块在指定旋转下，是否应被外部水网整体并入。
# v17：中心不再有 LAKE，中心本身不并入水网；水网只由 WATER 边连通构成。
func joins_water_net_via_center(quarter_turns := 0) -> bool:
	return false


# 给定旋转下，该地块的"land 边总位掩码"——所有 land 边的位 OR（不含中心）。
func land_edge_mask_at(quarter_turns := 0) -> int:
	var mask := 0
	for edge in range(4):
		if edges[int(posmod(edge - quarter_turns, 4))] == EdgeKind.LAND:
			mask |= edge_bitmask(edge)
	return mask


# 给定旋转下，该地块的"water 边总位掩码"——所有 water 边的位 OR（不含中心）。
func water_edge_mask_at(quarter_turns := 0) -> int:
	var mask := 0
	for edge in range(4):
		if edges[int(posmod(edge - quarter_turns, 4))] == EdgeKind.WATER:
			mask |= edge_bitmask(edge)
	return mask


# 给定旋转下，含 IRRIGATION 修饰的边的位掩码（LAND_WITH_IRRIGATION 与 WATER_WITH_IRRIGATION 都计入）
func irrigation_edge_mask_at(quarter_turns := 0) -> int:
	var mask := 0
	for edge in range(4):
		if ir_edges[int(posmod(edge - quarter_turns, 4))] == 1:
			mask |= edge_bitmask(edge)
	return mask


# 保留给旧调用方的本地 land 子网查询。CENTER_EMPTY 只分隔同一地块内部
# 的不同子网；跨地块 LAND↔LAND 接缝由 RuleEngine 按两侧实际命中的子网合并。
func can_land_join(world_edge: int, other_edge: int, other_centre_land: bool, quarter_turns := 0) -> bool:
	if edges[int(posmod(world_edge - quarter_turns, 4))] != EdgeKind.LAND:
		return false
	if center_kind == CenterKind.LAND:
		return true
	# 中心 EMPTY：每条 land 边仅在本地独立；当前 LAND 边仍可跨接缝连到邻格。
	return true
