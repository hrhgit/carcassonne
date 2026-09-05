extends SceneTree

# Editor/CI validation for the 3D conversion foundation.  It validates static
# scene structure and resource ownership only; it never redraws or assembles a
# tile from topology data.
const BASE_SCENE := preload("res://scenes/tiles_3d/tile_3d_base.tscn")
const RIVER_CROSS_SCENE := preload("res://scenes/tiles_3d/river_cross_3d.tscn")
const THREE_LAND_RIVER_SCENE := preload("res://scenes/tiles_3d/three_land_river_3d.tscn")
const OPPOSITE_CONNECTED_LAND_SCENE := preload("res://scenes/tiles_3d/opposite_connected_land_3d.tscn")
const NORTH_EAST_LAND_SOUTH_WATER_SCENE := preload("res://scenes/tiles_3d/north_east_land_south_water_3d.tscn")

const BASE_MATERIAL_PATH := "res://art/materials/terrain/tile_base.tres"
const MEADOW_MATERIAL_PATH := "res://art/materials/terrain/meadow.tres"
const RIVER_BANK_MATERIAL_PATH := "res://art/materials/terrain/river_bank.tres"


func _init() -> void:
	call_deferred("_validate")


func _validate() -> void:
	if not _validate_base_template():
		quit(1)
		return
	if not _validate_study_prefab(RIVER_CROSS_SCENE, "RiverCross3D", "res://art/materials/terrain/fertile_soil.tres"):
		quit(1)
		return
	if not _validate_study_prefab(THREE_LAND_RIVER_SCENE, "ThreeLandRiver3D", "res://art/materials/terrain/fertile_soil_edge_band.tres"):
		quit(1)
		return
	if not _validate_opposite_connected_land_prefab():
		quit(1)
		return
	if not _validate_north_east_land_south_water_prefab():
		quit(1)
		return
	print("TILE_3D_FOUNDATION_PASS: shared terrain materials, static prefab layers, study gates, and canonical land prefabs are valid.")
	quit()


func _validate_base_template() -> bool:
	var base := BASE_SCENE.instantiate() as TileArtwork3D
	if base == null or not base.has_valid_authored_contract():
		push_error("The Tile3DBase template no longer provides the standard static layer contract.")
		return false
	base.free()
	return true


func _validate_study_prefab(scene: PackedScene, expected_name: String, expected_soil_path: String) -> bool:
	var tile := scene.instantiate() as TileArtwork3D
	if tile == null or tile.name != expected_name:
		push_error("3D study prefab root is missing or renamed.")
		return false
	if not tile.has_valid_authored_contract() or tile.topology == null:
		push_error("3D study prefab lost its static topology or layer contract.")
		return false
	if tile.topology.is_canonical():
		push_error("A visual study was promoted before its declared terrain geometry was verified.")
		return false

	var base := tile.get_node_or_null(^"Base") as MeshInstance3D
	var meadow := tile.get_node_or_null(^"Meadow") as MeshInstance3D
	var river_bed := tile.get_node_or_null(^"Water/RiverBed") as MeshInstance3D
	var land_soil := tile.get_node_or_null(^"LandSoil")
	if base == null or meadow == null or river_bed == null or land_soil == null:
		push_error("3D study prefab lost one of its terrain layers.")
		return false
	if base.mesh.material == null or base.mesh.material.resource_path != BASE_MATERIAL_PATH:
		push_error("3D tile base no longer uses the shared base material.")
		return false
	if meadow.mesh.material == null or meadow.mesh.material.resource_path != MEADOW_MATERIAL_PATH:
		push_error("3D meadow no longer uses the shared meadow material.")
		return false
	if river_bed.material_override == null or river_bed.material_override.resource_path != RIVER_BANK_MATERIAL_PATH:
		push_error("3D river bank no longer uses the shared river-bank material.")
		return false
	for child in land_soil.get_children():
		var mesh_child := child as MeshInstance3D
		if mesh_child == null:
			continue
		if mesh_child.material_override == null or mesh_child.material_override.resource_path != expected_soil_path:
			push_error("3D fertile soil no longer uses its designated shared terrain material.")
			return false
	tile.free()
	return true


