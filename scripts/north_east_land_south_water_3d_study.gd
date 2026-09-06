extends Node3D

const CAMERA_DISTANCE := 9.4
const CAMERA_TARGET := Vector3(0.0, 0.35, 0.0)
const LAYOUT_PATH := "res://art/generated/north_east_land_south_water_flower_herb_layout.tres"
const PLAYER_COLORS := [
	Color(0.18, 0.52, 0.86, 1.0),
	Color(0.85, 0.27, 0.38, 1.0),
	Color(0.70, 0.40, 0.86, 1.0),
]

@onready var camera: Camera3D = $Camera3D
@onready var tile: TileArtwork3D = $NorthEastLandSouthWater3D
@onready var state_label: Label = $UI/InfoPanel/StateLabel
@onready var owner_label: Label = $UI/InfoPanel/OwnerLabel

var requested_state := TileArtwork3D.GrowthState.GROWING
var player_index := 0
var capture_requested := false
var smoke_requested := false


func _ready() -> void:
	get_viewport().msaa_3d = Viewport.MSAA_4X
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--capture-state="):
			requested_state = _state_from_name(argument.trim_prefix("--capture-state="))
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
	DisplayServer.window_set_title("正式地块 · 北东沃土 / 南侧入水")
	if capture_requested:
		call_deferred("_capture_preview")
	elif smoke_requested:
		call_deferred("_run_study_smoke")


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
	_apply_visual_state()


func _set_camera() -> void:
	var elevation := deg_to_rad(56.0)
	var azimuth := deg_to_rad(37.0)
	var horizontal_distance := CAMERA_DISTANCE * cos(elevation)
	camera.position = Vector3(
		horizontal_distance * sin(azimuth),
		CAMERA_DISTANCE * sin(elevation),
		horizontal_distance * cos(azimuth),
	)
	camera.look_at(CAMERA_TARGET, Vector3.UP)


func _apply_visual_state() -> void:
	tile.set_growth_state(requested_state)
	for plant in _collect_sowable_plants(tile):
		plant.set_owner_color(PLAYER_COLORS[player_index])
	var state_name := "裸土" if requested_state == TileArtwork3D.GrowthState.BARE else "生长" if requested_state == TileArtwork3D.GrowthState.GROWING else "枯萎"
	state_label.text = "状态：%s" % state_name
	owner_label.text = "玩家归属徽记：P%d" % (player_index + 1)
	owner_label.add_theme_color_override("font_color", PLAYER_COLORS[player_index])


func _state_from_name(name: String) -> TileArtwork3D.GrowthState:
	match name.to_lower():
		"bare":
			return TileArtwork3D.GrowthState.BARE
		"wilted":
			return TileArtwork3D.GrowthState.WITHERED
		_:
			return TileArtwork3D.GrowthState.GROWING


func _capture_preview() -> void:
	for frame in range(5):
		await get_tree().process_frame
	await get_tree().create_timer(0.25).timeout
	var state_suffix := "bare" if requested_state == TileArtwork3D.GrowthState.BARE else "growing" if requested_state == TileArtwork3D.GrowthState.GROWING else "wilted"
	var output_path := ProjectSettings.globalize_path("res://artifacts/north_east_land_south_water_3d_%s_p%d.png" % [state_suffix, player_index + 1])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://artifacts"))
	var image := get_viewport().get_texture().get_image()
	if image == null:
		_fail("Cannot capture the canonical tile without a real display driver.")
		return
	var save_error := image.save_png(output_path)
	if save_error != OK:
		_fail("Failed to save canonical tile capture: %s" % error_string(save_error))
		return
	print("NORTH_EAST_LAND_SOUTH_WATER_CAPTURE: %s" % output_path)
	get_tree().quit()


