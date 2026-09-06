extends SceneTree

# Validates the first fixed CENTER_RIVER prefab before its geometry is reused by
# the batch generator.  It deliberately tests the visual/rule split: the mesh
# is a sealed water surface, while RIVER is neither LAND nor a WATER-network
# member.
const RIVER_SCENE := preload("res://scenes/tiles_3d/generated/procedural_river_straight.tscn")
const BOARD_STATE_SCRIPT := preload("res://scripts/board_state.gd")
const RULE_ENGINE_SCRIPT := preload("res://scripts/rule_engine.gd")
const RIVER_WIDTH := 1.08


func _init() -> void:
	call_deferred("_smoke")


func _smoke() -> void:
	var tile := RIVER_SCENE.instantiate() as TileArtwork3D
	if tile == null:
		_fail("The generated river sample is not a TileArtwork3D prefab.")
		return
	get_root().add_child(tile)
	await process_frame
	if not tile.has_valid_authored_contract() or tile.topology == null or not tile.topology.is_canonical():
		_fail("The river sample lost its static layer or canonical topology contract.")
		return
	if tile.edge_markers != PackedInt32Array([0, 3, 0, 3]):
		_fail("The river sample no longer declares EMPTY/RIVER/EMPTY/RIVER ports.")
		return
	if tile.topology.land_region_ids.size() != 0 or not tile.get("planting_masks").is_empty():
		_fail("A pure river tile must not carry LAND regions or planting masks.")
		return
	var land_root := tile.get_node_or_null(^"LandSoil") as Node3D
	if land_root == null or not land_root.get_children().is_empty():
		_fail("A pure river tile unexpectedly contains LAND geometry.")
		return
	var riverbed := tile.get_node_or_null(^"Water/RiverBed") as MeshInstance3D
	var surface := tile.get_node_or_null(^"Water/AnimatedSurface") as MeshInstance3D
	if riverbed == null or surface == null or not riverbed.mesh is ArrayMesh or not surface.mesh is ArrayMesh:
		_fail("The river sample is missing its baked RiverBed or AnimatedSurface.")
		return
	var surface_arrays := surface.mesh.surface_get_arrays(0)
	var surface_vertices: PackedVector3Array = surface_arrays[Mesh.ARRAY_VERTEX]
	var surface_shoreline: PackedVector2Array = surface_arrays[Mesh.ARRAY_TEX_UV2]
	if not _is_covered(surface_vertices, Vector2(-2.42, 0.0)) or not _is_covered(surface_vertices, Vector2.ZERO) or not _is_covered(surface_vertices, Vector2(2.42, 0.0)):
		_fail("The wider river does not continuously reach both fixed RIVER anchors.")
		return
	if _is_covered(surface_vertices, Vector2(0.0, RIVER_WIDTH * 0.55)):
		_fail("The river surface exceeded its declared widened port width.")
		return
	if not _has_boundary_width(surface_vertices, RIVER_WIDTH):
		_fail("The river boundary is not baked at the widened fixed RIVER width.")
		return
	if not _river_ports_are_not_baked_as_foam_banks(surface_vertices, surface_shoreline):
		_fail("A RIVER port was baked as a shoreline and would create a foam seam.")
		return
	if not _riverbed_is_fully_submerged(riverbed, surface):
		_fail("The RiverBed escaped the wider AnimatedSurface footprint or elevation.")
		return
	if not _water_edge_is_sealed(surface):
		_fail("The wider AnimatedSurface has no terrain-buried edge seal.")
		return
	if not _has_flat_river_water_material(surface.material_override as ShaderMaterial):
		_fail("The river sample still contains the blue facet bands.")
		return
	if not _river_rules_remain_outside_water_network():
		_fail("RIVER was incorrectly treated as LAND or a WATER-network edge.")
		return
	tile.queue_free()
	print("RIVER_STRAIGHT_3D_PREFAB_PASS: pure widened RIVER prefab has flat blue water, sealed banks, no LAND mask, and no WATER-net membership.")
	quit()


func _river_rules_remain_outside_water_network() -> bool:
	var definition := TileDefinition.new()
	definition.configure(
		&"smoke_river_straight",
		"Smoke river straight",
		TileDefinition.CARD_RIVER,
		1,
		PackedInt32Array([TileDefinition.EdgeKind.EMPTY, TileDefinition.EdgeKind.RIVER, TileDefinition.EdgeKind.EMPTY, TileDefinition.EdgeKind.RIVER]),
		PackedInt32Array([0, 0, 0, 0]),
		TileDefinition.CenterKind.RIVER,
		true,
		false,
		17,
	)
	if not definition.is_playable():
		return false
	var board := BOARD_STATE_SCRIPT.new()
	board.start_with(definition)
	if not bool(board.place(definition, Vector2i.RIGHT, 0, 0).get("valid", false)):
		return false
	var analysis = RULE_ENGINE_SCRIPT.analyze(board)
	return analysis.land_regions.is_empty() and analysis.water_nets.is_empty()


