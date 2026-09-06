class_name BoardState
extends RefCounted

const RE := preload("res://scripts/rule_engine.gd")
const PD := preload("res://scripts/plant.gd")

# 规则书 §7 回合流程状态机
# 全手动推进：DEAL → PLACE → ACTION_WINDOW → 跑 PE.settle + 切玩家 → DEAL
# 牌堆空了 → 进入 GAME_OVER，等手动触发 end_game_settle + score + resolve_winner
enum Phase { DEAL, PLACE, ACTION_WINDOW, GAME_OVER }
var phase: int = Phase.DEAL
var active_player: int = 0
var turn_number: int = 1
var tile_to_place = null                       # 抽到待放的 TileDefinition 或 null
var discarded_tiles: Array[TileDefinition] = [] # 仅记录主牌堆中无合法落点而弃置的地块
var turn_placed_cells: Array[Vector2i] = []    # 当前玩家本回合已放置：主动种植的唯一候选
var planting_action_used := false               # §7.2.2：每回合至多主动种植一次

# BoardState is the rule authority for tile placement. Visual nodes only read
# the records stored here; they never decide whether a move is legal.
var placements: Dictionary = {}

# 玩家植物 / 种子库存（规则书 §5.1）
# 规则书 §5.1：每位玩家独立的种子集合，扩张/种植消耗 1 枚对应种类；§5.6 全封闭退还 1 枚对应种类
# 规则书 §7.1.1：开局草/花/树各 2 枚（共 6 枚）
var plants: Dictionary = {}                  # plant_id (int) -> Plant
var seed_inventory: Dictionary = {}          # player_id (int) -> { Species: count }
var next_plant_id: int = 0
var next_planting_order: int = 0             # §5.8：同种竞争 / 分水使用的稳定先后顺序
var locked_region_keys: Dictionary = {}      # §5.6.1：已收获锁定的 land_region 稳定 key -> true
var player_count: int = 2
const INITIAL_SEEDS_PER_SPECIES: int = 2     # §7.1.1


# starter：起手地块；player_count：本局游玩人数（默认 2，兼容旧调用方）。
# 人数由开始页面 GameConfig 传入；规则层不感知“颜色”，颜色只是视觉层的事。
func start_with(starter: TileDefinition, player_count: int = 2) -> void:
	placements.clear()
	_reset_plants(maxi(2, player_count))
	locked_region_keys.clear()
	placements[Vector2i.ZERO] = _record(starter, 0, -1)
	active_player = 0
	turn_number = 1
	phase = Phase.DEAL
	tile_to_place = null
	discarded_tiles.clear()
	turn_placed_cells.clear()
	planting_action_used = false
	next_planting_order = 0


# === §7 回合流程接口（每个由 main.gd 在玩家手动触发时调用） ===

# 抽牌：把 definition 当作本回合的"待放地块"分给 active_player，进入 PLACE
func deal_tile(definition: TileDefinition) -> Dictionary:
	if phase != Phase.DEAL:
		return _verdict(false, "当前阶段不应抽牌（当前 phase=%d）。" % int(phase))
	if definition == null:
		return _verdict(false, "牌堆已空。")
	tile_to_place = definition
	phase = Phase.PLACE
	planting_action_used = false
	return _verdict(true, "已抽牌，进入放置阶段。")


# 主牌堆的无解弃牌：规则层完整复查全棋盘的所有相邻空格与 90° 朝向，
# 因而 UI 不能借“弃牌重抽”筛掉仍可放置的地块。弃牌不结束当前玩家的回合；
# 调用方消费当前牌后，可继续从主牌堆抽下一张。
func discard_unplaceable_tile(deck_is_empty: bool) -> Dictionary:
	if phase != Phase.PLACE:
		return _verdict(false, "当前阶段不应弃牌（当前 phase=%d）。" % int(phase))
	if tile_to_place == null:
		return _verdict(false, "当前没有待处理的地块。")
	var discarded: TileDefinition = tile_to_place
	if discarded.card_type != TileDefinition.CARD_TILE or discarded.is_river_tile:
		return _verdict(false, "只有主牌堆的普通地块可以弃牌重抽。")
	if has_any_legal_placement(discarded):
		return _verdict(false, "这张地块仍有合法放置位置，不能弃牌重抽。")
	discarded_tiles.append(discarded)
	tile_to_place = null
	turn_placed_cells.clear()
	planting_action_used = false
	phase = Phase.GAME_OVER if deck_is_empty else Phase.DEAL
	var result := _verdict(true, "当前地块无合法位置，已弃置。")
	result["discarded_tile"] = discarded
	result["deck_exhausted"] = deck_is_empty
	return result


# 放置（manual by active_player 点空格）
# —— 一次性动作：放成功后自动进入 ACTION_WINDOW 并清空 tile_to_place，
#    玩家不能再用同一张待放块重复放置（卡卡颂原版规则）。
func commit_placement(cell: Vector2i, quarter_turns: int) -> Dictionary:
	if phase != Phase.PLACE:
		return _verdict(false, "当前阶段不应放置（当前 phase=%d）。" % int(phase))
	if tile_to_place == null:
		return _verdict(false, "当前回合没有待放地块。")
	var result := place(tile_to_place, cell, quarter_turns, active_player)
	if not bool(result["valid"]):
		return result
	turn_placed_cells.append(cell)
	# 一次性消费：吃完这块就进入动作窗口
	tile_to_place = null
	phase = Phase.ACTION_WINDOW
	return result


