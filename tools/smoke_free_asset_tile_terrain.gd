extends SceneTree

const PILOT_SCENE := preload("res://scenes/tiles_3d/free_asset_v2/north_east_land_south_water_free_v2.tscn")
const RUNTIME_SCATTER := preload("res://scripts/runtime_plant_scatter_3d.gd")
const TILE_SIZE := 4.9
const HALF_SIZE := 2.45
const EPSILON := 0.0003
const WATER_MEADOW_MIN_CLEARANCE := 0.006
const LAND_MEADOW_MIN_CLEARANCE := 0.006
const LAND_SURFACE_HEIGHT := 0.190
const RIVERBED_MIN_SUBMERGENCE := 0.004
const WATER_EDGE_SEAL_FLOOR := -0.012


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
	var riverbed := tile.get_node_or_null(^"Water/RiverBed") as MeshInstance3D
	var land := tile.get_node_or_null(^"LandSoil/NorthEastField") as MeshInstance3D
	var meadow := tile.get_node_or_null(^"Meadow") as MeshInstance3D
	if water == null or riverbed == null or land == null or meadow == null or not water.mesh is ArrayMesh or not riverbed.mesh is ArrayMesh:
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
	var elevated_land_water := false
	for vertex in water_vertices:
		if vertex.y > 0.190 and vertex.z < 0.90:
			elevated_land_water = true
			break
	if not elevated_land_water:
		_fail("Polygonal water no longer visibly enters the LAND contact.")
		return
	if not _water_has_broad_land_mouth(water.mesh as ArrayMesh, land.mesh as ArrayMesh):
		_fail("Water no longer makes a broad, direct contact on the flat LAND surface.")
		return
	if not _has_water_edge_seal(water.mesh as ArrayMesh):
		_fail("AnimatedSurface is no longer sealed down into terrain at its shoreline.")
		return
	var minimum_water_clearance := _minimum_surface_meadow_clearance(water.mesh as ArrayMesh, meadow.mesh as ArrayMesh, true)
	if minimum_water_clearance == INF or minimum_water_clearance < WATER_MEADOW_MIN_CLEARANCE:
		_fail("Water surface falls into or too near the MEADOW relief (minimum clearance %.5f)." % minimum_water_clearance)
		return
	var minimum_riverbed_submergence := _minimum_surface_submergence(riverbed.mesh as ArrayMesh, water.mesh as ArrayMesh)
	if minimum_riverbed_submergence == -INF or minimum_riverbed_submergence < RIVERBED_MIN_SUBMERGENCE:
		_fail("RiverBed is visible beside or above the AnimatedSurface (minimum submergence %.5f)." % minimum_riverbed_submergence)
		return
	var minimum_land_clearance := _minimum_surface_meadow_clearance(land.mesh as ArrayMesh, meadow.mesh as ArrayMesh)
	if minimum_land_clearance == INF or minimum_land_clearance < LAND_MEADOW_MIN_CLEARANCE:
		_fail("LAND surface falls into or too near the MEADOW relief (minimum clearance %.5f)." % minimum_land_clearance)
		return
	if not _land_top_is_flat(land.mesh as ArrayMesh):
		_fail("LAND top is no longer one flat planting plane.")
		return
	if not _land_palette_has_uniform_top_and_faceted_slope(land.mesh as ArrayMesh):
		_fail("LAND must keep one uniform flat top palette and varied polygonal slope faces.")
		return
	var material := water.material_override as ShaderMaterial
	if material == null or float(material.get_shader_parameter("foam_shoreline_length")) <= 0.0:
		_fail("Pilot water lost its per-prefab shoreline material data.")
		return

	var masks: Array[PlantingMask3D] = tile.planting_masks
	if masks.size() != 1 or not is_equal_approx(masks[0].surface_height, 0.190) or not _is_convex_polygon(masks[0].boundary):
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
		if absf(placement.local_position.y - 0.190) > EPSILON or not _is_covered(land.mesh as ArrayMesh, Vector2(placement.local_position.x, placement.local_position.z)):
			_fail("Pilot placed a plant off the Blender LAND surface.")
			return
		if _is_covered(water.mesh as ArrayMesh, Vector2(placement.local_position.x, placement.local_position.z)):
			_fail("Pilot placed a plant inside the polygonal WATER tongue.")
			return

	for decoration in tile.get_node(^"Decorations").get_children():
		var decoration_3d := decoration as Node3D
		if decoration_3d != null and masks[0].contains_point(Vector2(decoration_3d.position.x, decoration_3d.position.z)):
			_fail("A MEADOW decoration entered the sowable LAND mask.")
			return
		if decoration_3d != null and HALF_SIZE - maxf(absf(decoration_3d.position.x), absf(decoration_3d.position.z)) < 0.35:
			_fail("A free MEADOW decoration entered the canonical edge lock band.")
			return
	tile.queue_free()

	if not _test_pair(
		"WATER",
		Vector3(0.0, 0.0, TILE_SIZE),
		"z",
		HALF_SIZE,
		# RiverBed is intentionally inset from every visible water boundary;
		# AnimatedSurface alone owns the canonical WATER seam.
		[NodePath("Base"), NodePath("Meadow"), NodePath("Water/AnimatedSurface")],
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

	print("FREE_ASSET_TILE_TERRAIN_PASS: uniform flat LAND top, faceted broad polygon slopes, MEADOW-clearing LAND-fed WATER tongue, fully submerged RiverBed, KayKit MEADOW-only decorations, deterministic plants, UV2 water, and WATER/LAND/EMPTY seams are valid. minimum_clearance water=%.5f land=%.5f riverbed=%.5f" % [minimum_water_clearance, minimum_land_clearance, minimum_riverbed_submergence])
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
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var triangle_indices := indices if not indices.is_empty() else PackedInt32Array(range(vertices.size()))
	for index in range(0, triangle_indices.size(), 3):
		var a := vertices[triangle_indices[index]]
		var b := vertices[triangle_indices[index + 1]]
		var c := vertices[triangle_indices[index + 2]]
		if _point_in_triangle(probe, Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)):
			return true
	return false


