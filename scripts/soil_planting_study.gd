extends Node3D

# This scene is the visual tuning surface for the runtime plant scatterer. The
# old baked bed remains in the project as an audit/study artifact, but this
# preview deliberately regenerates from one stable seed whenever a control is
# changed so designers can see the real game path.
const CAMERA_DISTANCE := 9.2
const CAMERA_TARGET := Vector3(0.0, 0.32, 0.0)
const DEFAULT_SEED := 613_907
const MASK := preload("res://art/planting_masks/soil_planting_study.tres")
const HERB_PROFILE := preload("res://art/plant_profiles/soil_herb.tres")
const FLOWER_PROFILE := preload("res://art/plant_profiles/soil_flower.tres")
const SAPLING_PROFILE := preload("res://art/plant_profiles/soil_sapling.tres")
const PLAYER_COLORS := [
	Color(0.18, 0.52, 0.86, 1.0),
	Color(0.85, 0.27, 0.38, 1.0),
	Color(0.70, 0.40, 0.86, 1.0),
]

enum PreviewState {
	BARE,
	GROWING,
	WITHERED,
}

@onready var camera: Camera3D = $Camera3D
@onready var baked_bed: Node3D = get_node_or_null("SoilPlantingBed") as Node3D
@onready var state_label: Label = $UI/InfoPanel/StateLabel
@onready var coverage_label: Label = $UI/InfoPanel/CoverageLabel
@onready var owner_label: Label = $UI/InfoPanel/OwnerLabel

var preview_plants: Node3D
var preview_layout: PlantScatterLayout3D
var player_index := 0
var requested_state := PreviewState.GROWING
var requested_coverage := 1.0
var study_seed := DEFAULT_SEED
var selected_profile_id: StringName = &"soil_herb"
var capture_requested := false
var smoke_requested := false

var tuning: Dictionary = {
	&"soil_herb": {"density": 28.0, "scale": 1.0, "variation": 0.45},
	&"soil_flower": {"density": 12.0, "scale": 1.0, "variation": 0.30},
	&"soil_sapling": {"density": 3.0, "scale": 0.92, "variation": 0.20},
}

var species_select: OptionButton
var density_slider: HSlider
var scale_slider: HSlider
var variation_slider: HSlider
var density_value_label: Label
var scale_value_label: Label
var variation_value_label: Label
var preview_count_label: Label


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

	if baked_bed != null:
		baked_bed.visible = false
	preview_plants = get_node_or_null("PreviewPlants") as Node3D
	if preview_plants == null:
		preview_plants = Node3D.new()
		preview_plants.name = "PreviewPlants"
		add_child(preview_plants)
	_build_tuning_panel()
	_set_camera()
	_apply_visual_state(true)
	DisplayServer.window_set_title("碧水沃野 · 沃土播种植物调节")
	if capture_requested:
		call_deferred("_capture_preview")
	elif smoke_requested:
		call_deferred("_run_study_smoke")


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_B:
			requested_state = PreviewState.BARE
		KEY_G:
			requested_state = PreviewState.GROWING
		KEY_W:
			requested_state = PreviewState.WITHERED
		KEY_1:
			requested_coverage = 0.30
		KEY_2:
			requested_coverage = 0.62
		KEY_3:
			requested_coverage = 1.0
		KEY_C:
			player_index = (player_index + 1) % PLAYER_COLORS.size()
	_apply_visual_state(false)


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


func _apply_visual_state(rebuild_layout: bool) -> void:
	if rebuild_layout:
		_rebuild_preview()
	_apply_preview_state()
	state_label.text = "状态：%s" % _state_name(requested_state)
	coverage_label.text = "生长覆盖：%d%%" % int(round(requested_coverage * 100.0))
	owner_label.text = "玩家归属颜色：P%d（花瓣 / 树冠 / 整丛草）" % (player_index + 1)
	owner_label.add_theme_color_override("font_color", PLAYER_COLORS[player_index])
	_update_tuning_labels()


