extends Node3D

const CAMERA_DISTANCE := 9.2
const CAMERA_TARGET := Vector3(0.0, 0.32, 0.0)
const PLAYER_COLORS := [
	Color(0.18, 0.52, 0.86, 1.0),
	Color(0.85, 0.27, 0.38, 1.0),
	Color(0.70, 0.40, 0.86, 1.0),
]

@onready var camera: Camera3D = $Camera3D
@onready var bed: SoilPlantingBed3D = $SoilPlantingBed
@onready var state_label: Label = $UI/InfoPanel/StateLabel
@onready var coverage_label: Label = $UI/InfoPanel/CoverageLabel
@onready var owner_label: Label = $UI/InfoPanel/OwnerLabel

var player_index := 0
var requested_state := SoilPlantingBed3D.GrowthState.GROWING
var requested_coverage := 1.0
var capture_requested := false
var smoke_requested := false


func _ready() -> void:
	get_viewport().msaa_3d = Viewport.MSAA_4X
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-state="):
			requested_state = _state_from_name(argument.trim_prefix("--capture-state="))
			capture_requested = true
		elif argument.begins_with("--capture-coverage="):
			requested_coverage = clampf(argument.trim_prefix("--capture-coverage=").to_float(), 0.0, 1.0)
			capture_requested = true
		elif argument.begins_with("--capture-player="):
			player_index = clampi(argument.trim_prefix("--capture-player=").to_int() - 1, 0, PLAYER_COLORS.size() - 1)
			capture_requested = true
		elif argument == "--capture":
			capture_requested = true
		elif argument == "--study-smoke":
			smoke_requested = true

	_set_camera()
	_apply_visual_state()
	DisplayServer.window_set_title("碧水沃野 · 沃土播种植物研究")
	if capture_requested:
		call_deferred("_capture_preview")
	elif smoke_requested:
		call_deferred("_run_study_smoke")


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_B:
			requested_state = SoilPlantingBed3D.GrowthState.BARE
		KEY_G:
			requested_state = SoilPlantingBed3D.GrowthState.GROWING
		KEY_W:
			requested_state = SoilPlantingBed3D.GrowthState.WILTED
		KEY_1:
			requested_coverage = 0.30
		KEY_2:
			requested_coverage = 0.62
		KEY_3:
			requested_coverage = 1.0
		KEY_C:
			player_index = (player_index + 1) % PLAYER_COLORS.size()
	_apply_visual_state()


func _set_camera() -> void:
	var elevation := deg_to_rad(55.0)
	var azimuth := deg_to_rad(35.0)
	var horizontal_distance := CAMERA_DISTANCE * cos(elevation)
	camera.position = Vector3(
		horizontal_distance * sin(azimuth),
		CAMERA_DISTANCE * sin(elevation),
		horizontal_distance * cos(azimuth),
	)
	camera.look_at(CAMERA_TARGET, Vector3.UP)


func _apply_visual_state() -> void:
	bed.set_owner_color(PLAYER_COLORS[player_index])
	bed.set_growth_state(requested_state)
	bed.set_coverage(requested_coverage)
	var state_name := "裸土" if requested_state == SoilPlantingBed3D.GrowthState.BARE else "生长" if requested_state == SoilPlantingBed3D.GrowthState.GROWING else "枯萎"
	state_label.text = "状态：%s" % state_name
	coverage_label.text = "生长覆盖：%d%%" % int(round(requested_coverage * 100.0))
	owner_label.text = "玩家归属徽记：P%d" % (player_index + 1)
	owner_label.add_theme_color_override("font_color", PLAYER_COLORS[player_index])


func _state_from_name(name: String) -> SoilPlantingBed3D.GrowthState:
	match name.to_lower():
		"bare":
			return SoilPlantingBed3D.GrowthState.BARE
		"wilted":
			return SoilPlantingBed3D.GrowthState.WILTED
		_:
			return SoilPlantingBed3D.GrowthState.GROWING


func _capture_preview() -> void:
	for frame in range(5):
		await get_tree().process_frame
	await get_tree().create_timer(0.25).timeout
	var state_suffix := "bare" if requested_state == SoilPlantingBed3D.GrowthState.BARE else "growing" if requested_state == SoilPlantingBed3D.GrowthState.GROWING else "wilted"
	var output_path := ProjectSettings.globalize_path("res://artifacts/soil_planting_study_%s_%d_p%d.png" % [state_suffix, int(round(requested_coverage * 100.0)), player_index + 1])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	var image := get_viewport().get_texture().get_image()
	if image == null:
		push_error("Cannot capture soil-planting study without a real display driver.")
		get_tree().quit(1)
		return
	var save_error := image.save_png(output_path)
	if save_error != OK:
		push_error("Failed to save soil-planting study image: %s" % error_string(save_error))
		get_tree().quit(1)
		return
	print("SOIL_PLANTING_STUDY_CAPTURE: %s" % output_path)
	get_tree().quit()