func _minimum_surface_meadow_clearance(surface: ArrayMesh, meadow: ArrayMesh, top_faces_only := false) -> float:
	var minimum_clearance := INF
	var arrays := surface.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(vertices.size()))
	for index in range(0, indices.size(), 3):
		var a := vertices[indices[index]]
		var b := vertices[indices[index + 1]]
		var c := vertices[indices[index + 2]]
		if top_faces_only:
			var normal := (b - a).cross(c - a)
			if normal.length_squared() <= EPSILON * EPSILON or absf(normal.normalized().y) < 0.50:
				continue
		for sample in [a, b, c, (a + b) * 0.5, (b + c) * 0.5, (c + a) * 0.5, (a + b + c) / 3.0]:
			var meadow_height := _surface_height_at(meadow, Vector2(sample.x, sample.z))
			if meadow_height < INF:
				minimum_clearance = minf(minimum_clearance, sample.y - meadow_height)
	return minimum_clearance


func _has_water_edge_seal(mesh: ArrayMesh) -> bool:
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var floor_vertices := 0
	for vertex in vertices:
		if vertex.y <= WATER_EDGE_SEAL_FLOOR + EPSILON:
			floor_vertices += 1
	return floor_vertices >= 20


func _water_has_broad_land_mouth(water: ArrayMesh, land: ArrayMesh) -> bool:
	var water_vertices: PackedVector3Array = water.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var contact_samples := 0
	for vertex in water_vertices:
		if vertex.y < LAND_SURFACE_HEIGHT + 0.002:
			continue
		var land_height := _surface_height_at(land, Vector2(vertex.x, vertex.z))
		if land_height >= LAND_SURFACE_HEIGHT - EPSILON:
			contact_samples += 1
	return contact_samples >= 5


func _minimum_surface_submergence(underlay: ArrayMesh, surface: ArrayMesh) -> float:
	var arrays := underlay.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var triangle_indices := indices if not indices.is_empty() else PackedInt32Array(range(vertices.size()))
	var minimum_submergence := INF
	for index in range(0, triangle_indices.size(), 3):
		var a := vertices[triangle_indices[index]]
		var b := vertices[triangle_indices[index + 1]]
		var c := vertices[triangle_indices[index + 2]]
		for sample in [a, b, c, (a + b) * 0.5, (b + c) * 0.5, (c + a) * 0.5, (a + b + c) / 3.0]:
			var surface_height := _surface_height_at(surface, Vector2(sample.x, sample.z))
			if surface_height == INF:
				return -INF
			minimum_submergence = minf(minimum_submergence, surface_height - sample.y)
	return minimum_submergence


