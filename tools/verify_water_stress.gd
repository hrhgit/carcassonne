## 针对性验证：estimate_water_stress 缺水标记。
## 构造未闭合 S_L=0 区域注入存活植物 → 应全部标记缺水；水够场景应不标记。
## 运行：godot --headless --path . --script tools/verify_water_stress.gd
extends SceneTree

const PE = preload("res://scripts/plant_engine.gd")
const BS = preload("res://scripts/board_state.gd")
const RE = preload("res://scripts/rule_engine.gd")
const PD = preload("res://scripts/plant.gd")
const TC = preload("res://scripts/tile_catalog.gd")


func _init() -> void:
	var ok := _run()
	quit(0 if ok else 1)


func _inject(board, species: int, owner: int, cell: Vector2i, order: int) -> Plant:
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
	print("[INFO] starter is_closed=%s S_L=%s" % [str(lr0.is_closed), str(lr0.S_L)])

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

	# 注入 2 株树（各需水 2.0×面积），S_L=0 → 全部缺水
	var p0 := _inject(board, PD.Species.TREE, 0, cell, 0)
	var p1 := _inject(board, PD.Species.TREE, 1, cell, 1)

	var stressed := PE.estimate_water_stress(board)
	print("[INFO] stressed=%s" % str(stressed))

	if not bool(stressed.get(int(p0.id), false)):
		printerr("[FAIL] p0 应标记缺水。")
		return false
	if not bool(stressed.get(int(p1.id), false)):
		printerr("[FAIL] p1 应标记缺水。")
		return false

	# 断言：estimate_water_stress 是纯读，不移除植物、不改 form
	if board.plants.size() != 2:
		printerr("[FAIL] estimate_water_stress 不应移除植物。")
		return false
	if int(p0.form) != PD.Form.SURVIVING:
		printerr("[FAIL] estimate_water_stress 不应修改 form。")
		return false

	print("[PASS] estimate_water_stress：未闭合无水区域存活植物均标记缺水，且纯读不改状态。")
	return true
