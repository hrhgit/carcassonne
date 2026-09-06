## 针对性验证：§6.3 同级竞争计分 + estimate_score 预估。
## 运行：godot --headless --path . --script tools/verify_peer_scoring.gd
extends SceneTree

const PE = preload("res://scripts/plant_engine.gd")
const BS = preload("res://scripts/board_state.gd")
const RE = preload("res://scripts/rule_engine.gd")
const PD = preload("res://scripts/plant.gd")
const TC = preload("res://scripts/tile_catalog.gd")


func _init() -> void:
	var ok := _run()
	quit(0 if ok else 1)


func _inject(board, species: int, owner: int, cell: Vector2i, order: int) -> void:
	var p := Plant.new()
	p.id = board.next_plant_id
	board.next_plant_id += 1
	p.species = species
	p.owner = owner
	p.tile_cell = cell
	p.form = Plant.Form.SURVIVING
	p.seed_committed = true
	p.expansion_order = order
	board.plants[p.id] = p


func _run() -> bool:
	var catalog := TC.new()
	var board := BS.new()
	board.start_with(catalog.starter_tile())

	var rule0 := RE.analyze(board)
	if rule0.land_regions.is_empty():
		printerr("[FAIL] starter 无 land_region。")
		return false
	var lr0 = rule0.land_regions[0]
	print("[INFO] starter is_closed=%s S_L=%s" % [str(lr0.is_closed), str(lr0.S_L)])

	# 定位 land_region 内一个 cell
	var cell := Vector2i(-1, -1)
	for c in board.placements:
		var rgs := board.land_regions_at(c)
		for r in rgs:
			if int(r.id) == int(lr0.id):
				cell = c
				break
		if cell != Vector2i(-1, -1):
			break
	if cell == Vector2i(-1, -1):
		printerr("[FAIL] 无法定位 land_region 内格。")
		return false

	# 场景 1：同区域同物种，P0 两棵花、P1 一棵花 → P0 独得 (2+1)*2*mult
	# starter 未闭合 → 花 mult=0.5 → pool = 3 * 2 * 0.5 = 3.0 全归 P0
	_inject(board, PD.Species.FLOWER, 0, cell, 0)
	_inject(board, PD.Species.FLOWER, 0, cell, 1)
	_inject(board, PD.Species.FLOWER, 1, cell, 2)

	var sc := PE.score(board)
	var scores: Dictionary = sc.get("scores", {})
	print("[INFO] 场景1 scores=%s" % str(scores))
	var p0: float = float(scores.get(0, -1.0))
	var p1: float = float(scores.get(1, -1.0))
	# 未闭合区域：pool = 3 花 × 2 权重 × 0.5 = 3.0，P0 株数 2 > P1 株数 1 → P0 独得 3.0，P1 得 0
	if absf(p0 - 3.0) > 0.0001:
		printerr("[FAIL] 场景1 P0 应得 3.0，实际 %s。" % str(p0))
		return false
	if absf(p1 - 0.0) > 0.0001:
		printerr("[FAIL] 场景1 P1 应得 0，实际 %s。" % str(p1))
		return false
	print("[PASS] 场景1：株数多者独得全部（P0=3.0, P1=0）")

	# 场景 2：清空重建，双方各一棵花（同区域未闭合）→ 平分 pool = 2*2*0.5 = 2.0 → 各 1.0
	var board2 := BS.new()
	board2.start_with(catalog.starter_tile())
	var rule2 := RE.analyze(board2)
	var lr2 = rule2.land_regions[0]
	var cell2 := Vector2i(-1, -1)
	for c in board2.placements:
		var rgs := board2.land_regions_at(c)
		for r in rgs:
			if int(r.id) == int(lr2.id):
				cell2 = c
				break
		if cell2 != Vector2i(-1, -1):
			break
	_inject(board2, PD.Species.FLOWER, 0, cell2, 0)
	_inject(board2, PD.Species.FLOWER, 1, cell2, 1)
	var sc2 := PE.score(board2)
	var s2: Dictionary = sc2.get("scores", {})
	print("[INFO] 场景2 scores=%s" % str(s2))
	if absf(float(s2.get(0, -1.0)) - 1.0) > 0.0001 or absf(float(s2.get(1, -1.0)) - 1.0) > 0.0001:
		printerr("[FAIL] 场景2 双方应各得 1.0，实际 %s。" % str(s2))
		return false
	print("[PASS] 场景2：株数相同平分（各 1.0）")

	# 场景 3：estimate_score 与 score 在无死亡判定时一致，且不修改状态
	var before_count: int = board2.plants.size()
	var est := PE.estimate_score(board2)
	var after_count: int = board2.plants.size()
	var est_scores: Dictionary = est.get("scores", {})
	print("[INFO] 场景3 estimate_scores=%s" % str(est_scores))
	if before_count != after_count:
		printerr("[FAIL] 场景3 estimate_score 不应移除植物（%d → %d）。" % [before_count, after_count])
		return false
	if absf(float(est_scores.get(0, -1.0)) - 1.0) > 0.0001:
		printerr("[FAIL] 场景3 estimate_score 应得 1.0，实际 %s。" % str(est_scores))
		return false
	print("[PASS] 场景3：estimate_score 纯读、结果与 score 一致、不移除植物")

	print("[DONE] verify_peer_scoring 全部通过。")
	return true
