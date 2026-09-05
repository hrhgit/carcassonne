extends SceneTree

const GENERATED_SCENE := preload("res://scenes/tiles_3d/generated/procedural_north_east_land_south_water.tscn")
const GENERATOR := preload("res://scripts/tile_prefab_generator_3d.gd")
const EXPECTED_EDGES := [1, 1, 2, 0]
const EXPECTED_TOPOLOGY := "res://art/topologies/generated/procedural_north_east_land_south_water.tres"


func _init() -> void:
	call_deferred("_smoke")


func _smoke() -> void:
	var valid_spec := GENERATOR.validate_spec({
		"id": "valid_3d",
		"edges": ["LAND", "LAND", "WATER", "EMPTY"],
		"land_regions": [{"id": "north_east_field", "edges": ["NORTH", "EAST"]}],
		"water_routes": [{"from": "SOUTH", "to_region": "north_east_field", "via_hub": false}],
	})
	var orphan_water := GENERATOR.validate_spec({
		"id": "orphan_water",
		"edges": ["EMPTY", "EMPTY", "WATER", "EMPTY"],
		"land_regions": [],
		"water_routes": [],
	})
	if not valid_spec["ok"] or orphan_water["ok"]:
		_fail("TileSpec3D validation did not reject an orphan water edge.")
		return

	var tile := GENERATED_SCENE.instantiate() as Node3D
	if tile == null:
		_fail("Generated 3D scene did not instantiate.")
		return
	get_root().add_child(tile)
	var edges: PackedInt32Array = tile.get("edge_markers")
	var topology := tile.get("topology") as Resource
	if edges != PackedInt32Array(EXPECTED_EDGES) or topology == null or topology.resource_path != EXPECTED_TOPOLOGY or not bool(topology.call("is_canonical")) or not bool(tile.call("has_valid_authored_contract")):
		tile.queue_free()
		_fail("Generated scene lost its fixed canonical topology contract.")
		return
	for turns in range(4):
		for edge in range(4):
			if int(tile.call("edge_marker_at", edge, turns)) != EXPECTED_EDGES[int(posmod(edge - turns, 4))]:
				tile.queue_free()
				_fail("Generated ports do not obey 90-degree prefab rotation.")
				return

	var base := tile.get_node_or_null(^"Base") as MeshInstance3D
	var meadow := tile.get_node_or_null(^"Meadow") as MeshInstance3D
	var land := tile.get_node_or_null(^"LandSoil/NorthEastField") as MeshInstance3D
	var bank := tile.get_node_or_null(^"Water/RiverBed") as MeshInstance3D
	var water := tile.get_node_or_null(^"Water/AnimatedSurface") as MeshInstance3D
	if base == null or meadow == null or land == null or bank == null or water == null or not land.mesh is ArrayMesh or not water.mesh is ArrayMesh:
		tile.queue_free()
		_fail("Generated tile is missing one of its static 3D terrain layers.")
		return
	var land_vertices: PackedVector3Array = land.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for probe in [
		Vector2(-2.40, -2.40), Vector2(0.0, -2.40), Vector2(2.40, -2.40),
		Vector2(2.40, -2.40), Vector2(2.40, 0.0), Vector2(2.40, 2.40),
		Vector2(0.46, -0.46),
	]:
		if not _is_covered(land_vertices, probe):
			tile.queue_free()
			_fail("Generated north/east field does not cover a required LAND area.")
			return
	for probe in [Vector2(-2.45, 0.0), Vector2(-2.0, 2.45), Vector2(0.0, 2.45)]:
		if _is_covered(land_vertices, probe):
			tile.queue_free()
			_fail("Generated field occupies an EMPTY or WATER edge.")
			return
	var water_arrays := water.mesh.surface_get_arrays(0)
	var water_vertices: PackedVector3Array = water_arrays[Mesh.ARRAY_VERTEX]
	var shoreline: PackedVector2Array = water_arrays[Mesh.ARRAY_TEX_UV2]
	if shoreline.size() != water_vertices.size() or not _is_covered(water_vertices, Vector2(0.0, 2.35)) or not _is_covered(water_vertices, Vector2(0.0, 1.30)) or _is_covered(water_vertices, Vector2(1.0, -1.0)):
		tile.queue_free()
		_fail("Generated river is not a narrow south-centre inlet ending at the target field.")
		return
	var has_shore_vertex := false
	for value in shoreline:
		if value.x <= 0.001 and value.y >= 0.0 and value.y < 1.0:
			has_shore_vertex = true
			break
	if not has_shore_vertex:
		tile.queue_free()
		_fail("Generated water mesh is missing baked UV2 shoreline distance and arc coordinates.")
		return
	var water_material := water.material_override as ShaderMaterial
	if water_material == null or not _has_default_water_parameters(water_material):
		tile.queue_free()
		_fail("Generated water material lost the project foam defaults.")
		return

	var growing_layer := tile.get_node_or_null(^"GrowingPlants") as Node3D
	var withered_layer := tile.get_node_or_null(^"WitheredPlants") as Node3D
	var growing_plants := growing_layer.find_children("*", "SowablePlant3D", true, false)
	var withered_plants := withered_layer.find_children("*", "SowablePlant3D", true, false)
	if growing_plants.size() != 5 or withered_plants.size() != 5:
		tile.queue_free()
		_fail("Generated tile did not bake matching growing and withered plant layers.")
		return
	for plant in growing_plants:
		var planted_position := plant.position as Vector3
		if not _is_covered(land_vertices, Vector2(planted_position.x, planted_position.z)):
			tile.queue_free()
			_fail("A generated plant was placed on meadow instead of LAND.")
			return
	growing_plants[0].call("set_owner_color", Color("#e75f93"))
	tile.call("set_growth_state", 0)
	if growing_layer.visible or withered_layer.visible:
		tile.queue_free()
		_fail("Generated tile cannot display bare soil independently from plants.")
		return
	tile.call("set_growth_state", 1)
	if not growing_layer.visible or withered_layer.visible:
		tile.queue_free()
		_fail("Generated tile did not reveal its fixed growing layer.")
		return
	tile.call("set_growth_state", 2)
	if growing_layer.visible or not withered_layer.visible:
		tile.queue_free()
		_fail("Generated tile did not reveal its fixed withered layer.")
		return
	tile.queue_free()
	print("GENERATED_TILE_3D_PREFAB_PASS: canonical ports, static meshes, baked UV2 shoreline, and land-only plant states are valid.")
	quit()


