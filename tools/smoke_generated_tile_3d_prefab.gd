extends SceneTree

const GENERATED_SCENE := preload("res://scenes/tiles_3d/generated/procedural_north_east_land_south_water.tscn")
const GENERATOR := preload("res://scripts/tile_prefab_generator_3d.gd")
const RUNTIME_SCATTER := preload("res://scripts/runtime_plant_scatter_3d.gd")
const EXPECTED_EDGES := [1, 1, 2, 0]
const EXPECTED_TOPOLOGY := "res://art/topologies/generated/procedural_north_east_land_south_water.tres"
const WATER_EDGE_SEAL_LOCAL_FLOOR := -0.187
const WATER_PREFAB_PATHS := [
	"res://scenes/tiles_3d/generated/procedural_north_east_land_south_water.tscn",
	"res://scenes/tiles_3d/generated/procedural_land_n_water_w.tscn",
	"res://scenes/tiles_3d/generated/procedural_land_new_water_s.tscn",
	"res://scenes/tiles_3d/generated/procedural_land_nw_water_s.tscn",
	"res://scenes/tiles_3d/generated/procedural_water_ne.tscn",
	"res://scenes/tiles_3d/generated/procedural_water_ns.tscn",
	"res://scenes/tiles_3d/generated/procedural_water_nes.tscn",
	"res://scenes/tiles_3d/generated/procedural_water_nesw.tscn",
	"res://scenes/tiles_3d/generated/procedural_lake.tscn",
]


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

	var tile := GENERATED_SCENE.instantiate() as TileArtwork3D
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
	if base == null or meadow == null or land == null or bank == null or water == null or not land.mesh is ArrayMesh or not bank.mesh is ArrayMesh or not water.mesh is ArrayMesh:
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
	if not _riverbed_is_fully_submerged(bank, water):
		tile.queue_free()
		_fail("Generated RiverBed escaped the AnimatedSurface footprint or elevation.")
		return
	if not _water_edge_is_sealed(water):
		tile.queue_free()
		_fail("Generated AnimatedSurface has no terrain-buried edge seal.")
		return
	if not _all_generated_water_edges_are_sealed_and_riverbeds_submerged():
		tile.queue_free()
		_fail("A generated WATER prefab exposed RiverBed or an open water-to-terrain seam.")
		return
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
	var masks: Array[PlantingMask3D] = tile.get("planting_masks")
	if masks.is_empty() or not growing_layer.get_children().is_empty() or not withered_layer.get_children().is_empty():
		tile.queue_free()
		_fail("Generated tile must carry baked LAND masks but no baked plant instances.")
		return
	var layout_seed := RUNTIME_SCATTER.seed_for_tile(4493, Vector2i(3, -2))
	var placements := RUNTIME_SCATTER.generate_for_tile(tile, layout_seed)
	var repeated_placements := RUNTIME_SCATTER.generate_for_tile(tile, layout_seed)
	if placements.is_empty() or placements.size() != repeated_placements.size():
		tile.queue_free()
		_fail("Runtime scatter did not yield a stable LAND-only layout.")
		return
	for placement_index in range(placements.size()):
		var placement := placements[placement_index]
		var repeated := repeated_placements[placement_index]
		if placement.local_position.distance_to(repeated.local_position) > 0.00001 or not is_equal_approx(placement.scale_multiplier, repeated.scale_multiplier):
			tile.queue_free()
			_fail("Runtime scatter changed a stable seed layout.")
			return
		var planted_position := placement.local_position
		var inside_mask := false
		for mask in masks:
			inside_mask = inside_mask or mask.contains_point(Vector2(planted_position.x, planted_position.z), placement.profile.extra_edge_clearance + placement.profile.footprint_radius)
		if not inside_mask or not _is_covered(land_vertices, Vector2(planted_position.x, planted_position.z)):
			tile.queue_free()
			_fail("A runtime plant was placed outside the baked LAND mask.")
			return
	tile.set_runtime_plant_layout(placements)
	var runtime_plants: Array[SowablePlant3D] = tile.get_runtime_plants()
	if runtime_plants.size() != placements.size():
		tile.queue_free()
		_fail("Runtime plant instances do not match the generated placement count.")
		return
	var counts := {&"soil_herb": 0, &"soil_flower": 0, &"soil_sapling": 0}
	for plant in runtime_plants:
		counts[plant.species_id] = int(counts.get(plant.species_id, 0)) + 1
		if not plant.is_authored_model_valid():
			tile.queue_free()
			_fail("A runtime plant lost its selected Kenney model or ownership component.")
			return
	if int(counts[&"soil_herb"]) <= int(counts[&"soil_flower"]) or int(counts[&"soil_flower"]) <= int(counts[&"soil_sapling"]):
		tile.queue_free()
		_fail("Default runtime density must remain grass > flower > tree.")
		return
	tile.call("set_growth_state", 0)
	if growing_layer.visible or withered_layer.visible or runtime_plants.any(func(plant): return plant.visible):
		tile.queue_free()
		_fail("Generated tile cannot display bare soil independently from runtime plants.")
		return
	tile.call("set_growth_state", 1)
	if runtime_plants.any(func(plant): return not plant.visible):
		tile.queue_free()
		_fail("Generated tile did not reveal its runtime growing plants.")
		return
	tile.call("set_growth_state", 2)
	if runtime_plants.any(func(plant): return int(plant.growth_state) != SowablePlant3D.GrowthState.WILTED):
		tile.queue_free()
		_fail("Generated tile did not select the runtime withered form.")
		return
	var owner_color := Color("#e75f93")
	tile.set_runtime_plant_states({
		0: {"growth_state": TileArtwork3D.GrowthState.GROWING, "owner_color": owner_color},
	})
	tile.call("set_growth_state", 1)
	for plant in runtime_plants:
		var should_show := int(plant.get_meta("game_species", -1)) == 0
		if plant.visible != should_show:
			tile.queue_free()
			_fail("Selecting grass did not limit the runtime layer to grass placements.")
			return
	tile.set_runtime_plant_states({
		0: {"growth_state": TileArtwork3D.GrowthState.GROWING, "owner_color": owner_color},
		1: {"growth_state": TileArtwork3D.GrowthState.GROWING, "owner_color": owner_color},
		2: {"growth_state": TileArtwork3D.GrowthState.GROWING, "owner_color": owner_color},
	})
	tile.call("set_growth_state", 1)
	for plant in runtime_plants:
		if not plant.owner_color_is_applied(owner_color):
			tile.queue_free()
			_fail("A runtime plant did not recolour its authored flower/leaf/grass component.")
			return
	tile.queue_free()
	print("GENERATED_TILE_3D_PREFAB_PASS: canonical ports, static meshes, baked LAND masks, deterministic runtime plants, and land-only states are valid.")
	quit()