func _validate_opposite_connected_land_prefab() -> bool:
	var tile := OPPOSITE_CONNECTED_LAND_SCENE.instantiate() as TileArtwork3D
	if tile == null or tile.name != "OppositeConnectedLand3D":
		push_error("Opposite connected land prefab root is missing or renamed.")
		return false
	if not tile.has_valid_authored_contract() or tile.topology == null or not tile.topology.is_canonical():
		push_error("Opposite connected land prefab must satisfy the canonical static topology contract.")
		tile.free()
		return false

	var expected_edges := PackedInt32Array([1, 0, 1, 0])
	for quarter_turns in range(4):
		for edge in range(4):
			var expected_marker := expected_edges[int(posmod(edge - quarter_turns, 4))]
			if tile.edge_marker_at(edge, quarter_turns) != expected_marker:
				push_error("Opposite connected land ports no longer rotate as LAND/EMPTY/LAND/EMPTY.")
				tile.free()
				return false
	if tile.topology.double_land_topology != TileTopology3D.DoubleLandTopology.CENTER_CONNECTED:
		push_error("Opposite connected land topology is not explicitly CENTER_CONNECTED.")
		tile.free()
		return false
	if tile.topology.land_region_ids != PackedStringArray(["north_south_field"]) or tile.topology.land_region_edge_masks != PackedInt32Array([5]):
		push_error("Opposite connected land topology no longer maps both LAND edges to one region.")
		tile.free()
		return false

	var base := tile.get_node_or_null(^"Base") as MeshInstance3D
	var meadow := tile.get_node_or_null(^"Meadow") as MeshInstance3D
	var land := tile.get_node_or_null(^"LandSoil/NorthSouthConnectedLand") as MeshInstance3D
	if base == null or meadow == null or land == null or not land.mesh is ArrayMesh:
		push_error("Opposite connected land prefab lost its fixed base, meadow, or soil mesh.")
		tile.free()
		return false
	if base.mesh == null or base.mesh.material == null or base.mesh.material.resource_path != BASE_MATERIAL_PATH:
		push_error("Opposite connected land base no longer uses the shared base material.")
		tile.free()
		return false
	if meadow.mesh == null or meadow.mesh.material == null or meadow.mesh.material.resource_path != MEADOW_MATERIAL_PATH:
		push_error("Opposite connected land meadow no longer uses the shared meadow material.")
		tile.free()
		return false
	if land.material_override == null or land.material_override.resource_path != "res://art/materials/terrain/fertile_soil.tres":
		push_error("Opposite connected land no longer uses the shared fertile-soil material.")
		tile.free()
		return false

	var water := tile.get_node_or_null(^"Water")
	if water == null or not water.find_children("*", "MeshInstance3D", true, false).is_empty():
		push_error("The no-water prefab must keep the standard Water layer empty of geometry.")
		tile.free()
		return false
	if tile.get_node_or_null(^"GrowingPlants").find_children("*", "MeshInstance3D", true, false).is_empty() or tile.get_node_or_null(^"WitheredPlants").find_children("*", "MeshInstance3D", true, false).is_empty():
		push_error("Opposite connected land must keep separate authored growing and withered layers.")
		tile.free()
		return false

	var vertices: PackedVector3Array = land.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for probe in [
		Vector2(-2.40, -2.45), Vector2(0.0, -2.45), Vector2(2.40, -2.45),
		Vector2(-2.40, 2.45), Vector2(0.0, 2.45), Vector2(2.40, 2.45),
	]:
		if not _is_covered(vertices, probe):
			push_error("Opposite connected land no longer covers a complete claimed north/south edge.")
			tile.free()
			return false
	for probe in [Vector2(-2.40, 0.0), Vector2(2.40, 0.0)]:
		if _is_covered(vertices, probe):
			push_error("Opposite connected land incorrectly occupies an EMPTY east/west edge.")
			tile.free()
			return false
	for step in range(25):
		var z := lerpf(-2.40, 2.40, float(step) / 24.0)
		if not _is_covered(vertices, Vector2(0.0, z)):
			push_error("Opposite connected land is visually split across its centre.")
			tile.free()
			return false

	tile.free()
	return true


