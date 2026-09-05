class_name TileTopology3D
extends Resource

# Static authoring data for a fixed 3D tile prefab.  It never creates meshes or
# changes a tile at runtime; the scene remains the sole owner of its geometry.
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

enum DoubleLandTopology {
	NOT_APPLICABLE,
	CENTER_CONNECTED,
	CENTER_SPLIT,
}

@export var id: StringName
@export var edge_markers := PackedInt32Array([EdgeKind.EMPTY, EdgeKind.EMPTY, EdgeKind.EMPTY, EdgeKind.EMPTY])
# Each region has a stable id plus a four-bit edge mask.  Bit 0 is north, then
# east, south, and west.  This keeps connected and split two-edge fields
# explicit without asking runtime code to infer visual geometry.
@export var land_region_ids := PackedStringArray()
@export var land_region_edge_masks := PackedInt32Array()
@export var double_land_topology: DoubleLandTopology = DoubleLandTopology.NOT_APPLICABLE
# Every water port travels inward on its centre-directed route. It either stops
# at the first LAND contact or reaches the central hub. Only a hub-reaching
# route may turn or branch.
@export var water_edges_ending_at_land := PackedInt32Array()
@export var water_edges_via_central_hub := PackedInt32Array()
# This remains false for visual studies until an editor-time mesh check proves
# their baked water, land, and edge geometry follow the declared topology.
@export var visual_geometry_is_verified := false


func is_structurally_valid() -> bool:
	if id.is_empty() or edge_markers.size() != 4:
		return false
	for marker in edge_markers:
		if marker < EdgeKind.EMPTY or marker > EdgeKind.WATER:
			return false

	var land_mask := _marker_mask(EdgeKind.LAND)
	var water_mask := _marker_mask(EdgeKind.WATER)
	if water_mask != 0 and land_mask == 0:
		return false
	if land_region_ids.size() != land_region_edge_masks.size():
		return false

	var documented_land_mask := 0
	for index in range(land_region_ids.size()):
		if land_region_ids[index].is_empty():
			return false
		var region_mask := land_region_edge_masks[index]
		if region_mask <= 0 or (region_mask & ~land_mask) != 0:
			return false
		if (documented_land_mask & region_mask) != 0:
			return false
		documented_land_mask |= region_mask
	if documented_land_mask != land_mask:
		return false

	if not _has_complete_water_routing(water_mask):
		return false

	var land_count := _count_bits(land_mask)
	if land_count == 2:
		return double_land_topology != DoubleLandTopology.NOT_APPLICABLE
	return double_land_topology == DoubleLandTopology.NOT_APPLICABLE


func is_canonical() -> bool:
	return is_structurally_valid() and visual_geometry_is_verified


func matches_edge_markers(markers: PackedInt32Array) -> bool:
	if not is_structurally_valid() or markers.size() != edge_markers.size():
		return false
	for edge in range(edge_markers.size()):
		if markers[edge] != edge_markers[edge]:
			return false
	return true


func _marker_mask(kind: int) -> int:
	var mask := 0
	for edge in range(edge_markers.size()):
		if edge_markers[edge] == kind:
			mask |= 1 << edge
	return mask


func _edge_mask(edges: PackedInt32Array) -> int:
	var mask := 0
	for edge in edges:
		if edge < Edge.NORTH or edge > Edge.WEST:
			return -1
		var bit := 1 << edge
		if (mask & bit) != 0:
			return -1
		mask |= bit
	return mask


func _has_complete_water_routing(water_mask: int) -> bool:
	var land_ending_mask := _edge_mask(water_edges_ending_at_land)
	var hub_mask := _edge_mask(water_edges_via_central_hub)
	if land_ending_mask < 0 or hub_mask < 0:
		return false
	if (land_ending_mask & hub_mask) != 0:
		return false
	return (land_ending_mask | hub_mask) == water_mask


func _count_bits(mask: int) -> int:
	var count := 0
	for edge in range(4):
		if (mask & (1 << edge)) != 0:
			count += 1
	return count
