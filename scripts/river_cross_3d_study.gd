extends Node3D

const UI_FONT_SCRIPT := preload("res://scripts/ui_font.gd")
const CAMERA_DISTANCE := 9.0
const CAMERA_AZIMUTH_DEGREES := 45.0
const CAMERA_TARGET := Vector3(0.0, 0.12, 0.0)
const FOAM_DEBUG_CAMERA_OFFSET := 0.90
const FOAM_CONTROL_DEFINITIONS: Array[Dictionary] = [
	{
		"parameter": &"foam_line_width",
		"label": "基础线宽度",
		"minimum": 0.0025,
		"maximum": 0.085,
		"step": 0.0025,
	},
	{
		"parameter": &"foam_wave_strength",
		"label": "岸线起伏",
		"minimum": 0.0,
		"maximum": 1.40,
		"step": 0.02,
	},
	{
		"parameter": &"foam_wave_frequency",
		"label": "波浪频率",
		"minimum": 1.0,
		"maximum": 14.0,
		"step": 0.10,
	},
	{
		"parameter": &"foam_width",
		"label": "浮沫带宽度",
		"minimum": 0.02,
		"maximum": 0.20,
		"step": 0.0025,
	},
	{
		"parameter": &"foam_scale",
		"label": "泡沫疏密",
		"minimum": 1.0,
		"maximum": 16.0,
		"step": 0.10,
	},
	{
		"parameter": &"foam_radius",
		"label": "泡沫半径",
		"minimum": 0.08,
		"maximum": 0.68,
		"step": 0.01,
	},
	{
		"parameter": &"foam_cutoff",
		"label": "主阈值",
		"minimum": 0.0,
		"maximum": 1.0,
		"step": 0.01,
	},
	{
		"parameter": &"foam_speed",
		"label": "波动流速",
		"minimum": 0.0,
		"maximum": 0.85,
		"step": 0.005,
	},
]

@onready var camera: Camera3D = $Camera3D
@onready var tile: TileArtwork3D = $RiverCross3D
@onready var angle_label: Label = $UI/AngleLabel
@onready var state_label: Label = $UI/StateLabel
@onready var controls_hint: Label = $UI/Controls
@onready var foam_debug_toggle: Button = $UI/FoamDebugToggle
@onready var foam_debug_panel: PanelContainer = $UI/FoamDebugPanel
@onready var foam_shore_controls: VBoxContainer = $UI/FoamDebugPanel/Margin/Content/ShoreControls
@onready var show_foam_toggle: CheckButton = $UI/FoamDebugPanel/Margin/Content/Actions/ShowFoam
@onready var animate_foam_toggle: CheckButton = $UI/FoamDebugPanel/Margin/Content/Actions/AnimateFoam
@onready var reset_foam_button: Button = $UI/FoamDebugPanel/Margin/Content/Actions/Reset

var elevation_degrees := 55.0
var requested_state := TileArtwork3D.GrowthState.BARE
var state_capture_suffix := ""
var capture_requested := false
var capture_debug_ui := false
var smoke_requested := false
var foam_material: ShaderMaterial
var foam_sliders: Dictionary = {}
var foam_spin_boxes: Dictionary = {}
var foam_defaults: Dictionary = {}
var foam_enabled_default := true
var foam_animation_default := true


