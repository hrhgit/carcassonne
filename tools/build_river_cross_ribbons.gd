extends SceneTree

const OUTPUT_DIRECTORY := "res://art/generated"
const BANK_OUTPUT := OUTPUT_DIRECTORY + "/river_cross_bank_mesh.tres"
const WATER_OUTPUT := OUTPUT_DIRECTORY + "/river_cross_water_mesh.tres"

# East/west ports remain exactly centered and straight at the tile boundary.
# The inner points are intentionally asymmetric so the water reads as a river,
# not as four primitive boxes intersecting in the middle.
const MAIN_RIVER := [
	Vector2(-2.45, 0.0),
	Vector2(-2.08, 0.0),
	Vector2(-1.68, -0.12),
	Vector2(-1.18, -0.29),
	Vector2(-0.67, -0.31),
	Vector2(-0.18, -0.12),
	Vector2(0.31, 0.16),
	Vector2(0.86, 0.31),
	Vector2(1.42, 0.24),
	Vector2(1.95, 0.06),
	Vector2(2.45, 0.0),
]

const NORTH_IRRIGATION_BRANCH := [
	Vector2(-0.18, -0.12),
	Vector2(-0.27, -0.43),
	Vector2(-0.19, -0.76),
	Vector2(0.03, -1.08),
	Vector2(0.1, -1.42),
]

const SOUTH_IRRIGATION_BRANCH := [
	Vector2(0.31, 0.16),
	Vector2(0.44, 0.45),
	Vector2(0.4, 0.76),
	Vector2(0.2, 1.08),
	Vector2(0.13, 1.42),
]


func _init() -> void:
	call_deferred("_build_resources")


func _build_resources() -> void:
	var absolute_directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		push_error("Unable to create generated mesh directory: %s" % error_string(directory_error))
		quit(1)
		return

	var bank_mesh := _build_combined_ribbons(0.76, 0.68)
	var water_mesh := _build_combined_ribbons(0.48, 0.38)
	var bank_error := ResourceSaver.save(bank_mesh, BANK_OUTPUT)
	var water_error := ResourceSaver.save(water_mesh, WATER_OUTPUT)
	if bank_error != OK or water_error != OK:
		push_error("Unable to save fixed river meshes: bank=%s water=%s" % [
			error_string(bank_error),
			error_string(water_error),
		])
		quit(1)
		return

	print("RIVER_CROSS_RIBBONS_BUILT: %s and %s" % [BANK_OUTPUT, WATER_OUTPUT])
	quit()


func _build_combined_ribbons(main_width: float, branch_width: float) -> ArrayMesh:
	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_ribbon(surface_tool, MAIN_RIVER, main_width, 0.0)
	# A minute height offset avoids coplanar overlap at each authored junction.
	_append_ribbon(surface_tool, NORTH_IRRIGATION_BRANCH, branch_width, 0.002)
	_append_ribbon(surface_tool, SOUTH_IRRIGATION_BRANCH, branch_width, 0.002)
	return surface_tool.commit()


func _append_ribbon(
	surface_tool: SurfaceTool,
	points: Array,
	width: float,
	height_offset: float,
) -> void:
	var cumulative_distances: Array[float] = [0.0]
	for point_index in range(1, points.size()):
		var segment_length: float = points[point_index].distance_to(points[point_index - 1])
		cumulative_distances.append(cumulative_distances[-1] + segment_length)
	var total_length: float = cumulative_distances[-1]

	var left_points: Array[Vector2] = []
	var right_points: Array[Vector2] = []
	for point_index in range(points.size()):
		var tangent := _point_tangent(points, point_index)
		var perpendicular := Vector2(-tangent.y, tangent.x)
		left_points.append(points[point_index] + perpendicular * width * 0.5)
		right_points.append(points[point_index] - perpendicular * width * 0.5)

	for point_index in range(points.size() - 1):
		var current_u: float = cumulative_distances[point_index] / total_length
		var next_u: float = cumulative_distances[point_index + 1] / total_length
		_add_vertex(surface_tool, left_points[point_index], height_offset, Vector2(current_u, 0.0))
		_add_vertex(surface_tool, left_points[point_index + 1], height_offset, Vector2(next_u, 0.0))
		_add_vertex(surface_tool, right_points[point_index], height_offset, Vector2(current_u, 1.0))

		_add_vertex(surface_tool, right_points[point_index], height_offset, Vector2(current_u, 1.0))
		_add_vertex(surface_tool, left_points[point_index + 1], height_offset, Vector2(next_u, 0.0))
		_add_vertex(surface_tool, right_points[point_index + 1], height_offset, Vector2(next_u, 1.0))


func _point_tangent(points: Array, point_index: int) -> Vector2:
	if point_index == 0:
		return (points[1] - points[0]).normalized()
	if point_index == points.size() - 1:
		return (points[-1] - points[-2]).normalized()
	return (points[point_index + 1] - points[point_index - 1]).normalized()


func _add_vertex(
	surface_tool: SurfaceTool,
	point: Vector2,
	height_offset: float,
	uv: Vector2,
) -> void:
	surface_tool.set_normal(Vector3.UP)
	surface_tool.set_uv(uv)
	surface_tool.add_vertex(Vector3(point.x, height_offset, point.y))