func _run_study_smoke() -> void:
	await get_tree().process_frame
	if bed.layout == null or not bed.layout.is_valid():
		_fail("Baked soil bed has no valid PlantScatterLayout3D.")
		return
	var layout := bed.layout
	var expected_count := 0
	var counts: Dictionary = {}
	for placement_index in range(layout.placements.size()):
		var placement := layout.placements[placement_index]
		var point := Vector2(placement.local_position.x, placement.local_position.z)
		if not layout.planting_mask.contains_point(point, placement.profile.extra_edge_clearance + placement.profile.footprint_radius):
			_fail("A baked sowable plant lies outside its authored soil mask.")
			return
		for earlier_index in range(placement_index):
			var earlier := layout.placements[earlier_index]
			var earlier_point := Vector2(earlier.local_position.x, earlier.local_position.z)
			var required := placement.profile.footprint_radius + earlier.profile.footprint_radius + maxf(placement.profile.minimum_gap, earlier.profile.minimum_gap)
			if point.distance_to(earlier_point) + 0.0001 < required:
				_fail("Baked sowable plants violate their variable-radius spacing contract.")
				return
		counts[placement.profile.id] = int(counts.get(placement.profile.id, 0)) + 1
		expected_count += 1
	for profile_id in counts:
		var profile_count := int(counts[profile_id])
		if profile_count <= 0:
			_fail("A configured sowable species was omitted from the baked layout.")
			return
	var source_profiles: Array[PlantScatterProfile3D] = []
	for placement in layout.placements:
		if not source_profiles.has(placement.profile):
			source_profiles.append(placement.profile)
	var regenerated_layout := PlantScatterPlanner.generate(layout.id, layout.planting_mask, source_profiles, layout.seed)
	if regenerated_layout.placements.size() != layout.placements.size():
		_fail("The fixed seed no longer regenerates the baked planting count.")
		return
	for placement_index in range(layout.placements.size()):
		var baked_placement := layout.placements[placement_index]
		var regenerated_placement := regenerated_layout.placements[placement_index]
		if (
			baked_placement.profile != regenerated_placement.profile
			or baked_placement.local_position.distance_to(regenerated_placement.local_position) > 0.00001
			or not is_equal_approx(baked_placement.yaw_degrees, regenerated_placement.yaw_degrees)
			or not is_equal_approx(baked_placement.scale_multiplier, regenerated_placement.scale_multiplier)
		):
			_fail("The baked planting layout no longer reproduces from its fixed seed.")
			return

	var baked_plants := bed.get_baked_plants()
	if baked_plants.size() != expected_count * 2:
		_fail("Growing and withered layers no longer contain the same fixed planting layout.")
		return
	for plant in baked_plants:
		if (
			not plant.is_authored_model_valid()
			or not plant.has_meta("reveal_threshold")
			or String(plant.get_meta("planting_mask_id", "")) != String(layout.planting_mask.id)
		):
			_fail("A baked plant lost its state silhouette or replaceable owner marker contract.")
			return

	bed.set_growth_state(SoilPlantingBed3D.GrowthState.BARE)
	if bed.growing_plants.visible or bed.withered_plants.visible:
		_fail("Bare soil still shows a planted-plant layer.")
		return
	bed.set_growth_state(SoilPlantingBed3D.GrowthState.GROWING)
	if not bed.growing_plants.visible or bed.withered_plants.visible:
		_fail("Growing state did not select its fixed planted-plant layer.")
		return
	bed.set_growth_state(SoilPlantingBed3D.GrowthState.WILTED)
	if bed.growing_plants.visible or not bed.withered_plants.visible:
		_fail("Withered state did not select its fixed dry plant layer.")
		return

	bed.set_growth_state(SoilPlantingBed3D.GrowthState.GROWING)
	bed.set_owner_color(PLAYER_COLORS[1])
	var first_plant := bed.growing_plants.get_child(0) as SowablePlant3D
	var marker_material := first_plant.owner_marker.material_override as StandardMaterial3D
	if marker_material == null or not marker_material.albedo_color.is_equal_approx(PLAYER_COLORS[1]):
		_fail("Player ownership did not recolour only the authored marker material.")
		return

	requested_state = SoilPlantingBed3D.GrowthState.GROWING
	requested_coverage = 1.0
	player_index = 0
	_apply_visual_state()
	print("SOIL_PLANTING_STUDY_SMOKE_PASS: %d soil-only placements, three sowable silhouettes, stable baked layout, and replaceable owner markers are valid." % expected_count)
	get_tree().quit()


func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
