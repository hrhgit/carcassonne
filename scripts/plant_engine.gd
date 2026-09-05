## 碧水沃野植物结算引擎（规则书 §5 / §6 / §7）
##
## 无状态计算器：调用方传入 BoardState + 触发原因 → 返回 PlantAnalysis
##
## 实现规则段：
## - §5.4 缺水判定（按 V_L 单棵判定，可逆 HEALTHY ↔ WATER_SHORT）
## - §5.5 水源分配优先级（Step A 草拿满 → Step B 花/树对半分 → Step C 互相补给）
## - §5.6 全封闭两阶段（阶段 A 升级枯萎 if 水网全封闭；阶段 B 不论形态退种 + 清场）
## - §5.7 终局形态升级（所有 WATER_SHORT → WITHERED，不再退种）
## - §6 计分 + §6.4 减半（未封闭 land_region × 非草 → ×0.5）+ §6.3 平局破平链
class_name PlantEngine
extends RefCounted

const PD := preload("res://scripts/plant.gd")
const RE := preload("res://scripts/rule_engine.gd")

const SPECIES_GRASS := PD.Species.GRASS
const SPECIES_FLOWER := PD.Species.FLOWER
const SPECIES_TREE := PD.Species.TREE

const FORM_HEALTHY := PD.Form.HEALTHY
const FORM_WATER_SHORT := PD.Form.WATER_SHORT
const FORM_WITHERED := PD.Form.WITHERED


# 结算结果
class PlantAnalysis extends RefCounted:
	# 更新后的 plants：board.plants 已经被原地修改（form / land_region_id 字段更新）
	var plants_snapshot: Array = []          # Array[Plant]  —— 仅含在 board.plants 中仍然存在的植物
	var closed_regions_stage_a: Array = []   # 本次升级的 land_region.id（仅 land + 水网都封闭）
	var closed_regions_stage_b: Array = []   # 本次清场的 land_region.id（仅 land 封闭）
	var seeds_refunded: Dictionary = {}      # { player_id: { species: count } } 本次退还明细
	var plants_removed: Array = []           # 被 §5.6.2 阶段 B 移除的 plant_id
	var summary: Dictionary = {}             # { plant_count, healthy_count, water_short_count, withered_count }


## 主入口：每次放牌后 / 玩家回合结束时调用。
## 流程：assign land_region → §5.4 / §5.5 forms → §5.6 两阶段。
static func settle(board: BoardState) -> PlantAnalysis:
	var rule := RE.analyze(board)
	var pa := PlantAnalysis.new()
	if rule.land_regions.is_empty():
		pa.plants_snapshot = board.plants.values()
		pa.summary = _summary_of(board)
		return pa

	_assign_land_regions(board.plants, rule)
	_update_forms(board, rule, pa)
	_process_closures(board, rule, pa)
	pa.plants_snapshot = board.plants.values()
	pa.summary = _summary_of(board)
	return pa


## §5.7 游戏结束结算（终局专门入口）
## —— 重算 V_L → §5.5 重分配 → 升 WATER_SHORT → WITHERED（不退种，已由主循环处理）
static func end_game_settle(board: BoardState) -> PlantAnalysis:
	var pa := PlantAnalysis.new()
	# 终局形态结算前再跑一次 settle（这会触发 §5.6 退还路径——但终局规则禁止重复退种）
	# 因此调用方应在调用本方法前先判断牌堆已空并已彻底跳过 §5.6
	var rule := RE.analyze(board)
	_assign_land_regions(board.plants, rule)
	_update_forms(board, rule, pa)

	# §5.7 阶段 2：所有 WATER_SHORT 升级 WITHERED
	for plant_id in board.plants:
		var p: Plant = board.plants[plant_id]
		if int(p.form) == FORM_WATER_SHORT:
			p.form = FORM_WITHERED

	pa.plants_snapshot = board.plants.values()
	pa.summary = _summary_of(board)
	return pa


## 暴露给测试 / 自定义流程：复用调用方传入的 RuleEngine.Analysis（而非重新 analyze 一次）
## —— 例如测试想手动改 lr.is_closed 来模拟封闭状态时，绕过内部 analyze() 拿到的"未被改的"副本
static func settle_with_rule(board: BoardState, rule: RE.Analysis) -> PlantAnalysis:
	var pa := PlantAnalysis.new()
	_assign_land_regions(board.plants, rule)
	_update_forms(board, rule, pa)
	_process_closures(board, rule, pa)
	pa.plants_snapshot = board.plants.values()
	pa.summary = _summary_of(board)
	return pa