func _run_study_smoke() -> void:
	await get_tree().process_frame
	if not tile.has_valid_authored_contract() or tile.topology == null or not tile.topology.is_canonical():
		_fail("Canonical north/east/south tile lost its static layer or topology contract.")
		return
	if tile.edge_markers != PackedInt32Array([1, 1, 2, 0]):
		_fail("Canonical tile ports must be LAND/LAND/WATER/EMPTY in north/east/south/west order.")
		return
	for quarter_turns in range(4):
		for edge in range(4):
			if tile.edge_marker_at(edge, quarter_turns) != tile.edge_markers[int(posmod(edge - quarter_turns, 4))]:
				_fail("Canonical tile no longer rotates its ports in 90-degree increments.")
				return
	if (
		tile.topology.double_land_topology != TileTopology3D.DoubleLandTopology.CENTER_CONNECTED
		or tile.topology.land_region_ids != PackedStringArray(["north_east_field"])
		or tile.topology.land_region_edge_masks != PackedInt32Array([3])
		or tile.topology.water_edges_ending_at_land != PackedInt32Array([TileTopology3D.Edge.SOUTH])
		or not tile.topology.water_edges_via_central_hub.is_empty()
	):
		_fail("Canonical tile topology does not explicitly encode one connected north/east field fed by the south inlet.")
		return

	var base := tile.get_node_or_null(^"Base") as MeshInstance3D
	var meadow := tile.get_node_or_null(^"Meadow") as MeshInstance3D
	var land := tile.get_node_or_null(^"LandSoil/NorthEastConnectedLand") as MeshInstance3D
	var bank := tile.get_node_or_null(^"Water/RiverBed") as MeshInstance3D
	var water := tile.get_node_or_null(^"Water/AnimatedSurface") as MeshInstance3D
	if base == null or meadow == null or land == null or bank == null or water == null:
		_fail("Canonical tile is missing a fixed terrain layer.")
		return
	if (
		base.mesh == null or base.mesh.material == null or base.mesh.material.resource_path != "res://art/materials/terrain/tile_base.tres"
		or meadow.mesh == null or meadow.mesh.material == null or meadow.mesh.material.resource_path != "res://art/materials/terrain/meadow.tres"
		or land.material_override == null or land.material_override.resource_path != "res://art/materials/terrain/fertile_soil.tres"
		or bank.material_override == null or bank.material_override.resource_path != "res://art/materials/terrain/river_bank.tres"
		or water.material_override == null or water.material_override.resource_path != "res://art/materials/water/north_east_land_south_water.tres"
	):
		_fail("Canonical tile no longer uses the designated shared terrain and baked water materials.")
		return
	var water_material := water.material_override as ShaderMaterial
	if water_material == null or not _has_default_water_parameters(water_material):
		_fail("Canonical water material no longer carries the project foam defaults.")
		return

	var land_vertices: PackedVector3Array = land.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for probe in [
		Vector2(-2.40, -2.45), Vector2(0.0, -2.45), Vector2(2.40, -2.45),
		Vector2(2.45, -2.40), Vector2(2.45, 0.0), Vector2(2.45, 2.40),
	]:
		if not _is_covered(land_vertices, probe):
			_fail("The north/east land mesh no longer covers a complete claimed LAND edge.")
			return
	for probe in [Vector2(-2.45, 0.0), Vector2(-2.45, 2.0), Vector2(-2.0, 2.45), Vector2(2.0, 2.45)]:
		if _is_covered(land_vertices, probe):
			_fail("The north/east field incorrectly occupies an EMPTY or WATER edge.")
			return
	if not _is_covered(land_vertices, Vector2(0.0, 0.57)):
		_fail("The south inlet no longer terminates at a visible north/east land contact.")
		return

	var water_vertices: PackedVector3Array = water.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if (
		not _is_covered(water_vertices, Vector2(0.0, 2.42))
		or not _is_covered(water_vertices, Vector2(0.0, 1.28))
		or not _is_covered(water_vertices, Vector2(0.0, 0.65))
		or _is_covered(water_vertices, Vector2(0.0, 0.57))
		or _is_covered(water_vertices, Vector2(0.60, 1.28))
	):
		_fail("South water must remain a narrow, straight centre inlet and stop at the field contact.")
		return
	var water_uv2: PackedVector2Array = water.mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV2]
	if water_uv2.size() != water_vertices.size() or not _has_baked_shoreline_coordinates(water_uv2):
		_fail("South water lost baked shoreline distance/arc coordinates for its unified foam phase.")
		return

	var layout := load(LAYOUT_PATH) as PlantScatterLayout3D
	if layout == null or not layout.is_valid() or not _has_expected_flower_herb_layout(layout) or not _layout_regenerates_exactly(layout):
		_fail("Canonical tile lost its valid two-species flower/herb baked layout.")
		return
	var growing_layer := tile.get_node_or_null(^"GrowingPlants") as Node3D
	var withered_layer := tile.get_node_or_null(^"WitheredPlants") as Node3D
	var growing_plants := _collect_sowable_plants(growing_layer)
	var withered_plants := _collect_sowable_plants(withered_layer)
	if growing_plants.size() != layout.placements.size() or withered_plants.size() != layout.placements.size():
		_fail("Growing and withered layers no longer contain the same fixed flower/herb set.")
		return
	for index in range(layout.placements.size()):
		var placement := layout.placements[index]
		var point := Vector2(placement.local_position.x, placement.local_position.z)
		if not layout.planting_mask.contains_point(point, placement.profile.extra_edge_clearance + placement.profile.footprint_radius):
			_fail("A formal-tile flower or herb escaped the authored LandSoil planting mask.")
			return
		for earlier_index in range(index):
			var earlier := layout.placements[earlier_index]
			var earlier_point := Vector2(earlier.local_position.x, earlier.local_position.z)
			var required := placement.profile.footprint_radius + earlier.profile.footprint_radius + maxf(placement.profile.minimum_gap, earlier.profile.minimum_gap)
			if point.distance_to(earlier_point) + 0.0001 < required:
				_fail("Formal-tile flower/herb layout violates variable-radius spacing.")
				return
		if (
			growing_plants[index].position.distance_to(placement.local_position) > 0.00001
			or withered_plants[index].position.distance_to(placement.local_position) > 0.00001
			or not growing_plants[index].is_authored_model_valid()
			or not withered_plants[index].is_authored_model_valid()
			or String(growing_plants[index].get_meta("planting_mask_id", "")) != String(layout.planting_mask.id)
		):
			_fail("A baked plant layer lost its fixed transform, state silhouette, or owner-marker contract.")
			return

	tile.set_growth_state(TileArtwork3D.GrowthState.BARE)
	if growing_layer.visible or withered_layer.visible:
		_fail("Bare soil still exposes a planted-plant layer.")
		return
	tile.set_growth_state(TileArtwork3D.GrowthState.GROWING)
	if not growing_layer.visible or withered_layer.visible:
		_fail("Growing state did not select the fixed growing flower/herb layer.")
		return
	tile.set_growth_state(TileArtwork3D.GrowthState.WITHERED)
	if growing_layer.visible or not withered_layer.visible:
		_fail("Withered state did not select the fixed wilted flower/herb layer.")
		return
	growing_plants[0].set_owner_color(PLAYER_COLORS[1])
	var owner_material := growing_plants[0].owner_marker.material_override as StandardMaterial3D
	if owner_material == null or not owner_material.albedo_color.is_equal_approx(PLAYER_COLORS[1]):
		_fail("Formal-tile ownership did not recolour only the plant's named marker material.")
		return

	requested_state = TileArtwork3D.GrowthState.GROWING
	player_index = 0
	_apply_visual_state()
	print("NORTH_EAST_LAND_SOUTH_WATER_STUDY_SMOKE_PASS: canonical LAND/LAND/WATER/EMPTY geometry, baked shoreline foam coordinates, and fixed flower/herb state layers are valid.")
	get_tree().quit()


