class_name BoardState
extends RefCounted

# BoardState is the rule authority for tile placement. Visual nodes only read
# the records stored here; they never decide whether a move is legal.
var placements: Dictionary = {}


func start_with(starter: TileDefinition) -> void:
	placements.clear()
	placements[Vector2i.ZERO] = _record(starter, 0, -1)


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
	placements[cell] = _record(definition, quarter_turns, player_id)
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


func _record(definition: TileDefinition, quarter_turns: int, player_id: int) -> Dictionary:
	return {
		"definition": definition,
		"rotation": posmod(quarter_turns, 4),
		"owner_id": player_id,
	}


func _verdict(valid: bool, reason: String) -> Dictionary:
	return {
		"valid": valid,
		"reason": reason,
	}
