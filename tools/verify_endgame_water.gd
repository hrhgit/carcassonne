## 针对性验证：终局时未闭合区域缺水植物应判死移除、不计分。
## 直接注入植物到 board.plants，隔离验证 end_game_settle 的需水判定。
## 运行：godot --headless --path . --script tools/verify_endgame_water.gd
extends SceneTree

const PE = preload("res://scripts/plant_engine.gd")
const BS = preload("res://scripts/board_state.gd")
const RE = preload("res://scripts/rule_engine.gd")
const PD = preload("res://scripts/plant.gd")
const TC = preload("res://scripts/tile_catalog.gd")


func _init() -> void:
	var ok := _run()
	quit(0 if ok else 1)


func _inject_plant(board, species: int, owner: int, cell: Vector2i, order: int) -> Plant:
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
	return p


func _run() -> bool:
	var catalog := TC.new()
	var board := BS.new()
	board.start_with(catalog.starter_tile())

	var rule0 := RE.analyze(board)
	if rule0.land_regions.is_empty():
		printerr("[FAIL] starter 无 land_region。")
		return false
	var lr0 = rule0.land_regions[0]
	print("[INFO] starter land_region is_closed=%s S_L=%s open_edges=%d" % [str(lr0.is_closed), str(lr0.S_L), lr0.open_edges.size()])

	# 取该 land_region 里的一个 cell（land_region 对象应暴露其格集合；兜底用 placements 里落在 lr 的格）
	var cell_in_lr := Vector2i(-1, -1)
	# 尝试通过 lr.cells（若存在）
	if "cells" in lr0:
		var cs: Array = lr0.cells
		if not cs.is_empty():
			cell_in_lr = cs[0]
	if cell_in_lr == Vector2i(-1, -1):
		# 兜底：枚举 placements，找 land_regions_at 命中 lr0.id 的格
		for c in board.placements:
			var rgs := board.land_regions_at(c)
			for r in rgs:
				if int(r.id) == int(lr0.id):
					cell_in_lr = c
					break
			if cell_in_lr != Vector2i(-1, -1):
				break

	if cell_in_lr == Vector2i(-1, -1):
		printerr("[FAIL] 无法定位 land_region 内的格。")
		return false
	print("[INFO] 定位到 land_region 内格 %s" % str(cell_in_lr))

	# 注入两株树（各需水 2.0×面积），但该区域 S_L=0（未闭合无水），应全部判死
	_inject_plant(board, PD.Species.TREE, 0, cell_in_lr, 0)
	_inject_plant(board, PD.Species.TREE, 1, cell_in_lr, 1)

	var before: int = board.plants.size()
	print("[INFO] 注入后场上植物数=%d" % before)
	if before != 2:
		printerr("[FAIL] 注入失败。")
		return false

	# 跑终局结算
	var pa = PE.end_game_settle(board)
	var after: int = board.plants.size()
	print("[INFO] end_game_settle 后场上植物数=%d (移除=%d)" % [after, pa.plants_removed.size()])

	# 计分
	var sc = PE.score(board)
	print("[INFO] score 结果=%s" % str(sc.get("scores", {})))

	# 断言 1：两株缺水树都被移除
	if pa.plants_removed.size() != 2:
		printerr("[FAIL] 期望移除 2 株缺水树，实际移除 %d。" % pa.plants_removed.size())
		return false
	if after != 0:
		printerr("[FAIL] 缺水树应全部移除，场上应剩 0 株，实际 %d。" % after)
		return false

	# 断言 2：两玩家均 0 分（死亡植物不计分）
	var scores: Dictionary = sc.get("scores", {})
	for pid in scores:
		if float(scores[pid]) != 0.0:
			printerr("[FAIL] 玩家 %s 应 0 分，实际 %s。" % [str(pid), str(scores[pid])])
			return false

	print("[PASS] 终局需水结算正确：未闭合区域缺水植物被判死移除、不计分。")
	return true
