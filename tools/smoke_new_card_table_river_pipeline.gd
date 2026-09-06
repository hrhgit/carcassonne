extends SceneTree

# End-to-end build-time smoke for the compact card table: every row selects an
# already-baked prefab, and the former special channel is now a wide RIVER main
# channel with one ordinary narrow WATER branch.
const TILE_CATALOG_SCRIPT := preload("res://scripts/tile_catalog.gd")
const BOARD_STATE_SCRIPT := preload("res://scripts/board_state.gd")
const RULE_ENGINE_SCRIPT := preload("res://scripts/rule_engine.gd")
const RIVER_WATER_BRANCHES_SCENE := preload("res://scenes/tiles_3d/generated/procedural_river_water_branches.tscn")
const RIVER_WIDTH := 1.08
const WATER_WIDTH := 0.48


func _init() -> void:
	call_deferred("_smoke")


func _smoke() -> void:
	var catalog := TILE_CATALOG_SCRIPT.new() as TileCatalog
	get_root().add_child(catalog)
	await process_frame
	if catalog.all_definitions().size() != 27:
		_fail("The active compact table did not load all 27 definitions.")
		return
	var river_cards := catalog.river_setup_deck(_seeded_rng(7331))
	var main_deck := catalog.build_deck()
	if river_cards.size() != 7 or main_deck.size() != 55:
		_fail("The active table does not preserve its 7 setup river cards plus 55 terrain cards.")
		return
	if not _has_expected_main_deck_balance(main_deck):
		_fail("The main deck no longer has 30 LAND+WATER, 15 LAND-only, and 10 WATER-only cards.")
		return
	var starter := catalog.starter_tile()
	if starter == null or starter.id != &"starter_river" or not starter.is_river_tile:
		_fail("The new table did not select the river starter.")
		return
	var terminal: TileDefinition = river_cards.back()
	if terminal == null or terminal.id != &"river_end" or not terminal.river_setup_terminal \
			or terminal.visual_scene == null or starter.visual_scene == null \
			or terminal.visual_scene.resource_path != starter.visual_scene.resource_path:
		_fail("The fixed river terminal does not reuse the starter river prefab.")
		return
	for index in range(river_cards.size() - 1):
		if river_cards[index].river_setup_terminal:
			_fail("A river setup terminal appeared before the shuffled middle cards.")
			return
	if not _shuffle_contract_is_valid(catalog):
		_fail("Main or river decks are no longer reproducibly shuffled with their fixed cards preserved.")
		return
	for definition in catalog.all_definitions():
		if definition.visual_scene == null:
			_fail("Tile %s did not resolve its generated fixed prefab." % definition.id)
			return
		var piece := definition.visual_scene.instantiate() as TileArtwork3D
		if piece == null or not piece.has_valid_authored_contract():
			_fail("Tile %s failed its baked scene contract." % definition.id)
			return
		piece.free()

	var branch_tile := RIVER_WATER_BRANCHES_SCENE.instantiate() as TileArtwork3D
	if branch_tile == null or branch_tile.edge_markers != PackedInt32Array([2, 3, 0, 3]):
		_fail("The generated river branch prefab lost its WATER/RIVER port syntax.")
		return
	get_root().add_child(branch_tile)
	await process_frame
	var land_root := branch_tile.get_node_or_null(^"LandSoil") as Node3D
	var surface := branch_tile.get_node_or_null(^"Water/AnimatedSurface") as MeshInstance3D
	if land_root == null or not land_root.get_children().is_empty() or surface == null or not surface.mesh is ArrayMesh:
		_fail("The river-with-water-branches prefab must have no LAND geometry.")
		return
	var vertices: PackedVector3Array = surface.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if not _has_east_width(vertices, RIVER_WIDTH) or not _has_west_width(vertices, RIVER_WIDTH) \
			or not _has_north_width(vertices, WATER_WIDTH) or _has_south_width(vertices, WATER_WIDTH):
		_fail("The main river or its sole side outlet lost the fixed wide/narrow port contract.")
		return
	if branch_tile.topology == null or branch_tile.topology.water_edges_via_central_hub != PackedInt32Array([0, 1, 3]):
		_fail("The one small WATER route and the main RIVER were not baked through one central hub.")
		return
	branch_tile.queue_free()

	if not _water_branch_joins_small_water_network(catalog):
		_fail("The narrow WATER branch did not join the ordinary small-water network.")
		return
	print("NEW_CARD_TABLE_RIVER_PIPELINE_PASS: 27 fixed prefabs load; the 55-card main deck and six-card river middle shuffle while the starter and matching terminal remain fixed.")
	quit()


