class_name RuleEngine
extends RefCounted

# 碧水沃野规则引擎（基于 docs/规则书.md）：
# - §3.3 拼接后的连通性刷新（land/water 群）
# - §3.6 拼接后的事件钩子（含 BANK↔水口 永久改写为水渠）
# - §4 水网与供水（地块级 P + 水渠级 P_canal = 水网容量 S_W）
#
# 设计要点：
# 1) RuleEngine 是无状态计算器：调用方传入 BoardState + 触发原因（"place"），
#    返回该时刻的全量分析结果。
# 2) 内部使用 DSU/集合代表连通分量，land_region 与 water_net 用唯一 id 索引。
# 3) 与 board_state.gd 协作：place() 时由 BoardState 计算并落 water_rewrite_at，
#    RuleEngine 读取该字段识别"水渠边"。
# 4) 单地块水源 P 见 §4.1.1；水渠 P_canal = 6/条（§4.1.2）。

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
const KIND_BANK := TD.EdgeKind.BANK

# CenterKind
const CENTER_EMPTY := TD.CenterKind.EMPTY
const CENTER_LAND := TD.CenterKind.LAND
const CENTER_LAKE := TD.CenterKind.LAKE
const CENTER_RIVER := TD.CenterKind.RIVER


# === 数据结构 ===

# 一条开放边：地块位于 cell，开放边的方向为 edge（0..3）
# 如果是水渠，canal=true 表示该边被永久改写为水口
class OpenEdge extends RefCounted:
	var cell: Vector2i
	var edge: int
	var canal: bool = false


# 土地块：同一连通分量内的所有"含 land 的格"，共享同一块土地。
class LandRegion extends RefCounted:
	var id: int
	var cells: Array[Vector2i] = []           # 所有贡献 land 的格（去重）
	var open_edges: Array = []                # OpenEdge 列表，未对接的 land 边界
	var irrigated_water_net_ids: Dictionary = {}  # value=任意（去重 set）——实际灌溉到此 land 的水网
	var unit_count: int = 0                   # 地块内的"land 单元"数（含中心 LAND=1、land 边=1）
	var is_closed: bool = false               # §5.6 land 边全部封闭？
	var S_L: float = 0.0                      # §4.4 实际供水量 = Σ S_W
	var land_component_id: int = -1           # §3.3.2 land_component（合并后的更大群）

	func get_open_edge_count() -> int:
		return open_edges.size()


# 水网连通集合（§3.3.1）
class WaterNet extends RefCounted:
	var id: int
	var tiles: Array[Vector2i] = []           # 所有入水网的地块（含 CENTER_LAKE 自动并入）
	var open_edges: Array = []                # 未对接的水口 / IR / 水渠边界
	var P_tile: int = 0                       # §4.1.1 地块级水源点数之和
	var P_canal: int = 0                      # §4.1.2 水渠级水源点数之和（每条 6 点）
	var S_W: int = 0                          # §4.2 水网容量 = P_tile + P_canal
	var S_W_capped: int = 0                   # 同上（保留字段，便于将来加限额）
	var is_closed: bool = false               # §5.6.1 水口 / IR / 水渠全部封闭？


# 整局分析结果
class Analysis extends RefCounted:
	var land_regions: Array = []              # Array[LandRegion]
	var water_nets: Array = []                # Array[WaterNet]
	var land_region_by_cell: Dictionary = {}  # cell -> LandRegion
	var water_net_by_cell: Dictionary = {}    # cell -> WaterNet（仅含边入水网的格；CENTER_LAKE 自动入）
	var water_supply_by_land: Dictionary = {} # LandRegion.id -> float
	var land_regions_closed: Array = []       # 本次扫描中已 land 边全封闭的 land_region
	var water_nets_closed: Array = []         # 本次扫描中已水口全封闭的 water_net
	var summary: Dictionary = {}              # {land_count, water_count, total_S_W, total_S_L}


# === 主入口：分析整盘 ===

