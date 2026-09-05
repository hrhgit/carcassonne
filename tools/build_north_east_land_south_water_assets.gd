extends SceneTree

# Editor/build-time asset generator for the first fully canonical mixed tile.
# It makes one fixed field outline and one fixed south-mouth ribbon; runtime
# scenes only reference the saved meshes and never derive geometry from ports.
const OUTPUT_DIRECTORY := "res://art/generated"
const LAND_OUTPUT := OUTPUT_DIRECTORY + "/north_east_land_south_water_land_mesh.tres"
const BANK_OUTPUT := OUTPUT_DIRECTORY + "/north_east_land_south_water_bank_mesh.tres"
const WATER_OUTPUT := OUTPUT_DIRECTORY + "/north_east_land_south_water_water_mesh.tres"

const HALF_WIDTH := 2.45
const LAND_SURFACE_Y := 0.152
const BANK_WIDTH := 0.72
const WATER_WIDTH := 0.48
const SURFACE_SUBDIVISIONS := 3

# South port → centre direction → first contact with the north/east field.
# The last point lies exactly on the field's flat irrigation contact segment.
var south_inlet := [
	Vector2(0.0, HALF_WIDTH),
	Vector2(0.0, 1.78),
	Vector2(0.0, 0.62),
]

# North and east claim full outer edges.  The west and south non-land corners
# taper inward, leaving meadow around the single south water port.
var north_east_field := PackedVector2Array([
	Vector2(-HALF_WIDTH, -HALF_WIDTH),
	Vector2(HALF_WIDTH, -HALF_WIDTH),
	Vector2(HALF_WIDTH, HALF_WIDTH),
	Vector2(1.88, 2.14),
	Vector2(1.42, 1.65),
	Vector2(0.98, 1.20),
	Vector2(0.45, 0.62),
	Vector2(-0.45, 0.62),
	Vector2(-0.66, 0.13),
	Vector2(-0.95, -0.55),
	Vector2(-1.20, -1.12),
])


func _init() -> void:
	call_deferred("_build_resources")


func _build_resources() -> void:
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	if directory_error != OK:
		_fail("Unable to create generated-mesh directory: %s" % error_string(directory_error))
		return

	var land_mesh := _build_land_mesh()
	var bank_mesh := _build_ribbon_mesh(BANK_WIDTH)
	var water_mesh := _build_ribbon_mesh(WATER_WIDTH)
	if land_mesh.get_surface_count() == 0 or bank_mesh.get_surface_count() == 0 or water_mesh.get_surface_count() == 0:
		_fail("Canonical north/east field or south-water mesh generation returned an empty mesh.")
		return

	for asset in [
		[land_mesh, LAND_OUTPUT],
		[bank_mesh, BANK_OUTPUT],
		[water_mesh, WATER_OUTPUT],
	]:
		var save_error := ResourceSaver.save(asset[0], asset[1])
		if save_error != OK:
			_fail("Could not save %s: %s" % [asset[1], error_string(save_error)])
			return

	var shoreline_length := _outline_length(_build_ribbon_outline(WATER_WIDTH))
	if not is_equal_approx(shoreline_length, 4.62):
		_fail("The water material's baked shoreline length changed unexpectedly: %.5f" % shoreline_length)
		return
	print("NORTH_EAST_LAND_SOUTH_WATER_ASSETS_BUILT: land, bank, water | water_shoreline_length=%.5f" % shoreline_length)
	quit()


func _build_land_mesh() -> ArrayMesh:
	var triangle_indices := Geometry2D.triangulate_polygon(north_east_field)
	if triangle_indices.is_empty():
		return ArrayMesh.new()
	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for triangle_index in range(0, triangle_indices.size(), 3):
		for point in [
			north_east_field[triangle_indices[triangle_index]],
			north_east_field[triangle_indices[triangle_index + 1]],
			north_east_field[triangle_indices[triangle_index + 2]],
		]:
			surface_tool.set_normal(Vector3.UP)
			surface_tool.set_uv(_land_uv(point))
			surface_tool.add_vertex(Vector3(point.x, LAND_SURFACE_Y, point.y))
	return surface_tool.commit()