func _shuffle_contract_is_valid(catalog: TileCatalog) -> bool:
	var canonical_main := catalog.build_deck(TileDefinition.CARD_TILE)
	var main_a := catalog.build_shuffled_deck(TileDefinition.CARD_TILE, _seeded_rng(101))
	var main_repeat := catalog.build_shuffled_deck(TileDefinition.CARD_TILE, _seeded_rng(101))
	if not _same_contents(canonical_main, main_a) or _deck_signature(main_a) != _deck_signature(main_repeat):
		return false

	var river_a := catalog.river_setup_deck(_seeded_rng(101))
	var river_repeat := catalog.river_setup_deck(_seeded_rng(101))
	if river_a.is_empty() or river_a.back().id != &"river_end" \
			or _deck_signature(river_a) != _deck_signature(river_repeat):
		return false

	var main_varies := false
	var river_middle_varies := false
	var main_signature := _deck_signature(main_a)
	var river_middle_signature := _deck_signature(river_a, river_a.size() - 1)
	for seed_value in range(102, 118):
		var candidate_main := catalog.build_shuffled_deck(TileDefinition.CARD_TILE, _seeded_rng(seed_value))
		var candidate_river := catalog.river_setup_deck(_seeded_rng(seed_value))
		if not _same_contents(canonical_main, candidate_main) or candidate_river.is_empty() \
				or candidate_river.back().id != &"river_end":
			return false
		main_varies = main_varies or _deck_signature(candidate_main) != main_signature
		river_middle_varies = river_middle_varies \
			or _deck_signature(candidate_river, candidate_river.size() - 1) != river_middle_signature
	return main_varies and river_middle_varies


func _has_expected_main_deck_balance(deck: Array[TileDefinition]) -> bool:
	var land_with_water := 0
	var land_without_water := 0
	var water_only := 0
	for definition in deck:
		var has_land := not definition.edge_indices(TileDefinition.EdgeKind.LAND).is_empty()
		var has_water := not definition.edge_indices(TileDefinition.EdgeKind.WATER).is_empty()
		if has_land and has_water:
			land_with_water += 1
		elif has_land:
			land_without_water += 1
		elif has_water:
			water_only += 1
	return land_with_water == 30 and land_without_water == 15 and water_only == 10


func _seeded_rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


func _deck_signature(deck: Array[TileDefinition], limit := -1) -> String:
	var result := ""
	var count := deck.size() if limit < 0 else mini(deck.size(), limit)
	for index in range(count):
		result += "%s|" % deck[index].id
	return result


func _same_contents(first: Array[TileDefinition], second: Array[TileDefinition]) -> bool:
	if first.size() != second.size():
		return false
	var counts := {}
	for definition in first:
		counts[definition.id] = int(counts.get(definition.id, 0)) + 1
	for definition in second:
		if not counts.has(definition.id):
			return false
		counts[definition.id] = int(counts[definition.id]) - 1
		if int(counts[definition.id]) == 0:
			counts.erase(definition.id)
	return counts.is_empty()


func _water_branch_joins_small_water_network(catalog: TileCatalog) -> bool:
	var river: TileDefinition = catalog.get_definition(&"river_water_branches")
	var water: TileDefinition = catalog.get_definition(&"water_opposite")
	if river == null or water == null:
		return false
	if river.edge_indices(TileDefinition.EdgeKind.RIVER).size() != 2 \
			or river.edge_indices(TileDefinition.EdgeKind.WATER).size() != 1:
		return false
	var board := BOARD_STATE_SCRIPT.new()
	board.start_with(river)
	# river 的北 WATER 对接 water_opposite 的南 WATER。这里必须进入
	# 常规水网；它没有独立的特殊水渠规则。
	var placement := board.place(water, Vector2i.UP, 0, 0)
	var analysis = RULE_ENGINE_SCRIPT.analyze(board)
	if not bool(placement.get("valid", false)) or not analysis.land_regions.is_empty() \
			or analysis.water_nets.size() != 1:
		return false
	var net = analysis.water_nets[0]
	return analysis.water_net_by_cell.has(Vector2i.ZERO) \
		and analysis.water_net_by_cell.has(Vector2i.UP) \
		and net.open_edges.size() == 1


func _has_east_width(vertices: PackedVector3Array, expected_width: float) -> bool:
	var samples := PackedFloat32Array()
	for vertex in vertices:
		if is_equal_approx(vertex.x, 2.45) and is_zero_approx(vertex.y):
			samples.append(vertex.z)
	return _matches_width(samples, expected_width)


func _has_north_width(vertices: PackedVector3Array, expected_width: float) -> bool:
	var samples := PackedFloat32Array()
	for vertex in vertices:
		if is_equal_approx(vertex.z, -2.45) and is_zero_approx(vertex.y):
			samples.append(vertex.x)
	return _matches_width(samples, expected_width)


func _has_south_width(vertices: PackedVector3Array, expected_width: float) -> bool:
	var samples := PackedFloat32Array()
	for vertex in vertices:
		if is_equal_approx(vertex.z, 2.45) and is_zero_approx(vertex.y):
			samples.append(vertex.x)
	return _matches_width(samples, expected_width)


func _has_west_width(vertices: PackedVector3Array, expected_width: float) -> bool:
	var samples := PackedFloat32Array()
	for vertex in vertices:
		if is_equal_approx(vertex.x, -2.45) and is_zero_approx(vertex.y):
			samples.append(vertex.z)
	return _matches_width(samples, expected_width)


func _matches_width(samples: PackedFloat32Array, expected_width: float) -> bool:
	if samples.size() < 2:
		return false
	var minimum := samples[0]
	var maximum := samples[0]
	for value in samples:
		minimum = minf(minimum, value)
		maximum = maxf(maximum, value)
	return is_equal_approx(maximum - minimum, expected_width)


func _fail(message: String) -> void:
	push_error("NEW_CARD_TABLE_RIVER_PIPELINE_FAIL: " + message)
	quit(1)