func _has_default_water_parameters(material: ShaderMaterial) -> bool:
	var expected := {
		"foam_line_width": 0.06,
		"foam_wave_strength": 0.5,
		"foam_wave_frequency": 10.0,
		"foam_width": 0.09,
		"foam_scale": 10.7,
		"foam_radius": 0.58,
		"foam_cutoff": 0.6,
		"foam_speed": 0.025,
		"foam_shoreline_length": 4.62,
	}
	for parameter in expected:
		if not is_equal_approx(float(material.get_shader_parameter(parameter)), float(expected[parameter])):
			return false
	return true


func _has_baked_shoreline_coordinates(coordinates: PackedVector2Array) -> bool:
	var max_distance := 0.0
	var min_arc := INF
	var max_arc := -INF
	for coordinate in coordinates:
		if coordinate.x < -0.0001 or coordinate.y < -0.0001 or coordinate.y > 1.0001:
			return false
		max_distance = maxf(max_distance, coordinate.x)
		min_arc = minf(min_arc, coordinate.y)
		max_arc = maxf(max_arc, coordinate.y)
	return max_distance > 0.14 and max_arc - min_arc > 0.20


func _has_expected_flower_herb_layout(layout: PlantScatterLayout3D) -> bool:
	var counts: Dictionary = {}
	for placement in layout.placements:
		var profile_id := String(placement.profile.id)
		if profile_id != "north_east_field_flower" and profile_id != "north_east_field_herb":
			return false
		counts[profile_id] = int(counts.get(profile_id, 0)) + 1
	return int(counts.get("north_east_field_flower", 0)) == 8 and int(counts.get("north_east_field_herb", 0)) == 10