func _rebuild_preview() -> void:
	for child in preview_plants.get_children():
		child.free()
	var profiles := _effective_profiles()
	preview_layout = PlantScatterPlanner.generate(
		&"soil_planting_runtime_preview",
		MASK,
		profiles,
		study_seed,
		false,
	)
	for placement_index in range(preview_layout.placements.size()):
		var placement := preview_layout.placements[placement_index]
		var plant := placement.profile.plant_scene.instantiate() as SowablePlant3D
		if plant == null:
			continue
		plant.name = "%s_%02d" % [placement.profile.id, placement_index + 1]
		plant.position = placement.local_position
		plant.rotation.y = deg_to_rad(placement.yaw_degrees)
		plant.scale = Vector3.ONE * placement.scale_multiplier
		plant.set_meta("reveal_threshold", placement.reveal_threshold)
		plant.set_meta("planting_mask_id", MASK.id)
		preview_plants.add_child(plant)


func _apply_preview_state() -> void:
	for child in preview_plants.get_children():
		if not child is SowablePlant3D:
			continue
		var plant := child as SowablePlant3D
		plant.set_owner_color(PLAYER_COLORS[player_index])
		plant.set_growth_state(
			SowablePlant3D.GrowthState.WILTED if requested_state == PreviewState.WITHERED else SowablePlant3D.GrowthState.GROWING
		)
		plant.visible = requested_state != PreviewState.BARE and float(plant.get_meta("reveal_threshold", 1.0)) <= requested_coverage


func _effective_profiles() -> Array[PlantScatterProfile3D]:
	var result: Array[PlantScatterProfile3D] = []
	for source in _source_profiles():
		var settings: Dictionary = tuning.get(source.id, {})
		var density := int(round(float(settings.get("density", source.desired_count))))
		if density <= 0:
			continue
		var overall_scale := float(settings.get("scale", 1.0))
		var variation := float(settings.get("variation", 0.0))
		var profile := source.duplicate(true) as PlantScatterProfile3D
		profile.desired_count = density
		profile.minimum_scale = maxf(0.05, source.minimum_scale * overall_scale * maxf(0.08, 1.0 - variation * 0.45))
		profile.maximum_scale = minf(8.0, source.maximum_scale * overall_scale * (1.0 + variation * 0.45))
		profile.footprint_radius = source.footprint_radius * overall_scale * (1.0 + variation * 0.20)
		profile.minimum_gap = source.minimum_gap * overall_scale
		profile.cluster_radius = source.cluster_radius * overall_scale
		result.append(profile)
	return result


func _source_profiles() -> Array[PlantScatterProfile3D]:
	return [HERB_PROFILE, FLOWER_PROFILE, SAPLING_PROFILE]


func _build_tuning_panel() -> void:
	var panel := PanelContainer.new()
	panel.name = "PlantTuningPanel"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -358.0
	panel.offset_top = 28.0
	panel.offset_right = -28.0
	panel.offset_bottom = 470.0
	$UI.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	var title := Label.new()
	title.text = "植物散布调节"
	title.add_theme_font_size_override("font_size", 21)
	box.add_child(title)
	var hint := Label.new()
	hint.text = "只重算稳定种子预览；不会修改地形或水路。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_font_size_override("font_size", 12)
	box.add_child(hint)

	species_select = OptionButton.new()
	species_select.add_item("草 · plant_bush")
	species_select.set_item_metadata(0, &"soil_herb")
	species_select.add_item("花 · flower_redC")
	species_select.set_item_metadata(1, &"soil_flower")
	species_select.add_item("树 · tree_detailed")
	species_select.set_item_metadata(2, &"soil_sapling")
	species_select.item_selected.connect(_on_species_selected)
	box.add_child(species_select)

	density_value_label = _add_slider(box, "密度", 0.0, 160.0, 1.0, _on_density_changed)
	density_slider = density_value_label.get_meta("slider") as HSlider
	scale_value_label = _add_slider(box, "整体大小", 0.05, 8.0, 0.05, _on_scale_changed)
	scale_slider = scale_value_label.get_meta("slider") as HSlider
	variation_value_label = _add_slider(box, "大小差异（0 = 整齐）", 0.0, 1.50, 0.01, _on_variation_changed)
	variation_slider = variation_value_label.get_meta("slider") as HSlider

	preview_count_label = Label.new()
	preview_count_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_count_label.add_theme_font_size_override("font_size", 13)
	box.add_child(preview_count_label)
	var buttons := HBoxContainer.new()
	var reset_button := Button.new()
	reset_button.text = "恢复默认"
	reset_button.pressed.connect(_restore_defaults)
	buttons.add_child(reset_button)
	var reseed_button := Button.new()
	reseed_button.text = "重掷稳定种子"
	reseed_button.pressed.connect(_reseed_preview)
	buttons.add_child(reseed_button)
	box.add_child(buttons)
	_sync_tuning_controls()


