## 针对性验证：多土地地块多 region 建模 + 单次命中子区种植 + 收获锁区（§2.4.3 / §5.1 / §5.6.1 / §6.2）
## 运行：godot --headless --path . --script tools/verify_multi_region_lock.gd
extends SceneTree

const PE = preload("res://scripts/plant_engine.gd")
const BS = preload("res://scripts/board_state.gd")
const RE = preload("res://scripts/rule_engine.gd")
const PD = preload("res://scripts/plant.gd")
const TC = preload("res://scripts/tile_catalog.gd")
const RUNTIME_PLANT_SCATTER = preload("res://scripts/runtime_plant_scatter_3d.gd")
const SPLIT_TILE_SCENE = preload("res://scenes/tiles_3d/generated/procedural_land_opposite_edges_split.tscn")


func _init() -> void:
	var ok := _run()
	quit(0 if ok else 1)


func _run() -> bool:
	var catalog := TC.new()
	catalog._load_from_csv()  # --script 模式下 _ready 不执行，需手动加载 CSV

	# === A：中心 EMPTY 多 land 边 → 多个独立 land_region（§2.4.3） ===
	var split_def = catalog.get_definition(&"land_opposite_edges_split")
	if split_def == null:
		printerr("[FAIL] 找不到 land_opposite_edges_split")
		return false
	if split_def.center_kind != TileDefinition.CenterKind.EMPTY:
		printerr("[FAIL] land_opposite_edges_split 应为 CENTER_EMPTY")
		return false

	var board := BS.new()
	board.start_with(split_def)
	var rule := RE.analyze(board)
	print("[INFO] A: split 卡 land_regions=%d（期望 2）" % rule.land_regions.size())
	if rule.land_regions.size() != 2:
		printerr("[FAIL] A: 中心 EMPTY 的 N/S 两条 land 边应各成独立 region（共 2），实际 %d" % rule.land_regions.size())
		return false
	var regs: Array = rule.land_regions_by_cell.get(Vector2i.ZERO, [])
	if regs.size() != 2:
		printerr("[FAIL] A: (0,0) 应属于 2 个 region，实际 %d" % regs.size())
		return false
	# 两个 region 各自只有一条开放边（N 边 / S 边），互不连通
	var open_total := 0
	for lr in rule.land_regions:
		open_total += lr.open_edges.size()
	if open_total != 2:
		printerr("[FAIL] A: 两个 region 应各有 1 条开放 land 边（共 2），实际 %d" % open_total)
		return false
	print("[PASS] A: 中心 EMPTY 多 land 边 → 2 个独立 land_region")

	# === 对照：中心 LAND 多 land 边 → 合并为 1 个 region（§2.4.2） ===
	var merged_def = catalog.get_definition(&"land_opposite_edges")
	if merged_def == null:
		printerr("[FAIL] 找不到 land_opposite_edges")
		return false
	var board_m := BS.new()
	board_m.start_with(merged_def)
	var rule_m := RE.analyze(board_m)
	print("[INFO] 对照: center LAND 对边 land_regions=%d（期望 1）" % rule_m.land_regions.size())
	if rule_m.land_regions.size() != 1:
		printerr("[FAIL] 对照: 中心 LAND 的多 land 边应合并为 1 个 region，实际 %d" % rule_m.land_regions.size())
		return false
	print("[PASS] 对照: 中心 LAND 多 land 边 → 1 个 region")

	# === B：种植 split 格 → 一次只种一块地（1 动作 1 种子 1 株），可再种另一块地 ===
	var board_b := BS.new()
	board_b.start_with(split_def)
	var deal := board_b.deal_tile(split_def)
	if not bool(deal["valid"]):
		printerr("[FAIL] B: 抽牌失败 %s" % str(deal["reason"]))
		return false
	# 放到 (1,0)：其 W=EMPTY 接 (0,0) 的 E=EMPTY
	var placed := board_b.commit_placement(Vector2i(1, 0), 0)
	if not bool(placed["valid"]):
		printerr("[FAIL] B: 放置失败 %s" % str(placed["reason"]))
		return false
	var grass_before := int(board_b.seed_inventory[0][PD.Species.GRASS])
	# (1,0) 是 split 卡，有 2 块地（subnet 0 和 1）。第一次种 subnet 0。
	var planted := board_b.plant(Vector2i(1, 0), PD.Species.GRASS, 0, 0)
	if not bool(planted["valid"]):
		printerr("[FAIL] B: 种植失败 %s" % str(planted["reason"]))
		return false
	var ids: Array = planted.get("plant_ids", [])
	print("[INFO] B: 第一次种植 (1,0) subnet 0 创建 plant_ids=%s（期望 1 株）" % str(ids))
	if ids.size() != 1:
		printerr("[FAIL] B: 一次种植应只落 1 株（一块地），实际 %d" % ids.size())
		return false
	# 消耗 1 枚种子
	if int(board_b.seed_inventory[0][PD.Species.GRASS]) != grass_before - 1:
		printerr("[FAIL] B: 一次种植应消耗 1 枚种子，实际消耗 %d" % (grass_before - int(board_b.seed_inventory[0][PD.Species.GRASS])))
		return false
	# 该格还剩 1 块空地上（subnet 1）未被占据
	if board_b.region_has_any_plant(Vector2i(1, 0), 0) != true:
		printerr("[FAIL] B: subnet 0 应已有植物")
		return false
	if board_b.region_has_any_plant(Vector2i(1, 0), 1) != false:
		printerr("[FAIL] B: subnet 1 应仍为空")
		return false
	print("[PASS] B: split 格一次只种一块地 → 1 株、耗 1 种子、另一块地仍空")

	# === E：运行时植物可视状态不得跨越 split 卡的另一块 LAND ===
	if not _verify_split_runtime_visibility():
		return false

	# === D：一格多株 —— 两块地各自独立种（每块地一株） ===
	# 每回合只能主动种植一次；模拟进入新回合（重置 planting_action_used）后，
	# 同格的另一块地（subnet 1）仍可种植，而已种的 subnet 0 不可再种。
	board_b.planting_action_used = false
	var check_subnet1 := board_b.can_plant_at(Vector2i(1, 0), PD.Species.GRASS, 0, 1)
	print("[INFO] D: 已种 subnet 0 后，can_plant_at subnet 1 = %s（期望 valid=true）" % str(check_subnet1["valid"]))
	if not bool(check_subnet1["valid"]):
		printerr("[FAIL] D: 一格多块地，subnet 0 已种不应阻止 subnet 1 种植。reason=%s" % str(check_subnet1["reason"]))
		return false
	# 而 subnet 0 已种，再种 subnet 0 应被拒
	var check_subnet0_again := board_b.can_plant_at(Vector2i(1, 0), PD.Species.GRASS, 0, 0)
	if bool(check_subnet0_again["valid"]):
		printerr("[FAIL] D: subnet 0 已有植物，再种应被拒")
		return false
	print("[PASS] D: 一格多株 —— 每块地独立占用、独立可种")

	# === C：收获锁区（§5.6.1）—— 锁定后禁种 + 免疫驱逐 ===
	var board_c := BS.new()
	board_c.start_with(split_def)
	var rule_c := RE.analyze(board_c)
	# 锁定 (0,0) 的所有 region
	for lr in rule_c.land_regions:
		board_c.lock_region_by_key(RE.stable_region_key(lr))
	if not board_c.any_region_locked_at(Vector2i.ZERO):
		printerr("[FAIL] C: 锁定后 any_region_locked_at(0,0) 应为 true")
		return false
	# 再放一格 (1,0)，它未锁定，可种植；但 (0,0) 已锁定不可种
	var deal_c := board_c.deal_tile(split_def)
	var placed_c := board_c.commit_placement(Vector2i(1, 0), 0)
	if not bool(placed_c["valid"]):
		printerr("[FAIL] C: 放置失败 %s" % str(placed_c["reason"]))
		return false
	# (0,0) 不是本回合放置格，本来也种不了；这里验证锁定检查本身对"本回合放置格"生效：
	# 锁定 (1,0) 的 region 后，种植 (1,0) 应被拒
	var rule_c2 := RE.analyze(board_c)
	for lr in rule_c2.land_regions:
		for m in lr.subnets:
			if m[0] == Vector2i(1, 0):
				board_c.lock_region_by_key(RE.stable_region_key(lr))
	var denied := board_c.plant(Vector2i(1, 0), PD.Species.GRASS, 0)
	if bool(denied["valid"]):
		printerr("[FAIL] C: 目标格 region 已锁定，种植应被拒")
		return false
	if not String(denied["reason"]).contains("锁定"):
		printerr("[FAIL] C: 拒绝原因应提及锁定，实际 %s" % str(denied["reason"]))
		return false
	print("[PASS] C: 收获锁区——锁定后种植被拒")

	print("[DONE] verify_multi_region_lock 全部通过。")
	return true


