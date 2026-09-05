class_name TileDefinition
extends Resource

enum Edge {
	NORTH,
	EAST,
	SOUTH,
	WEST,
}

enum EdgeKind {
	EMPTY,
	LAND,
	WATER,
}

var id: StringName
var display_name := ""
var edges := PackedInt32Array([EdgeKind.EMPTY, EdgeKind.EMPTY, EdgeKind.EMPTY, EdgeKind.EMPTY])
# Kept for compatibility with the old visual-study nodes. The playable board
# deliberately never enables growth or planting in this milestone.
var starts_grown := false
var visual_seed := 0
var irrigated_land_edges := PackedInt32Array()
var visual_scene: PackedScene
var visual_rotation_quarters := 0


func configure(
	new_id: StringName,
	new_display_name: String,
	new_edges: PackedInt32Array,
	new_starts_grown: bool,
	new_visual_seed: int,
	new_irrigated_land_edges := PackedInt32Array(),
	new_visual_scene: PackedScene = null,
	new_visual_rotation_quarters := 0,
) -> void:
	if new_edges.size() != 4:
		push_error("A tile definition must have exactly four edge values.")
		return
	for edge_kind in new_edges:
		if edge_kind < EdgeKind.EMPTY or edge_kind > EdgeKind.WATER:
			push_error("Tile definitions can only use EMPTY, LAND, or WATER edge markers.")
			return
	id = new_id
	display_name = new_display_name
	edges = new_edges.duplicate()
	starts_grown = new_starts_grown
	visual_seed = new_visual_seed
	irrigated_land_edges = new_irrigated_land_edges.duplicate()
	visual_scene = new_visual_scene
	visual_rotation_quarters = int(posmod(new_visual_rotation_quarters, 4))
	if irrigated_land_edges.is_empty() and not edge_indices(EdgeKind.WATER).is_empty():
		# In this first placement-only slice every water route branches into each
		# land region. Storing the targets makes the invariant explicit in data.
		irrigated_land_edges = edge_indices(EdgeKind.LAND)
	if not has_valid_irrigation():
		push_error("Every water edge must route to at least one land edge on the same tile.")


func edge_indices(kind: int, quarter_turns := 0) -> PackedInt32Array:
	var indices := PackedInt32Array()
	for edge in range(4):
		if edge_kind_at(edge, quarter_turns) == kind:
			indices.append(edge)
	return indices


func land_edge_count() -> int:
	return edge_indices(EdgeKind.LAND).size()


func edge_kind_at(world_edge: int, quarter_turns := 0) -> int:
	if edges.size() != 4:
		return EdgeKind.EMPTY
	# A clockwise quarter turn moves the original north edge to the east, so a
	# world-space lookup reads the source edge in the opposite direction.
	var source_edge := int(posmod(world_edge - quarter_turns, 4))
	return edges[source_edge]


func has_valid_irrigation() -> bool:
	var water_edges := edge_indices(EdgeKind.WATER)
	if water_edges.is_empty():
		return true
	if irrigated_land_edges.is_empty():
		return false
	for land_edge in irrigated_land_edges:
		if land_edge < Edge.NORTH or land_edge > Edge.WEST:
			return false
		if edges[land_edge] != EdgeKind.LAND:
			return false
	return true


func is_playable() -> bool:
	return edges.size() == 4 and has_valid_irrigation() and visual_scene != null


static func edge_kind_label(kind: int) -> String:
	match kind:
		EdgeKind.LAND:
			return "土地"
		EdgeKind.WATER:
			return "水流"
		_:
			return "空地"
