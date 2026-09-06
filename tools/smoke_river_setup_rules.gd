extends SceneTree

# Rule-level smoke for the new compact card table. The runtime smoke in
# main.gd covers the UI route; this one makes the river-specific invariants
# explicit and deterministic without relying on camera input.
const TILE_CATALOG_SCRIPT := preload("res://scripts/tile_catalog.gd")
const BOARD_STATE_SCRIPT := preload("res://scripts/board_state.gd")
const RULE_ENGINE_SCRIPT := preload("res://scripts/rule_engine.gd")


func _init() -> void:
	call_deferred("_smoke")


func _smoke() -> void:
	var catalog := TILE_CATALOG_SCRIPT.new() as TileCatalog
	get_root().add_child(catalog)
	await process_frame
	var starter := catalog.starter_tile()
	var river_cards := catalog.river_setup_deck(_seeded_rng(241))
	if starter == null or starter.id != &"starter_river" or river_cards.size() != 7 \
			or river_cards.back().id != &"river_end" or not river_cards.back().river_setup_terminal:
		_fail("The compact table did not provide its fixed river starter, six shuffled middle cards, and terminal.")
		return
	if not _has_expected_middle_mix(river_cards):
		_fail("The river middle cards are not three curves, one straight, and two single-water-branch rivers.")
		return
	for index in range(river_cards.size() - 1):
		if river_cards[index].river_setup_terminal:
			_fail("The river terminal was mixed into the shuffled middle cards.")
			return
	var board := BOARD_STATE_SCRIPT.new() as BoardState
	board.start_with(starter, 2)
	if not _rejects_empty_edge_river_island(board, catalog.get_definition(&"river_curve")):
		_fail("A river tile could form a disconnected island through matching EMPTY edges.")
		return
	var seeds_before: Dictionary = board.seed_inventory.duplicate(true)
	for card in river_cards:
		var definition: TileDefinition = card
		if not definition.is_river_tile or definition.card_type != TileDefinition.CARD_RIVER:
			_fail("The river setup deck contains a non-river card: %s." % definition.id)
			return
		var deal := board.deal_tile(definition)
		if not bool(deal.get("valid", false)):
			_fail("River setup draw failed: %s." % deal.get("reason", "unknown"))
			return
		var move := _first_legal_move(board, definition)
		if move.is_empty():
			var skipped := board.skip_unplaceable_river_setup_tile()
			if not bool(skipped.get("valid", false)):
				_fail("A genuinely unplaceable river card could not be skipped.")
				return
			_fail("The authored 7-card river deck unexpectedly produced an unplaceable card.")
			return
		var placed := board.commit_river_setup_placement(move["cell"], int(move["rotation"]))
		if not bool(placed.get("valid", false)):
			_fail("Legal river placement was rejected: %s." % placed.get("reason", "unknown"))
			return
		if int(board.phase) != BoardState.Phase.DEAL or board.tile_to_place != null \
				or not board.turn_placed_cells.is_empty():
			_fail("A river setup placement leaked a normal-turn action state.")
			return
		if not board.plants.is_empty() or board.seed_inventory != seeds_before:
			_fail("River setup triggered plant logic or altered seed inventory.")
			return

	if board.placements.size() != 8 or board.active_player != 1 or board.turn_number != 8:
		_fail("River setup did not advance exactly once per one of the seven cards.")
		return
	var river_analysis = RULE_ENGINE_SCRIPT.analyze(board)
	if not river_analysis.land_regions.is_empty():
		_fail("River setup unexpectedly created a LAND region.")
		return
	if not _setup_branch_tiles_join_water_network(board, river_analysis):
		_fail("The placed river branch cards did not enter the ordinary small-water network.")
		return
	if not _river_water_branch_card_is_normal_water(catalog):
		_fail("The former special channel was not converted to a normal WATER branch on the river.")
		return
	print("RIVER_SETUP_RULES_PASS: six shuffled middle river cards and the fixed terminal stay globally connected, bypass plant actions, and keep the normal single WATER branches.")
	quit()


func _seeded_rng(seed_value: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng


# starter_river exposes EMPTY to its east. A rotated curve can match that
# EMPTY edge while keeping all of its RIVER ports separate; global component
# validation must reject precisely that otherwise-locally-valid placement.
func _rejects_empty_edge_river_island(board: BoardState, curve: TileDefinition) -> bool:
	if curve == null:
		return false
	var verdict := board.can_place(curve, Vector2i.RIGHT, 2)
	return not bool(verdict.get("valid", false)) and String(verdict.get("reason", "")).contains("孤立河段")


func _first_legal_move(board: BoardState, definition: TileDefinition) -> Dictionary:
	for occupied in board.occupied_cells():
		for edge in range(4):
			var candidate := BoardState.neighbour_for_edge(occupied, edge)
			if board.has_tile(candidate):
				continue
			for rotation in range(4):
				if bool(board.can_place(definition, candidate, rotation).get("valid", false)):
					return {"cell": candidate, "rotation": rotation}
	return {}


func _has_expected_middle_mix(river_cards: Array[TileDefinition]) -> bool:
	var counts := {}
	for definition in river_cards:
		if definition.river_setup_terminal:
			continue
		var id := String(definition.id)
		counts[id] = int(counts.get(id, 0)) + 1
	return counts.size() == 3 \
		and int(counts.get("river_curve", 0)) == 3 \
		and int(counts.get("river_straight", 0)) == 1 \
		and int(counts.get("river_water_branches", 0)) == 2


func _setup_branch_tiles_join_water_network(board: BoardState, analysis) -> bool:
	var branch_count := 0
	for cell in board.occupied_cells():
		var placement: Dictionary = board.get_placement(cell)
		var definition: TileDefinition = placement["definition"]
		if definition.id != &"river_water_branches":
			continue
		branch_count += 1
		if not analysis.water_net_by_cell.has(cell):
			return false
	return branch_count == 2


func _river_water_branch_card_is_normal_water(catalog: TileCatalog) -> bool:
	var river: TileDefinition = catalog.get_definition(&"river_water_branches")
	var water: TileDefinition = catalog.get_definition(&"water_opposite")
	if river == null or water == null:
		return false
	if river.edge_indices(TileDefinition.EdgeKind.RIVER).size() != 2 \
			or river.edge_indices(TileDefinition.EdgeKind.WATER).size() != 1:
		return false
	var board := BOARD_STATE_SCRIPT.new() as BoardState
	board.start_with(river, 2)
	# 北侧细水口接普通 WATER；它应成为正常水网成员。
	var placement := board.place(water, Vector2i.UP, 0, 0)
	var analysis = RULE_ENGINE_SCRIPT.analyze(board)
	if not bool(placement.get("valid", false)) or not analysis.land_regions.is_empty() \
			or analysis.water_nets.size() != 1:
		return false
	var net = analysis.water_nets[0]
	return analysis.water_net_by_cell.has(Vector2i.ZERO) \
		and analysis.water_net_by_cell.has(Vector2i.UP) \
		and net.open_edges.size() == 1


func _fail(message: String) -> void:
	push_error("RIVER_SETUP_RULES_FAIL: " + message)
	quit(1)