func _land_uv(point: Vector2) -> Vector2:
	# UV.x keeps a modest material treatment coherent from claimed outer edges
	# into the tapered meadow frontier, without encoding gameplay geometry.
	var north_distance := point.y + HALF_WIDTH
	var east_distance := HALF_WIDTH - point.x
	return Vector2(clampf(minf(north_distance, east_distance) / 1.35, 0.0, 1.0), (point.x + HALF_WIDTH) / (HALF_WIDTH * 2.0))


func _build_ribbon_mesh(width: float) -> ArrayMesh:
	var outline := _build_ribbon_outline(width)
	var shoreline_length := _outline_length(outline)
	var triangle_indices := Geometry2D.triangulate_polygon(outline)
	if shoreline_length <= 0.0 or triangle_indices.is_empty():
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


func _build_ribbon_outline(width: float) -> PackedVector2Array:
	var left_points := PackedVector2Array()
	var right_points := PackedVector2Array()
	for point_index in range(south_inlet.size()):
		var tangent := _point_tangent(point_index)
		var perpendicular := Vector2(-tangent.y, tangent.x)
		left_points.append(south_inlet[point_index] + perpendicular * width * 0.5)
		right_points.append(south_inlet[point_index] - perpendicular * width * 0.5)
	var outline := PackedVector2Array()
	for point in left_points:
		outline.append(point)
	for point_index in range(right_points.size() - 1, -1, -1):
		outline.append(right_points[point_index])
	return outline


func _point_tangent(point_index: int) -> Vector2:
	if point_index == 0:
		return (south_inlet[1] - south_inlet[0]).normalized()
	if point_index == south_inlet.size() - 1:
		return (south_inlet[-1] - south_inlet[-2]).normalized()
	return (south_inlet[point_index + 1] - south_inlet[point_index - 1]).normalized()


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
	_add_water_vertex(surface_tool, a, outline, shoreline_length, width)
	_add_water_vertex(surface_tool, b, outline, shoreline_length, width)
	_add_water_vertex(surface_tool, c, outline, shoreline_length, width)


func _add_water_vertex(surface_tool: SurfaceTool, point: Vector2, outline: PackedVector2Array, shoreline_length: float, width: float) -> void:
	surface_tool.set_normal(Vector3.UP)
	surface_tool.set_uv(_flow_uv(point, width))
	# UV2.x = final-outline distance d; UV2.y = final-outline arc s.  The water
	# material derives its uninterrupted white edge and foam births from these
	# two baked values and one shared p(s, t) wave phase.
	surface_tool.set_uv2(_shoreline_sample(point, outline, shoreline_length))
	surface_tool.add_vertex(Vector3(point.x, 0.0, point.y))


func _flow_uv(point: Vector2, width: float) -> Vector2:
	var total_length := _path_length()
	var projected_length := clampf(south_inlet[0].y - point.y, 0.0, total_length)
	return Vector2(projected_length / total_length, clampf(0.5 + point.x / width, 0.0, 1.0))


func _path_length() -> float:
	var result := 0.0
	for index in range(south_inlet.size() - 1):
		result += south_inlet[index].distance_to(south_inlet[index + 1])
	return result


func _outline_length(outline: PackedVector2Array) -> float:
	var result := 0.0
	for index in range(outline.size()):
		result += outline[index].distance_to(outline[(index + 1) % outline.size()])
	return result


func _shoreline_sample(point: Vector2, outline: PackedVector2Array, shoreline_length: float) -> Vector2:
	var closest_distance_squared := INF
	var closest_arc_length := 0.0
	var accumulated_length := 0.0
	for index in range(outline.size()):
		var start := outline[index]
		var end := outline[(index + 1) % outline.size()]
		var segment := end - start
		var segment_length := segment.length()
		if is_zero_approx(segment_length):
			continue
		var closest := Geometry2D.get_closest_point_to_segment(point, start, end)
		var distance_squared := point.distance_squared_to(closest)
		if distance_squared < closest_distance_squared:
			closest_distance_squared = distance_squared
			var projected_length := clampf((point - start).dot(segment / segment_length), 0.0, segment_length)
			closest_arc_length = accumulated_length + projected_length
		accumulated_length += segment_length
	return Vector2(sqrt(closest_distance_squared), fposmod(closest_arc_length / shoreline_length, 1.0))


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
