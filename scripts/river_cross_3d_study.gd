extends Node3D

const CAMERA_DISTANCE := 9.0
const CAMERA_AZIMUTH_DEGREES := 45.0
const CAMERA_TARGET := Vector3(0.0, 0.12, 0.0)

@onready var camera: Camera3D = $Camera3D
@onready var tile: TileArtwork3D = $RiverCross3D
@onready var angle_label: Label = $UI/AngleLabel
@onready var state_label: Label = $UI/StateLabel

var elevation_degrees := 55.0
var capture_requested := false
var smoke_requested := false


func _ready() -> void:
	get_viewport().msaa_3d = Viewport.MSAA_4X
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-angle="):
			elevation_degrees = clampf(argument.trim_prefix("--capture-angle=").to_float(), 35.0, 80.0)
			capture_requested = true
		elif argument == "--study-smoke":
			smoke_requested = true

	_set_camera_elevation(elevation_degrees)
	_set_growth_state(TileArtwork3D.GrowthState.GROWING)
	DisplayServer.window_set_title("碧水沃野 · River Cross 3D Study")

	if capture_requested:
		call_deferred("_capture_preview")
	elif smoke_requested:
		call_deferred("_run_study_smoke")


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_1:
			_set_camera_elevation(45.0)
		KEY_2:
			_set_camera_elevation(55.0)
		KEY_3:
			_set_camera_elevation(65.0)
		KEY_B:
			_set_growth_state(TileArtwork3D.GrowthState.BARE)
		KEY_G:
			_set_growth_state(TileArtwork3D.GrowthState.GROWING)
		KEY_W:
			_set_growth_state(TileArtwork3D.GrowthState.WITHERED)


func _set_camera_elevation(new_elevation_degrees: float) -> void:
	elevation_degrees = new_elevation_degrees
	var elevation := deg_to_rad(elevation_degrees)
	var azimuth := deg_to_rad(CAMERA_AZIMUTH_DEGREES)
	var horizontal_distance := CAMERA_DISTANCE * cos(elevation)
	camera.position = Vector3(
		horizontal_distance * sin(azimuth),
		CAMERA_DISTANCE * sin(elevation),
		horizontal_distance * cos(azimuth),
	)
	camera.look_at(CAMERA_TARGET, Vector3.UP)
	angle_label.text = "%d° 斜俯视 · 正交投影" % int(round(elevation_degrees))


func _set_growth_state(state: TileArtwork3D.GrowthState) -> void:
	tile.set_growth_state(state)
	match state:
		TileArtwork3D.GrowthState.BARE:
			state_label.text = "生长状态：裸土"
		TileArtwork3D.GrowthState.GROWING:
			state_label.text = "生长状态：生长"
		TileArtwork3D.GrowthState.WITHERED:
			state_label.text = "生长状态：枯萎"


func _capture_preview() -> void:
	# Let the scene enter the tree, compile materials, and draw a few real frames.
	for frame in range(5):
		await get_tree().process_frame
	await get_tree().create_timer(0.25).timeout

	var capture_directory := ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(capture_directory)
	var angle_number := int(round(elevation_degrees))
	var output_path := capture_directory.path_join("river_cross_3d_%d.png" % angle_number)
	var save_error := get_viewport().get_texture().get_image().save_png(output_path)
	if save_error != OK:
		push_error("Failed to save River Cross 3D preview: %s" % error_string(save_error))
		get_tree().quit(1)
		return
	print("RIVER_CROSS_3D_CAPTURE: %s" % output_path)
	get_tree().quit()


func _run_study_smoke() -> void:
	await get_tree().process_frame
	var expected_edges := PackedInt32Array([1, 2, 1, 2])
	for edge in range(4):
		if tile.edge_marker_at(edge) != expected_edges[edge]:
			push_error("3D prefab port metadata no longer matches LAND/WATER/LAND/WATER.")
			get_tree().quit(1)
			return

	var mesh_nodes := tile.find_children("*", "MeshInstance3D", true, false)
	if mesh_nodes.size() < 40:
		push_error("3D prefab lost its authored mesh composition.")
		get_tree().quit(1)
		return
	var water_surface := tile.get_node_or_null("Water/AnimatedSurface") as MeshInstance3D
	if water_surface == null or not water_surface.mesh is ArrayMesh:
		push_error("3D prefab no longer uses its baked river ribbon mesh.")
		get_tree().quit(1)
		return
	if not water_surface.material_override is ShaderMaterial:
		push_error("3D prefab water surface lost its ShaderMaterial.")
		get_tree().quit(1)
		return
	var water_bounds := water_surface.mesh.get_aabb()
	if water_bounds.position.x > -2.44 or water_bounds.position.x + water_bounds.size.x < 2.44:
		push_error("Baked river no longer reaches both centered east/west ports.")
		get_tree().quit(1)
		return
	if water_bounds.size.z < 2.7:
		push_error("Baked river branches no longer reach both land regions.")
		get_tree().quit(1)
		return

	tile.set_growth_state(TileArtwork3D.GrowthState.BARE)
	if tile.growing_plants.visible or tile.withered_plants.visible:
		push_error("Bare-soil state still shows a plant layer.")
		get_tree().quit(1)
		return
	tile.set_growth_state(TileArtwork3D.GrowthState.GROWING)
	if not tile.growing_plants.visible or tile.withered_plants.visible:
		push_error("Growing state did not select the authored crop layer.")
		get_tree().quit(1)
		return
	tile.set_growth_state(TileArtwork3D.GrowthState.WITHERED)
	if tile.growing_plants.visible or not tile.withered_plants.visible:
		push_error("Withered state did not select the authored wilted layer.")
		get_tree().quit(1)
		return

	print("RIVER_CROSS_3D_SMOKE_PASS: fixed curved ribbon, shader water, edge ports, and three growth states are valid.")
	get_tree().quit()