# 河流长牌专用放置：它与普通回合共用边口和河流组件校验，但不会打开
# 种植／结算窗口，也不会触发自动扩张或物种驱逐。成功后立即轮到下一位
# 玩家继续处理河流牌堆。
func commit_river_setup_placement(cell: Vector2i, quarter_turns: int) -> Dictionary:
	if phase != Phase.PLACE:
		return _verdict(false, "当前阶段不应放置河流牌（当前 phase=%d）。" % int(phase))
	if tile_to_place == null:
		return _verdict(false, "当前没有待放的河流牌。")
	var river_tile: TileDefinition = tile_to_place
	if not river_tile.is_river_tile or river_tile.card_type != TileDefinition.CARD_RIVER:
		return _verdict(false, "长牌阶段只能放置中心河流地块。")
	var result := _place(river_tile, cell, quarter_turns, active_player, false)
	if not bool(result["valid"]):
		return result
	_advance_river_setup_turn()
	result["river_setup"] = true
	return result


# 长牌阶段只有在当前河流牌没有任何合法位置时才能跳过。合法位置只可能
# 出现在既有棋盘的相邻空格，因此在规则层即可完整检索，不把该约束留给 UI。
func skip_unplaceable_river_setup_tile() -> Dictionary:
	if phase != Phase.PLACE:
		return _verdict(false, "当前阶段不应跳过河流牌（当前 phase=%d）。" % int(phase))
	if tile_to_place == null:
		return _verdict(false, "当前没有待处理的河流牌。")
	var river_tile: TileDefinition = tile_to_place
	if not river_tile.is_river_tile or river_tile.card_type != TileDefinition.CARD_RIVER:
		return _verdict(false, "只有河流长牌可以在此阶段跳过。")
	if has_any_legal_placement(river_tile):
		return _verdict(false, "这张河流牌仍有合法放置位置，不能跳过。")
	_advance_river_setup_turn()
	return _verdict(true, "河流牌无合法位置，已跳过。")


# 结束放置阶段（手动按"完成放置"按钮）→ 进入 ACTION_WINDOW
# —— 现在已经由 commit_placement 自动完成；保留此函数兼容旧调用方，
#    若当前已经不在 PLACE 阶段则返回 valid=true 的幂等响应。
func finish_placement() -> Dictionary:
	if phase == Phase.ACTION_WINDOW:
		return _verdict(true, "已在动作窗口（commit_placement 已自动完成）。")
	if phase != Phase.PLACE:
		return _verdict(false, "当前不在放置阶段。")
	phase = Phase.ACTION_WINDOW
	return _verdict(true, "进入动作窗口。")


# 结束动作窗口（手动点"回合结束"） → PE.settle + 切玩家 + 回 DEAL 或 GAME_OVER
# deck_is_empty：调用方（main.gd）从 deck_index >= deck.size() 算出来传进来
# 结束动作窗口（手动点"回合结束"） → PE.settle + 切玩家 + 回 DEAL 或 GAME_OVER
# deck_is_empty：调用方（main.gd）从 deck_index >= deck.size() 算出来传进来
# plant_engine_script：传预加载的 PlantEngine.gd 常量（Script），内部用静态方法调用
func finish_action_window(plant_engine_script, deck_is_empty: bool) -> Dictionary:
	if phase != Phase.ACTION_WINDOW:
		return _verdict(false, "当前不在动作窗口。")
	var pa = plant_engine_script.settle(self)
	active_player = int(posmod(active_player + 1, player_count))
	turn_number += 1
	turn_placed_cells.clear()
	planting_action_used = false
	tile_to_place = null
	if deck_is_empty:
		phase = Phase.GAME_OVER
	else:
		phase = Phase.DEAL
	return {"valid": true, "reason": "回合已结算。", "plant_analysis": pa}


# 终局：跑 §5.7 终局升级 + §6 计分 + 决胜，由 main.gd 在 GAME_OVER 时手动触发
func run_end_game(plant_engine_script) -> Dictionary:
	if phase != Phase.GAME_OVER:
		return _verdict(false, "游戏未到终局阶段。")
	var pa = plant_engine_script.end_game_settle(self)
	var sc = plant_engine_script.score(self)
	var w = plant_engine_script.resolve_winner(sc, player_count)
	return {"valid": true, "reason": "终局已结算。", "plant_analysis": pa, "score_result": sc, "winner": w}


# 本回合当前玩家刚放置的格列表（供主动种植、流程与视觉使用）。
func is_turn_placed(cell: Vector2i) -> bool:
	for c in turn_placed_cells:
		if c == cell:
			return true
	return false


# 把 plants / seed_inventory 重置回开局状态；不破坏 placements（由调用方按需清空）
func _reset_plants(new_player_count: int) -> void:
	plants.clear()
	seed_inventory.clear()
	next_plant_id = 0
	player_count = new_player_count
	for player_id in range(player_count):
		seed_inventory[player_id] = {
			PD.Species.GRASS: INITIAL_SEEDS_PER_SPECIES,
			PD.Species.FLOWER: INITIAL_SEEDS_PER_SPECIES,
			PD.Species.TREE: INITIAL_SEEDS_PER_SPECIES,
		}