func _riverbed_is_fully_submerged(riverbed: MeshInstance3D, water: MeshInstance3D) -> bool:
	var riverbed_arrays := riverbed.mesh.surface_get_arrays(0)
	var riverbed_vertices: PackedVector3Array = riverbed_arrays[Mesh.ARRAY_VERTEX]
	var riverbed_indices: PackedInt32Array = riverbed_arrays[Mesh.ARRAY_INDEX] if riverbed_arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var riverbed_triangles := riverbed_indices if not riverbed_indices.is_empty() else PackedInt32Array(range(riverbed_vertices.size()))
	var water_vertices: PackedVector3Array = water.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var riverbed_to_water := water.global_transform.affine_inverse() * riverbed.global_transform
	for index in range(0, riverbed_triangles.size(), 3):
		var a := riverbed_vertices[riverbed_triangles[index]]
		var b := riverbed_vertices[riverbed_triangles[index + 1]]
		var c := riverbed_vertices[riverbed_triangles[index + 2]]
		for sample in [a, b, c, (a + b) * 0.5, (b + c) * 0.5, (c + a) * 0.5, (a + b + c) / 3.0]:
			var surface_local: Vector3 = riverbed_to_water * sample
			if surface_local.y >= -0.002 or not _is_covered(water_vertices, Vector2(surface_local.x, surface_local.z)):
				return false
	return true


func _all_generated_water_edges_are_sealed_and_riverbeds_submerged() -> bool:
	for scene_path in WATER_PREFAB_PATHS:
		var scene := load(scene_path) as PackedScene
		var tile := scene.instantiate() as TileArtwork3D if scene != null else null
		if tile == null:
			return false
		get_root().add_child(tile)
		var riverbed := tile.get_node_or_null(^"Water/RiverBed") as MeshInstance3D
		var water := tile.get_node_or_null(^"Water/AnimatedSurface") as MeshInstance3D
		var valid := riverbed != null and water != null and riverbed.mesh is ArrayMesh and water.mesh is ArrayMesh and _riverbed_is_fully_submerged(riverbed, water) and _water_edge_is_sealed(water)
		tile.free()
		if not valid:
			return false
	return true


func _water_edge_is_sealed(water: MeshInstance3D) -> bool:
	var vertices: PackedVector3Array = water.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var floor_vertices := 0
	for vertex in vertices:
		if vertex.y <= WATER_EDGE_SEAL_LOCAL_FLOOR + 0.001:
			floor_vertices += 1
	# Port endpoints meet matching water sheets directly.  Only non-port banks
	# need vertical seals, which avoids a z-fighting dark strip at tile seams.
	return floor_vertices >= 4


func _has_default_water_parameters(material: ShaderMaterial) -> bool:
	return (
		is_equal_approx(float(material.get_shader_parameter("foam_line_width")), 0.06)
		and is_equal_approx(float(material.get_shader_parameter("foam_wave_strength")), 0.5)
		and is_equal_approx(float(material.get_shader_parameter("foam_wave_frequency")), 10.0)
		and is_equal_approx(float(material.get_shader_parameter("foam_width")), 0.09)
		and is_equal_approx(float(material.get_shader_parameter("foam_scale")), 10.7)
		and is_equal_approx(float(material.get_shader_parameter("foam_radius")), 0.58)
		and is_equal_approx(float(material.get_shader_parameter("foam_cutoff")), 0.6)
		and is_equal_approx(float(material.get_shader_parameter("foam_speed")), 0.025)
		and float(material.get_shader_parameter("foam_shoreline_length")) > 0.0
		and is_equal_approx(float(material.get_shader_parameter("foam_network_speed_scale")), 1.0)
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