func _verify_split_runtime_visibility() -> bool:
	var tile := SPLIT_TILE_SCENE.instantiate() as TileArtwork3D
	if tile == null:
		printerr("[FAIL] E: 无法实例化 split 地块预制件")
		return false
	root.add_child(tile)
	tile.set_runtime_plant_layout(RUNTIME_PLANT_SCATTER.generate_for_tile(tile, 72_019))
	tile.set_growth_state(TileArtwork3D.GrowthState.GROWING)
	var selected_key := "%d:%d" % [0, PD.Species.GRASS]
	tile.set_runtime_plant_states({
		selected_key: {
			"growth_state": TileArtwork3D.GrowthState.GROWING,
			"owner_color": Color("#f26b4d"),
		},
	})
	var selected_visible := 0
	var other_visible := 0
	for plant in tile.get_runtime_plants():
		if int(plant.get_meta("game_species", -1)) != PD.Species.GRASS or not plant.visible:
			continue
		var mask_id := String(plant.get_meta("planting_mask_id", &""))
		if mask_id.contains("_region_0_"):
			selected_visible += 1
		elif mask_id.contains("_region_1_"):
			other_visible += 1
		else:
			printerr("[FAIL] E: 运行时植物没有可识别的烘焙 planting mask")
			tile.free()
			return false
	tile.free()
	if selected_visible <= 0:
		printerr("[FAIL] E: 选中的 split LAND 没有显示草")
		return false
	if other_visible != 0:
		printerr("[FAIL] E: 只选 region 0 时 region 1 仍显示了 %d 株草" % other_visible)
		return false
	print("[PASS] E: split 格按 land_subnet 显示植物，未选的 LAND 保持裸土")
	return true