# 给指定玩家补一份开局种子（默认 3 物种各 INITIAL_SEEDS_PER_SPECIES）
# —— 不重置已有库存，可在测试中初始化扩展玩家数场景
func initialize_player_seeds(player_id: int, seeds_per_species: int = INITIAL_SEEDS_PER_SPECIES) -> void:
	seed_inventory[player_id] = {
		PD.Species.GRASS: seeds_per_species,
		PD.Species.FLOWER: seeds_per_species,
		PD.Species.TREE: seeds_per_species,
	}


func has_tile(cell: Vector2i) -> bool:
	return placements.has(cell)


func get_placement(cell: Vector2i) -> Dictionary:
	return placements.get(cell, {})


# 可放位置一定紧贴现有地图；不需要扫描无限棋盘。这个查询同时使用
# can_place，因此会包含 WATER 和全局 RIVER 连通等全部规则。
func has_any_legal_placement(definition: TileDefinition) -> bool:
	if definition == null:
		return false
	if placements.is_empty():
		return bool(can_place(definition, Vector2i.ZERO, 0)["valid"])
	for occupied_cell in occupied_cells():
		for edge in range(4):
			var candidate_cell := neighbour_for_edge(occupied_cell, edge)
			if has_tile(candidate_cell):
				continue
			for rotation in range(4):
				if bool(can_place(definition, candidate_cell, rotation)["valid"]):
					return true
	return false


func can_place(definition: TileDefinition, cell: Vector2i, quarter_turns: int) -> Dictionary:
	if definition == null:
		return _verdict(false, "当前没有可放置的地块。")
	if not definition.is_playable():
		return _verdict(false, "这张地块的灌溉定义无效。")
	if has_tile(cell):
		return _verdict(false, "该位置已经有地块。")

	var touching_neighbours := 0
	for edge in range(4):
		var neighbour_cell := neighbour_for_edge(cell, edge)
		if not has_tile(neighbour_cell):
			continue

		touching_neighbours += 1
		var neighbour := get_placement(neighbour_cell)
		var neighbour_definition: TileDefinition = neighbour["definition"]
		var own_marker := definition.edge_kind_at(edge, quarter_turns)
		var neighbour_marker := neighbour_definition.edge_kind_at(
			opposite_edge(edge),
			int(neighbour["rotation"]),
		)
		if not _edges_compatible(own_marker, neighbour_marker):
			return _verdict(false, "%s为%s，但相接边为%s。" % [
				edge_label(edge),
				TileDefinition.edge_kind_label(own_marker),
				TileDefinition.edge_kind_label(neighbour_marker),
			])

	if not placements.is_empty() and touching_neighbours == 0:
		return _verdict(false, "新地块必须至少与现有地图的一条边相接。")
	if definition.is_river_tile and not _river_component_remains_single(definition, cell, quarter_turns):
		return _verdict(false, "河流必须接入当前唯一的连通河流，不能形成孤立河段。")

	return _verdict(true, "所有相接的边口都匹配。")


# 规则书 §3.2 边拼接兼容判定（v17）
# - 同基础地形对接合法（LAND↔LAND / WATER↔WATER / EMPTY↔EMPTY / RIVER↔RIVER）
# - 其余组合非法
static func _edges_compatible(own: int, neighbour: int) -> bool:
	return own == neighbour


func place(definition: TileDefinition, cell: Vector2i, quarter_turns: int, player_id: int) -> Dictionary:
	return _place(definition, cell, quarter_turns, player_id, true)


# 普通回合和河流长牌共享落子记录、边口校验与水网刷新前置数据，但只有
# 普通回合会进入植物事件。运行时美术仍只读取已落定的固定预制件记录。
func _place(definition: TileDefinition, cell: Vector2i, quarter_turns: int, player_id: int, trigger_plant_events: bool) -> Dictionary:
	var result := can_place(definition, cell, quarter_turns)
	if not bool(result["valid"]):
		return result
	# v17：无 CANAL/水渠，不存在永久改写；detect_pending_rewrites 恒空，不产生 water_rewrite_at
	var rewrites := RE.detect_pending_rewrites(self, definition, cell, quarter_turns)
	placements[cell] = _record(definition, quarter_turns, player_id, rewrites)
	if trigger_plant_events:
		# §5.4.2：放牌后，直接相邻且 LAND 真正连通的已有植物会无消耗自动扩张。
		# 这发生在玩家主动种植之前，且不会占用本回合的种植动作。
		result["automatic_expansion"] = _apply_automatic_expansion(cell)
		# §5.4.1：本次拼接可能把原本分离、且各有不同物种的土地块合并。
		# 立即按树 > 花 > 草驱逐，不把冲突拖到回合结算。
		result["species_conflict"] = _resolve_species_conflicts()
	else:
		result["automatic_expansion"] = {}
		result["species_conflict"] = {"evicted_plant_ids": [], "changed_cells": []}
	return result


func _advance_river_setup_turn() -> void:
	active_player = int(posmod(active_player + 1, player_count))
	turn_number += 1
	turn_placed_cells.clear()
	planting_action_used = false
	tile_to_place = null
	phase = Phase.DEAL


