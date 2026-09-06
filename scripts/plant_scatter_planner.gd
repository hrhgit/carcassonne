class_name PlantScatterPlanner
extends RefCounted

# A deterministic, variable-radius Poisson-style sampler for authored soil.
# Large silhouettes are placed first; clustered species bias their candidates
# around prior siblings; every accepted point still observes the same mask,
# boundary safety, and pairwise footprint rules.
const CANDIDATES_PER_SAMPLE := 36
const RANDOM_POINT_ATTEMPTS := 20


static func generate(
	layout_id: StringName,
	planting_mask: PlantingMask3D,
	profiles: Array[PlantScatterProfile3D],
	seed: int,
	report_exhausted := true,
) -> PlantScatterLayout3D:
	var layout := PlantScatterLayout3D.new()
	layout.id = layout_id
	layout.planting_mask = planting_mask
	layout.seed = seed
	if planting_mask == null or not planting_mask.is_valid():
		push_error("Plant scatter requires a valid authored PlantingMask3D.")
		return layout

	var ordered_profiles := profiles.filter(func(profile): return profile != null and profile.is_valid())
	ordered_profiles.sort_custom(func(a, b): return a.placement_priority > b.placement_priority)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	for profile in ordered_profiles:
		for profile_index in range(profile.desired_count):
			var point := _choose_point(planting_mask, profile, layout.placements, rng)
			if point == Vector2.INF:
				if report_exhausted:
					push_warning("Plant scatter could not place %s instance %d inside mask %s." % [profile.id, profile_index + 1, planting_mask.id])
				continue
			var placement := PlantScatterPlacement3D.new()
			placement.profile = profile
			placement.local_position = Vector3(point.x, planting_mask.surface_height, point.y)
			placement.yaw_degrees = rng.randf_range(0.0, 360.0)
			placement.scale_multiplier = rng.randf_range(profile.minimum_scale, profile.maximum_scale)
			# This is stored once, so partial growth reveals a stable subset rather
			# than making plants teleport when the field grows or dries out.
			placement.reveal_threshold = clampf((float(profile_index) + rng.randf()) / float(profile.desired_count), 0.02, 0.98)
			layout.placements.append(placement)
	return layout


static func _choose_point(
	planting_mask: PlantingMask3D,
	profile: PlantScatterProfile3D,
	placements: Array[PlantScatterPlacement3D],
	rng: RandomNumberGenerator,
) -> Vector2:
	var best_point := Vector2.INF
	var best_score := -INF
	for candidate_index in range(CANDIDATES_PER_SAMPLE):
		var candidate := _random_candidate(planting_mask, profile, placements, rng)
		if candidate == Vector2.INF:
			continue
		var score := _candidate_score(candidate, planting_mask, profile, placements)
		if score > best_score:
			best_score = score
			best_point = candidate
	return best_point


static func _random_candidate(
	planting_mask: PlantingMask3D,
	profile: PlantScatterProfile3D,
	placements: Array[PlantScatterPlacement3D],
	rng: RandomNumberGenerator,
) -> Vector2:
	var same_species := _placements_for_profile(profile, placements)
	for attempt in range(RANDOM_POINT_ATTEMPTS):
		var candidate := Vector2.INF
		if (
			profile.cluster_radius > 0.0
			and not same_species.is_empty()
			and rng.randf() < profile.cluster_chance
		):
			var anchor := same_species[rng.randi_range(0, same_species.size() - 1)]
			var angle := rng.randf_range(0.0, TAU)
			var radius := rng.randf_range(_required_distance(profile, anchor.profile), profile.cluster_radius)
			candidate = Vector2(anchor.local_position.x, anchor.local_position.z) + Vector2(cos(angle), sin(angle)) * radius
		else:
			var bounds := planting_mask.get_bounds()
			candidate = Vector2(
				rng.randf_range(bounds.position.x, bounds.end.x),
				rng.randf_range(bounds.position.y, bounds.end.y),
			)
		if planting_mask.contains_point(candidate, profile.extra_edge_clearance + profile.footprint_radius):
			return candidate
	return Vector2.INF


static func _candidate_score(
	point: Vector2,
	planting_mask: PlantingMask3D,
	profile: PlantScatterProfile3D,
	placements: Array[PlantScatterPlacement3D],
) -> float:
	var nearest_normalized_distance := INF
	for placement in placements:
		var other_point := Vector2(placement.local_position.x, placement.local_position.z)
		var required_distance := _required_distance(profile, placement.profile)
		var distance := point.distance_to(other_point)
		if distance < required_distance:
			return -INF
		nearest_normalized_distance = minf(nearest_normalized_distance, distance / required_distance)
	var boundary_distance := planting_mask.distance_to_boundary(point) - planting_mask.edge_clearance
	var boundary_score := boundary_distance / maxf(profile.footprint_radius, 0.01)
	if is_inf(nearest_normalized_distance):
		nearest_normalized_distance = boundary_score
	return minf(nearest_normalized_distance, boundary_score)


static func _required_distance(first: PlantScatterProfile3D, second: PlantScatterProfile3D) -> float:
	return first.footprint_radius + second.footprint_radius + maxf(first.minimum_gap, second.minimum_gap)


static func _placements_for_profile(
	profile: PlantScatterProfile3D,
	placements: Array[PlantScatterPlacement3D],
) -> Array[PlantScatterPlacement3D]:
	var result: Array[PlantScatterPlacement3D] = []
	for placement in placements:
		if placement.profile == profile:
			result.append(placement)
	return result