## §6 计分 + §6.4 减半 + §6.3 平局破平链
## —— 输入是已 §5.7 终局形态锁定后的 BoardState
static func score(board: BoardState) -> Dictionary:
	var rule := RE.analyze(board)
	var scores := {}             # player_id -> float
	var tiebreakers := {}        # player_id -> Dictionary
	if rule.land_regions.is_empty():
		return _empty_score(board)

	# 把每个 land_region 上的 HEALTHY 植物按 (owner, species) 聚拢
	# —— §6.4.1 公式：Σ_{L} Σ_{p ∈ P ∩ L, HEALTHY}  weight(species) × multiplier(L, species)
	for player_id in board.seed_inventory:
		scores[player_id] = 0.0
		tiebreakers[player_id] = {
			"healthy_tree": 0,
			"healthy_flower": 0,
			"healthy_grass": 0,
			"closed_score": 0.0,
		}

	for lr in rule.land_regions:
		var closed_mult := 1.0 if bool(lr.is_closed) else 0.5
		for plant_id in board.plants:
			var p: Plant = board.plants[plant_id]
			if int(p.land_region_id) != int(lr.id):
				continue
			if int(p.form) != FORM_HEALTHY:
				continue
			var owner := int(p.owner)
			if owner < 0:
				continue
			var weight: float = float(PD.weight_for(int(p.species)))
			var multiplier: float = 1.0
			if int(p.species) != SPECIES_GRASS:
				multiplier = closed_mult
			var contribution: float = weight * multiplier
			scores[owner] = float(scores[owner]) + contribution
			tiebreakers[owner]["closed_score"] = float(tiebreakers[owner]["closed_score"]) + (weight if bool(lr.is_closed) else 0.0)
			match int(p.species):
				SPECIES_GRASS:
					tiebreakers[owner]["healthy_grass"] = int(tiebreakers[owner]["healthy_grass"]) + 1
				SPECIES_FLOWER:
					tiebreakers[owner]["healthy_flower"] = int(tiebreakers[owner]["healthy_flower"]) + 1
				SPECIES_TREE:
					tiebreakers[owner]["healthy_tree"] = int(tiebreakers[owner]["healthy_tree"]) + 1

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
	var healthy := 0
	var short_ := 0
	var withered := 0
	for plant_id in board.plants:
		var p: Plant = board.plants[plant_id]
		match int(p.form):
			FORM_HEALTHY:
				healthy += 1
			FORM_WATER_SHORT:
				short_ += 1
			FORM_WITHERED:
				withered += 1
	return {
		"plant_count": board.plants.size(),
		"healthy_count": healthy,
		"water_short_count": short_,
		"withered_count": withered,
	}


static func _assign_land_regions(plants_dict: Dictionary, rule: RE.Analysis) -> void:
	for plant_id in plants_dict:
		var p: Plant = plants_dict[plant_id]
		var cell: Vector2i = p.tile_cell
		var lr = rule.land_region_by_cell.get(cell, null)
		if lr == null:
			p.land_region_id = -1
			continue
		p.land_region_id = int(lr.id)


# §5.4 形态判定 + §5.5 水源分配
static func _update_forms(board: BoardState, rule: RE.Analysis, pa: PlantAnalysis) -> void:
	for lr in rule.land_regions:
		var V_L: float = float(lr.S_L)
		var plants_in: Array = []
		for plant_id in board.plants:
			var p: Plant = board.plants[plant_id]
			if int(p.land_region_id) != int(lr.id):
				continue
			if int(p.form) == FORM_WITHERED:
				continue
			plants_in.append(p)
		if plants_in.is_empty():
			continue
		var forms := _distribute_water(plants_in, V_L)
		for plant_id in board.plants:
			var p: Plant = board.plants[plant_id]
			if forms.has(p.id):
				p.form = int(forms[p.id])