# 规则书 §2.4.4：任意时刻所有 RIVER 边只能属于一个全局河流组件。
# CENTER_RIVER 代表同一张河流牌内的所有 RIVER 口已经连通；图上的节点
# 因而是“带至少一个 RIVER 边的地块”，相邻 RIVER↔RIVER 才形成图边。
func _river_component_remains_single(candidate: TileDefinition, candidate_cell: Vector2i, candidate_rotation: int) -> bool:
	var river_cells: Dictionary = {}
	for placed_cell in placements.keys():
		var placement: Dictionary = get_placement(placed_cell)
		var placed_definition: TileDefinition = placement["definition"]
		if _definition_has_river_port(placed_definition, int(placement["rotation"])):
			river_cells[placed_cell] = true
	if _definition_has_river_port(candidate, candidate_rotation):
		river_cells[candidate_cell] = true
	if river_cells.size() <= 1:
		return true

	var start_cell: Vector2i = river_cells.keys()[0]
	var visited: Dictionary = {start_cell: true}
	var queue: Array[Vector2i] = [start_cell]
	while not queue.is_empty():
		var current_cell: Vector2i = queue.pop_front()
		for edge in range(4):
			var neighbour_cell := neighbour_for_edge(current_cell, edge)
			if not river_cells.has(neighbour_cell) or visited.has(neighbour_cell):
				continue
			if not _river_cells_connect(current_cell, neighbour_cell, edge, candidate, candidate_cell, candidate_rotation):
				continue
			visited[neighbour_cell] = true
			queue.append(neighbour_cell)
	return visited.size() == river_cells.size()


func _river_cells_connect(first_cell: Vector2i, second_cell: Vector2i, first_edge: int, candidate: TileDefinition, candidate_cell: Vector2i, candidate_rotation: int) -> bool:
	return _river_edge_at(first_cell, first_edge, candidate, candidate_cell, candidate_rotation) \
		and _river_edge_at(second_cell, opposite_edge(first_edge), candidate, candidate_cell, candidate_rotation)


func _river_edge_at(cell: Vector2i, edge: int, candidate: TileDefinition, candidate_cell: Vector2i, candidate_rotation: int) -> bool:
	if cell == candidate_cell:
		return candidate.edge_kind_at(edge, candidate_rotation) == TileDefinition.EdgeKind.RIVER
	var placement: Dictionary = get_placement(cell)
	if placement.is_empty():
		return false
	var definition: TileDefinition = placement["definition"]
	return definition.edge_kind_at(edge, int(placement["rotation"])) == TileDefinition.EdgeKind.RIVER


static func _definition_has_river_port(definition: TileDefinition, rotation: int) -> bool:
	if definition == null:
		return false
	for edge in range(4):
		if definition.edge_kind_at(edge, rotation) == TileDefinition.EdgeKind.RIVER:
			return true
	return false


func owned_tile_count(player_id: int) -> int:
	var count := 0
	for placement in placements.values():
		if int(placement["owner_id"]) == player_id:
			count += 1
	return count


func occupied_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for cell in placements.keys():
		cells.append(cell)
	cells.sort_custom(func(first: Vector2i, second: Vector2i) -> bool:
		if first.y == second.y:
			return first.x < second.x
		return first.y < second.y
	)
	return cells


# === 植物 API（规则书 §5.1 / §5.8 / §7.2.2.A） ===

# 列出指定玩家所有已放置的植物 id（按 species 顺序：草→花→树，再按 tile_cell 排序）。
# 自动扩张会从这类既有植物中选择直接相邻、土地连通的来源。
func plants_owned_by(player_id: int) -> Array:
	var out: Array = []
	for plant_id in plants:
		var p: Plant = plants[plant_id]
		if int(p.owner) == player_id:
			out.append(p)
	out.sort_custom(func(a: Plant, b: Plant) -> bool:
		if a.species != b.species:
			return a.species < b.species
		if a.tile_cell.y == b.tile_cell.y:
			return a.tile_cell.x < b.tile_cell.x
		return a.tile_cell.y < b.tile_cell.y
	)
	return out


# 目标格一旦有任意植物即被占据——这是"格级"查询，仅供 UI 渲染/旧调用方使用。
# 规则层（§5.1）的种植占用判定以"一个 land_region 一株"为准，见 region_has_any_plant。
func tile_has_any_plant(tile: Vector2i) -> bool:
	for plant_id in plants:
		var p: Plant = plants[plant_id]
		if p.tile_cell == tile:
			return true
	return false


# §5.1「一个 land_region 一株」：目标格的目标地块（land 子网）是否已有任何植物。
# 用 (tile_cell, land_subnet_idx) 精确定位到"格内的第几块地"——split 卡一格多块地时，
# 每块地独立判定占用，同一格的其他块地不受影响。
func region_has_any_plant(tile: Vector2i, subnet_idx: int) -> bool:
	for plant_id in plants:
		var p: Plant = plants[plant_id]
		if p.tile_cell == tile and int(p.land_subnet_idx) == subnet_idx:
			return true
	return false