func _ready() -> void:
	get_viewport().msaa_3d = Viewport.MSAA_4X
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-angle="):
			elevation_degrees = clampf(argument.trim_prefix("--capture-angle=").to_float(), 35.0, 80.0)
			capture_requested = true
		elif argument.begins_with("--capture-state="):
			var state_name := argument.trim_prefix("--capture-state=").to_lower()
			if state_name == "growing":
				requested_state = TileArtwork3D.GrowthState.GROWING
				state_capture_suffix = "_growing"
			elif state_name == "withered":
				requested_state = TileArtwork3D.GrowthState.WITHERED
				state_capture_suffix = "_withered"
			else:
				requested_state = TileArtwork3D.GrowthState.BARE
				state_capture_suffix = ""
			capture_requested = true
		elif argument == "--study-smoke":
			smoke_requested = true
		elif argument == "--capture-debug-ui":
			capture_debug_ui = true
			capture_requested = true

	_set_camera_elevation(elevation_degrees)
	_set_growth_state(requested_state)
	_setup_foam_debug_ui()
	if capture_requested and not capture_debug_ui:
		foam_debug_toggle.visible = false
		_set_foam_debug_panel_visible(false)
	else:
		_set_foam_debug_panel_visible(true)
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
		KEY_F:
			_set_foam_debug_panel_visible(not foam_debug_panel.visible)


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


func _setup_foam_debug_ui() -> void:
	var water_surface := tile.get_node_or_null("Water/AnimatedSurface") as MeshInstance3D
	if water_surface == null or not water_surface.material_override is ShaderMaterial:
		foam_debug_panel.visible = false
		foam_debug_toggle.disabled = true
		foam_debug_toggle.text = "浮沫材质不可用"
		return

	foam_material = (water_surface.material_override as ShaderMaterial).duplicate() as ShaderMaterial
	water_surface.material_override = foam_material
	var ui_font: Font = UI_FONT_SCRIPT.ui_font()
	foam_debug_panel.add_theme_font_override("font", ui_font)
	foam_debug_toggle.add_theme_font_override("font", ui_font)

	for definition in FOAM_CONTROL_DEFINITIONS:
		var parameter := StringName(definition["parameter"])
		var current_value := float(foam_material.get_shader_parameter(parameter))
		foam_defaults[parameter] = current_value
		_add_foam_control_row(foam_shore_controls, definition, current_value)

	foam_enabled_default = bool(foam_material.get_shader_parameter(&"foam_enabled"))
	foam_animation_default = bool(foam_material.get_shader_parameter(&"foam_animation_enabled"))
	show_foam_toggle.button_pressed = foam_enabled_default
	animate_foam_toggle.button_pressed = foam_animation_default
	foam_debug_toggle.pressed.connect(_toggle_foam_debug_panel)
	show_foam_toggle.toggled.connect(_set_foam_enabled)
	animate_foam_toggle.toggled.connect(_set_foam_animation_enabled)
	reset_foam_button.pressed.connect(_reset_foam_parameters)


