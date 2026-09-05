extends SceneTree

# Editor/CI validation for the 3D conversion foundation.  It validates static
# scene structure and resource ownership only; it never redraws or assembles a
# tile from topology data.
const BASE_SCENE := preload("res://scenes/tiles_3d/tile_3d_base.tscn")
const RIVER_CROSS_SCENE := preload("res://scenes/tiles_3d/river_cross_3d.tscn")
const THREE_LAND_RIVER_SCENE := preload("res://scenes/tiles_3d/three_land_river_3d.tscn")

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
	print("TILE_3D_FOUNDATION_PASS: shared terrain materials, static prefab layers, and non-canonical study topology gates are valid.")
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
