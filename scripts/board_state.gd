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
var turn_placed_cells: Array[Vector2i] = []    # 本回合已放置（仅用于流程/视觉，不限制种植目标）
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
var player_count: int = 2
const INITIAL_SEEDS_PER_SPECIES: int = 2     # §7.1.1


func start_with(starter: TileDefinition) -> void:
	placements.clear()
	_reset_plants(2)
	placements[Vector2i.ZERO] = _record(starter, 0, -1)
	active_player = 0
	turn_number = 1
	phase = Phase.DEAL
	tile_to_place = null
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


# 本回合刚放置的格列表（供流程/视觉使用；r16 起不限制主动种植目标）
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

	return _verdict(true, "所有相接的边口都匹配。")


# 规则书 §3.2 边拼接兼容判定
# - 同基础地形对接合法（LAND↔LAND / WATER↔WATER / EMPTY↔EMPTY / RIVER↔RIVER / BANK↔BANK）
# - BANK ↔ EMPTY 合法
# - BANK ↔ WATER 合法（永久改写为水渠，本函数只判定可行性）
# - 其余组合非法
static func _edges_compatible(own: int, neighbour: int) -> bool:
	if own == neighbour:
		return true
	if own == TileDefinition.EdgeKind.BANK and (neighbour == TileDefinition.EdgeKind.EMPTY or neighbour == TileDefinition.EdgeKind.WATER):
		return true
	if neighbour == TileDefinition.EdgeKind.BANK and (own == TileDefinition.EdgeKind.EMPTY or own == TileDefinition.EdgeKind.WATER):
		return true
	return false


func place(definition: TileDefinition, cell: Vector2i, quarter_turns: int, player_id: int) -> Dictionary:
	var result := can_place(definition, cell, quarter_turns)
	if not bool(result["valid"]):
		return result
	# §3.6 步骤 5：拼接前先识别 BANK↔水口 待改写边，落地时一并写入 water_rewrite_at
	var pending := RE.detect_pending_rewrites(self, definition, cell, quarter_turns)
	var rewrites: Array = []
	for entry in pending:
		if entry["cell"] == cell:
			rewrites.append(entry["edge"])
	placements[cell] = _record(definition, quarter_turns, player_id, rewrites)
	# §5.4.2：放牌后，直接相邻且 LAND 真正连通的已有植物会无消耗自动扩张。
	# 这发生在玩家主动种植之前，且不会占用本回合的种植动作。
	result["automatic_expansion"] = _apply_automatic_expansion(cell)
	# §5.4.1：本次拼接可能把原本分离、且各有不同物种的土地块合并。
	# 立即按树 > 花 > 草驱逐，不把冲突拖到回合结算。
	result["species_conflict"] = _resolve_species_conflicts()
	return result


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


# 目标格一旦有任意植物即被占据（§5.1 / §5.8）。
# 这与 land_region 内可有多株同种植物是不同层级的限制。
func tile_has_any_plant(tile: Vector2i) -> bool:
	for plant_id in plants:
		var p: Plant = plants[plant_id]
		if p.tile_cell == tile:
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
#   1. 只能在本回合"放置完成"后的动作窗口主动种植；
#   2. 目标可以是棋盘上任意历史地块，不限本回合新牌；
#   3. 目标必须含可种植 LAND，且整格没有任何植物；
#   4. 当前玩家必须还有所选物种种子；
#   5. 每回合最多一次主动种植。
func can_plant_at(target_cell: Vector2i, species: int, owner: int) -> Dictionary:
	if phase != Phase.ACTION_WINDOW:
		return _verdict(false, "请先完成本回合的地块放置，再种植。")
	if planting_action_used:
		return _verdict(false, "本回合已经种植过；可结束回合。")
	if not has_tile(target_cell):
		return _verdict(false, "目标格尚未放置地块。")
	if land_regions_at(target_cell).is_empty():
		return _verdict(false, "目标格不属于任何土地块（无可种植空间）。")
	if tile_has_any_plant(target_cell):
		return _verdict(false, "目标格已经有植物占据。")
	if not _has_seed(owner, species):
		return _verdict(false, "该物种种子已耗尽。")
	return _verdict(true, "种植合法。")