static func analyze(board: BoardState) -> Analysis:
	var result := Analysis.new()
	if board == null or board.placements.is_empty():
		result.summary = {"land_count": 0, "water_count": 0, "total_S_W": 0, "total_S_L": 0.0}
		return result

	# 第一遍：建立每个地块的"开放边表"（含水渠标记）
	var edge_table := _build_edge_table(board)

	# 第二遍：land 群 DSU 合并
	var land_dsu := _build_land_dsu(board, edge_table)
	var land_regions := _collect_land_regions(board, land_dsu, edge_table)

	# 第三遍：water 群 DSU 合并（含 IR、含水渠边、含 CENTER_LAKE 自动并入）
	var water_dsu := _build_water_dsu(board, edge_table)
	var water_nets := _collect_water_nets(board, water_dsu, edge_table)

	# 第四遍：跨界灌溉接口（§3.3.3）—— 把 water_net 与 land_region 关联
	_link_irrigation(board, edge_table, land_regions, water_nets)

	# 第五遍：补水容量 + 全封闭判定
	_compute_supply_and_closure(land_regions, water_nets)

	# 第六遍：填回 result
	result.land_regions = land_regions
	result.water_nets = water_nets
	for lr in land_regions:
		result.land_region_by_cell[lr.id] = lr
		for c in lr.cells:
			result.land_region_by_cell[c] = lr
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

	var total_sw := 0
	for wn in water_nets:
		total_sw += wn.S_W
	var total_sl := 0.0
	for lr in land_regions:
		total_sl += lr.S_L
	result.summary = {
		"land_count": land_regions.size(),
		"water_count": water_nets.size(),
		"total_S_W": total_sw,
		"total_S_L": total_sl,
	}
	return result


# === 边表：枚举每条边是否开放 + 边类型 ===

# 返回 Dictionary[Vector2i cell -> Array of OpenEdge]，
# 仅包含"有边参与 land/water 群"的边（land/water/ir/canal）。
static func _build_edge_table(board: BoardState) -> Dictionary:
	var table: Dictionary = {}
	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		var rewrites: Array = placement.get("water_rewrite_at", [])

		var cell_edges: Array = []
		for edge in range(4):
			var kind := def.edge_kind_at(edge, rotation)
			var is_ir: bool = def.ir_at(edge, rotation)
			var is_rewritten: bool = rewrites.has(edge)
			# 边是否参与 land/water 群？
			# - LAND 边 → 参与 land 群
			# - WATER 边 → 参与 water 群
			# - 含 IR 修饰 → 双参与（land 灌溉接口 + water 入网）
			# - BANK 边 + is_rewritten → 参与 water 群（视为水口）
			var joins_land := kind == KIND_LAND
			var joins_water := kind == KIND_WATER or (kind == KIND_BANK and is_rewritten)
			# IR 修饰视为跨界接口，无论基础地形是 LAND 还是 WATER 都入对应群
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
			oe.canal = is_rewritten
			cell_edges.append(oe)
		table[cell] = cell_edges
	return table


# === land 群 DSU 合并（§3.3.2） ===

# §3.3.2 第 1 条：两侧均为 CENTER_LAND + 两侧 LAND 边对接 → 合并
# §3.3.2 第 2 条：任一侧 CENTER_EMPTY → 不合并
# §3.3.2 第 3 条：CENTER_EMPTY 时每条 land 边各算独立 land_region
# 其余中心（CENTER_LAKE / CENTER_RIVER）：land 边视为"非合并"——仅在与 CENTER_LAND
# 地块配对时才能合并，否则每条 land 边独立成块（保持规则保守语义）。
static func _build_land_dsu(board: BoardState, edge_table: Dictionary) -> DSU:
	var dsu := DSU.new()
	for cell in board.placements.keys():
		dsu.make(cell)

	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		for edge in range(4):
			var nb_cell := BS.neighbour_for_edge(cell, edge)
			if not board.has_tile(nb_cell):
				continue
			var own_kind := def.edge_kind_at(edge, rotation)
			if own_kind != KIND_LAND:
				continue
			var nb_placement: Dictionary = board.get_placement(nb_cell)
			var nb_def: TileDefinition = nb_placement["definition"]
			var nb_rotation: int = int(nb_placement["rotation"])
			var nb_edge := BS.opposite_edge(edge)
			var nb_kind := nb_def.edge_kind_at(nb_edge, nb_rotation)
			if nb_kind != KIND_LAND:
				continue
			# 两侧都是 LAND。检查合并条件：两侧都必须是 CENTER_LAND。
			var own_centre_land := def.center_kind == CENTER_LAND
			var nb_centre_land := nb_def.center_kind == CENTER_LAND
			if own_centre_land and nb_centre_land:
				dsu.union(cell, nb_cell)
		# 同地块内 land 边按 land_subnets 合并（同中心 LAND 规则合并一切）；
		# 中心 EMPTY 时按子网分组（同一子网内合并）。这个在 dsu 之外用
		# _collect_land_regions 处理；这里只处理跨地块。
	return dsu


