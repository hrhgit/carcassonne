## 青菱沃野植物结算引擎（规则书 §5 / §6 / §7）
##
## 无状态计算器：调用方传入 BoardState + 触发原因 → 返回 PlantAnalysis
##
## 实现规则段（r16 / v17）：
## - §5.3 植物三态：存活 / 收获 / 死亡（无中间可逆形态）
## - §5.5 闭合结算水量分配：需水 = need × 地块面积，按种植顺序 round-down 满足
## - §5.6 全封闭结算：水够 → 收获；水不够 → 死亡；收获锁区
## - §6 计分 + §6.4 减半 + §6.3 平局破平链
class_name PlantEngine
extends RefCounted

const PD := preload("res://scripts/plant.gd")
const RE := preload("res://scripts/rule_engine.gd")

const SPECIES_GRASS := PD.Species.GRASS
const SPECIES_FLOWER := PD.Species.FLOWER
const SPECIES_TREE := PD.Species.TREE

const FORM_SURVIVING := PD.Form.SURVIVING
const FORM_HARVESTED := PD.Form.HARVESTED
const FORM_DEAD := PD.Form.DEAD


# 结算结果
class PlantAnalysis extends RefCounted:
	# 更新后的 plants：board.plants 已经被原地修改（form / land_region_id 字段更新）
	var plants_snapshot: Array = []          # Array[Plant]  —— 仅含在 board.plants 中仍然存在的植物
	var closed_regions_stage_a: Array = []   # 本次产生"收获"的 land_region.id
	var closed_regions_stage_b: Array = []   # 本次结算（退种）的 land_region.id
	var seeds_refunded: Dictionary = {}      # { player_id: { species: count } } 本次退还明细
	var plants_removed: Array = []           # 被 §5.6 死亡移除的 plant_id
	var summary: Dictionary = {}             # { plant_count, surviving_count, harvested_count, dead_count }


## 主入口：每次放牌后 / 玩家回合结束时调用。
## 流程：assign land_region → §5.5/§5.6 闭合结算（收获/死亡判定 + 退种 + 锁区）。
static func settle(board: BoardState) -> PlantAnalysis:
	var rule := RE.analyze(board)
	var pa := PlantAnalysis.new()
	if rule.land_regions.is_empty():
		pa.plants_snapshot = board.plants.values()
		pa.summary = _summary_of(board)
		return pa

	_assign_land_regions(board.plants, rule)
	_process_closures(board, rule, pa)
	pa.plants_snapshot = board.plants.values()
	pa.summary = _summary_of(board)
	return pa


## §5.7 游戏结束结算（终局专门入口）
## —— 终局对所有仍存活的植物统一结算一次需水量：水够 → 保持存活/收获；
## 水不够 → 死亡移除（不退种）。已闭合区域在 settle 时已判定的收获/死亡不重复处理；
## 未闭合区域的存活植物在此按 §5.5 需水分配判定——缺水即死亡、不计分。
static func end_game_settle(board: BoardState) -> PlantAnalysis:
	var pa := PlantAnalysis.new()
	var rule := RE.analyze(board)
	_assign_land_regions(board.plants, rule)
	_process_endgame_water(board, rule, pa)
	pa.plants_snapshot = board.plants.values()
	pa.summary = _summary_of(board)
	return pa