func can_plant_any_species_at(target_cell: Vector2i, owner: int) -> Dictionary:
	for species in [PD.Species.GRASS, PD.Species.FLOWER, PD.Species.TREE]:
		var check := can_plant_at(target_cell, species, owner)
		if bool(check["valid"]):
			return check
	return can_plant_at(target_cell, PD.Species.GRASS, owner)


# §7.2.2.A 种植动作：从 owner 扣除 1 枚对应种类种子，在 target_cell 上种一棵 species。
# 初始形态置 §5.3 的存活状态；水量只在闭合结算窗口处理。
func plant(target_cell: Vector2i, species: int, owner: int) -> Dictionary:
	var check := can_plant_at(target_cell, species, owner)
	if not bool(check["valid"]):
		return check
	_consume_seed(owner, species)
	var p := Plant.new()
	p.id = next_plant_id
	next_plant_id += 1
	p.species = species
	p.owner = owner
	p.tile_cell = target_cell
	p.form = Plant.Form.HEALTHY
	p.seed_committed = true
	p.expansion_order = next_planting_order
	next_planting_order += 1
	var regions := land_regions_at(target_cell)
	if not regions.is_empty():
		p.land_region_id = int(regions[0].id)
	plants[p.id] = p
	planting_action_used = true
	return {
		"valid": true,
		"reason": "已种植",
		"plant_id": p.id,
		"species_conflict": _resolve_species_conflicts(),
	}


# §5.4.2 自动扩张：只考察新地块的直接相邻格；两个边均为 LAND，且两格都是
# CENTER_LAND 时才是同一个 land_region。中心 EMPTY 的 land 边按规则书切断连通。
func _apply_automatic_expansion(target_cell: Vector2i) -> Dictionary:
	if tile_has_any_plant(target_cell):
		return {}
	var candidates: Array = []
	for edge in range(4):
		if not _direct_land_connection_at(target_cell, edge):
			continue
		var source_cell := neighbour_for_edge(target_cell, edge)
		for source_plant in list_plants_in_tile(source_cell):
			candidates.append(source_plant)
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a: Plant, b: Plant) -> bool:
		if int(a.species) != int(b.species):
			return int(a.species) > int(b.species) # 树 > 花 > 草
		var a_order := int(a.expansion_order)
		var b_order := int(b.expansion_order)
		if a_order != b_order:
			return a_order < b_order
		return int(a.id) < int(b.id)
	)
	var source: Plant = candidates[0]
	var expanded := Plant.new()
	expanded.id = next_plant_id
	next_plant_id += 1
	expanded.species = int(source.species)
	expanded.owner = int(source.owner)
	expanded.tile_cell = target_cell
	expanded.form = Plant.Form.HEALTHY
	expanded.seed_committed = false
	expanded.expansion_order = next_planting_order
	next_planting_order += 1
	var regions := land_regions_at(target_cell)
	if not regions.is_empty():
		expanded.land_region_id = int(regions[0].id)
	plants[expanded.id] = expanded
	return {
		"plant_id": expanded.id,
		"source_plant_id": int(source.id),
		"owner": int(source.owner),
		"species": int(source.species),
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
	return definition.center_kind == TileDefinition.CenterKind.LAND \
		and neighbour_definition.center_kind == TileDefinition.CenterKind.LAND


# §5.4.1：一个 land_region 内只保留最高优先级物种（树 > 花 > 草）。
# 同物种、哪怕跨玩家，也不会互相驱逐。退种按 "区域 × 玩家 × 物种" 去重。
func _resolve_species_conflicts() -> Dictionary:
	var rule := RE.analyze(self)
	for plant_id in plants:
		var plant: Plant = plants[plant_id]
		var region = rule.land_region_by_cell.get(plant.tile_cell, null)
		plant.land_region_id = int(region.id) if region != null else -1

	var evicted_ids: Array = []
	var changed_cells: Array[Vector2i] = []
	for region in rule.land_regions:
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
	for region in rule.land_regions:
		if region.cells.has(cell):
			result.append(region)
	return result


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


func _verdict(valid: bool, reason: String) -> Dictionary:
	return {
		"valid": valid,
		"reason": reason,
	}
