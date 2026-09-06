extends SceneTree

const CATALOG_SCENE := preload("res://scenes/main.tscn")
const RUNTIME_SCATTER := preload("res://scripts/runtime_plant_scatter_3d.gd")


func _init() -> void:
	call_deferred("_smoke")


func _smoke() -> void:
	# Main's catalog is a real scene child, avoiding a second CSV parser in this
	# smoke while keeping all card-to-prefab mappings under test.
	var main := CATALOG_SCENE.instantiate() as Node
	get_root().add_child(main)
	await process_frame
	var catalog := main.get_node_or_null(^"TileCatalog") as TileCatalog
	if catalog == null:
		_fail("Main scene no longer exposes TileCatalog.")
		return
	var checked_scenes: Dictionary = {}
	for definition in catalog.all_definitions():
		if definition.visual_scene == null or definition.edge_indices(TileDefinition.EdgeKind.LAND).is_empty():
			continue
		var scene_path := definition.visual_scene.resource_path
		if checked_scenes.has(scene_path):
			continue
		checked_scenes[scene_path] = true
		var tile := definition.visual_scene.instantiate() as TileArtwork3D
		if tile == null:
			_fail("Plantable card %s has no TileArtwork3D prefab." % definition.id)
			return
		var placements := RUNTIME_SCATTER.generate_for_tile(tile, RUNTIME_SCATTER.seed_for_tile(definition.visual_seed, Vector2i.ZERO))
		var counts := {&"soil_herb": 0, &"soil_flower": 0, &"soil_sapling": 0}
		for placement in placements:
			counts[placement.profile.id] = int(counts.get(placement.profile.id, 0)) + 1
		tile.free()
		for profile_id in counts:
			if int(counts[profile_id]) <= 0:
				_fail("Plantable prefab %s cannot produce a %s layout." % [scene_path, profile_id])
				return
	main.queue_free()
	print("RUNTIME_PLANT_SPECIES_COVERAGE_PASS: every plantable game prefab can display grass, flower, and tree from a stable seed.")
	quit()


func _fail(message: String) -> void:
	push_error("RUNTIME_PLANT_SPECIES_COVERAGE_FAIL: " + message)
	quit(1)