func _add_slider(parent: VBoxContainer, title: String, minimum: float, maximum: float, step: float, callback: Callable) -> Label:
	var row := VBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 14)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = step
	slider.value_changed.connect(callback)
	row.add_child(slider)
	label.set_meta("slider", slider)
	return label


func _on_species_selected(index: int) -> void:
	selected_profile_id = species_select.get_item_metadata(index) as StringName
	_sync_tuning_controls()


func _on_density_changed(value: float) -> void:
	_update_selected_setting("density", value)


func _on_scale_changed(value: float) -> void:
	_update_selected_setting("scale", value)


func _on_variation_changed(value: float) -> void:
	_update_selected_setting("variation", value)


func _update_selected_setting(key: StringName, value: float) -> void:
	var settings: Dictionary = tuning.get(selected_profile_id, {}).duplicate(true)
	settings[key] = value
	tuning[selected_profile_id] = settings
	_apply_visual_state(true)


func _sync_tuning_controls() -> void:
	var settings: Dictionary = tuning.get(selected_profile_id, {})
	density_slider.set_block_signals(true)
	scale_slider.set_block_signals(true)
	variation_slider.set_block_signals(true)
	density_slider.value = float(settings.get("density", 0.0))
	scale_slider.value = float(settings.get("scale", 1.0))
	variation_slider.value = float(settings.get("variation", 0.0))
	density_slider.set_block_signals(false)
	scale_slider.set_block_signals(false)
	variation_slider.set_block_signals(false)
	_update_tuning_labels()


func _update_tuning_labels() -> void:
	if density_value_label == null:
		return
	density_value_label.text = "密度：%d 株 / 当前沃土" % int(round(density_slider.value))
	scale_value_label.text = "整体大小：%.2f ×" % scale_slider.value
	variation_value_label.text = "大小差异：%.0f%%" % (variation_slider.value * 100.0)
	var counts := _count_preview_species()
	preview_count_label.text = "稳定种子 %d · 预览：草 %d / 花 %d / 树 %d\n默认层级：草最密，花其次，树最稀。" % [
		study_seed,
		int(counts.get(&"soil_herb", 0)),
		int(counts.get(&"soil_flower", 0)),
		int(counts.get(&"soil_sapling", 0)),
	]


func _count_preview_species() -> Dictionary:
	var counts: Dictionary = {}
	if preview_layout == null:
		return counts
	for placement in preview_layout.placements:
		counts[placement.profile.id] = int(counts.get(placement.profile.id, 0)) + 1
	return counts


func _restore_defaults() -> void:
	tuning = {
		&"soil_herb": {"density": 28.0, "scale": 1.0, "variation": 0.45},
		&"soil_flower": {"density": 12.0, "scale": 1.0, "variation": 0.30},
		&"soil_sapling": {"density": 3.0, "scale": 0.92, "variation": 0.20},
	}
	study_seed = DEFAULT_SEED
	_sync_tuning_controls()
	_apply_visual_state(true)


func _reseed_preview() -> void:
	study_seed = int(posmod(study_seed * 1_103_515_245 + 12_345, 2_147_483_647))
	_apply_visual_state(true)


func _state_from_name(name: String) -> PreviewState:
	match name.to_lower():
		"bare":
			return PreviewState.BARE
		"wilted":
			return PreviewState.WITHERED
		_:
			return PreviewState.GROWING


func _state_name(state: PreviewState) -> String:
	match state:
		PreviewState.BARE:
			return "裸土"
		PreviewState.WITHERED:
			return "枯萎"
		_:
			return "生长"


