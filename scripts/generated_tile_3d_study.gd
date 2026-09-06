extends Node3D

const PLAYER_COLORS := [Color(0.18, 0.52, 0.86, 1.0), Color(0.85, 0.27, 0.38, 1.0)]

@onready var camera: Camera3D = $Camera3D
@onready var tile: Node3D = $GeneratedTile

var requested_state := 1
var player_index := 0
var capture_requested := false
@export var capture_name := "procedural_north_east_land_south_water_3d"


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-state="):
			requested_state = {"bare": 0, "growing": 1, "withered": 2}.get(argument.trim_prefix("--capture-state=").to_lower(), 1)
			capture_requested = true
		elif argument.begins_with("--capture-player="):
			player_index = clampi(argument.trim_prefix("--capture-player=").to_int() - 1, 0, PLAYER_COLORS.size() - 1)
			capture_requested = true
		elif argument.begins_with("--capture-name="):
			capture_name = argument.trim_prefix("--capture-name=").strip_edges()
			capture_requested = true
		elif argument == "--capture":
			capture_requested = true
	_set_camera()
	_apply_state()
	if capture_requested:
		call_deferred("_capture")


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_B:
			requested_state = 0
		KEY_G:
			requested_state = 1
		KEY_W:
			requested_state = 2
		KEY_C:
			player_index = (player_index + 1) % PLAYER_COLORS.size()
	_apply_state()


func _set_camera() -> void:
	var elevation := deg_to_rad(56.0)
	var azimuth := deg_to_rad(37.0)
	var distance := 9.4
	var horizontal_distance := distance * cos(elevation)
	camera.position = Vector3(horizontal_distance * sin(azimuth), distance * sin(elevation), horizontal_distance * cos(azimuth))
	camera.look_at(Vector3(0.0, 0.35, 0.0), Vector3.UP)


func _apply_state() -> void:
	tile.call("set_growth_state", requested_state)
	for plant in tile.find_children("*", "SowablePlant3D", true, false):
		plant.call("set_owner_color", PLAYER_COLORS[player_index])


func _capture() -> void:
	for frame in range(5):
		await get_tree().process_frame
	await get_tree().create_timer(0.25).timeout
	var state_name: String = ["bare", "growing", "withered"][requested_state]
	var output_path := ProjectSettings.globalize_path("res://artifacts/%s_%s_p%d.png" % [capture_name, state_name, player_index + 1])
	var image := get_viewport().get_texture().get_image()
	if image == null or image.save_png(output_path) != OK:
		push_error("Could not capture generated 3D tile with the active display driver.")
		get_tree().quit(1)
		return
	print("GENERATED_TILE_3D_CAPTURE: %s" % output_path)
	get_tree().quit()