# §5.7 终局需水结算：对所有含存活植物的 land_region（无论闭合与否）做一次需水分配，
# 缺水植物判死并移除。已收获 / 已死亡（历史结算）的植物跳过。
static func _process_endgame_water(board: BoardState, rule: RE.Analysis, pa: PlantAnalysis) -> void:
	for lr in rule.land_regions:
		var V_L: float = float(lr.S_L)
		var plants_in: Array = []
		for plant_id in board.plants:
			var p: Plant = board.plants[plant_id]
			if int(p.land_region_id) != int(lr.id):
				continue
			if int(p.form) != FORM_SURVIVING:
				continue
			plants_in.append(p)
		if plants_in.is_empty():
			continue

		var forms := _distribute_water(board, plants_in, V_L)

		var to_remove: Array = []
		for p in plants_in:
			var f: int = int(forms.get(int(p.id), FORM_DEAD))
			if f == FORM_HARVESTED:
				# 终局：存活但水够的植物保持留场；若区域已闭合可标记收获，未闭合仍按存活计分（§6.5 减半）
				if bool(lr.is_closed):
					p.form = FORM_HARVESTED
			else:
				p.form = FORM_DEAD
				to_remove.append(p)

		for p in to_remove:
			pa.plants_removed.append(int(p.id))
			board.remove_plant(int(p.id))


## 暴露给测试 / 自定义流程：复用调用方传入的 RuleEngine.Analysis（而非重新 analyze 一次）
static func settle_with_rule(board: BoardState, rule: RE.Analysis) -> PlantAnalysis:
	var pa := PlantAnalysis.new()
	_assign_land_regions(board.plants, rule)
	_process_closures(board, rule, pa)
	pa.plants_snapshot = board.plants.values()
	pa.summary = _summary_of(board)
	return pa


## §6 计分 + §6.3 同级竞争 + §6.5 减半 + §6.4 破平链数据
## —— 输入是已 §5.7 终局形态锁定后的 BoardState
static func score(board: BoardState) -> Dictionary:
	var rule := RE.analyze(board)
	_assign_land_regions(board.plants, rule)
	return _compute_scores(board, rule)


## 预估得分：用于游戏进行中（右侧面板）实时估算"若此刻终局各玩家能得多少分"。
## —— 纯读、不修改 board 状态、不做死亡判定 / 不触发移除；只回填 land_region_id（幂等）。
## 计分规则与 §6 一致（含 §6.3 同级竞争、§6.5 减半），但以当前场上存活/收获植物为准。
static func estimate_score(board: BoardState) -> Dictionary:
	var rule := RE.analyze(board)
	_assign_land_regions(board.plants, rule)
	return _compute_scores(board, rule)


## 预估缺水：返回 { plant_id: true }，标记"若此刻结算会因缺水而死亡"的存活植物。
## —— 纯读、不修改状态、不移除植物、不改 form。用于渲染层给缺水植物轻微灰化。
## 判定复用 §5.5 需水分配：逐 land_region（无论闭合与否）对存活植物做一次 round-down 分配，
## 分不到完整需水的即视为缺水（会死）。
static func estimate_water_stress(board: BoardState) -> Dictionary:
	var rule := RE.analyze(board)
	_assign_land_regions(board.plants, rule)
	var stressed := {}
	for lr in rule.land_regions:
		var V_L: float = float(lr.S_L)
		var plants_in: Array = []
		for plant_id in board.plants:
			var p: Plant = board.plants[plant_id]
			if int(p.land_region_id) != int(lr.id):
				continue
			if int(p.form) != FORM_SURVIVING:
				continue
			plants_in.append(p)
		if plants_in.is_empty():
			continue
		var forms := _distribute_water(board, plants_in, V_L)
		for p in plants_in:
			if int(forms.get(int(p.id), FORM_DEAD)) == FORM_DEAD:
				stressed[int(p.id)] = true
	return stressed


