extends SceneTree

const WIND_SCRIPT := preload("res://scripts/vegetation_wind_3d.gd")
const HERB_SCENE := preload("res://scenes/plants/soil_herb.tscn")
const FLOWER_SCENE := preload("res://scenes/plants/soil_flower.tscn")
const SAPLING_SCENE := preload("res://scenes/plants/soil_sapling.tscn")


func _init() -> void:
	call_deferred("_smoke")


func _smoke() -> void:
	var wind: Node = get_root().get_node_or_null(^"VegetationWind")
	if wind == null:
		wind = WIND_SCRIPT.new()
		wind.name = "VegetationWind"
		get_root().add_child(wind)
	if not is_equal_approx(float(wind.get("sway_frequency_hz")), 0.333):
		_fail("The shared wind default must keep the approximately three-second cycle.")
		return
	wind.set("world_direction", Vector3.RIGHT)
	wind.set("sway_frequency_hz", 1.0)
	wind.set("maximum_angle_degrees", 8.0)
	wind.call("set_phase_seconds", 0.25)

	var first_tile := Node3D.new()
	first_tile.rotation.y = deg_to_rad(17.0)
	get_root().add_child(first_tile)
	var second_tile := Node3D.new()
	second_tile.rotation.y = deg_to_rad(90.0)
	get_root().add_child(second_tile)

	var herb := HERB_SCENE.instantiate() as SowablePlant3D
	herb.rotation.y = deg_to_rad(-31.0)
	first_tile.add_child(herb)
	var flower := FLOWER_SCENE.instantiate() as SowablePlant3D
	flower.rotation.y = deg_to_rad(43.0)
	second_tile.add_child(flower)
	var sapling := SAPLING_SCENE.instantiate() as SowablePlant3D
	sapling.rotation.y = deg_to_rad(68.0)
	second_tile.add_child(sapling)

	await process_frame
	await process_frame
	if not herb.wind_sway_enabled or not flower.wind_sway_enabled or sapling.wind_sway_enabled:
		_fail("Only the grass and flower scenes may opt into the shared wind sway.")
		return
	var wind_direction: Vector3 = wind.call("get_world_direction")
	if not _leans_toward(herb, wind_direction) or not _leans_toward(flower, wind_direction):
		_fail("Rotated grass and flower instances did not lean along the same world direction.")
		return
	if not _is_vertical(sapling):
		_fail("Tree instance unexpectedly received the grass-and-flower wind sway.")
		return

	wind.call("set_phase_seconds", 0.75)
	await process_frame
	await process_frame
	var reverse_direction := -wind_direction
	if not _leans_toward(herb, reverse_direction) or not _leans_toward(flower, reverse_direction):
		_fail("Grass and flower lost their shared phase when the wind swing reversed.")
		return
	print("VEGETATION_WIND_3D_PASS: grass and flower share one world-space direction and phase across rotated tiles; tree remains still.")
	quit()


func _leans_toward(plant: SowablePlant3D, expected_direction: Vector3) -> bool:
	var up := plant.global_transform.basis.y.normalized()
	var horizontal_tilt := Vector3(up.x, 0.0, up.z)
	return horizontal_tilt.length_squared() > 0.000001 and horizontal_tilt.normalized().dot(expected_direction) > 0.999


func _is_vertical(plant: SowablePlant3D) -> bool:
	var up := plant.global_transform.basis.y.normalized()
	return Vector3(up.x, 0.0, up.z).length_squared() <= 0.000001


func _fail(message: String) -> void:
	push_error("VEGETATION_WIND_3D_FAIL: " + message)
	quit(1)
