extends SceneTree

const PILOT_SCENE := preload("res://scenes/tiles_3d/blender_pilot/north_east_land_south_water_blender.tscn")
const RUNTIME_SCATTER := preload("res://scripts/runtime_plant_scatter_3d.gd")
const TILE_SIZE := 4.9
const HALF_SIZE := 2.45
const EPSILON := 0.0003


func _init() -> void:
	call_deferred("_smoke")


func _smoke() -> void:
	var tile := PILOT_SCENE.instantiate() as TileArtwork3D
	if tile == null:
		_fail("Pilot scene did not instantiate.")
		return
	get_root().add_child(tile)
	if not tile.has_valid_authored_contract() or tile.edge_markers != PackedInt32Array([1, 1, 2, 0]):
		_fail("Pilot lost its fixed canonical topology contract.")
		return
	for turns in range(4):
		for edge in range(4):
			if tile.edge_marker_at(edge, turns) != tile.edge_markers[int(posmod(edge - turns, 4))]:
				_fail("Pilot edge markers do not rotate in 90-degree increments.")
				return

	var water := tile.get_node_or_null(^"Water/AnimatedSurface") as MeshInstance3D
	var land := tile.get_node_or_null(^"LandSoil/NorthEastField") as MeshInstance3D
	var meadow := tile.get_node_or_null(^"Meadow") as MeshInstance3D
	if water == null or land == null or meadow == null:
		_fail("Pilot lost a required terrain layer.")
		return
	var water_arrays := water.mesh.surface_get_arrays(0)
	var water_vertices: PackedVector3Array = water_arrays[Mesh.ARRAY_VERTEX]
	var water_uv2: PackedVector2Array = water_arrays[Mesh.ARRAY_TEX_UV2]
	var maximum_shore_distance := 0.0
	for coordinate in water_uv2:
		maximum_shore_distance = maxf(maximum_shore_distance, coordinate.x)
	if water_uv2.size() != water_vertices.size() or water_uv2.is_empty() or maximum_shore_distance < 0.20:
		_fail("Pilot water lost its baked d/s UV2 data.")
		return
	var material := water.material_override as ShaderMaterial
	if material == null or float(material.get_shader_parameter("foam_shoreline_length")) <= 0.0:
		_fail("Pilot water lost its per-prefab shoreline material data.")
		return

	var masks: Array[PlantingMask3D] = tile.planting_masks
	if masks.size() != 1 or not is_equal_approx(masks[0].surface_height, 0.20):
		_fail("Pilot LAND mask was not rebased to the Blender soil surface.")
		return
	for point in masks[0].boundary:
		if not _is_covered(land.mesh as ArrayMesh, point):
			_fail("Pilot LAND mask escapes the naturalized soil at %s." % point)
			return
	var layout_seed := RUNTIME_SCATTER.seed_for_tile(4493, Vector2i(6, -4))
	var placements := RUNTIME_SCATTER.generate_for_tile(tile, layout_seed)
	var repeated := RUNTIME_SCATTER.generate_for_tile(tile, layout_seed)
	if placements.is_empty() or placements.size() != repeated.size():
		_fail("Pilot no longer produces a deterministic LAND-only plant layout.")
		return
	for index in range(placements.size()):
		var placement := placements[index] as PlantScatterPlacement3D
		var repeated_placement := repeated[index] as PlantScatterPlacement3D
		if placement.local_position.distance_to(repeated_placement.local_position) > 0.00001:
			_fail("Pilot plant scatter changed for an identical seed.")
			return
		if absf(placement.local_position.y - 0.20) > EPSILON or not _is_covered(land.mesh as ArrayMesh, Vector2(placement.local_position.x, placement.local_position.z)):
			_fail("Pilot placed a plant off the Blender LAND surface.")
			return

	for decoration in tile.get_node(^"Decorations").get_children():
		var decoration_3d := decoration as Node3D
		if decoration_3d != null and masks[0].contains_point(Vector2(decoration_3d.position.x, decoration_3d.position.z)):
			_fail("A MEADOW decoration entered the sowable LAND mask.")
			return
	tile.queue_free()

	if not _test_pair(
		"WATER",
		Vector3(0.0, 0.0, TILE_SIZE),
		"z",
		HALF_SIZE,
		[NodePath("Base"), NodePath("Meadow"), NodePath("Water/RiverBed"), NodePath("Water/AnimatedSurface")],
	):
		return
	if not _test_pair(
		"LAND",
		Vector3(TILE_SIZE, 0.0, 0.0),
		"x",
		HALF_SIZE,
		[NodePath("Base"), NodePath("Meadow"), NodePath("LandSoil/NorthEastField")],
	):
		return
	if not _test_pair(
		"EMPTY",
		Vector3(-TILE_SIZE, 0.0, 0.0),
		"x",
		-HALF_SIZE,
		[NodePath("Base"), NodePath("Meadow")],
	):
		return

	print("BLENDER_TILE_TERRAIN_PASS: Blender bake, canonical anchors, LAND mask, deterministic plants, UV2 water, and WATER/LAND/EMPTY prefab seams are valid.")
	quit()