# 保留给旧调用方的物种级查询；新的主动种植合法性不再使用它。
func tile_has_species(tile: Vector2i, species: int) -> bool:
	for plant_id in plants:
		var p: Plant = plants[plant_id]
		if p.tile_cell == tile and int(p.species) == species:
			return true
	return false

# §5.8 / §7.2.2.A 种植合法性前置检查：
#   1. 只能在本回合"放置完成"后的动作窗口由当前玩家主动种植；
#   2. 目标必须是该玩家本回合刚放置的地块；
#   3. 目标格必须含可种植 LAND，且目标"地块"（land_region）没有任何植物；
#   4. 当前玩家必须还有所选物种种子；
#   5. 每回合最多一次主动种植。
# subnet_idx 指定种格内哪一块地（§5.1 split 卡）；-1 表示"任选一块可种的地块"，
# 返回的 verdict 附带实际选中的 subnet_idx（见 result["subnet_idx"]）。
func can_plant_at(target_cell: Vector2i, species: int, owner: int, subnet_idx: int = -1) -> Dictionary:
	if phase != Phase.ACTION_WINDOW:
		return _verdict(false, "请先完成本回合的地块放置，再种植。")
	if owner != active_player:
		return _verdict(false, "只能由当前回合玩家主动种植。")
	if not has_tile(target_cell):
		return _verdict(false, "目标格尚未放置地块。")
	var placement := get_placement(target_cell)
	if not is_turn_placed(target_cell) or int(placement.get("owner_id", -1)) != owner:
		return _verdict(false, "本回合只能在自己刚放置的地块种植。")
	if planting_action_used:
		return _verdict(false, "本回合已经种植过；可结束回合。")
	var entries := land_subnet_entries_at(target_cell)
	if entries.is_empty():
		return _verdict(false, "目标格不属于任何土地块（无可种植空间）。")
	if not _has_seed(owner, species):
		return _verdict(false, "该物种种子已耗尽。")
	# 选定目标地块：显式指定则校验，未指定则自动选第一块可种的地。
	if subnet_idx >= 0:
		var found := false
		for entry in entries:
			if int(entry["subnet_idx"]) == subnet_idx:
				found = true
				break
		if not found:
			return _verdict(false, "目标格没有第 %d 块土地。" % subnet_idx)
		if region_has_any_plant(target_cell, subnet_idx):
			return _verdict(false, "该块土地已经有植物占据。")
		if _subnet_locked(target_cell, subnet_idx):
			return _verdict(false, "该块土地已收获锁定，不可再种植。")
		return _verdict(true, "种植合法。", subnet_idx)
	# 未指定：找一个可种的地块。
	for entry in entries:
		var idx := int(entry["subnet_idx"])
		if region_has_any_plant(target_cell, idx):
			continue
		if _subnet_locked(target_cell, idx):
			continue
		return _verdict(true, "种植合法。", idx)
	return _verdict(false, "目标格的所有土地块都已被占据或锁定。")


func can_plant_any_species_at(target_cell: Vector2i, owner: int, subnet_idx: int = -1) -> Dictionary:
	for species in [PD.Species.GRASS, PD.Species.FLOWER, PD.Species.TREE]:
		var check := can_plant_at(target_cell, species, owner, subnet_idx)
		if bool(check["valid"]):
			return check
	return can_plant_at(target_cell, PD.Species.GRASS, owner, subnet_idx)


# §7.2.2.A 种植动作：从 owner 扣除 1 枚对应种类种子，在 target_cell 的指定地块上种一棵 species。
# §5.1「一个 land_region 一株 / split 卡每块地独立」：一次种植只在一块地落 1 株。
# subnet_idx 指定种哪块地（-1 = 由 can_plant_at 自动选第一块可种的地）。
# 初始形态置 §5.3 的存活状态；水量只在闭合结算窗口处理。
func plant(target_cell: Vector2i, species: int, owner: int, subnet_idx: int = -1) -> Dictionary:
	var check := can_plant_at(target_cell, species, owner, subnet_idx)
	if not bool(check["valid"]):
		return check
	# 未显式指定地块时，采用 can_plant_at 返回的自动选中地块。
	var resolved_idx := subnet_idx
	if resolved_idx < 0:
		resolved_idx = int(check.get("subnet_idx", -1))
	_consume_seed(owner, species)
	var entry: Dictionary = {}
	for e in land_subnet_entries_at(target_cell):
		if int(e["subnet_idx"]) == resolved_idx:
			entry = e
			break
	if entry.is_empty():
		return _verdict(false, "目标格没有第 %d 块土地。" % resolved_idx)
	var p := Plant.new()
	p.id = next_plant_id
	next_plant_id += 1
	p.species = species
	p.owner = owner
	p.tile_cell = target_cell
	p.form = Plant.Form.SURVIVING
	p.seed_committed = true
	p.land_subnet_idx = int(entry["subnet_idx"])
	p.land_region_id = int(entry["region"].id)
	p.expansion_order = next_planting_order
	next_planting_order += 1
	plants[p.id] = p
	planting_action_used = true
	# 主动种植和放置新地块是自动扩张的两个唯一触发时机。这里仅以
	# 本次种下的植物为源，向其直接相邻且真正 LAND 连通的既有地块扩张；
	# 不把刚生成的扩张株再次作为源，避免一次种植递归填满整片地图。
	var automatic_expansions := _expand_plant_to_direct_land_neighbours(p)
	return {
		"valid": true,
		"reason": "已种植",
		"plant_id": int(p.id),
		"plant_ids": [int(p.id)],
		"subnet_idx": int(p.land_subnet_idx),
		"automatic_expansions": automatic_expansions,
		"species_conflict": _resolve_species_conflicts(),
	}


