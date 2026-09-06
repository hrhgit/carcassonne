class_name RuleEngine
extends RefCounted

# 青菱沃野规则引擎（基于 docs/规则书.md）：
# - §3.3 拼接后的连通性刷新（land/water 群）
# - §3.6 拼接后的事件钩子
# - §4 水网与供水（r17：按灌溉接口数量计，每接口 2 点水）
#
# 设计要点：
# 1) RuleEngine 是无状态计算器：调用方传入 BoardState + 触发原因（"place"），
#    返回该时刻的全量分析结果。
# 2) 内部使用 DSU/集合代表连通分量，land_region 与 water_net 用唯一 id 索引。
# 3) 供水 r17：一个 land_region 每有一处灌溉接口（IR 接口）即获得 2 点水；
#    多接口叠加，不再"同一水网只算一次"。水网仍用于连通判定。
# 4) **r17.1 land_region 原子单位 = land 子网**（§2.4.2 / §2.4.3）：
#    - center=LAND 的地块：整格是一个 land 子网（中心 + 全部 land 边连通）。
#    - center=EMPTY 的地块：每条 land 边独立成一个 land 子网（互相不连通）。
#    一个"格"因此可以属于 0..N 个 land_region（split 卡横跨多 region）。
#    跨格合并发生在两侧 LAND↔LAND 对接时；中心类型只决定地块内部哪些边属于同一子网（§3.3.2）。

const TD := preload("res://scripts/tile_definition.gd")
const BS := preload("res://scripts/board_state.gd")

# 边索引对应方向
const NORTH := TD.Edge.NORTH
const EAST := TD.Edge.EAST
const SOUTH := TD.Edge.SOUTH
const WEST := TD.Edge.WEST

# EdgeKind
const KIND_EMPTY := TD.EdgeKind.EMPTY
const KIND_LAND := TD.EdgeKind.LAND
const KIND_WATER := TD.EdgeKind.WATER
const KIND_RIVER := TD.EdgeKind.RIVER

# CenterKind
const CENTER_EMPTY := TD.CenterKind.EMPTY
const CENTER_LAND := TD.CenterKind.LAND
const CENTER_RIVER := TD.CenterKind.RIVER


# === 数据结构 ===

# 一条开放边：地块位于 cell，开放边的方向为 edge（0..3）
class OpenEdge extends RefCounted:
	var cell: Vector2i
	var edge: int
	var canal: bool = false


# 土地块：同一连通分量内的所有"含 land 的子网"，共享同一块土地。
class LandRegion extends RefCounted:
	var id: int
	var cells: Array[Vector2i] = []           # 所有贡献 land 的格（去重）
	var open_edges: Array = []                # OpenEdge 列表，未对接的 land 边界
	var irrigated_water_net_ids: Dictionary = {}  # value=任意（去重 set）——实际灌溉到此 land 的水网
	var irrigation_link_count: int = 0        # r17：实际灌溉接口数（每个 IR 接口 +1）
	var subnets: Array = []                   # 本 region 内的 land 子网（[Vector2i cell, int subnet_idx] 列表）
	var is_closed: bool = false               # §5.6 land 边全部封闭？
	var S_L: float = 0.0                      # r17：实际供水量 = 灌溉接口数 × 2
	var land_component_id: int = -1           # §3.3.2 land_component（合并后的更大群）

	func get_open_edge_count() -> int:
		return open_edges.size()


# 水网连通集合（§3.3.1）
class WaterNet extends RefCounted:
	var id: int
	var tiles: Array[Vector2i] = []           # 所有入水网的地块（仅 WATER 边连通）
	var open_edges: Array = []                # 未对接的水口 / IR 边界
	var is_closed: bool = false               # §5.6.1 水口 / IR 全部封闭？


# 整局分析结果
class Analysis extends RefCounted:
	var land_regions: Array = []              # Array[LandRegion]
	var water_nets: Array = []                # Array[WaterNet]
	var land_regions_by_cell: Dictionary = {} # cell -> Array[LandRegion]（一格可属多个 region）
	var land_subnet_to_region: Dictionary = {} # (cell, subnet_idx) key -> LandRegion（稳定定位用）
	var water_net_by_cell: Dictionary = {}    # cell -> WaterNet（仅含边入水网的格）
	var water_supply_by_land: Dictionary = {} # LandRegion.id -> float
	var land_regions_closed: Array = []       # 本次扫描中已 land 边全封闭的 land_region
	var water_nets_closed: Array = []         # 本次扫描中已水口全封闭的 water_net
	var summary: Dictionary = {}              # {land_count, water_count, total_irrigation_links, total_S_L}


