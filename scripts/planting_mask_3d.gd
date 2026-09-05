class_name PlantingMask3D
extends Resource

# Editor-time source of truth for where a sowable plant may stand on a tile.
# Coordinates are local X/Z values encoded as Vector2(x, z). The soil mesh is
# authored separately, but its usable interior must be represented here rather
# than inferred from its material colour or from nearby water geometry.
@export var id: StringName
@export var boundary: PackedVector2Array = PackedVector2Array()
@export var exclusion_zones: Array[PackedVector2Array] = []
@export_range(0.0, 2.0, 0.01) var edge_clearance := 0.14
@export var surface_height := 0.0


func is_valid() -> bool:
	if id.is_empty() or boundary.size() < 3 or absf(_signed_area(boundary)) < 0.001:
		return false
	for zone in exclusion_zones:
		if zone.size() < 3:
			return false
	return true


func contains_point(point: Vector2, additional_clearance := 0.0) -> bool:
	if not is_valid() or not Geometry2D.is_point_in_polygon(point, boundary):
		return false
	if _distance_to_edges(point, boundary) < edge_clearance + additional_clearance:
		return false
	for zone in exclusion_zones:
		if Geometry2D.is_point_in_polygon(point, zone):
			return false
		if _distance_to_edges(point, zone) < additional_clearance:
			return false
	return true


func get_bounds() -> Rect2:
	if boundary.is_empty():
		return Rect2()
	var minimum := boundary[0]
	var maximum := boundary[0]
	for point in boundary:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return Rect2(minimum, maximum - minimum)


func distance_to_boundary(point: Vector2) -> float:
	if boundary.size() < 3:
		return 0.0
	return _distance_to_edges(point, boundary)


func _distance_to_edges(point: Vector2, polygon: PackedVector2Array) -> float:
	var closest_distance := INF
	for index in range(polygon.size()):
		var start := polygon[index]
		var end := polygon[(index + 1) % polygon.size()]
		var closest := Geometry2D.get_closest_point_to_segment(point, start, end)
		closest_distance = minf(closest_distance, point.distance_to(closest))
	return closest_distance


func _signed_area(polygon: PackedVector2Array) -> float:
	var doubled_area := 0.0
	for index in range(polygon.size()):
		var point := polygon[index]
		var next_point := polygon[(index + 1) % polygon.size()]
		doubled_area += point.x * next_point.y - next_point.x * point.y
	return doubled_area * 0.5