# §5.4.2 自动扩张：只考察新地块的直接相邻格。CENTER_EMPTY 仅让同一
# 地块内的 land 边分区；一条贴合的 LAND↔LAND 接缝依旧连接各自命中的子网。
func _apply_automatic_expansion(target_cell: Vector2i) -> Dictionary:
	var candidates_by_target_subnet: Dictionary = {}
	for edge in range(4):
		if not _direct_land_connection_at(target_cell, edge):
			continue
		var source_cell := neighbour_for_edge(target_cell, edge)
		var target_subnet_idx := _land_subnet_index_at(target_cell, edge)
		var source_subnet_idx := _land_subnet_index_at(source_cell, opposite_edge(edge))
		if target_subnet_idx < 0 or source_subnet_idx < 0:
			continue
		if region_has_any_plant(target_cell, target_subnet_idx):
			continue
		for source_plant in list_plants_in_tile(source_cell):
			if int(source_plant.land_subnet_idx) != source_subnet_idx:
				continue
			if not candidates_by_target_subnet.has(target_subnet_idx):
				candidates_by_target_subnet[target_subnet_idx] = []
			(candidates_by_target_subnet[target_subnet_idx] as Array).append(source_plant)
	if candidates_by_target_subnet.is_empty():
		return {}

	var target_subnet_indices: Array = candidates_by_target_subnet.keys()
	target_subnet_indices.sort()
	var expansions: Array = []
	var created_ids: Array = []
	for target_subnet_idx in target_subnet_indices:
		var candidates: Array = candidates_by_target_subnet[target_subnet_idx]
		candidates.sort_custom(func(a: Plant, b: Plant) -> bool:
			if int(a.species) != int(b.species):
				return int(a.species) > int(b.species) # 树 > 花 > 草
			var a_order := int(a.expansion_order)
			var b_order := int(b.expansion_order)
			if a_order != b_order:
				return a_order < b_order
			return int(a.id) < int(b.id)
		)
		var expansion := _create_automatic_expansion(candidates[0], target_cell, int(target_subnet_idx))
		if expansion.is_empty():
			continue
		expansions.append(expansion)
		for plant_id in expansion.get("plant_ids", []):
			created_ids.append(int(plant_id))
	if expansions.is_empty():
		return {}
	var first_expansion: Dictionary = expansions[0]
	return {
		"plant_id": int(first_expansion["plant_id"]),
		"plant_ids": created_ids,
		"source_plant_id": int(first_expansion["source_plant_id"]),
		"owner": int(first_expansion["owner"]),
		"species": int(first_expansion["species"]),
		"target_cell": target_cell,
		"expansions": expansions,
	}


# 目标格是否还有至少一块未种植的土地（land 子网）。§5.1「一个 region 一株」。
func _tile_has_empty_region(cell: Vector2i) -> bool:
	for entry in land_subnet_entries_at(cell):
		if not region_has_any_plant(cell, int(entry["subnet_idx"])):
			return true
	return false


# 主动种植后的自动扩张：只检查源植物所在格的四个直接邻居。
# 这使“种植时扩张”与“新地块紧邻已有植物时扩张”共用同一 LAND 连通判定，
# 同时严格保持一跳传播，避免在一个事件里递归扩张。
func _expand_plant_to_direct_land_neighbours(source: Plant) -> Array:
	var expansions: Array = []
	if source == null:
		return expansions
	for edge in range(4):
		if not _direct_land_connection_at(source.tile_cell, edge):
			continue
		if _land_subnet_index_at(source.tile_cell, edge) != int(source.land_subnet_idx):
			continue
		var target_cell := neighbour_for_edge(source.tile_cell, edge)
		var target_subnet_idx := _land_subnet_index_at(target_cell, opposite_edge(edge))
		if target_subnet_idx < 0 or region_has_any_plant(target_cell, target_subnet_idx):
			continue
		var expansion := _create_automatic_expansion(source, target_cell, target_subnet_idx)
		if not expansion.is_empty():
			expansions.append(expansion)
	return expansions