# === 主入口：分析整盘 ===

static func analyze(board: BoardState) -> Analysis:
	var result := Analysis.new()
	if board == null or board.placements.is_empty():
		result.summary = {"land_count": 0, "water_count": 0, "total_irrigation_links": 0, "total_S_L": 0.0}
		return result

	# 第一遍：建立每个地块的"开放边表"
	var edge_table := _build_edge_table(board)

	# 第二遍：land 群 DSU 合并（以 land 子网为原子单位）
	var land_dsu := _build_land_dsu(board)
	var land_regions := _collect_land_regions(board, land_dsu)

	# 第三遍：water 群 DSU 合并（含 IR 跨界接口）
	var water_dsu := _build_water_dsu(board, edge_table)
	var water_nets := _collect_water_nets(board, water_dsu, edge_table)

	# 第四遍：跨界灌溉接口（§3.3.3）—— 把 water_net 与 land_region 关联
	_link_irrigation(board, land_regions, water_nets)

	# 第五遍：补水容量 + 全封闭判定
	_compute_supply_and_closure(land_regions, water_nets)

	# 第六遍：填回 result
	result.land_regions = land_regions
	result.water_nets = water_nets
	for lr in land_regions:
		for c in lr.cells:
			if not result.land_regions_by_cell.has(c):
				result.land_regions_by_cell[c] = []
			(result.land_regions_by_cell[c] as Array).append(lr)
		for m in lr.subnets:
			result.land_subnet_to_region[_land_subnet_key(m[0], m[1])] = lr
	for wn in water_nets:
		result.water_net_by_cell[wn.id] = wn
		for c in wn.tiles:
			result.water_net_by_cell[c] = wn

	for lr in land_regions:
		if lr.is_closed:
			result.land_regions_closed.append(lr)
		result.water_supply_by_land[lr.id] = lr.S_L
	for wn in water_nets:
		if wn.is_closed:
			result.water_nets_closed.append(wn)

	var total_links := 0
	for lr in land_regions:
		total_links += lr.irrigation_link_count
	var total_sl := 0.0
	for lr in land_regions:
		total_sl += lr.S_L
	result.summary = {
		"land_count": land_regions.size(),
		"water_count": water_nets.size(),
		"total_irrigation_links": total_links,
		"total_S_L": total_sl,
	}
	return result


# === land 子网 ===

# 返回一个地块的 land 子网列表。每个元素是 {"edges": Array[int], "center_land": bool}。
# - center=LAND：整格一个子网（含全部 land 边，center_land=true）；即使 0 条 land 边也保留一个（纯中心）。
# - center=EMPTY：每条 land 边独立一个子网（center_land=false）——§2.4.3。
# - center=RIVER：无 land 边（河流地块不允许 LAND），返回空。
static func _land_subnets_of(def: TileDefinition, rotation: int) -> Array:
	var out: Array = []
	if def.center_kind == CENTER_LAND:
		var edges: Array = []
		for e in range(4):
			if def.edge_kind_at(e, rotation) == KIND_LAND:
				edges.append(e)
		out.append({"edges": edges, "center_land": true})
		return out
	# center EMPTY / RIVER：每条 land 边独立
	for e in range(4):
		if def.edge_kind_at(e, rotation) == KIND_LAND:
			out.append({"edges": [e], "center_land": false})
	return out


# (cell, subnet_idx) 的稳定字符串键，用于 DSU 与 land_region_of_subnet 索引。
static func _land_subnet_key(cell: Vector2i, subnet_idx: int) -> String:
	return "%d,%d#%d" % [cell.x, cell.y, subnet_idx]


# 一个 land_region 的稳定标识：其 subnets 集合规范化排序后拼接。
# 闭合的 region 不再合并、subnets 固定，故该 key 跨多次 analyze 稳定，可用于收获锁定。
static func stable_region_key(lr: LandRegion) -> String:
	var subs: Array = lr.subnets.duplicate()
	subs.sort_custom(func(a: Array, b: Array) -> bool:
		var ca: Vector2i = a[0]
		var cb: Vector2i = b[0]
		if ca.y != cb.y:
			return ca.y < cb.y
		if ca.x != cb.x:
			return ca.x < cb.x
		return int(a[1]) < int(b[1])
	)
	var parts: Array = []
	for s in subs:
		parts.append(_land_subnet_key(s[0], s[1]))
	return "|".join(parts)


# === 边表：枚举每条边是否开放 + 边类型 ===