func _test_pair(label: String, second_position: Vector3, seam_axis: String, seam_coordinate: float, node_paths: Array[NodePath]) -> bool:
	var first := PILOT_SCENE.instantiate() as TileArtwork3D
	var second := PILOT_SCENE.instantiate() as TileArtwork3D
	get_root().add_child(first)
	get_root().add_child(second)
	second.position = second_position
	second.rotation.y = PI
	for node_path in node_paths:
		var first_mesh := first.get_node_or_null(node_path) as MeshInstance3D
		var second_mesh := second.get_node_or_null(node_path) as MeshInstance3D
		if first_mesh == null or second_mesh == null:
			first.queue_free()
			second.queue_free()
			_fail("%s seam lost layer %s." % [label, node_path])
			return false
		var first_signature := _boundary_signature(first_mesh, seam_axis, seam_coordinate)
		var second_signature := _boundary_signature(second_mesh, seam_axis, seam_coordinate)
		if first_signature.is_empty() or not _signatures_match(first_signature, second_signature):
			first.queue_free()
			second.queue_free()
			_fail("%s seam mismatch on %s: %s != %s" % [label, node_path, first_signature, second_signature])
			return false
	first.queue_free()
	second.queue_free()
	return true


func _boundary_signature(mesh_instance: MeshInstance3D, seam_axis: String, seam_coordinate: float) -> Array[Vector2]:
	var arrays := mesh_instance.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var result: Array[Vector2] = []
	for vertex in vertices:
		var world := mesh_instance.global_transform * vertex
		var plane_value := world.x if seam_axis == "x" else world.z
		if absf(plane_value - seam_coordinate) > EPSILON:
			continue
		var parallel := world.z if seam_axis == "x" else world.x
		var sample := Vector2(parallel, world.y)
		if not result.any(func(existing: Vector2): return existing.distance_to(sample) <= EPSILON):
			result.append(sample)
	result.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x if not is_equal_approx(a.x, b.x) else a.y < b.y)
	return result


func _signatures_match(first: Array[Vector2], second: Array[Vector2]) -> bool:
	if first.size() != second.size():
		return false
	for index in range(first.size()):
		if first[index].distance_to(second[index]) > EPSILON:
			return false
	return true


func _is_covered(mesh: ArrayMesh, probe: Vector2) -> bool:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var triangle_indices := indices if not indices.is_empty() else PackedInt32Array(range(vertices.size()))
	for index in range(0, triangle_indices.size(), 3):
		var a := vertices[triangle_indices[index]]
		var b := vertices[triangle_indices[index + 1]]
		var c := vertices[triangle_indices[index + 2]]
		if _point_in_triangle(probe, Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)):
			return true
	return false


func _point_in_triangle(point: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (point - b).cross(c - b)
	var d2 := (point - c).cross(a - c)
	var d3 := (point - a).cross(b - a)
	return not ((d1 < 0.0 or d2 < 0.0 or d3 < 0.0) and (d1 > 0.0 or d2 > 0.0 or d3 > 0.0))


func _fail(message: String) -> void:
	push_error("BLENDER_TILE_TERRAIN_FAIL: " + message)
	quit(1)
