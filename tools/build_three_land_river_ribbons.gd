extends SceneTree

const OUTPUT_DIRECTORY := "res://art/generated"
const BANK_OUTPUT := OUTPUT_DIRECTORY + "/three_land_river_bank_mesh.tres"
const WATER_OUTPUT := OUTPUT_DIRECTORY + "/three_land_river_water_mesh.tres"
# A denser fixed mesh keeps the baked shoreline-distance field accurate along
# the short channel rather than interpolating broad triangular bands.
const SURFACE_SUBDIVISIONS := 3

# One river, one mouth. The water stays a narrow straight tongue inside the
# south-side green lobe, so the reference layout keeps its broad soil U-shape.
# It enters exactly through the bottom-edge centre and stops against the
# meadow's inner soil boundary, visibly irrigating the connected field.
const MAIN_RIVER := [
	Vector2(0.0, 2.45),
	# The first two points stay collinear so the ribbon cap stays exactly on the
	# tile boundary instead of drifting sideways with the first tangent.
	Vector2(0.0, 2.02),
	Vector2(0.0, 1.57),
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

	var bank_mesh := _build_river_mesh(0.76)
	var water_mesh := _build_river_mesh(0.48)
	if bank_mesh.get_surface_count() == 0 or water_mesh.get_surface_count() == 0:
		push_error("Unable to build the single-channel river meshes.")
		quit(1)
		return
	var bank_error := ResourceSaver.save(bank_mesh, BANK_OUTPUT)
	var water_error := ResourceSaver.save(water_mesh, WATER_OUTPUT)
	if bank_error != OK or water_error != OK:
		push_error("Unable to save fixed river meshes: bank=%s water=%s" % [
			error_string(bank_error),
			error_string(water_error),
		])
		quit(1)
		return

	var water_outline := _build_river_outline(0.48)
	print("THREE_LAND_RIVER_RIBBONS_BUILT: %s and %s | water_shoreline_length=%.5f" % [
		BANK_OUTPUT,
		WATER_OUTPUT,
		_outline_length(water_outline),
	])
	quit()


func _build_river_mesh(width: float) -> ArrayMesh:
	var outline := _build_river_outline(width)
	if outline.size() < 3:
		return ArrayMesh.new()
	var shoreline_length := _outline_length(outline)
	if shoreline_length <= 0.0:
		push_error("The river outline has no measurable shoreline length.")
		return ArrayMesh.new()

	var triangle_indices := Geometry2D.triangulate_polygon(outline)
	if triangle_indices.is_empty():
		push_error("Unable to triangulate the river outline.")
		return ArrayMesh.new()

	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for triangle_index in range(0, triangle_indices.size(), 3):
		_append_subdivided_triangle(
			surface_tool,
			outline[triangle_indices[triangle_index]],
			outline[triangle_indices[triangle_index + 1]],
			outline[triangle_indices[triangle_index + 2]],
			outline,
			shoreline_length,
			width,
			SURFACE_SUBDIVISIONS,
		)
	return surface_tool.commit()


func _build_river_outline(width: float) -> PackedVector2Array:
	return _build_ribbon_outline(MAIN_RIVER, width)


func _build_ribbon_outline(points: Array, width: float) -> PackedVector2Array:
	var left_points := PackedVector2Array()
	var right_points := PackedVector2Array()
	for point_index in range(points.size()):
		var tangent := _point_tangent(points, point_index)
		var perpendicular := Vector2(-tangent.y, tangent.x)
		left_points.append(points[point_index] + perpendicular * width * 0.5)
		right_points.append(points[point_index] - perpendicular * width * 0.5)

	var outline := PackedVector2Array()
	for point in left_points:
		outline.append(point)
	for point_index in range(right_points.size() - 1, -1, -1):
		outline.append(right_points[point_index])
	return outline


func _append_subdivided_triangle(
	surface_tool: SurfaceTool,
	a: Vector2,
	b: Vector2,
	c: Vector2,
	outline: PackedVector2Array,
	shoreline_length: float,
	width: float,
	remaining_subdivisions: int,
) -> void:
	if remaining_subdivisions > 0:
		var ab := (a + b) * 0.5
		var bc := (b + c) * 0.5
		var ca := (c + a) * 0.5
		var next_subdivisions := remaining_subdivisions - 1
		_append_subdivided_triangle(surface_tool, a, ab, ca, outline, shoreline_length, width, next_subdivisions)
		_append_subdivided_triangle(surface_tool, ab, b, bc, outline, shoreline_length, width, next_subdivisions)
		_append_subdivided_triangle(surface_tool, ca, bc, c, outline, shoreline_length, width, next_subdivisions)
		_append_subdivided_triangle(surface_tool, ab, bc, ca, outline, shoreline_length, width, next_subdivisions)
		return

	_add_surface_vertex(surface_tool, a, outline, shoreline_length, width)
	_add_surface_vertex(surface_tool, b, outline, shoreline_length, width)
	_add_surface_vertex(surface_tool, c, outline, shoreline_length, width)


func _point_tangent(points: Array, point_index: int) -> Vector2:
	if point_index == 0:
		return (points[1] - points[0]).normalized()
	if point_index == points.size() - 1:
		return (points[-1] - points[-2]).normalized()
	return (points[point_index + 1] - points[point_index - 1]).normalized()


func _add_surface_vertex(
	surface_tool: SurfaceTool,
	point: Vector2,
	outline: PackedVector2Array,
	shoreline_length: float,
	width: float,
) -> void:
	surface_tool.set_normal(Vector3.UP)
	surface_tool.set_uv(_flow_uv(point, width))
	# UV2 stores a local shoreline coordinate system baked from the final
	# outline: X is distance inward from the bank, Y is normalized arc length.
	# The water shader can therefore derive both the white line and foam births
	# from one shoreline wave field without reconstructing tile geometry.
	var shoreline_sample := _shoreline_sample(point, outline, shoreline_length)
	surface_tool.set_uv2(shoreline_sample)
	surface_tool.add_vertex(Vector3(point.x, 0.0, point.y))


func _flow_uv(point: Vector2, width: float) -> Vector2:
	var total_length := _path_length(MAIN_RIVER)
	var distance_along := 0.0
	var best_distance_squared := INF
	var best_uv := Vector2.ZERO

	for segment_index in range(MAIN_RIVER.size() - 1):
		var start: Vector2 = MAIN_RIVER[segment_index]
		var segment: Vector2 = MAIN_RIVER[segment_index + 1] - start
		var segment_length := segment.length()
		var tangent := segment / segment_length
		var projected_length := clampf(
			(point - start).dot(tangent),
			0.0,
			segment_length,
		)
		var projected_point: Vector2 = start + tangent * projected_length
		var offset := point - projected_point
		var distance_squared := offset.length_squared()
		if distance_squared < best_distance_squared:
			var perpendicular := Vector2(-tangent.y, tangent.x)
			best_distance_squared = distance_squared
			best_uv = Vector2(
				(distance_along + projected_length) / total_length,
				clampf(0.5 + offset.dot(perpendicular) / width, 0.0, 1.0),
			)
		distance_along += segment_length
	return best_uv


func _path_length(points: Array) -> float:
	var length := 0.0
	for point_index in range(points.size() - 1):
		length += points[point_index].distance_to(points[point_index + 1])
	return length


func _outline_length(outline: PackedVector2Array) -> float:
	var length := 0.0
	for point_index in range(outline.size()):
		length += outline[point_index].distance_to(outline[(point_index + 1) % outline.size()])
	return length


func _shoreline_sample(
	point: Vector2,
	outline: PackedVector2Array,
	shoreline_length: float,
) -> Vector2:
	var closest_distance_squared := INF
	var closest_arc_length := 0.0
	var accumulated_length := 0.0
	for point_index in range(outline.size()):
		var segment_start := outline[point_index]
		var segment_end := outline[(point_index + 1) % outline.size()]
		var segment := segment_end - segment_start
		var segment_length := segment.length()
		if is_zero_approx(segment_length):
			continue
		var closest_point := Geometry2D.get_closest_point_to_segment(point, segment_start, segment_end)
		var distance_squared := point.distance_squared_to(closest_point)
		if distance_squared < closest_distance_squared:
			closest_distance_squared = distance_squared
			var projected_length := clampf(
				(point - segment_start).dot(segment / segment_length),
				0.0,
				segment_length,
			)
			closest_arc_length = accumulated_length + projected_length
		accumulated_length += segment_length
	return Vector2(
		sqrt(closest_distance_squared),
		fposmod(closest_arc_length / shoreline_length, 1.0),
	)