## 计分核心：给定已 analyze 的 rule 与场上植物，产出 {scores, tiebreakers}。
## —— 实现 §6.1 公式、§6.3 同级竞争、§6.5 减半；死亡植物不计分。
static func _compute_scores(board: BoardState, rule: RE.Analysis) -> Dictionary:
	var scores := {}             # player_id -> float
	var tiebreakers := {}        # player_id -> Dictionary
	if rule.land_regions.is_empty():
		return _empty_score(board)

	for player_id in board.seed_inventory:
		scores[player_id] = 0.0
		tiebreakers[player_id] = {
			"healthy_tree": 0,
			"healthy_flower": 0,
			"healthy_grass": 0,
			"closed_score": 0.0,
		}

	# 第一遍：按 (land_region, species) 聚合留场（存活 / 收获）植物的 owner → 株数。
	# 同时记录该二元组的 multiplier（§6.5 减半：花/树在未闭合区域 ×0.5，草恒 ×1.0）
	# 与 weight（§6.1），供 §6.3 同级竞争裁决使用。
	var groups := {}              # key = "%d:%d" % [lr_id, species]  -> {"mult": float, "owners": {owner: count}}
	var group_meta := {}          # key -> {"lr_id": int, "species": int, "weight": float, "mult": float, "is_closed": bool}
	for lr in rule.land_regions:
		var closed_mult := 1.0 if bool(lr.is_closed) else 0.5
		for plant_id in board.plants:
			var p: Plant = board.plants[plant_id]
			if int(p.land_region_id) != int(lr.id):
				continue
			if int(p.form) == FORM_DEAD:
				continue
			var owner := int(p.owner)
			if owner < 0:
				continue
			var species := int(p.species)
			var key := "%d:%d" % [int(lr.id), species]
			if not groups.has(key):
				groups[key] = {"owners": {}}
				group_meta[key] = {
					"lr_id": int(lr.id),
					"species": species,
					"weight": float(PD.weight_for(species)),
					"mult": closed_mult if species != SPECIES_GRASS else 1.0,
					"is_closed": bool(lr.is_closed),
				}
			var owners: Dictionary = groups[key]["owners"]
			owners[owner] = int(owners.get(owner, 0)) + 1

			# tiebreaker：破平链的"棵数"与"封闭得分"按玩家自身留场植株累计（与同级竞争无关）
			tiebreakers[owner]["closed_score"] = float(tiebreakers[owner]["closed_score"]) + (float(PD.weight_for(species)) if bool(lr.is_closed) else 0.0)
			match species:
				SPECIES_GRASS:
					tiebreakers[owner]["healthy_grass"] = int(tiebreakers[owner]["healthy_grass"]) + 1
				SPECIES_FLOWER:
					tiebreakers[owner]["healthy_flower"] = int(tiebreakers[owner]["healthy_flower"]) + 1
				SPECIES_TREE:
					tiebreakers[owner]["healthy_tree"] = int(tiebreakers[owner]["healthy_tree"]) + 1

	# 第二遍：逐 (land_region, species) 组做 §6.3 同级竞争裁决，把得分落到对应 owner。
	for key in groups:
		var meta: Dictionary = group_meta[key]
		var owners: Dictionary = groups[key]["owners"]
		var weight: float = float(meta["weight"])
		var mult: float = float(meta["mult"])
		var total := 0
		for o in owners:
			total += int(owners[o])

		if owners.size() == 1:
			# 单一 owner：正常累加该物种在该区域的全部得分
			var only_owner: int = int(owners.keys()[0])
			scores[only_owner] = float(scores[only_owner]) + weight * mult * float(total)
			continue

		# 多 owner 同物种 → 同级竞争：株数最多者独得全部；并列最多者平分（§6.3）
		var max_count := -1
		for o in owners:
			var c := int(owners[o])
			if c > max_count:
				max_count = c
		var leaders: Array = []
		for o in owners:
			if int(owners[o]) == max_count:
				leaders.append(int(o))
		var pool: float = weight * mult * float(total)
		var share: float = pool / float(leaders.size())
		for o in leaders:
			scores[o] = float(scores[o]) + share
		# 落败方不得分（其植物留场但 0 分）——scores 不额外加，即自然 0

	return {
		"scores": scores,
		"tiebreakers": tiebreakers,
	}