func _land_top_is_flat(land: ArrayMesh) -> bool:
	var arrays := land.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(vertices.size()))
	var found_top := false
	for index in range(0, indices.size(), 3):
		var a := vertices[indices[index]]
		var b := vertices[indices[index + 1]]
		var c := vertices[indices[index + 2]]
		var is_top := (
			absf(a.y - LAND_SURFACE_HEIGHT) <= EPSILON
			and absf(b.y - LAND_SURFACE_HEIGHT) <= EPSILON
			and absf(c.y - LAND_SURFACE_HEIGHT) <= EPSILON
		)
		if not is_top:
			continue
		found_top = true
		if absf((b - a).cross(c - a).normalized().y) < 0.98:
			return false
	return found_top


func _land_palette_has_uniform_top_and_faceted_slope(land: ArrayMesh) -> bool:
	var arrays := land.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	if uv.size() != vertices.size() or uv.is_empty():
		return false
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var triangle_indices := indices if not indices.is_empty() else PackedInt32Array(range(vertices.size()))
	var top_tones := {}
	var slope_tones := {}
	for index in range(0, triangle_indices.size(), 3):
		var a_index := triangle_indices[index]
		var b_index := triangle_indices[index + 1]
		var c_index := triangle_indices[index + 2]
		var a := vertices[a_index]
		var b := vertices[b_index]
		var c := vertices[c_index]
		var normal := (b - a).cross(c - a)
		if normal.length_squared() <= EPSILON * EPSILON:
			continue
		var is_top := (
			absf(a.y - LAND_SURFACE_HEIGHT) <= EPSILON
			and absf(b.y - LAND_SURFACE_HEIGHT) <= EPSILON
			and absf(c.y - LAND_SURFACE_HEIGHT) <= EPSILON
		)
		for vertex_index in [a_index, b_index, c_index]:
			if is_top:
				if absf(normal.normalized().y) < 0.98:
					return false
				if absf(vertices[vertex_index].y - LAND_SURFACE_HEIGHT) > EPSILON:
					return false
				top_tones[int(roundf(uv[vertex_index].x * 100.0))] = true
			else:
				slope_tones[int(roundf(uv[vertex_index].x * 100.0))] = true
	return top_tones.size() == 1 and slope_tones.size() >= 4


func _surface_height_at(mesh: ArrayMesh, probe: Vector2) -> float:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array(range(vertices.size()))
	var highest_surface := -INF
	for index in range(0, indices.size(), 3):
		var a := vertices[indices[index]]
		var b := vertices[indices[index + 1]]
		var c := vertices[indices[index + 2]]
		var denominator := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(denominator) <= EPSILON:
			continue
		var weight_a := ((b.z - c.z) * (probe.x - c.x) + (c.x - b.x) * (probe.y - c.z)) / denominator
		var weight_b := ((c.z - a.z) * (probe.x - c.x) + (a.x - c.x) * (probe.y - c.z)) / denominator
		var weight_c := 1.0 - weight_a - weight_b
		if weight_a >= -EPSILON and weight_b >= -EPSILON and weight_c >= -EPSILON:
			highest_surface = maxf(highest_surface, a.y * weight_a + b.y * weight_b + c.y * weight_c)
	return INF if highest_surface == -INF else highest_surface


func _point_in_triangle(point: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (point - b).cross(c - b)
	var d2 := (point - c).cross(a - c)
	var d3 := (point - a).cross(b - a)
	return not ((d1 < 0.0 or d2 < 0.0 or d3 < 0.0) and (d1 > 0.0 or d2 > 0.0 or d3 > 0.0))


func _is_convex_polygon(points: PackedVector2Array) -> bool:
	var sign := 0.0
	for index in range(points.size()):
		var first := points[(index + 1) % points.size()] - points[index]
		var second := points[(index + 2) % points.size()] - points[(index + 1) % points.size()]
		var cross := first.cross(second)
		if absf(cross) <= 0.00001:
			continue
		if is_zero_approx(sign):
			sign = signf(cross)
		elif cross * sign < 0.0:
			return false
	return not is_zero_approx(sign)


func _fail(message: String) -> void:
	push_error("FREE_ASSET_TILE_TERRAIN_FAIL: " + message)
	quit(1)