func _has_boundary_width(vertices: PackedVector3Array, expected_width: float) -> bool:
	var boundary_z := PackedFloat32Array()
	for vertex in vertices:
		if is_equal_approx(vertex.x, 2.45) and is_zero_approx(vertex.y):
			boundary_z.append(vertex.z)
	if boundary_z.size() < 2:
		return false
	var min_z := boundary_z[0]
	var max_z := boundary_z[0]
	for value in boundary_z:
		min_z = minf(min_z, value)
		max_z = maxf(max_z, value)
	return is_equal_approx(max_z - min_z, expected_width)


func _river_ports_are_not_baked_as_foam_banks(vertices: PackedVector3Array, shoreline: PackedVector2Array) -> bool:
	if shoreline.size() != vertices.size():
		return false
	var samples := 0
	for index in range(vertices.size()):
		var vertex := vertices[index]
		var on_east_or_west_port := absf(absf(vertex.x) - 2.45) <= 0.001
		if not is_zero_approx(vertex.y) or not on_east_or_west_port or absf(vertex.z) > RIVER_WIDTH * 0.25:
			continue
		samples += 1
		if shoreline[index].x <= 0.12:
			return false
	return samples >= 2


func _riverbed_is_fully_submerged(riverbed: MeshInstance3D, surface: MeshInstance3D) -> bool:
	var riverbed_vertices: PackedVector3Array = riverbed.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var water_vertices: PackedVector3Array = surface.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var riverbed_to_water := surface.global_transform.affine_inverse() * riverbed.global_transform
	for vertex in riverbed_vertices:
		var local_to_surface: Vector3 = riverbed_to_water * vertex
		if local_to_surface.y >= -0.002 or not _is_covered(water_vertices, Vector2(local_to_surface.x, local_to_surface.z)):
			return false
	return true


func _water_edge_is_sealed(surface: MeshInstance3D) -> bool:
	var vertices: PackedVector3Array = surface.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var floor_vertices := 0
	for vertex in vertices:
		if vertex.y <= -0.186:
			floor_vertices += 1
	# The two true banks remain sealed; the two locked RIVER ports deliberately
	# omit duplicate vertical walls so an adjacent prefab cannot z-fight.
	return floor_vertices >= 4


func _has_flat_river_water_material(material: ShaderMaterial) -> bool:
	return material != null and (
		bool(material.get_shader_parameter("foam_enabled"))
		and bool(material.get_shader_parameter("foam_animation_enabled"))
		and not bool(material.get_shader_parameter("facet_bands_enabled"))
		and is_equal_approx(float(material.get_shader_parameter("foam_line_width")), 0.06)
		and is_equal_approx(float(material.get_shader_parameter("foam_wave_strength")), 0.5)
		and is_equal_approx(float(material.get_shader_parameter("foam_wave_frequency")), 10.0)
		and is_equal_approx(float(material.get_shader_parameter("foam_width")), 0.09)
		and is_equal_approx(float(material.get_shader_parameter("foam_scale")), 10.7)
		and is_equal_approx(float(material.get_shader_parameter("foam_radius")), 0.58)
		and is_equal_approx(float(material.get_shader_parameter("foam_cutoff")), 0.6)
		and is_equal_approx(float(material.get_shader_parameter("foam_speed")), 0.025)
	)


func _is_covered(vertices: PackedVector3Array, point: Vector2) -> bool:
	for index in range(0, vertices.size(), 3):
		if _point_in_triangle(point, Vector2(vertices[index].x, vertices[index].z), Vector2(vertices[index + 1].x, vertices[index + 1].z), Vector2(vertices[index + 2].x, vertices[index + 2].z)):
			return true
	return false


func _point_in_triangle(point: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (point - b).cross(c - b)
	var d2 := (point - c).cross(a - c)
	var d3 := (point - a).cross(b - a)
	return not ((d1 < 0.0 or d2 < 0.0 or d3 < 0.0) and (d1 > 0.0 or d2 > 0.0 or d3 > 0.0))


func _fail(message: String) -> void:
	push_error("RIVER_STRAIGHT_3D_PREFAB_FAIL: " + message)
	quit(1)
