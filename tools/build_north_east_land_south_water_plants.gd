extends SceneTree

# Editor/build-time only.  This tile deliberately uses the generic two-profile
# sampler (flowers + herbs) and then serializes its result into two fixed layers.
const MASK_PATH := "res://art/planting_masks/north_east_land_south_water_field.tres"
const HERB_PROFILE_PATH := "res://art/plant_profiles/north_east_land_south_water_herb.tres"
const FLOWER_PROFILE_PATH := "res://art/plant_profiles/north_east_land_south_water_flower.tres"
const LAYOUT_OUTPUT_PATH := "res://art/generated/north_east_land_south_water_flower_herb_layout.tres"
const GROWING_OUTPUT_PATH := "res://scenes/plants/generated/north_east_land_south_water_flower_herb_growing.tscn"
const WITHERED_OUTPUT_PATH := "res://scenes/plants/generated/north_east_land_south_water_flower_herb_withered.tscn"
const DEFAULT_OWNER_COLOR := Color(0.18, 0.52, 0.86, 1.0)
const LAYOUT_SEED := 420_317


func _init() -> void:
	call_deferred("_build")


func _build() -> void:
	var planting_mask := load(MASK_PATH) as PlantingMask3D
	var flower := load(FLOWER_PROFILE_PATH) as PlantScatterProfile3D
	var herb := load(HERB_PROFILE_PATH) as PlantScatterProfile3D
	var profiles: Array[PlantScatterProfile3D] = [flower, herb]
	if planting_mask == null or profiles.any(func(profile): return profile == null or not profile.is_valid()):
		_fail("North/east canonical tile needs a valid field mask and flower/herb profiles.")
		return

	var layout := PlantScatterPlanner.generate(&"north_east_land_south_water_flower_herb", planting_mask, profiles, LAYOUT_SEED)
	if not layout.is_valid() or not _has_requested_counts_and_spacing(layout, profiles):
		_fail("The fixed flower/herb layout does not satisfy its soil mask, requested counts, or spacing.")
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://art/generated"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://scenes/plants/generated"))
	var layout_error := ResourceSaver.save(layout, LAYOUT_OUTPUT_PATH)
	if layout_error != OK:
		_fail("Could not save fixed north/east flower/herb layout: %s" % error_string(layout_error))
		return
	var saved_layout := load(LAYOUT_OUTPUT_PATH) as PlantScatterLayout3D
	if saved_layout == null or not saved_layout.is_valid():
		_fail("Saved flower/herb layout could not be reloaded as valid baked data.")
		return

	if not _save_layer(saved_layout, GROWING_OUTPUT_PATH, "NorthEastFlowerHerbGrowing", SowablePlant3D.GrowthState.GROWING):
		return
	if not _save_layer(saved_layout, WITHERED_OUTPUT_PATH, "NorthEastFlowerHerbWithered", SowablePlant3D.GrowthState.WILTED):
		return
	print("NORTH_EAST_LAND_SOUTH_WATER_PLANTS_BUILT: %d flower/herb placements -> fixed growing + withered layers" % saved_layout.placements.size())
	quit()


func _save_layer(layout: PlantScatterLayout3D, output_path: String, layer_name: String, state: SowablePlant3D.GrowthState) -> bool:
	var layer := Node3D.new()
	layer.name = layer_name
	for index in range(layout.placements.size()):
		var placement := layout.placements[index]
		var plant := placement.profile.plant_scene.instantiate() as SowablePlant3D
		if plant == null:
			layer.free()
			_fail("Could not instance authored plant profile %s." % placement.profile.id)
			return false
		plant.name = "%s_%02d" % [placement.profile.id, index + 1]
		plant.position = placement.local_position
		plant.rotation.y = deg_to_rad(placement.yaw_degrees)
		plant.scale = Vector3.ONE * placement.scale_multiplier
		plant.owner_color = DEFAULT_OWNER_COLOR
		plant.growth_state = state
		plant.set_meta("reveal_threshold", placement.reveal_threshold)
		plant.set_meta("planting_mask_id", String(layout.planting_mask.id))
		plant.set_meta("scatter_profile_id", String(placement.profile.id))
		layer.add_child(plant)
		plant.owner = layer

	var packed_scene := PackedScene.new()
	var pack_error := packed_scene.pack(layer)
	if pack_error != OK:
		layer.free()
		_fail("Could not pack %s: %s" % [layer_name, error_string(pack_error)])
		return false
	var save_error := ResourceSaver.save(packed_scene, output_path)
	layer.free()
	if save_error != OK:
		_fail("Could not save %s: %s" % [output_path, error_string(save_error)])
		return false
	return true


func _has_requested_counts_and_spacing(layout: PlantScatterLayout3D, profiles: Array[PlantScatterProfile3D]) -> bool:
	var counts: Dictionary = {}
	for first_index in range(layout.placements.size()):
		var placement := layout.placements[first_index]
		counts[placement.profile.id] = int(counts.get(placement.profile.id, 0)) + 1
		var point := Vector2(placement.local_position.x, placement.local_position.z)
		if not layout.planting_mask.contains_point(point, placement.profile.extra_edge_clearance + placement.profile.footprint_radius):
			return false
		for second_index in range(first_index):
			var earlier := layout.placements[second_index]
			var earlier_point := Vector2(earlier.local_position.x, earlier.local_position.z)
			var required := placement.profile.footprint_radius + earlier.profile.footprint_radius + maxf(placement.profile.minimum_gap, earlier.profile.minimum_gap)
			if point.distance_to(earlier_point) + 0.0001 < required:
				return false
	for profile in profiles:
		if int(counts.get(profile.id, 0)) != profile.desired_count:
			return false
	return true


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