static func _collect_land_regions(board: BoardState, dsu: DSU, edge_table: Dictionary) -> Array:
	var groups: Dictionary = {}  # root_key -> Array[Vector2i]
	for cell in board.placements.keys():
		# 跳过无 LAND 贡献的格子（CENTER_EMPTY + 0 LAND 边 OR CENTER_RIVER 等）
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		var has_land := def.center_kind == CENTER_LAND
		if not has_land:
			for edge in range(4):
				if def.edge_kind_at(edge, rotation) == KIND_LAND:
					has_land = true
					break
		if not has_land:
			continue
		var root: Variant = dsu.find(cell)
		if not groups.has(root):
			groups[root] = [] as Array[Vector2i]
		(groups[root] as Array[Vector2i]).append(cell)

	var regions: Array = []
	var id := 0
	for root in groups.keys():
		var cells: Array[Vector2i] = groups[root]
		var lr := LandRegion.new()
		lr.id = id
		lr.cells = cells
		id += 1
		regions.append(lr)

	# 二次遍历：填 open_edges + unit_count
	# - open_edges：所有"land 边尚未与另一 land 边对接"的边
	# - unit_count：本区域内 land 单元数（中心 LAND=1 + land 边数）
	for lr in regions:
		var cell_set: Dictionary = {}
		for c in lr.cells:
			cell_set[c] = true
		var unit := 0
		for c in lr.cells:
			var placement: Dictionary = board.get_placement(c)
			var def: TileDefinition = placement["definition"]
			var rotation: int = int(placement["rotation"])
			if def.center_kind == CENTER_LAND:
				unit += 1
			for edge in range(4):
				if def.edge_kind_at(edge, rotation) != KIND_LAND:
					continue
				unit += 1
				# 是否对接：相邻格存在 + 邻居对侧为 LAND + 都属于同一 land 群（中心 LAND 合并）
				var nb_cell := BS.neighbour_for_edge(c, edge)
				var matched := false
				if board.has_tile(nb_cell) and cell_set.has(nb_cell):
					var nb_placement: Dictionary = board.get_placement(nb_cell)
					var nb_def: TileDefinition = nb_placement["definition"]
					var nb_rotation: int = int(nb_placement["rotation"])
					var nb_edge := BS.opposite_edge(edge)
					if nb_def.edge_kind_at(nb_edge, nb_rotation) == KIND_LAND:
						matched = true
				# §3.3.2 第 2 条：中心 EMPTY 切断连接 → 即使邻居是 LAND 也不算 matched
				if def.center_kind != CENTER_LAND:
					matched = false
				if not matched:
					var oe := OpenEdge.new()
					oe.cell = c
					oe.edge = edge
					lr.open_edges.append(oe)
		lr.unit_count = unit
	return regions


# === water 群 DSU 合并（§3.3.1） ===