## §6.3 平局破平链（按 healthy_tree → closed_score → healthy_flower → healthy_grass → 平局）
## —— 把每个玩家映射到 5-tuple (score, healthy_tree, closed_score, healthy_flower, healthy_grass)
## 然后字典序降序；字典序相同的玩家并列胜出
static func resolve_winner(score_result: Dictionary, player_count: int) -> Dictionary:
	var scores: Dictionary = score_result.get("scores", {})
	var tb: Dictionary = score_result.get("tiebreakers", {})

	# 每位玩家的破平键 = 5-tuple (score, healthy_tree, closed_score, healthy_flower, healthy_grass)
	var tuples := {}
	for player_id in range(player_count):
		var tba: Dictionary = tb.get(player_id, {})
		tuples[player_id] = [
			float(scores.get(player_id, 0.0)),
			float(int(tba.get("healthy_tree", 0))),
			float(tba.get("closed_score", 0.0)),
			float(int(tba.get("healthy_flower", 0))),
			float(int(tba.get("healthy_grass", 0))),
		]

	var ranked_players := []
	for player_id in range(player_count):
		ranked_players.append(int(player_id))
	ranked_players.sort_custom(func(a: int, b: int) -> bool:
		var ta: Array = tuples[a]
		var tb_: Array = tuples[b]
		# 字典序倒排（更大的胜）
		for i in range(5):
			var va: float = float(ta[i])
			var vb: float = float(tb_[i])
			if va != vb:
				return va > vb
		return false  # 完全相同 → 保持顺序
	)

	if ranked_players.is_empty():
		return {"winners": [], "is_tie": true}

	var top_tuple: Array = tuples[ranked_players[0]]
	var winners := [int(ranked_players[0])]
	for i in range(1, ranked_players.size()):
		var pid: int = int(ranked_players[i])
		var t: Array = tuples[pid]
		var same: bool = true
		for j in range(5):
			if float(t[j]) != float(top_tuple[j]):
				same = false
				break
		if same:
			winners.append(pid)

	return {"winners": winners, "is_tie": winners.size() > 1}


# === 内部 helpers ===

static func _empty_score(board: BoardState) -> Dictionary:
	var scores := {}
	var tiebreakers := {}
	for player_id in board.seed_inventory:
		scores[player_id] = 0.0
		tiebreakers[player_id] = {
			"healthy_tree": 0,
			"healthy_flower": 0,
			"healthy_grass": 0,
			"closed_score": 0.0,
		}
	return {"scores": scores, "tiebreakers": tiebreakers}


static func _summary_of(board: BoardState) -> Dictionary:
	var surviving := 0
	var harvested := 0
	var dead := 0
	for plant_id in board.plants:
		var p: Plant = board.plants[plant_id]
		match int(p.form):
			FORM_SURVIVING:
				surviving += 1
			FORM_HARVESTED:
				harvested += 1
			FORM_DEAD:
				dead += 1
	return {
		"plant_count": board.plants.size(),
		"surviving_count": surviving,
		"harvested_count": harvested,
		"dead_count": dead,
	}


static func _assign_land_regions(plants_dict: Dictionary, rule: RE.Analysis) -> void:
	for plant_id in plants_dict:
		var p: Plant = plants_dict[plant_id]
		var lr = rule.land_subnet_to_region.get(
			RE._land_subnet_key(p.tile_cell, p.land_subnet_idx), null
		)
		if lr == null:
			p.land_region_id = -1
			continue
		p.land_region_id = int(lr.id)