func _validate_north_east_land_south_water_prefab() -> bool:
	var tile := NORTH_EAST_LAND_SOUTH_WATER_SCENE.instantiate() as TileArtwork3D
	if tile == null or tile.name != "NorthEastLandSouthWater3D":
		push_error("North/east land south-water prefab root is missing or renamed.")
		return false
	if not tile.has_valid_authored_contract() or tile.topology == null or not tile.topology.is_canonical():
		push_error("North/east land south-water prefab must satisfy the canonical static topology contract.")
		tile.free()
		return false
	var expected_edges := PackedInt32Array([1, 1, 2, 0])
	for quarter_turns in range(4):
		for edge in range(4):
			if tile.edge_marker_at(edge, quarter_turns) != expected_edges[int(posmod(edge - quarter_turns, 4))]:
				push_error("North/east land south-water ports no longer rotate as LAND/LAND/WATER/EMPTY.")
				tile.free()
				return false
	if (
		tile.topology.double_land_topology != TileTopology3D.DoubleLandTopology.CENTER_CONNECTED
		or tile.topology.land_region_ids != PackedStringArray(["north_east_field"])
		or tile.topology.land_region_edge_masks != PackedInt32Array([3])
		or tile.topology.water_edges_ending_at_land != PackedInt32Array([TileTopology3D.Edge.SOUTH])
		or not tile.topology.water_edges_via_central_hub.is_empty()
	):
		push_error("North/east land south-water topology no longer declares its joined field and first-land water contact.")
		tile.free()
		return false

	var base := tile.get_node_or_null(^"Base") as MeshInstance3D
	var meadow := tile.get_node_or_null(^"Meadow") as MeshInstance3D
	var land := tile.get_node_or_null(^"LandSoil/NorthEastConnectedLand") as MeshInstance3D
	var bank := tile.get_node_or_null(^"Water/RiverBed") as MeshInstance3D
	var water := tile.get_node_or_null(^"Water/AnimatedSurface") as MeshInstance3D
	if base == null or meadow == null or land == null or bank == null or water == null or not land.mesh is ArrayMesh or not water.mesh is ArrayMesh:
		push_error("North/east land south-water prefab lost one of its fixed terrain meshes.")
		tile.free()
		return false
	if (
		base.mesh == null or base.mesh.material == null or base.mesh.material.resource_path != BASE_MATERIAL_PATH
		or meadow.mesh == null or meadow.mesh.material == null or meadow.mesh.material.resource_path != MEADOW_MATERIAL_PATH
		or land.material_override == null or land.material_override.resource_path != "res://art/materials/terrain/fertile_soil.tres"
		or bank.material_override == null or bank.material_override.resource_path != RIVER_BANK_MATERIAL_PATH
		or water.material_override == null or water.material_override.resource_path != "res://art/materials/water/north_east_land_south_water.tres"
	):
		push_error("North/east land south-water prefab no longer uses its designated shared terrain or baked water materials.")
		tile.free()
		return false
	var water_material := water.material_override as ShaderMaterial
	if water_material == null or not is_equal_approx(float(water_material.get_shader_parameter("foam_shoreline_length")), 4.62):
		push_error("North/east land south-water material no longer matches its baked shoreline length.")
		tile.free()
		return false

	var land_vertices: PackedVector3Array = land.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for probe in [
		Vector2(-2.40, -2.45), Vector2(0.0, -2.45), Vector2(2.40, -2.45),
		Vector2(2.45, -2.40), Vector2(2.45, 0.0), Vector2(2.45, 2.40),
	]:
		if not _is_covered(land_vertices, probe):
			push_error("North/east field no longer covers a complete claimed LAND edge.")
			tile.free()
			return false
	for probe in [Vector2(-2.45, 0.0), Vector2(-2.0, 2.45), Vector2(2.0, 2.45)]:
		if _is_covered(land_vertices, probe):
			push_error("North/east field incorrectly occupies its EMPTY or WATER edge.")
			tile.free()
			return false
	var water_vertices: PackedVector3Array = water.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var water_uv2: PackedVector2Array = water.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	if (
		not _is_covered(water_vertices, Vector2(0.0, 2.42))
		or not _is_covered(water_vertices, Vector2(0.0, 0.65))
		or _is_covered(water_vertices, Vector2(0.0, 0.57))
		or water_uv2.size() != water_vertices.size()
	):
		push_error("North/east land south-water channel no longer reaches the south centre and stops at its field contact with baked UV2.")
		tile.free()
		return false
	if tile.get_node_or_null(^"GrowingPlants").find_children("*", "MeshInstance3D", true, false).is_empty() or tile.get_node_or_null(^"WitheredPlants").find_children("*", "MeshInstance3D", true, false).is_empty():
		push_error("North/east land south-water prefab lost its fixed flower/herb state layers.")
		tile.free()
		return false
	tile.free()
	return true


func _is_covered(vertices: PackedVector3Array, probe: Vector2) -> bool:
	for triangle in range(0, vertices.size(), 3):
		var a := Vector2(vertices[triangle].x, vertices[triangle].z)
		var b := Vector2(vertices[triangle + 1].x, vertices[triangle + 1].z)
		var c := Vector2(vertices[triangle + 2].x, vertices[triangle + 2].z)
		if _point_in_triangle(probe, a, b, c):
			return true
	return false


func _point_in_triangle(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (p - b).cross(c - b)
	var d2 := (p - c).cross(a - c)
	var d3 := (p - a).cross(b - a)
	var has_neg := d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_pos := d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (has_neg and has_pos)