# §3.3.1 第 1 条：WATER 边对接 → 合并
# §3.3.1 第 2 条：IR 修饰边（不论 LAND 还是 WATER）→ 双参与
# §3.3.1 第 3 条：CENTER_LAKE 地块整体入水网
# §3.3.1 第 4 条：水渠边（BANK 改写）→ 按水口对待
# §3.3.1 第 5 条：RIVER 边 / CENTER_RIVER 不入水网
static func _build_water_dsu(board: BoardState, edge_table: Dictionary) -> DSU:
	var dsu := DSU.new()
	for cell in board.placements.keys():
		dsu.make(cell)

	# 边对边合并
	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		var rewrites: Array = placement.get("water_rewrite_at", [])

		for edge in range(4):
			var own_kind := def.edge_kind_at(edge, rotation)
			var own_ir: bool = def.ir_at(edge, rotation)
			var own_rewritten: bool = rewrites.has(edge)
			# 是否入 water 群？WATER / WATER+IR / (BANK + rewritten)
			var own_water := own_kind == KIND_WATER or (own_kind == KIND_BANK and own_rewritten)
			var own_ir_only := own_ir and own_kind == KIND_LAND  # LAND+IR 跨界
			if not (own_water or own_ir_only):
				continue
			var nb_cell := BS.neighbour_for_edge(cell, edge)
			if not board.has_tile(nb_cell):
				continue
			var nb_placement: Dictionary = board.get_placement(nb_cell)
			var nb_def: TileDefinition = nb_placement["definition"]
			var nb_rotation: int = int(nb_placement["rotation"])
			var nb_rewrites: Array = nb_placement.get("water_rewrite_at", [])
			var nb_edge := BS.opposite_edge(edge)
			var nb_kind := nb_def.edge_kind_at(nb_edge, nb_rotation)
			var nb_ir: bool = nb_def.ir_at(nb_edge, nb_rotation)
			var nb_rewritten: bool = nb_rewrites.has(nb_edge)
			var nb_water := nb_kind == KIND_WATER or (nb_kind == KIND_BANK and nb_rewritten)
			var nb_ir_only := nb_ir and nb_kind == KIND_LAND
			if not (nb_water or nb_ir_only):
				continue
			# 至少一侧是 WATER（或水渠）；IR-only 不与 IR-only 合并（无水流连通）
			# 但 IR-only 的 LAND+IR ↔ WATER+IR 或 WATER 是合法的跨界接口
			if own_water and nb_water:
				dsu.union(cell, nb_cell)
			elif own_water and nb_ir_only:
				dsu.union(cell, nb_cell)
			elif own_ir_only and nb_water:
				dsu.union(cell, nb_cell)
			# own_ir_only + nb_ir_only 不直接合并（但后续会通过外部 WATER 桥接）

	# CENTER_LAKE 自动入水网：把该格与至少一条"水口/IR/水渠"邻接的格合并
	# §3.3.1 第 3 条：中心 LAKE 地块"整体并入所连接的水网连通集合"
	# — 若该 LAKE 地块本身没有水边也没 IR 边，仍独自成一水网（id 唯一）
	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		if def.center_kind != CENTER_LAKE:
			continue
		var merged := false
		for edge in range(4):
			var nb_cell := BS.neighbour_for_edge(cell, edge)
			if not board.has_tile(nb_cell):
				continue
			var nb_placement: Dictionary = board.get_placement(nb_cell)
			var nb_def: TileDefinition = nb_placement["definition"]
			var nb_rotation: int = int(nb_placement["rotation"])
			var nb_rewrites: Array = nb_placement.get("water_rewrite_at", [])
			var nb_edge := BS.opposite_edge(edge)
			var nb_kind := nb_def.edge_kind_at(nb_edge, nb_rotation)
			var nb_ir: bool = nb_def.ir_at(nb_edge, nb_rotation)
			var nb_rewritten: bool = nb_rewrites.has(nb_edge)
			var nb_water := nb_kind == KIND_WATER or (nb_kind == KIND_BANK and nb_rewritten)
			if nb_water or nb_ir:
				dsu.union(cell, nb_cell)
				merged = true
				break
		# 即使没合并也保留独立水网（DSU 节点已存在）

	# 同地块内 water 子网合并（land_subnet_masks 不影响，但 water_subnet_masks 是辅助）
	# §3.3.1 第 1 条附加：地块内不同 water 边属于同一 water_subnet → 自动连通
	# 这里通过"land_subnet_connected / water_subnet_connected"协助判定。
	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		if def.water_subnets.size() < 2:
			continue
		# 同地块内属于同一 water_subnet 的所有水边 → 它们共用同一"内部连通的子图"
		# 由于 DSU 按格为节点而不是按边为节点，同地块内所有水边天然合并到同一水网
		# （它们都把 cell 加入同一个 DSU 集合）。无需额外 union。

	return dsu