# §5.5 闭合结算：水量分配（v17 简化）
# —— 输入：一个 land_region L 上按种植顺序排列的植物 + V_L
# —— 每株需水 = need(species) × 地块面积（单边 0.5 / 其余 1.0）
# —— round-down：剩余水 ≥ 需水 → 收获；否则死亡
# —— 返回：{ plant_id: form }
static func _distribute_water(board: BoardState, plants_in_region: Array, V_L: float) -> Dictionary:
	var forms := {}
	var remaining: float = V_L

	# 按种植顺序（expansion_order 升序）排序，先种先得
	var ordered: Array = plants_in_region.duplicate()
	ordered.sort_custom(func(a: Plant, b: Plant) -> bool:
		return int(a.expansion_order) < int(b.expansion_order))

	for p in ordered:
		var area := _land_area_of(board, p)
		var need: float = float(PD.need_for(int(p.species))) * area
		if remaining >= need:
			forms[int(p.id)] = FORM_HARVESTED
			remaining -= need
		else:
			forms[int(p.id)] = FORM_DEAD
	return forms


# 地块面积（v17）：单边土地（1 条 land 边）算 0.5 格，其余（2/3/4 条）算 1 格。
# §5.1/§5.2：split 卡一格多块地时按"块"（land 子网）计面积，而非整格。
static func _land_area_of(board: BoardState, p: Plant) -> float:
	var cell: Vector2i = p.tile_cell
	if board == null or not board.has_tile(cell):
		return 1.0
	var placement: Dictionary = board.get_placement(cell)
	var def: TileDefinition = placement.get("definition", null)
	if def == null:
		return 1.0
	return float(def.land_subnet_area(int(p.land_subnet_idx), int(placement.get("rotation", 0))))


# §5.6 全封闭结算：收获 / 死亡判定 + 退种 + 收获锁区
# —— 触发条件仅需 land 边全封闭（r16 取消水网也全封闭的前置）
static func _process_closures(board: BoardState, rule: RE.Analysis, pa: PlantAnalysis) -> void:
	for lr in rule.land_regions:
		if not bool(lr.is_closed):
			continue

		var V_L: float = float(lr.S_L)
		var plants_in: Array = []
		for plant_id in board.plants:
			var p: Plant = board.plants[plant_id]
			if int(p.land_region_id) != int(lr.id):
				continue
			# 已收获 / 已死亡（历史结算）不重复判定
			if int(p.form) == FORM_HARVESTED or int(p.form) == FORM_DEAD:
				continue
			plants_in.append(p)
		if plants_in.is_empty():
			continue

		var forms := _distribute_water(board, plants_in, V_L)

		# 判定收获 / 死亡，并统计"是否产生收获"
		var any_harvested := false
		for p in plants_in:
			var f: int = int(forms.get(int(p.id), FORM_DEAD))
			if f == FORM_HARVESTED:
				p.form = FORM_HARVESTED
				any_harvested = true
			else:
				p.form = FORM_DEAD

		# §5.6 区域退种：每位玩家每物种退 1 枚（与株数无关）
		# 死亡植物移除；收获植物留场（占格 + 锁区）
		var refunded_players: Dictionary = {}  # player_id -> { species: true }
		var to_remove: Array = []
		for p in plants_in:
			var owner := int(p.owner)
			if owner < 0:
				continue
			if not refunded_players.has(owner):
				refunded_players[owner] = {}
			refunded_players[owner][int(p.species)] = true
			if int(p.form) == FORM_DEAD:
				to_remove.append(p)

		for owner in refunded_players:
			for species in refunded_players[owner]:
				board._refund_seed(int(owner), int(species))
				if not pa.seeds_refunded.has(int(owner)):
					pa.seeds_refunded[int(owner)] = {}
				var bag: Dictionary = pa.seeds_refunded[int(owner)]
				bag[int(species)] = int(bag.get(int(species), 0)) + 1

		for p in to_remove:
			pa.plants_removed.append(int(p.id))
			board.remove_plant(int(p.id))

		if any_harvested:
			pa.closed_regions_stage_a.append(int(lr.id))
			# §5.6.1 收获锁区：产生收获的 region 立即锁定（禁种 + V_L 冻结 + 免疫驱逐）
			board.lock_region_by_key(RE.stable_region_key(lr))
		if not to_remove.is_empty() or any_harvested:
			pa.closed_regions_stage_b.append(int(lr.id))