# 返回 Dictionary[Vector2i cell -> Array of OpenEdge]，
# 仅包含"有边参与 land/water 群"的边（land/water/ir/canal）。
static func _build_edge_table(board: BoardState) -> Dictionary:
	var table: Dictionary = {}
	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		var cell_edges: Array = []
		for edge in range(4):
			var kind := def.edge_kind_at(edge, rotation)
			var is_ir: bool = def.ir_at(edge, rotation)
			var joins_land := kind == KIND_LAND
			var joins_water := kind == KIND_WATER
			if is_ir:
				if kind == KIND_LAND:
					joins_land = true
					joins_water = true
				elif kind == KIND_WATER:
					joins_land = true
					joins_water = true
			if not (joins_land or joins_water):
				continue
			var oe := OpenEdge.new()
			oe.cell = cell
			oe.edge = edge
			oe.canal = false
			cell_edges.append(oe)
		table[cell] = cell_edges
	return table


# === land 群 DSU 合并（§3.3.2） ===

# 每条 LAND 接缝都连通两侧“实际接触这条边”的 land 子网。CENTER_EMPTY
# 只切断同一张地块内部的不同 land 边，不能切断一条已经贴合的 LAND↔LAND 接缝。
# 节点 = (cell, land_subnet_idx)，因此 split 地块仍可在同一格保留多个互不相通的土地块。
static func _build_land_dsu(board: BoardState) -> DSU:
	var dsu := DSU.new()
	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		var subnets := _land_subnets_of(def, rotation)
		for i in range(subnets.size()):
			dsu.make(_land_subnet_key(cell, i))

	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		for edge in range(4):
			if def.edge_kind_at(edge, rotation) != KIND_LAND:
				continue
			var nb_cell := BS.neighbour_for_edge(cell, edge)
			if not board.has_tile(nb_cell):
				continue
			var nb_placement: Dictionary = board.get_placement(nb_cell)
			var nb_def: TileDefinition = nb_placement["definition"]
			var nb_rotation: int = int(nb_placement["rotation"])
			var nb_edge := BS.opposite_edge(edge)
			if nb_def.edge_kind_at(nb_edge, nb_rotation) != KIND_LAND:
				continue
			var own_subnet_idx := _land_subnet_index_for_edge(def, rotation, edge)
			var nb_subnet_idx := _land_subnet_index_for_edge(nb_def, nb_rotation, nb_edge)
			if own_subnet_idx < 0 or nb_subnet_idx < 0:
				push_error("LAND edge did not resolve to a land subnet while joining %s and %s." % [cell, nb_cell])
				continue
			dsu.union(
				_land_subnet_key(cell, own_subnet_idx),
				_land_subnet_key(nb_cell, nb_subnet_idx),
			)
	return dsu


# `_land_subnets_of` is the source of truth for the runtime region graph. Find
# the exact subnet that reaches one world-space edge so cross-tile joins do not
# accidentally merge sibling regions of a CENTER_EMPTY split tile.
static func _land_subnet_index_for_edge(def: TileDefinition, rotation: int, edge: int) -> int:
	var subnets := _land_subnets_of(def, rotation)
	for subnet_idx in range(subnets.size()):
		if edge in subnets[subnet_idx]["edges"]:
			return subnet_idx
	return -1


static func _collect_land_regions(board: BoardState, dsu: DSU) -> Array:
	var groups: Dictionary = {}  # root_key -> Array[ [cell, subnet_idx] ]
	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		var subnets := _land_subnets_of(def, rotation)
		for i in range(subnets.size()):
			var root: Variant = dsu.find(_land_subnet_key(cell, i))
			if not groups.has(root):
				groups[root] = []
			(groups[root] as Array).append([cell, i])

	var regions: Array = []
	var id := 0
	for root in groups.keys():
		var members: Array = groups[root]
		var lr := LandRegion.new()
		lr.id = id
		lr.subnets = members
		var cell_set: Dictionary = {}
		for m in members:
			cell_set[m[0]] = true
		for c in cell_set.keys():
			lr.cells.append(c)
		# open_edges：本 region 内所有"land 边尚未与另一 land 边物理对接"的边
		# §5.6.1 全封闭 = 所有 land 边均已被同型 land 边对接（物理对接，与是否合并无关）
		for m in members:
			var cell: Vector2i = m[0]
			var subnet_idx: int = m[1]
			var placement: Dictionary = board.get_placement(cell)
			var def: TileDefinition = placement["definition"]
			var rotation: int = int(placement["rotation"])
			var subnet: Dictionary = _land_subnets_of(def, rotation)[subnet_idx]
			for edge in subnet["edges"]:
				var nb_cell := BS.neighbour_for_edge(cell, edge)
				var closed := false
				if board.has_tile(nb_cell):
					var nb_placement: Dictionary = board.get_placement(nb_cell)
					var nb_def: TileDefinition = nb_placement["definition"]
					var nb_rotation: int = int(nb_placement["rotation"])
					if nb_def.edge_kind_at(BS.opposite_edge(edge), nb_rotation) == KIND_LAND:
						closed = true
				if not closed:
					var oe := OpenEdge.new()
					oe.cell = cell
					oe.edge = edge
					lr.open_edges.append(oe)
		id += 1
		regions.append(lr)
	return regions