static func _collect_water_nets(board: BoardState, dsu: DSU, edge_table: Dictionary) -> Array:
	var groups: Dictionary = {}
	for cell in board.placements.keys():
		# 跳过无水贡献的格子（无 WATER 边、无 IR 边、CENTER_LAND/CENTER_EMPTY + 无跨界接口）
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		var rewrites: Array = placement.get("water_rewrite_at", [])
		var has_water := def.center_kind == CENTER_LAKE  # 中心 LAKE 自动入水网
		if not has_water:
			for edge in range(4):
				var kind := def.edge_kind_at(edge, rotation)
				var ir: bool = def.ir_at(edge, rotation)
				var rewritten: bool = rewrites.has(edge)
				if kind == KIND_WATER or (kind == KIND_BANK and rewritten) or ir:
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

	# 填 open_edges + P_tile + P_canal
	# open_edges：未对接的水口 / IR / 水渠边界
	# P_tile：每地块取一档（§4.1.1）：CENTER_LAKE=3 / WATER/IR=1 / 0
	# P_canal：每条水渠边 +6
	for wn in nets:
		var tile_set: Dictionary = {}
		for c in wn.tiles:
			tile_set[c] = true
		for c in wn.tiles:
			var placement: Dictionary = board.get_placement(c)
			var def: TileDefinition = placement["definition"]
			var rotation: int = int(placement["rotation"])
			var rewrites: Array = placement.get("water_rewrite_at", [])
			# §4.1.1 优先级取档（中心 LAKE 优先）
			var tile_p := 0
			if def.center_kind == CENTER_LAKE:
				tile_p = 3
			elif def.edge_kind_at(NORTH, rotation) == KIND_WATER \
				or def.edge_kind_at(EAST, rotation) == KIND_WATER \
				or def.edge_kind_at(SOUTH, rotation) == KIND_WATER \
				or def.edge_kind_at(WEST, rotation) == KIND_WATER \
				or def.ir_at(NORTH, rotation) \
				or def.ir_at(EAST, rotation) \
				or def.ir_at(SOUTH, rotation) \
				or def.ir_at(WEST, rotation):
				tile_p = 1
			# 显式黑名单：RIVER 边 / CENTER_RIVER → 0（已默认）
			if def.center_kind == CENTER_RIVER:
				tile_p = 0
			wn.P_tile += tile_p

			# 水渠边：每条 +6
			for re_edge in rewrites:
				wn.P_canal += 6

			# open_edges：水口 / IR / 水渠边，对接后移除
			for edge in range(4):
				var kind := def.edge_kind_at(edge, rotation)
				var ir: bool = def.ir_at(edge, rotation)
				var rewritten: bool = rewrites.has(edge)
				var is_water_edge := kind == KIND_WATER or (kind == KIND_BANK and rewritten)
				var is_ir_only := ir and kind == KIND_LAND
				if not (is_water_edge or is_ir_only):
					continue
				var nb_cell := BS.neighbour_for_edge(c, edge)
				var matched := false
				if board.has_tile(nb_cell) and tile_set.has(nb_cell):
					var nb_placement: Dictionary = board.get_placement(nb_cell)
					var nb_def: TileDefinition = nb_placement["definition"]
					var nb_rotation: int = int(nb_placement["rotation"])
					var nb_rewrites: Array = nb_placement.get("water_rewrite_at", [])
					var nb_edge := BS.opposite_edge(edge)
					var nb_kind := nb_def.edge_kind_at(nb_edge, nb_rotation)
					var nb_ir: bool = nb_def.ir_at(nb_edge, nb_rotation)
					var nb_rewritten: bool = nb_rewrites.has(nb_edge)
					var nb_water := nb_kind == KIND_WATER or (nb_kind == KIND_BANK and nb_rewritten)
					if nb_water:
						matched = true
					elif nb_ir and nb_kind == KIND_LAND and is_water_edge:
						matched = true  # WATER ↔ LAND+IR 跨界接口
				if not matched:
					var oe := OpenEdge.new()
					oe.cell = c
					oe.edge = edge
					oe.canal = rewritten
					wn.open_edges.append(oe)
		wn.S_W = wn.P_tile + wn.P_canal
		wn.S_W_capped = wn.S_W
	return nets


# === 跨界灌溉接口（§3.3.3）===