func _capture_preview() -> void:
	for _frame in range(5):
		await get_tree().process_frame
	await get_tree().create_timer(0.25).timeout
	var state_suffix := "bare" if requested_state == PreviewState.BARE else "growing" if requested_state == PreviewState.GROWING else "wilted"
	var output_path := ProjectSettings.globalize_path("res://artifacts/soil_planting_study_%s_%d_p%d.png" % [state_suffix, int(round(requested_coverage * 100.0)), player_index + 1])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	var image := get_viewport().get_texture().get_image()
	if image == null:
		_fail("Cannot capture soil-planting study without a real display driver.")
		return
	var save_error := image.save_png(output_path)
	if save_error != OK:
		_fail("Failed to save soil-planting study image: %s" % error_string(save_error))
		return
	print("SOIL_PLANTING_STUDY_CAPTURE: %s" % output_path)
	get_tree().quit()


func _run_study_smoke() -> void:
	await get_tree().process_frame
	if preview_layout == null or preview_layout.placements.is_empty():
		_fail("Runtime tuning preview did not generate any planted instances.")
		return
	var expected_count := preview_layout.placements.size()
	for placement_index in range(expected_count):
		var placement := preview_layout.placements[placement_index]
		var point := Vector2(placement.local_position.x, placement.local_position.z)
		if not MASK.contains_point(point, placement.profile.extra_edge_clearance + placement.profile.footprint_radius):
			_fail("A runtime plant lies outside its authored LAND mask.")
			return
		for earlier_index in range(placement_index):
			var earlier := preview_layout.placements[earlier_index]
			var earlier_point := Vector2(earlier.local_position.x, earlier.local_position.z)
			var required := placement.profile.footprint_radius + earlier.profile.footprint_radius + maxf(placement.profile.minimum_gap, earlier.profile.minimum_gap)
			if point.distance_to(earlier_point) + 0.0001 < required:
				_fail("Runtime plants violate their variable-radius spacing contract.")
				return
	var regenerated := PlantScatterPlanner.generate(&"soil_planting_runtime_preview", MASK, _effective_profiles(), study_seed, false)
	if regenerated.placements.size() != expected_count:
		_fail("The same seed no longer reproduces the runtime plant count.")
		return
	for placement_index in range(expected_count):
		var original := preview_layout.placements[placement_index]
		var repeat := regenerated.placements[placement_index]
		if original.profile.id != repeat.profile.id or original.local_position.distance_to(repeat.local_position) > 0.00001 or not is_equal_approx(original.scale_multiplier, repeat.scale_multiplier):
			_fail("The runtime plant layout is not stable for one seed.")
			return
	if preview_plants.get_child_count() != expected_count:
		_fail("The runtime plant layer did not instantiate every generated placement.")
		return
	var counts := _count_preview_species()
	if int(counts.get(&"soil_herb", 0)) <= int(counts.get(&"soil_flower", 0)) or int(counts.get(&"soil_flower", 0)) <= int(counts.get(&"soil_sapling", 0)):
		_fail("Default density ordering must be grass > flower > tree.")
		return
	requested_state = PreviewState.BARE
	_apply_visual_state(false)
	if preview_plants.get_children().any(func(child): return child.visible):
		_fail("Bare soil still shows a runtime plant.")
		return
	requested_state = PreviewState.WITHERED
	_apply_visual_state(false)
	if preview_plants.get_children().any(func(child): return not child.visible):
		_fail("Withered state did not reveal every runtime plant.")
		return
	requested_state = PreviewState.GROWING
	requested_coverage = 1.0
	player_index = 1
	_apply_visual_state(false)
	await get_tree().process_frame
	var first_plant := preview_plants.get_child(0) as SowablePlant3D
	if first_plant == null or not first_plant.is_authored_model_valid() or not first_plant.owner_color_is_applied(PLAYER_COLORS[player_index]):
		_fail("A model lost its target ownership-colour component.")
		return
	print("SOIL_PLANTING_STUDY_SMOKE_PASS: %d deterministic runtime placements; grass > flower > tree; wide density/scale/variation controls and model ownership colours are valid." % expected_count)
	get_tree().quit()


func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