func _has_default_water_parameters(material: ShaderMaterial) -> bool:
	return (
		is_equal_approx(float(material.get_shader_parameter("foam_line_width")), 0.06)
		and is_equal_approx(float(material.get_shader_parameter("foam_wave_strength")), 0.5)
		and is_equal_approx(float(material.get_shader_parameter("foam_wave_frequency")), 10.0)
		and is_equal_approx(float(material.get_shader_parameter("foam_width")), 0.05)
		and is_equal_approx(float(material.get_shader_parameter("foam_scale")), 10.7)
		and is_equal_approx(float(material.get_shader_parameter("foam_radius")), 0.4)
		and is_equal_approx(float(material.get_shader_parameter("foam_cutoff")), 0.6)
		and is_equal_approx(float(material.get_shader_parameter("foam_speed")), 0.025)
		and float(material.get_shader_parameter("foam_shoreline_length")) > 0.0
	)


func _is_covered(vertices: PackedVector3Array, probe: Vector2) -> bool:
	for index in range(0, vertices.size(), 3):
		if _point_in_triangle(probe, Vector2(vertices[index].x, vertices[index].z), Vector2(vertices[index + 1].x, vertices[index + 1].z), Vector2(vertices[index + 2].x, vertices[index + 2].z)):
			return true
	return false


func _point_in_triangle(point: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (point - b).cross(c - b)
	var d2 := (point - c).cross(a - c)
	var d3 := (point - a).cross(b - a)
	return not ((d1 < 0.0 or d2 < 0.0 or d3 < 0.0) and (d1 > 0.0 or d2 > 0.0 or d3 > 0.0))


func _fail(message: String) -> void:
	push_error("GENERATED_TILE_3D_PREFAB_FAIL: " + message)
	quit(1)
