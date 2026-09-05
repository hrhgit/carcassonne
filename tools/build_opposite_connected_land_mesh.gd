extends SceneTree

# Editor-time bake for the opposite two-edge, centre-connected land field.
# The game scene only references the generated ArrayMesh; it never rebuilds
# this outline from topology data at runtime.
const OUTPUT_PATH := "res://art/generated/opposite_connected_land_3d.tres"
const HALF_WIDTH := 2.45
const LAND_SURFACE_Y := 0.152

# North and south claim their complete outer edges.  Between those edges the
# field narrows, but never pinches off, leaving two readable meadow channels
# beside one continuous land region.
var field_outline := PackedVector2Array([
	Vector2(-2.45, -2.45),
	Vector2(2.45, -2.45),
	Vector2(2.02, -2.14),
	Vector2(1.55, -1.55),
	Vector2(1.22, -0.78),
	Vector2(1.06, 0.0),
	Vector2(1.22, 0.78),
	Vector2(1.55, 1.55),
	Vector2(2.02, 2.14),
	Vector2(2.45, 2.45),
	Vector2(-2.45, 2.45),
	Vector2(-2.02, 2.14),
	Vector2(-1.55, 1.55),
	Vector2(-1.22, 0.78),
	Vector2(-1.06, 0.0),
	Vector2(-1.22, -0.78),
	Vector2(-1.55, -1.55),
	Vector2(-2.02, -2.14),
])


func _init() -> void:
	call_deferred("_build_resource")


func _build_resource() -> void:
	var output_directory := ProjectSettings.globalize_path("res://art/generated")
	var directory_error := DirAccess.make_dir_recursive_absolute(output_directory)
	if directory_error != OK:
		push_error("Unable to create generated mesh directory: %s" % error_string(directory_error))
		quit(1)
		return

	var mesh := _build_mesh()
	if mesh == null:
		push_error("Unable to triangulate opposite connected land outline.")
		quit(1)
		return
	var save_error := ResourceSaver.save(mesh, OUTPUT_PATH)
	if save_error != OK:
		push_error("Failed to save opposite connected land mesh: %s" % error_string(save_error))
		quit(1)
		return

	print("OPPOSITE_CONNECTED_LAND_MESH_BUILT: %s" % OUTPUT_PATH)
	quit()


func _build_mesh() -> ArrayMesh:
	var triangles := Geometry2D.triangulate_polygon(field_outline)
	if triangles.is_empty():
		return null

	var surface_tool := SurfaceTool.new()
	surface_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for triangle_index in range(0, triangles.size(), 3):
		for point_index in range(3):
			var point: Vector2 = field_outline[triangles[triangle_index + point_index]]
			surface_tool.set_normal(Vector3.UP)
			surface_tool.set_uv(Vector2(
			(point.x + HALF_WIDTH) / (2.0 * HALF_WIDTH),
			(point.y + HALF_WIDTH) / (2.0 * HALF_WIDTH),
		))
			surface_tool.add_vertex(Vector3(point.x, LAND_SURFACE_Y, point.y))
	return surface_tool.commit()