# 把每个 water_net 与其灌溉到的 land_region 关联；
# 同一 land_region 对同一 water_net 只算 1 次（§4.5）。
static func _link_irrigation(board: BoardState, edge_table: Dictionary, land_regions: Array, water_nets: Array) -> void:
	# 建索引：cell -> LandRegion, cell -> WaterNet
	var cell_to_lr: Dictionary = {}
	for lr in land_regions:
		for c in lr.cells:
			cell_to_lr[c] = lr
	var cell_to_wn: Dictionary = {}
	for wn in water_nets:
		for c in wn.tiles:
			cell_to_wn[c] = wn

	for cell in board.placements.keys():
		var placement: Dictionary = board.get_placement(cell)
		var def: TileDefinition = placement["definition"]
		var rotation: int = int(placement["rotation"])
		var rewrites: Array = placement.get("water_rewrite_at", [])
		var lr: LandRegion = cell_to_lr.get(cell, null)
		var wn: WaterNet = cell_to_wn.get(cell, null)
		if lr == null or wn == null:
			continue
		for edge in range(4):
			var ir: bool = def.ir_at(edge, rotation)
			if not ir:
				continue
			var kind := def.edge_kind_at(edge, rotation)
			# §3.3.3：含 IR 的边作为 land ↔ water 接口
			if kind == KIND_LAND:
				lr.irrigated_water_net_ids[wn.id] = true
			elif kind == KIND_WATER:
				# WATER+IR 跨界接口：land 侧来自邻格，water 侧来自本格
				# 邻格的 LAND+IR 边 / LAND 边对接 → 该邻格的 land_region 接收本水网
				var nb_cell := BS.neighbour_for_edge(cell, edge)
				if not board.has_tile(nb_cell):
					continue
				var nb_placement: Dictionary = board.get_placement(nb_cell)
				var nb_def: TileDefinition = nb_placement["definition"]
				var nb_rotation: int = int(nb_placement["rotation"])
				var nb_edge := BS.opposite_edge(edge)
				var nb_kind := nb_def.edge_kind_at(nb_edge, nb_rotation)
				var nb_lr: LandRegion = cell_to_lr.get(nb_cell, null)
				if nb_kind == KIND_LAND and nb_lr != null:
					nb_lr.irrigated_water_net_ids[wn.id] = true
			# BANK+IR 不存在（IR 不允许修饰 BANK / RIVER）
		# CENTER_LAKE 的整体入水网：lake 地块若有 land 边配 LAND+IR，会通过上面的 LAND 边循环命中
		# 但 CENTER_LAKE 地块本身不在 land_region（除非它的 LAND 边连到 CENTER_LAND 地块已合并）
		# —— 见 §3.3.2：只有 CENTER_LAND ↔ CENTER_LAND 才合并 land_region；
		# CENTER_LAKE ↔ CENTER_LAND 不合并，所以 lake 的 land 边不进入邻 land_region。
		# 这种情况：lake 的 LAND 边需要单独作为"land_region"——目前不在主流程里。
		# 已知影响：当前数据没有"CENTER_LAKE + LAND 边"组合（修道院之湖是空边），可忽略。


# === 供水计算 + 全封闭判定 ===

static func _compute_supply_and_closure(land_regions: Array, water_nets: Array) -> void:
	# §4.4：V_L = Σ S_{K_i}（按 land_region 关联的所有水网容量求和，无封顶）
	for lr in land_regions:
		var s := 0.0
		for wn_id in lr.irrigated_water_net_ids.keys():
			for wn in water_nets:
				if wn.id == int(wn_id):
					s += float(wn.S_W)
					break
		lr.S_L = s
		# §5.6.1 land 边全封闭 = open_edges 全部对接
		lr.is_closed = lr.open_edges.is_empty()

	# §5.6.1 水网全封闭 = open_edges 全部对接
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

# 给定一个即将落下的地块 + 已放置棋盘，返回本放置产生的所有"待改写边"列表
# 每条记录 {cell: Vector2i, edge: int} —— 表示该格的 edge 应被永久改写为水口
static func detect_pending_rewrites(board: BoardState, definition: TileDefinition, cell: Vector2i, quarter_turns: int) -> Array:
	var pending: Array = []
	if definition == null:
		return pending
	for edge in range(4):
		var nb_cell := BS.neighbour_for_edge(cell, edge)
		if not board.has_tile(nb_cell):
			continue
		var own_kind := definition.edge_kind_at(edge, quarter_turns)
		var nb_placement: Dictionary = board.get_placement(nb_cell)
		var nb_def: TileDefinition = nb_placement["definition"]
		var nb_rotation: int = int(nb_placement["rotation"])
		var nb_edge := BS.opposite_edge(edge)
		var nb_kind := nb_def.edge_kind_at(nb_edge, nb_rotation)
		# §3.2 / §3.6：方向 A 我方河流 BANK ↔ 邻方水口
		var cond_a := definition.is_river_tile and own_kind == KIND_BANK \
			and (nb_kind == KIND_WATER)
		# 方向 B：邻方河流 BANK ↔ 我方水口
		var cond_b := nb_def.is_river_tile and nb_kind == KIND_BANK \
			and (own_kind == KIND_WATER)
		if cond_a or cond_b:
			if cond_a:
				pending.append({"cell": cell, "edge": edge})
			if cond_b:
				pending.append({"cell": nb_cell, "edge": nb_edge})
	return pending