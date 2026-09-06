extends Node3D

const RUNTIME_SCATTER := preload("res://scripts/runtime_plant_scatter_3d.gd")
const PLAYER_COLORS := [Color(0.18, 0.52, 0.86, 1.0), Color(0.85, 0.27, 0.38, 1.0)]

@onready var camera: Camera3D = $Camera3D
@onready var tile: TileArtwork3D = $BlenderTile

var requested_state := TileArtwork3D.GrowthState.GROWING
var player_index := 0
var capture_requested := false


func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-state="):
			requested_state = {
				"bare": TileArtwork3D.GrowthState.BARE,
				"growing": TileArtwork3D.GrowthState.GROWING,
				"withered": TileArtwork3D.GrowthState.WITHERED,
			}.get(argument.trim_prefix("--capture-state=").to_lower(), TileArtwork3D.GrowthState.GROWING)
			capture_requested = true
		elif argument.begins_with("--capture-player="):
			player_index = clampi(argument.trim_prefix("--capture-player=").to_int() - 1, 0, PLAYER_COLORS.size() - 1)
			capture_requested = true
		elif argument == "--capture":
			capture_requested = true
	_set_camera()
	var seed := RUNTIME_SCATTER.seed_for_tile(20260905, Vector2i.ZERO)
	tile.set_runtime_plant_layout(RUNTIME_SCATTER.generate_for_tile(tile, seed))
	_apply_state()
	if capture_requested:
		call_deferred("_capture")


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_B:
			requested_state = TileArtwork3D.GrowthState.BARE
		KEY_G:
			requested_state = TileArtwork3D.GrowthState.GROWING
		KEY_W:
			requested_state = TileArtwork3D.GrowthState.WITHERED
		KEY_C:
			player_index = (player_index + 1) % PLAYER_COLORS.size()
	_apply_state()


func _set_camera() -> void:
	var elevation := deg_to_rad(56.0)
	var azimuth := deg_to_rad(37.0)
	var distance := 9.4
	var horizontal_distance := distance * cos(elevation)
	camera.position = Vector3(horizontal_distance * sin(azimuth), distance * sin(elevation), horizontal_distance * cos(azimuth))
	camera.look_at(Vector3(0.0, 0.30, 0.0), Vector3.UP)


func _apply_state() -> void:
	var state := {
		0: {"growth_state": requested_state, "owner_color": PLAYER_COLORS[player_index]},
		1: {"growth_state": requested_state, "owner_color": PLAYER_COLORS[player_index]},
		2: {"growth_state": requested_state, "owner_color": PLAYER_COLORS[player_index]},
	}
	tile.set_runtime_plant_states(state)
	tile.set_growth_state(requested_state)
	$UI/Panel/State.text = "状态：%s · 玩家 P%d" % [["裸土", "生长", "枯萎"][requested_state], player_index + 1]


func _capture() -> void:
	for frame in range(6):
		await get_tree().process_frame
	await get_tree().create_timer(0.30).timeout
	var state_name: String = ["bare", "growing", "withered"][requested_state]
	var output_path := ProjectSettings.globalize_path("res://artifacts/blender_north_east_land_south_water_3d_%s_p%d.png" % [state_name, player_index + 1])
	var image := get_viewport().get_texture().get_image()
	if image == null or image.save_png(output_path) != OK:
		push_error("Could not capture Blender terrain pilot with the active display driver.")
		get_tree().quit(1)
		return
	print("BLENDER_TILE_CAPTURE: %s" % output_path)
	get_tree().quit()