func _add_foam_control_row(container: VBoxContainer, definition: Dictionary, current_value: float) -> void:
	var parameter := StringName(definition["parameter"])
	var row := HBoxContainer.new()
	row.name = String(parameter).to_pascal_case()
	row.custom_minimum_size.y = 27.0
	row.add_theme_constant_override("separation", 6)
	container.add_child(row)

	var label := Label.new()
	label.custom_minimum_size = Vector2(88.0, 24.0)
	label.add_theme_color_override("font_color", Color(0.76, 0.89, 0.86, 1.0))
	label.add_theme_font_size_override("font_size", 12)
	label.text = String(definition["label"])
	label.tooltip_text = String(parameter)
	row.add_child(label)

	var slider := HSlider.new()
	slider.name = "Slider"
	slider.custom_minimum_size = Vector2(138.0, 24.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.min_value = float(definition["minimum"])
	slider.max_value = float(definition["maximum"])
	slider.step = float(definition["step"])
	slider.value = current_value
	slider.tooltip_text = String(parameter)
	row.add_child(slider)

	var spin_box := SpinBox.new()
	spin_box.name = "Value"
	spin_box.custom_minimum_size = Vector2(82.0, 26.0)
	spin_box.min_value = slider.min_value
	spin_box.max_value = slider.max_value
	spin_box.step = slider.step
	spin_box.value = current_value
	spin_box.allow_greater = false
	spin_box.allow_lesser = false
	spin_box.add_theme_font_size_override("font_size", 11)
	spin_box.get_line_edit().alignment = HORIZONTAL_ALIGNMENT_RIGHT
	spin_box.tooltip_text = String(parameter)
	row.add_child(spin_box)

	foam_sliders[parameter] = slider
	foam_spin_boxes[parameter] = spin_box
	slider.value_changed.connect(_on_foam_control_changed.bind(parameter))
	spin_box.value_changed.connect(_on_foam_control_changed.bind(parameter))


func _on_foam_control_changed(value: float, parameter: StringName) -> void:
	_set_foam_parameter(parameter, value)


func _set_foam_parameter(parameter: StringName, value: float) -> void:
	if foam_material == null:
		return
	foam_material.set_shader_parameter(parameter, value)
	var slider := foam_sliders.get(parameter) as HSlider
	if slider != null and not is_equal_approx(slider.value, value):
		slider.set_value_no_signal(value)
	var spin_box := foam_spin_boxes.get(parameter) as SpinBox
	if spin_box != null and not is_equal_approx(spin_box.value, value):
		spin_box.set_value_no_signal(value)


func _set_foam_enabled(enabled: bool) -> void:
	if foam_material != null:
		foam_material.set_shader_parameter(&"foam_enabled", enabled)


func _set_foam_animation_enabled(enabled: bool) -> void:
	if foam_material != null:
		foam_material.set_shader_parameter(&"foam_animation_enabled", enabled)


func _reset_foam_parameters() -> void:
	for parameter_variant in foam_defaults:
		var parameter := StringName(parameter_variant)
		_set_foam_parameter(parameter, float(foam_defaults[parameter]))
	show_foam_toggle.set_pressed_no_signal(foam_enabled_default)
	animate_foam_toggle.set_pressed_no_signal(foam_animation_default)
	_set_foam_enabled(foam_enabled_default)
	_set_foam_animation_enabled(foam_animation_default)


func _toggle_foam_debug_panel() -> void:
	_set_foam_debug_panel_visible(not foam_debug_panel.visible)


func _set_foam_debug_panel_visible(should_show: bool) -> void:
	if foam_material == null:
		should_show = false
	foam_debug_panel.visible = should_show
	foam_debug_toggle.text = "收起浮沫调试  [F]" if should_show else "展开浮沫调试  [F]"
	controls_hint.visible = not should_show
	camera.h_offset = FOAM_DEBUG_CAMERA_OFFSET if should_show else 0.0


func _capture_preview() -> void:
	# Let the scene enter the tree, compile materials, and draw a few real frames.
	for frame in range(5):
		await get_tree().process_frame
	await get_tree().create_timer(0.25).timeout

	var capture_directory := ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(capture_directory)
	var angle_number := int(round(elevation_degrees))
	var debug_suffix := "_foam_debug" if capture_debug_ui else ""
	var output_path := capture_directory.path_join("river_cross_3d_%d%s%s.png" % [angle_number, state_capture_suffix, debug_suffix])
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
	for quarter_turns in range(4):
		for edge in range(4):
			var expected_marker := expected_edges[int(posmod(edge - quarter_turns, 4))]
			if tile.edge_marker_at(edge, quarter_turns) != expected_marker:
				push_error("3D prefab port metadata no longer matches LAND/WATER/LAND/WATER after a 90-degree rotation.")
				get_tree().quit(1)
				return

	var mesh_nodes := tile.find_children("*", "MeshInstance3D", true, false)
	if mesh_nodes.size() < 40:
		push_error("3D prefab lost its authored mesh composition.")
		get_tree().quit(1)
		return
	if tile.get_node_or_null("Frame") != null:
		push_error("3D prefab still contains the retired wooden edge fence.")
		get_tree().quit(1)
		return
	var meadow := tile.get_node_or_null("Meadow") as MeshInstance3D
	if meadow == null or not meadow.mesh is PlaneMesh:
		push_error("3D prefab meadow must be a full-footprint plane without a visible green side wall.")
		get_tree().quit(1)
		return
	var meadow_plane := meadow.mesh as PlaneMesh
	if meadow_plane.size.x < 4.89 or meadow_plane.size.y < 4.89:
		push_error("3D prefab meadow plane no longer covers the complete tile footprint.")
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
	if foam_material == null or foam_sliders.size() != FOAM_CONTROL_DEFINITIONS.size():
		push_error("Foam debug UI did not bind every exposed shader parameter.")
		get_tree().quit(1)
		return
	var expected_control_maxima := {
		&"foam_line_width": 0.085,
		&"foam_wave_strength": 1.40,
		&"foam_wave_frequency": 14.0,
		&"foam_width": 0.20,
		&"foam_scale": 16.0,
		&"foam_radius": 0.68,
		&"foam_speed": 0.85,
	}
	for parameter_variant in expected_control_maxima:
		var parameter := StringName(parameter_variant)
		var control := foam_sliders.get(parameter) as HSlider
		if control == null or control.max_value + 0.0001 < float(expected_control_maxima[parameter_variant]):
			push_error("Foam debug UI did not expose the requested higher maximum for %s." % parameter)
			get_tree().quit(1)
			return
	var expected_foam_defaults := {
		&"foam_line_width": 0.06,
		&"foam_wave_strength": 0.5,
		&"foam_wave_frequency": 10.0,
		&"foam_width": 0.05,
		&"foam_scale": 10.7,
		&"foam_radius": 0.4,
		&"foam_cutoff": 0.6,
		&"foam_speed": 0.025,
	}
	for parameter_variant in expected_foam_defaults:
		var parameter := StringName(parameter_variant)
		var expected_value := float(expected_foam_defaults[parameter_variant])
		if (
			not foam_defaults.has(parameter)
			or not is_equal_approx(float(foam_defaults[parameter]), expected_value)
			or not is_equal_approx(float(foam_material.get_shader_parameter(parameter)), expected_value)
		):
			push_error("Foam debug UI did not load the expected default for %s." % parameter)
			get_tree().quit(1)
			return
	var tiling_slider := foam_sliders.get(&"foam_scale") as HSlider
	if tiling_slider == null:
		push_error("Foam debug UI is missing its main tiling slider.")
		get_tree().quit(1)
		return
	var original_tiling := float(foam_defaults[&"foam_scale"])
	var probe_tiling := minf(original_tiling + tiling_slider.step, tiling_slider.max_value)
	tiling_slider.value = probe_tiling
	if not is_equal_approx(float(foam_material.get_shader_parameter(&"foam_scale")), probe_tiling):
		push_error("Foam debug UI did not apply a slider change to the live material.")
		get_tree().quit(1)
		return
	_set_foam_enabled(false)
	_reset_foam_parameters()
	if (
		not is_equal_approx(float(foam_material.get_shader_parameter(&"foam_scale")), original_tiling)
		or not bool(foam_material.get_shader_parameter(&"foam_enabled"))
	):
		push_error("Foam debug UI did not restore its live material defaults.")
		get_tree().quit(1)
		return
	for parameter_variant in expected_foam_defaults:
		var parameter := StringName(parameter_variant)
		if not is_equal_approx(float(foam_material.get_shader_parameter(parameter)), float(expected_foam_defaults[parameter_variant])):
			push_error("Foam debug UI did not restore the expected default for %s." % parameter)
			get_tree().quit(1)
			return
	_set_foam_debug_panel_visible(false)
	if foam_debug_panel.visible or controls_hint.visible == false or not is_zero_approx(camera.h_offset):
		push_error("Foam debug UI did not collapse cleanly.")
		get_tree().quit(1)
		return
	_set_foam_debug_panel_visible(true)
	if not foam_debug_panel.visible or controls_hint.visible or not is_equal_approx(camera.h_offset, FOAM_DEBUG_CAMERA_OFFSET):
		push_error("Foam debug UI did not reopen with its camera framing.")
		get_tree().quit(1)
		return
	var water_arrays := water_surface.mesh.surface_get_arrays(0)
	var water_vertices: PackedVector3Array = water_arrays[Mesh.ARRAY_VERTEX]
	var shoreline_coordinates: PackedVector2Array = water_arrays[Mesh.ARRAY_TEX_UV2]
	if shoreline_coordinates.size() != water_vertices.size():
		push_error("Fused river mesh lost its baked shoreline-coordinate field.")
		get_tree().quit(1)
		return
	var has_interior_distance := false
	var minimum_shoreline_arc := 1.0
	var maximum_shoreline_arc := 0.0
	for vertex_index in range(water_vertices.size()):
		if absf(water_vertices[vertex_index].y) > 0.00001:
			push_error("River surface contains layered height offsets instead of one fused plane.")
			get_tree().quit(1)
			return
		var shoreline_coordinate := shoreline_coordinates[vertex_index]
		if shoreline_coordinate.x > 0.10:
			has_interior_distance = true
		minimum_shoreline_arc = minf(minimum_shoreline_arc, shoreline_coordinate.y)
		maximum_shoreline_arc = maxf(maximum_shoreline_arc, shoreline_coordinate.y)
	if not has_interior_distance:
		push_error("Fused river shoreline-distance field has no interior samples.")
		get_tree().quit(1)
		return
	if maximum_shoreline_arc - minimum_shoreline_arc < 0.80:
		push_error("Fused river mesh lost its shoreline arc coordinate needed to derive foam from the white edge.")
		get_tree().quit(1)
		return
	var foam_shoreline_length := float(foam_material.get_shader_parameter(&"foam_shoreline_length"))
	if foam_shoreline_length <= 1.0:
		push_error("Water material is missing its baked shoreline length for foam source placement.")
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
	var north_land := tile.get_node_or_null("LandSoil/NorthArcLand") as MeshInstance3D
	var south_land := tile.get_node_or_null("LandSoil/SouthArcLand") as MeshInstance3D
	if not _has_valid_low_soil_profile(north_land, "north") or not _has_valid_low_soil_profile(south_land, "south"):
		get_tree().quit(1)
		return
	var north_bounds := north_land.mesh.get_aabb()
	var south_bounds := south_land.mesh.get_aabb()
	if north_bounds.position.x > -2.44 or north_bounds.position.x + north_bounds.size.x < 2.44 or north_bounds.position.z > -2.44:
		push_error("North fertile land no longer reaches the full tile edge after the fence removal.")
		get_tree().quit(1)
		return
	if south_bounds.position.x > -2.44 or south_bounds.position.x + south_bounds.size.x < 2.44 or south_bounds.position.z + south_bounds.size.z < 2.44:
		push_error("South fertile land no longer reaches the full tile edge after the fence removal.")
		get_tree().quit(1)
		return
	if tile.get_node_or_null("LandSoil/NorthArcHighlight") != null or tile.get_node_or_null("LandSoil/SouthArcHighlight") != null:
		push_error("Fertile land still contains the retired central ridge highlight mesh.")
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

	print("RIVER_CROSS_3D_SMOKE_PASS: fused river surface, live foam debug controls, low edge-connected fertile soil, edge ports, and three growth states are valid.")
	get_tree().quit()


func _has_valid_low_soil_profile(land: MeshInstance3D, label: String) -> bool:
	if land == null or not land.mesh is ArrayMesh:
		push_error("%s fertile land mesh is missing or no longer baked." % label)
		return false
	if not land.material_override is ShaderMaterial:
		push_error("%s fertile land no longer uses the coherent stylized soil material." % label)
		return false
	var bounds := land.mesh.get_aabb()
	if bounds.size.x < 4.89:
		push_error("%s fertile land no longer preserves its full edge-connected width." % label)
		return false
	var top_y := bounds.position.y + bounds.size.y
	if bounds.size.y > 0.025 or bounds.position.y < 0.14 or top_y > 0.17:
		push_error("%s fertile land no longer has a near-level low top profile." % label)
		return false
	return true