# === water 群 DSU 合并（§3.3.1） ===

# §3.3.1 第 1 条：WATER 边对接 → 合并
# §3.3.1 第 2 条：IR 修饰边（不论 LAND 还是 WATER）→ 双参与
# r17：中心不再有 LAKE；RIVER 边 / CENTER_RIVER 不入水网
static func _build_water_dsu(board: BoardState, edge_table: Dictionary) -> DSU:
	var dsu := DSU.new()
	for cell in board.placements.keys():
		dsu.make(cell)

	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		for edge in range(4):
			var own_kind := def.edge_kind_at(edge, rotation)
			var own_ir: bool = def.ir_at(edge, rotation)
			var own_water := own_kind == KIND_WATER
			var own_ir_only := own_ir and own_kind == KIND_LAND  # LAND+IR 跨界
			if not (own_water or own_ir_only):
				continue
			var nb_cell := BS.neighbour_for_edge(cell, edge)
			if not board.has_tile(nb_cell):
				continue
			var nb_placement: Dictionary = board.get_placement(nb_cell)
			var nb_def: TileDefinition = nb_placement["definition"]
			var nb_rotation: int = int(nb_placement["rotation"])
			var nb_edge := BS.opposite_edge(edge)
			var nb_kind := nb_def.edge_kind_at(nb_edge, nb_rotation)
			var nb_ir: bool = nb_def.ir_at(nb_edge, nb_rotation)
			var nb_water := nb_kind == KIND_WATER
			var nb_ir_only := nb_ir and nb_kind == KIND_LAND
			if not (nb_water or nb_ir_only):
				continue
			if own_water and nb_water:
				dsu.union(cell, nb_cell)
			elif own_water and nb_ir_only:
				dsu.union(cell, nb_cell)
			elif own_ir_only and nb_water:
				dsu.union(cell, nb_cell)
			# own_ir_only + nb_ir_only 不直接合并（但后续会通过外部 WATER 桥接）

	return dsu


static func _collect_water_nets(board: BoardState, dsu: DSU, edge_table: Dictionary) -> Array:
	var groups: Dictionary = {}
	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		var has_water := false
		for edge in range(4):
			var kind := def.edge_kind_at(edge, rotation)
			var ir: bool = def.ir_at(edge, rotation)
			if kind == KIND_WATER or ir:
				has_water = true
				break
		if not has_water:
			continue
		var root: Variant = dsu.find(cell)
		if not groups.has(root):
			groups[root] = [] as Array[Vector2i]
		(groups[root] as Array[Vector2i]).append(cell)

	var nets: Array = []
	var id := 0
	for root in groups.keys():
		var tiles: Array[Vector2i] = groups[root]
		var wn := WaterNet.new()
		wn.id = id
		wn.tiles = tiles
		id += 1
		nets.append(wn)

	for wn in nets:
		var tile_set: Dictionary = {}
		for c in wn.tiles:
			tile_set[c] = true
		for c in wn.tiles:
			var placement: Dictionary = board.get_placement(c)
			var def: TileDefinition = placement["definition"]
			var rotation: int = int(placement["rotation"])
			for edge in range(4):
				var kind := def.edge_kind_at(edge, rotation)
				var ir: bool = def.ir_at(edge, rotation)
				var is_water_edge := kind == KIND_WATER
				var is_ir_only := ir and kind == KIND_LAND
				if not (is_water_edge or is_ir_only):
					continue
				var nb_cell := BS.neighbour_for_edge(c, edge)
				var matched := false
				if board.has_tile(nb_cell):
					var nb_placement: Dictionary = board.get_placement(nb_cell)
					var nb_def: TileDefinition = nb_placement["definition"]
					var nb_rotation: int = int(nb_placement["rotation"])
					var nb_edge := BS.opposite_edge(edge)
					var nb_kind := nb_def.edge_kind_at(nb_edge, nb_rotation)
					var nb_ir: bool = nb_def.ir_at(nb_edge, nb_rotation)
					var nb_water := nb_kind == KIND_WATER
					if nb_water and tile_set.has(nb_cell):
						matched = true
					elif nb_ir and nb_kind == KIND_LAND and is_water_edge and tile_set.has(nb_cell):
						matched = true  # WATER ↔ LAND+IR 跨界接口
				if not matched:
					var oe := OpenEdge.new()
					oe.cell = c
					oe.edge = edge
					oe.canal = false
					wn.open_edges.append(oe)
	return nets