# 两个扩张触发器共用的无种子克隆步骤。调用方已经确认 target_cell
# 是直接 LAND 连通的空地块；这里仍保留基础防护，避免测试或未来调用方
# 绕过该契约后覆盖已有植物。
# §5.4.2(6)：多土地地块（split 卡）自动扩张只写入真正通过当前 LAND
# 接缝连到源植物的目标子网，绝不把同格的其它独立土地块一并占满。
func _create_automatic_expansion(source: Plant, target_cell: Vector2i, target_subnet_idx: int = -1) -> Dictionary:
	if source == null or not has_tile(target_cell):
		return {}
	var entries := land_subnet_entries_at(target_cell)
	if entries.is_empty():
		return {}
	var created_ids: Array = []
	var first_id := -1
	for entry in entries:
		var subnet_idx := int(entry["subnet_idx"])
		if target_subnet_idx >= 0 and subnet_idx != target_subnet_idx:
			continue
		if region_has_any_plant(target_cell, subnet_idx):
			continue
		var expanded := Plant.new()
		expanded.id = next_plant_id
		next_plant_id += 1
		expanded.species = int(source.species)
		expanded.owner = int(source.owner)
		expanded.tile_cell = target_cell
		expanded.form = Plant.Form.SURVIVING
		expanded.seed_committed = false
		expanded.land_subnet_idx = subnet_idx
		expanded.land_region_id = int(entry["region"].id)
		expanded.expansion_order = next_planting_order
		plants[expanded.id] = expanded
		created_ids.append(expanded.id)
		if first_id < 0:
			first_id = int(expanded.id)
	if created_ids.is_empty():
		return {}
	next_planting_order += 1
	return {
		"plant_id": first_id,
		"plant_ids": created_ids,
		"source_plant_id": int(source.id),
		"owner": int(source.owner),
		"species": int(source.species),
		"target_cell": target_cell,
	}


func _direct_land_connection_at(cell: Vector2i, edge: int) -> bool:
	if not has_tile(cell):
		return false
	var neighbour_cell := neighbour_for_edge(cell, edge)
	if not has_tile(neighbour_cell):
		return false
	var placement := get_placement(cell)
	var definition: TileDefinition = placement["definition"]
	var rotation := int(placement["rotation"])
	var neighbour := get_placement(neighbour_cell)
	var neighbour_definition: TileDefinition = neighbour["definition"]
	var neighbour_rotation := int(neighbour["rotation"])
	if definition.edge_kind_at(edge, rotation) != TileDefinition.EdgeKind.LAND:
		return false
	if neighbour_definition.edge_kind_at(opposite_edge(edge), neighbour_rotation) != TileDefinition.EdgeKind.LAND:
		return false
	return _land_subnet_index_at(cell, edge) >= 0 \
		and _land_subnet_index_at(neighbour_cell, opposite_edge(edge)) >= 0


# Keep BoardState's expansion targeting aligned with RuleEngine's runtime graph:
# CENTER_LAND has one subnet; CENTER_EMPTY has one subnet per LAND edge.
func _land_subnet_index_at(cell: Vector2i, edge: int) -> int:
	if not has_tile(cell):
		return -1
	var placement := get_placement(cell)
	var definition: TileDefinition = placement["definition"]
	var rotation := int(placement["rotation"])
	if definition.edge_kind_at(edge, rotation) != TileDefinition.EdgeKind.LAND:
		return -1
	if definition.center_kind == TileDefinition.CenterKind.LAND:
		return 0
	var subnet_idx := 0
	for candidate_edge in range(4):
		if definition.edge_kind_at(candidate_edge, rotation) != TileDefinition.EdgeKind.LAND:
			continue
		if candidate_edge == edge:
			return subnet_idx
		subnet_idx += 1
	return -1


# §5.4.1：一个 land_region 内只保留最高优先级物种（树 > 花 > 草）。
# 同物种、哪怕跨玩家，也不会互相驱逐。退种按 "区域 × 玩家 × 物种" 去重。
func _resolve_species_conflicts() -> Dictionary:
	var rule := RE.analyze(self)
	for plant_id in plants:
		var plant: Plant = plants[plant_id]
		var region = rule.land_subnet_to_region.get(
			RE._land_subnet_key(plant.tile_cell, plant.land_subnet_idx), null
		)
		plant.land_region_id = int(region.id) if region != null else -1

	var evicted_ids: Array = []
	var changed_cells: Array[Vector2i] = []
	for region in rule.land_regions:
		# §5.6.1 免疫驱逐：已收获锁定的 region 不再参与驱逐（收获植物结构性不可被驱逐）
		if locked_region_keys.has(RE.stable_region_key(region)):
			continue
		var plants_in_region: Array = []
		for plant_id in plants:
			var plant: Plant = plants[plant_id]
			if int(plant.land_region_id) == int(region.id):
				plants_in_region.append(plant)
		if plants_in_region.size() < 2:
			continue
		var highest_species := -1
		for plant in plants_in_region:
			highest_species = maxi(highest_species, int(plant.species))
		var refunds: Dictionary = {}
		for plant in plants_in_region:
			if int(plant.species) == highest_species:
				continue
			var refund_key := "%d:%d" % [int(plant.owner), int(plant.species)]
			if bool(plant.seed_committed) and not refunds.has(refund_key):
				_refund_seed(int(plant.owner), int(plant.species))
				refunds[refund_key] = true
			evicted_ids.append(int(plant.id))
			changed_cells.append(plant.tile_cell)
	for plant_id in evicted_ids:
		plants.erase(plant_id)
	return {
		"evicted_plant_ids": evicted_ids,
		"changed_cells": changed_cells,
	}


# 供输入和悬停预览使用：一个中心 EMPTY 的多土地地块会返回它的每片土地。
func land_regions_at(cell: Vector2i) -> Array:
	var rule := RE.analyze(self)
	var result: Array = []
	var seen: Dictionary = {}
	for region in rule.land_regions:
		for m in region.subnets:
			if m[0] == cell and not seen.has(region.id):
				seen[region.id] = true
				result.append(region)
	return result


