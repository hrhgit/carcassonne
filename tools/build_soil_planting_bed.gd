extends SceneTree

# Editor/build-time only. It turns a seeded PlantingMask layout into a fixed
# scene; no gameplay scene calls this generator or randomly instantiates plant
# geometry while a player is placing tiles.
const MASK_PATH := "res://art/planting_masks/soil_planting_study.tres"
const HERB_PROFILE_PATH := "res://art/plant_profiles/soil_herb.tres"
const FLOWER_PROFILE_PATH := "res://art/plant_profiles/soil_flower.tres"
const SAPLING_PROFILE_PATH := "res://art/plant_profiles/soil_sapling.tres"
const LAYOUT_OUTPUT_PATH := "res://art/generated/soil_planting_study_layout.tres"
const BED_OUTPUT_PATH := "res://scenes/plants/generated/soil_planting_study_bed.tscn"
const BED_SCRIPT := preload("res://scripts/soil_planting_bed_3d.gd")
const DEFAULT_OWNER_COLOR := Color(0.18, 0.52, 0.86, 1.0)
const LAYOUT_SEED := 613_907


func _init() -> void:
	call_deferred("_build")


func _build() -> void:
	var planting_mask := load(MASK_PATH) as PlantingMask3D
	var herb := load(HERB_PROFILE_PATH) as PlantScatterProfile3D
	var flower := load(FLOWER_PROFILE_PATH) as PlantScatterProfile3D
	var sapling := load(SAPLING_PROFILE_PATH) as PlantScatterProfile3D
	var profiles: Array[PlantScatterProfile3D] = [sapling, flower, herb]
	if planting_mask == null or profiles.any(func(profile): return profile == null or not profile.is_valid()):
		push_error("Soil plant-bed builder could not load a valid mask and all three species profiles.")
		quit(1)
		return

	var layout := PlantScatterPlanner.generate(&"soil_planting_study_layout", planting_mask, profiles, LAYOUT_SEED)
	if not layout.is_valid():
		push_error("The generated planting layout violates its mask or profile constraints.")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://art/generated"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://scenes/plants/generated"))
	var layout_error := ResourceSaver.save(layout, LAYOUT_OUTPUT_PATH)
	if layout_error != OK:
		push_error("Could not save planting layout: %s" % error_string(layout_error))
		quit(1)
		return
	var persisted_layout := load(LAYOUT_OUTPUT_PATH) as PlantScatterLayout3D
	if persisted_layout == null or not persisted_layout.is_valid():
		push_error("The saved planting layout could not be reloaded as valid baked data.")
		quit(1)
		return

	var bed := SoilPlantingBed3D.new()
	bed.name = "SoilPlantingStudyBed"
	bed.layout = persisted_layout
	bed.owner_color = DEFAULT_OWNER_COLOR
	bed.growth_state = SoilPlantingBed3D.GrowthState.GROWING
	bed.coverage = 1.0
	var growing_layer := Node3D.new()
	growing_layer.name = "GrowingPlants"
	bed.add_child(growing_layer)
	growing_layer.owner = bed
	var withered_layer := Node3D.new()
	withered_layer.name = "WitheredPlants"
	bed.add_child(withered_layer)
	withered_layer.owner = bed

	for index in range(persisted_layout.placements.size()):
		var placement := persisted_layout.placements[index]
		_add_baked_plant(growing_layer, placement, index, SowablePlant3D.GrowthState.GROWING, String(persisted_layout.planting_mask.id))
		_add_baked_plant(withered_layer, placement, index, SowablePlant3D.GrowthState.WILTED, String(persisted_layout.planting_mask.id))

	var packed_scene := PackedScene.new()
	var pack_error := packed_scene.pack(bed)
	if pack_error != OK:
		push_error("Could not pack baked soil plant bed: %s" % error_string(pack_error))
		quit(1)
		return
	var scene_error := ResourceSaver.save(packed_scene, BED_OUTPUT_PATH)
	if scene_error != OK:
		push_error("Could not save baked soil plant bed: %s" % error_string(scene_error))
		quit(1)
		return

	bed.free()
	print("SOIL_PLANTING_BED_BUILT: %d fixed placements -> %s" % [persisted_layout.placements.size(), BED_OUTPUT_PATH])
	quit()


func _add_baked_plant(
	parent: Node3D,
	placement: PlantScatterPlacement3D,
	index: int,
	state: SowablePlant3D.GrowthState,
	mask_id: String,
) -> void:
	var plant := placement.profile.plant_scene.instantiate() as SowablePlant3D
	plant.name = "%s_%02d" % [placement.profile.id, index + 1]
	plant.position = placement.local_position
	plant.rotation.y = deg_to_rad(placement.yaw_degrees)
	plant.scale = Vector3.ONE * placement.scale_multiplier
	plant.owner_color = DEFAULT_OWNER_COLOR
	plant.growth_state = state
	plant.set_meta("reveal_threshold", placement.reveal_threshold)
	plant.set_meta("planting_mask_id", mask_id)
	parent.add_child(plant)
	plant.owner = parent.owner
