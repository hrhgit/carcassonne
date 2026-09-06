extends Node3D

const CAMERA_DISTANCE := 9.0
const CAMERA_AZIMUTH_DEGREES := 32.0

@onready var camera: Camera3D = $Camera3D
@onready var tile: TileArtwork3D = $OppositeConnectedLand3D
@onready var state_label: Label = $UI/StateLabel
@onready var angle_label: Label = $UI/AngleLabel

var elevation_degrees := 55.0


func _ready() -> void:
	_set_camera_elevation(elevation_degrees)
	_set_growth_state(TileArtwork3D.GrowthState.BARE)
	DisplayServer.window_set_title("青菱沃野 · 相对双边连通地块")


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
	camera.look_at(Vector3(0.0, 0.12, 0.0), Vector3.UP)
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
