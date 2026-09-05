extends SceneTree

const SCENE := preload("res://scenes/tiles_3d/opposite_connected_land_3d.tscn")


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var tile := SCENE.instantiate() as TileArtwork3D
	get_root().add_child(tile)
	await process_frame
	if not tile.has_valid_authored_contract():
		push_error("Runtime smoke failed: canonical contract rejected after entering the scene tree.")
		quit(1)
		return
	if tile.growing_plants == null or tile.withered_plants == null:
		push_error("Runtime smoke failed: growth layers were not cached on ready.")
		quit(1)
		return
	tile.set_growth_state(TileArtwork3D.GrowthState.BARE)
	if tile.growing_plants.visible or tile.withered_plants.visible:
		push_error("Runtime smoke failed: bare state shows a plant layer.")
		quit(1)
		return
	tile.set_growth_state(TileArtwork3D.GrowthState.GROWING)
	if not tile.growing_plants.visible or tile.withered_plants.visible:
		push_error("Runtime smoke failed: growing state did not select the growing layer.")
		quit(1)
		return
	tile.set_growth_state(TileArtwork3D.GrowthState.WITHERED)
	if tile.growing_plants.visible or not tile.withered_plants.visible:
		push_error("Runtime smoke failed: withered state did not select the withered layer.")
		quit(1)
		return
	print("OPPOSITE_CONNECTED_LAND_RUNTIME_PASS: canonical prefab enters the tree and switches bare/growing/withered layers.")
	tile.queue_free()
	await process_frame
	quit()