# 返回目标格的 (subnet_idx, region) 列表，按 subnet_idx 升序。
# 用于种植/扩张在 split 卡（一格多 land 子网）上"每 region 各落一株"，
# 并给每株绑定稳定的 land_subnet_idx 供后续重新定位。
func land_subnet_entries_at(cell: Vector2i) -> Array:
	var rule := RE.analyze(self)
	var result: Array = []
	for region in rule.land_regions:
		for m in region.subnets:
			if m[0] == cell:
				result.append({"subnet_idx": int(m[1]), "region": region})
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["subnet_idx"]) < int(b["subnet_idx"])
	)
	return result


# §5.6.1 收获锁区：目标格所属的任一 land_region 已锁定（含收获植物）→ 整格不可种植。
func any_region_locked_at(cell: Vector2i) -> bool:
	var rule := RE.analyze(self)
	for region in rule.land_regions:
		for m in region.subnets:
			if m[0] == cell:
				if locked_region_keys.has(RE.stable_region_key(region)):
					return true
				break
	return false


# §5.6.1：格内第 subnet_idx 块地（land 子网）所属 region 是否已锁定。
# 种植按单块地粒度，锁定判定也按单块地。
func _subnet_locked(cell: Vector2i, subnet_idx: int) -> bool:
	for entry in land_subnet_entries_at(cell):
		if int(entry["subnet_idx"]) == subnet_idx:
			var region = entry["region"]
			return locked_region_keys.has(RE.stable_region_key(region))
	return false


# §5.6.1：把一个 land_region 标记为锁定（收获后调用）。
func lock_region_by_key(key: String) -> void:
	locked_region_keys[key] = true


# §5.6.1：查询某 land_region 是否已锁定（供驱逐免疫等使用）。
func is_region_locked_by_key(key: String) -> bool:
	return locked_region_keys.has(key)


# 返回鼠标所在格全部 land_region 以及其相连格。结果去重并按稳定坐标排序，
# 使视觉层不会因 Dictionary 遍历顺序闪动。
func connected_land_cells_at(cell: Vector2i) -> Array[Vector2i]:
	var cells: Dictionary = {}
	for region in land_regions_at(cell):
		for region_cell in region.cells:
			cells[region_cell] = true
	var result: Array[Vector2i] = []
	for region_cell in cells.keys():
		result.append(region_cell)
	result.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		if a.y == b.y:
			return a.x < b.x
		return a.y < b.y
	)
	return result


# 内部：扣 1 枚种子（无校验；调用方负责合法性）
func _consume_seed(player_id: int, species: int) -> void:
	if not seed_inventory.has(player_id):
		return
	var bag: Dictionary = seed_inventory[player_id]
	if not bag.has(species):
		return
	bag[species] = int(bag[species]) - 1


# 内部：退还 1 枚种子（§5.6.2 阶段 B；不受上限影响）
func _refund_seed(player_id: int, species: int) -> void:
	if not seed_inventory.has(player_id):
		seed_inventory[player_id] = {}
	var bag: Dictionary = seed_inventory[player_id]
	bag[species] = int(bag.get(species, 0)) + 1


func _has_seed(player_id: int, species: int) -> bool:
	if not seed_inventory.has(player_id):
		return false
	return int(seed_inventory[player_id].get(species, 0)) > 0


# 移除一棵植物（§5.6.2 阶段 B 的清场动作；当前仅 plant_engine 调用）
func remove_plant(plant_id: int) -> void:
	plants.erase(plant_id)


# 给定玩家所有植物按 (species, cell) 排序的唯一列表，便于 UI 渲染
func list_plants_in_tile(cell: Vector2i) -> Array:
	var out: Array = []
	for plant_id in plants:
		var p: Plant = plants[plant_id]
		if p.tile_cell == cell:
			out.append(p)
	out.sort_custom(func(a: Plant, b: Plant) -> bool:
		return int(a.species) < int(b.species)
	)
	return out


static func neighbour_for_edge(cell: Vector2i, edge: int) -> Vector2i:
	match edge:
		TileDefinition.Edge.NORTH:
			return cell + Vector2i.UP
		TileDefinition.Edge.EAST:
			return cell + Vector2i.RIGHT
		TileDefinition.Edge.SOUTH:
			return cell + Vector2i.DOWN
		_:
			return cell + Vector2i.LEFT


static func opposite_edge(edge: int) -> int:
	return posmod(edge + 2, 4)


static func edge_label(edge: int) -> String:
	match edge:
		TileDefinition.Edge.NORTH:
			return "北边"
		TileDefinition.Edge.EAST:
			return "东边"
		TileDefinition.Edge.SOUTH:
			return "南边"
		_:
			return "西边"


func _record(definition: TileDefinition, quarter_turns: int, player_id: int, water_rewrite_at: Array = []) -> Dictionary:
	return {
		"definition": definition,
		"rotation": posmod(quarter_turns, 4),
		"owner_id": player_id,
		"water_rewrite_at": water_rewrite_at,
	}


func _verdict(valid: bool, reason: String, subnet_idx: int = -1) -> Dictionary:
	var out := {
		"valid": valid,
		"reason": reason,
	}
	if subnet_idx >= 0:
		out["subnet_idx"] = subnet_idx
	return out
