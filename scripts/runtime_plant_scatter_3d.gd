class_name RuntimePlantScatter3D
extends RefCounted

# Runtime scattering owns only the plant instances. Terrain, water meshes,
# topology and shoreline UV2 data remain frozen in the generated prefab.
# A tile seed includes its board cell, so adjacent copies of the same card are
# varied while reloading the same board state is completely reproducible.
const HERB_PROFILE := preload("res://art/plant_profiles/soil_herb.tres")
const FLOWER_PROFILE := preload("res://art/plant_profiles/soil_flower.tres")
const SAPLING_PROFILE := preload("res://art/plant_profiles/soil_sapling.tres")
const TILE_AREA := 4.9 * 4.9


static func default_profiles() -> Array[PlantScatterProfile3D]:
	return [HERB_PROFILE, FLOWER_PROFILE, SAPLING_PROFILE]


static func seed_for_tile(definition_seed: int, cell: Vector2i) -> int:
	return _mix_seed(definition_seed, cell.x * 73_856_093 + cell.y * 19_349_663)


static func generate_for_tile(tile: TileArtwork3D, tile_seed: int) -> Array[PlantScatterPlacement3D]:
	return generate_for_masks(
		StringName(tile.name),
		tile.planting_masks,
		default_profiles(),
		tile_seed,
		TILE_AREA,
	)


# `density_reference_area` is zero for a standalone study mask, where the
# profile count is literal. Game tiles pass the full tile area, so a narrow
# LAND lobe receives a proportionate, still deterministic subset.
static func generate_for_masks(
	layout_prefix: StringName,
	masks: Array[PlantingMask3D],
	source_profiles: Array[PlantScatterProfile3D],
	seed: int,
	density_reference_area := 0.0,
) -> Array[PlantScatterPlacement3D]:
	var result: Array[PlantScatterPlacement3D] = []
	for mask_index in range(masks.size()):
		var mask := masks[mask_index]
		if mask == null or not mask.is_valid():
			push_warning("Runtime plant scatter skipped an invalid LAND mask on %s." % layout_prefix)
			continue
		var profiles := _profiles_for_mask(source_profiles, mask, density_reference_area)
		if profiles.is_empty():
			continue
		var layout := PlantScatterPlanner.generate(
			StringName("%s_%02d" % [layout_prefix, mask_index + 1]),
			mask,
			profiles,
			_mix_seed(seed, mask_index + 1),
			false,
		)
		for placement in layout.placements:
			result.append(placement)
	return result


static func _profiles_for_mask(
	source_profiles: Array[PlantScatterProfile3D],
	mask: PlantingMask3D,
	density_reference_area: float,
) -> Array[PlantScatterProfile3D]:
	var result: Array[PlantScatterProfile3D] = []
	var area_factor := 1.0
	if density_reference_area > 0.0:
		area_factor = clampf(_polygon_area(mask.boundary) / density_reference_area, 0.0, 1.0)
	for source in source_profiles:
		if source == null or not source.is_valid():
			continue
		var profile := source.duplicate(true) as PlantScatterProfile3D
		if density_reference_area > 0.0:
			var scaled_count := float(source.desired_count) * area_factor
			# Trees cap at one per LAND lobe. Trying one even on a narrow lobe
			# preserves a tree layout whenever its authored safety envelope fits;
			# grass and flowers keep their denser area-scaled targets.
			profile.desired_count = 1 if source.id == &"soil_sapling" else int(round(scaled_count))
		if profile.desired_count > 0:
			result.append(profile)
	return result


static func _polygon_area(polygon: PackedVector2Array) -> float:
	var doubled_area := 0.0
	for index in range(polygon.size()):
		var point := polygon[index]
		var next_point := polygon[(index + 1) % polygon.size()]
		doubled_area += point.x * next_point.y - next_point.x * point.y
	return absf(doubled_area) * 0.5


static func _mix_seed(seed: int, salt: int) -> int:
	var mixed := int(seed) * 1_103_515_245 + int(salt) * 2_654_435_761 + 12_345
	mixed = mixed ^ (mixed >> 16)
	mixed = mixed * 22_695_477 + 1
	return abs(mixed)