# §5.5 水源分配：草优先 → 花/树对半分 → 互相补给
# — 输入：一个 land_region L 上的所有"未枯萎"植物 + V_L
# — 输出：{ plant_id: form }
static func _distribute_water(plants_in_region: Array, V_L: float) -> Dictionary:
	var forms := {}

	var grasses: Array = []
	var flowers: Array = []
	var trees: Array = []
	for p in plants_in_region:
		match int(p.species):
			SPECIES_GRASS:
				grasses.append(p)
			SPECIES_FLOWER:
				flowers.append(p)
			SPECIES_TREE:
				trees.append(p)

	var remaining: float = V_L

	# Step A：草拿满（不足则缺水；不超过 V_L 后即停止，不再透支花/树的水）
	for g in grasses:
		if remaining >= 0.5:
			forms[int(g.id)] = FORM_HEALTHY
			remaining -= 0.5
		else:
			forms[int(g.id)] = FORM_WATER_SHORT

	# Step B：对半分给花 / 树
	var half: float = remaining * 0.5

	# B.1：花拿 half
	var need_F: float = float(flowers.size())
	var take_F: float = minf(half, need_F)
	var full_flowers: int = int(floor(take_F))   # 完全满足的花数
	for i in range(min(full_flowers, flowers.size())):
		forms[int(flowers[i].id)] = FORM_HEALTHY
	for i in range(full_flowers, flowers.size()):
		forms[int(flowers[i].id)] = FORM_WATER_SHORT
	var remain_F: float = maxf(0.0, half - need_F)

	# B.2：树拿 half
	var need_T: float = float(trees.size()) * 2.0
	var take_T: float = minf(half, need_T)
	var full_trees: int = int(floor(take_T / 2.0))   # 完全满足的树数
	for i in range(min(full_trees, trees.size())):
		forms[int(trees[i].id)] = FORM_HEALTHY
	for i in range(full_trees, trees.size()):
		forms[int(trees[i].id)] = FORM_WATER_SHORT
	var remain_T: float = maxf(0.0, half - need_T)

	# Step C：互相补给
	# extra_F：树剩余补给花（只够补满部分）
	var extra_F_capacity: float = maxf(0.0, need_F - take_F)  # 还差多少花能全满足
	var extra_F: float = minf(remain_T, extra_F_capacity)
	# extra_T：花剩余补给树（以"能补几棵树"计）
	var extra_T_capacity_trees: float = maxf(0.0, (need_T - take_T) / 2.0)
	var extra_T: float = minf(floor(remain_F / 2.0), extra_T_capacity_trees)

	# 真正去升级（按原始顺序，跳过已健康的）
	var fill_F: int = int(floor(extra_F))
	var cursor_F: int = 0
	for i in range(full_flowers, flowers.size()):
		if cursor_F >= fill_F:
			break
		if int(forms[int(flowers[i].id)]) == FORM_WATER_SHORT:
			forms[int(flowers[i].id)] = FORM_HEALTHY
			cursor_F += 1

	var fill_T: int = int(floor(extra_T))
	var cursor_T: int = 0
	for i in range(full_trees, trees.size()):
		if cursor_T >= fill_T:
			break
		if int(forms[int(trees[i].id)]) == FORM_WATER_SHORT:
			forms[int(trees[i].id)] = FORM_HEALTHY
			cursor_T += 1

	return forms


# §5.6 两阶段结算
# —— 阶段 A：land 边全封闭 + 关联水网也全封闭 → 缺水升 WITHERED
# —— 阶段 B：land 边全封闭 → 退种 + 清场
static func _process_closures(board: BoardState, rule: RE.Analysis, pa: PlantAnalysis) -> void:
	for lr in rule.land_regions:
		if not bool(lr.is_closed):
			continue

		# 关联水网是否全封闭？
		var all_water_closed := true
		for w_id in lr.irrigated_water_net_ids:
			var wn = _find_water_net(rule, int(w_id))
			if wn == null:
				continue
			if not bool(wn.is_closed):
				all_water_closed = false
				break

		# 阶段 A：升级 WITHERED
		if all_water_closed:
			for plant_id in board.plants:
				var p: Plant = board.plants[plant_id]
				if int(p.land_region_id) != int(lr.id):
					continue
				if int(p.form) == FORM_WATER_SHORT:
					p.form = FORM_WITHERED
			pa.closed_regions_stage_a.append(int(lr.id))

		# 阶段 B：退种 + 清场
		var to_remove: Array = []
		for plant_id in board.plants:
			var p: Plant = board.plants[plant_id]
			if int(p.land_region_id) != int(lr.id):
				continue
			to_remove.append(p)
		for p in to_remove:
			_refund_and_remove(board, p, pa)
		if not to_remove.is_empty():
			pa.closed_regions_stage_b.append(int(lr.id))


static func _refund_and_remove(board: BoardState, p: Plant, pa: PlantAnalysis) -> void:
	# 退种 1 枚
	board._refund_seed(int(p.owner), int(p.species))
	# 记录明细
	if not pa.seeds_refunded.has(int(p.owner)):
		pa.seeds_refunded[int(p.owner)] = {}
	var bag: Dictionary = pa.seeds_refunded[int(p.owner)]
	bag[int(p.species)] = int(bag.get(int(p.species), 0)) + 1
	# 移除
	pa.plants_removed.append(int(p.id))
	board.remove_plant(int(p.id))


static func _find_water_net(rule: RE.Analysis, net_id: int):
	for wn in rule.water_nets:
		if int(wn.id) == net_id:
			return wn
	return null