# === 跨界灌溉接口（§3.3.3）===

# 把每个 water_net 与其灌溉到的 land_region 关联。
# r17：供水按"灌溉接口数量"计——每个 IR 接口给对应 land_region +1 个接口计数，
# 最终 V_L = 接口数 × 2。每个 IR 接口独立计数（多接口叠加）。
static func _link_irrigation(board: BoardState, land_regions: Array, water_nets: Array) -> void:
	var land_region_of_subnet: Dictionary = {}
	for lr in land_regions:
		for m in lr.subnets:
			land_region_of_subnet[_land_subnet_key(m[0], m[1])] = lr
	var cell_to_wn: Dictionary = {}
	for wn in water_nets:
		for c in wn.tiles:
			cell_to_wn[c] = wn

	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		var wn: WaterNet = cell_to_wn.get(cell, null)
		var subnets := _land_subnets_of(def, rotation)
		for edge in range(4):
			if not def.ir_at(edge, rotation):
				continue
			var kind := def.edge_kind_at(edge, rotation)
			if kind == KIND_LAND:
				for i in range(subnets.size()):
					if edge in subnets[i]["edges"]:
						var lr: LandRegion = land_region_of_subnet.get(_land_subnet_key(cell, i), null)
						if lr != null and wn != null:
							lr.irrigation_link_count += 1
							lr.irrigated_water_net_ids[wn.id] = true
						break
			elif kind == KIND_WATER:
				var nb_cell := BS.neighbour_for_edge(cell, edge)
				if not board.has_tile(nb_cell):
					continue
				var nb_placement: Dictionary = board.get_placement(nb_cell)
				var nb_def: TileDefinition = nb_placement["definition"]
				var nb_rotation: int = int(nb_placement["rotation"])
				var nb_edge := BS.opposite_edge(edge)
				if nb_def.edge_kind_at(nb_edge, nb_rotation) != KIND_LAND:
					continue
				var nb_subnets := _land_subnets_of(nb_def, nb_rotation)
				for i in range(nb_subnets.size()):
					if nb_edge in nb_subnets[i]["edges"]:
						var lr: LandRegion = land_region_of_subnet.get(_land_subnet_key(nb_cell, i), null)
						if lr != null and wn != null:
							lr.irrigation_link_count += 1
							lr.irrigated_water_net_ids[wn.id] = true
						break
			# RIVER+IR 不存在（IR 不允许修饰 RIVER / EMPTY）


# === 供水计算 + 全封闭判定 ===

# r17：V_L = 灌溉接口数 × 2 点水（每处接口固定 2 点）。
static func _compute_supply_and_closure(land_regions: Array, water_nets: Array) -> void:
	for lr in land_regions:
		lr.S_L = float(lr.irrigation_link_count) * 2.0
		lr.is_closed = lr.open_edges.is_empty()

	for wn in water_nets:
		wn.is_closed = wn.open_edges.is_empty()


# === DSU 工具 ===

class DSU extends RefCounted:
	var parent: Dictionary = {}
	var rank: Dictionary = {}

	func make(x: Variant) -> void:
		if not parent.has(x):
			parent[x] = x
			rank[x] = 0

	func find(x: Variant) -> Variant:
		if not parent.has(x):
			make(x)
		var p: Variant = parent[x]
		if p == x:
			return x
		var root: Variant = find(p)
		parent[x] = root
		return root

	func union(a: Variant, b: Variant) -> void:
		var ra: Variant = find(a)
		var rb: Variant = find(b)
		if ra == rb:
			return
		var rank_a: int = int(rank.get(ra, 0))
		var rank_b: int = int(rank.get(rb, 0))
		if rank_a < rank_b:
			parent[ra] = rb
		elif rank_a > rank_b:
			parent[rb] = ra
		else:
			parent[rb] = ra
			rank[ra] = rank_a + 1


# === 工具：水渠改写检测（用于 board_state.place 时调用） ===

# r17：无 CANAL/水渠，不存在永久改写（不存在旧版 BANK 的 water_rewrite_at 语义）。
# 本函数保留签名以便调用方兼容，恒返回空。
static func detect_pending_rewrites(board: BoardState, definition: TileDefinition, cell: Vector2i, quarter_turns: int) -> Array:
	return []
