class_name PlantScatterLayout3D
extends Resource

@export var id: StringName
@export var planting_mask: PlantingMask3D
@export var seed := 0
@export var placements: Array[PlantScatterPlacement3D] = []


func is_valid() -> bool:
	if id.is_empty() or planting_mask == null or not planting_mask.is_valid() or placements.is_empty():
		return false
	for placement in placements:
		if placement == null or placement.profile == null or not placement.profile.is_valid():
			return false
		var point := Vector2(placement.local_position.x, placement.local_position.z)
		if not planting_mask.contains_point(point, placement.profile.extra_edge_clearance + placement.profile.footprint_radius):
			return false
	return true
