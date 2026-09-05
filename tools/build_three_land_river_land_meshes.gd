extends SceneTree

const OUTPUT_DIRECTORY := "res://art/generated"
const LAND_OUTPUT := OUTPUT_DIRECTORY + "/three_land_river_land_mesh.tres"

const HALF_WIDTH := 2.45
# North, west, and east are one connected field. The south side opens into a
# broad, rounded green meadow lobe, matching the three-edge reference layout
# instead of filling the entire tile with soil.
const LAND_SURFACE_Y := 0.152
const EDGE_SUBDIVISIONS := 12
# This is the 2D three-edge tile's rounded open south side. The soil surrounds
# this lobe through its north, west, and east edges.
const REFERENCE_GREEN_LOBE_CONTOUR := [
	Vector2(2.45, 2.45),
	Vector2(2.13, 2.15),
	Vector2(1.80, 2.01),
	Vector2(1.48, 1.92),
	Vector2(1.20, 1.85),
	Vector2(0.93, 1.80),
	Vector2(0.69, 1.78),
	Vector2(0.51, 1.78),
	Vector2(0.35, 1.73),
	Vector2(0.19, 1.64),
	Vector2(0.0, 1.57),
	Vector2(-0.19, 1.64),
	Vector2(-0.35, 1.73),
	Vector2(-0.51, 1.78),
	Vector2(-0.69, 1.78),
	Vector2(-0.93, 1.80),
	Vector2(-1.20, 1.85),
	Vector2(-1.48, 1.92),
	Vector2(-1.80, 2.01),
	Vector2(-2.13, 2.15),
	Vector2(-2.45, 2.45),
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

	var land_mesh := _build_land_mesh()
	var save_error := ResourceSaver.save(land_mesh, LAND_OUTPUT)
	if save_error != OK:
		push_error("Failed to save generated three-edge land mesh: %s" % error_string(save_error))
		quit(1)
		return

	print("THREE_LAND_RIVER_LAND_MESH_BUILT: %s" % LAND_OUTPUT)
	quit()


func _build_land_mesh() -> ArrayMesh:
	var footprint := _build_connected_field_footprint()
	var triangle_indices := Geometry2D.triangulate_polygon(footprint)
	if triangle_indices.is_empty():
		push_error("Unable to triangulate the connected three-edge land footprint.")
		return ArrayMesh.new()

	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for triangle_index in range(0, triangle_indices.size(), 3):
		_add_land_triangle(
			surface_tool,
			footprint[triangle_indices[triangle_index]],
			footprint[triangle_indices[triangle_index + 1]],
			footprint[triangle_indices[triangle_index + 2]],
		)
	return surface_tool.commit()


func _build_connected_field_footprint() -> PackedVector2Array:
	var footprint := PackedVector2Array([Vector2(-HALF_WIDTH, -HALF_WIDTH)])
	_append_edge(footprint, Vector2(-HALF_WIDTH, -HALF_WIDTH), Vector2(HALF_WIDTH, -HALF_WIDTH), true)
	_append_edge(footprint, Vector2(HALF_WIDTH, -HALF_WIDTH), Vector2(HALF_WIDTH, HALF_WIDTH), true)
	# The first contour point is the already-emitted south-east corner. Skipping
	# it prevents a duplicate vertex, while the last point deliberately reaches
	# the south-west corner so both claimed side edges remain fully soil.
	for point_index in range(1, REFERENCE_GREEN_LOBE_CONTOUR.size()):
		footprint.append(REFERENCE_GREEN_LOBE_CONTOUR[point_index])
	_append_edge(footprint, Vector2(-HALF_WIDTH, HALF_WIDTH), Vector2(-HALF_WIDTH, -HALF_WIDTH), false)
	return footprint


func _append_edge(
	footprint: PackedVector2Array,
	start: Vector2,
	end: Vector2,
	include_end: bool,
) -> void:
	var last_index := EDGE_SUBDIVISIONS + 1 if include_end else EDGE_SUBDIVISIONS
	for index in range(1, last_index):
		footprint.append(start.lerp(end, float(index) / float(EDGE_SUBDIVISIONS)))


func _add_land_triangle(surface_tool: SurfaceTool, a: Vector2, b: Vector2, c: Vector2) -> void:
	for point in [a, b, c]:
		surface_tool.set_normal(Vector3.UP)
		surface_tool.set_uv(_land_uv(point))
		surface_tool.add_vertex(Vector3(point.x, LAND_SURFACE_Y, point.y))


func _land_uv(point: Vector2) -> Vector2:
	# UV.x is zero on each claimed outer edge and one at the connected field's
	# meadow contour, which keeps the authored moss treatment coherent around the
	# open green lobe.
	var outer_edge_distance := minf(minf(point.x + HALF_WIDTH, point.y + HALF_WIDTH), HALF_WIDTH - point.y)
	return Vector2(clampf(outer_edge_distance / 1.20, 0.0, 1.0), (point.x + HALF_WIDTH) / (2.0 * HALF_WIDTH))