func _layout_regenerates_exactly(layout: PlantScatterLayout3D) -> bool:
	var source_profiles: Array[PlantScatterProfile3D] = []
	for placement in layout.placements:
		if not source_profiles.has(placement.profile):
			source_profiles.append(placement.profile)
	var regenerated := PlantScatterPlanner.generate(layout.id, layout.planting_mask, source_profiles, layout.seed)
	if regenerated.placements.size() != layout.placements.size():
		return false
	for index in range(layout.placements.size()):
		var baked := layout.placements[index]
		var regenerated_placement := regenerated.placements[index]
		if (
			baked.profile != regenerated_placement.profile
			or baked.local_position.distance_to(regenerated_placement.local_position) > 0.00001
			or not is_equal_approx(baked.yaw_degrees, regenerated_placement.yaw_degrees)
			or not is_equal_approx(baked.scale_multiplier, regenerated_placement.scale_multiplier)
			or not is_equal_approx(baked.reveal_threshold, regenerated_placement.reveal_threshold)
		):
			return false
	return true


func _collect_sowable_plants(node: Node) -> Array[SowablePlant3D]:
	var result: Array[SowablePlant3D] = []
	if node == null:
		return result
	for child in node.get_children():
		if child is SowablePlant3D:
			result.append(child as SowablePlant3D)
		result.append_array(_collect_sowable_plants(child))
	return result


func _is_covered(vertices: PackedVector3Array, probe: Vector2) -> bool:
	for triangle in range(0, vertices.size(), 3):
		var a := Vector2(vertices[triangle].x, vertices[triangle].z)
		var b := Vector2(vertices[triangle + 1].x, vertices[triangle + 1].z)
		var c := Vector2(vertices[triangle + 2].x, vertices[triangle + 2].z)
		if _point_in_triangle(probe, a, b, c):
			return true
	return false


func _point_in_triangle(point: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (point - b).cross(c - b)
	var d2 := (point - c).cross(a - c)
	var d3 := (point - a).cross(b - a)
	var has_negative := d1 < 0.0 or d2 < 0.0 or d3 < 0.0
	var has_positive := d1 > 0.0 or d2 > 0.0 or d3 > 0.0
	return not (has_negative and has_positive)


func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
