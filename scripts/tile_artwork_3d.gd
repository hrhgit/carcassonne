class_name TileArtwork3D
extends Node3D

const TileTopology3DResource := preload("res://scripts/tile_topology_3d.gd")

enum GrowthState {
	BARE,
	GROWING,
	WITHERED,
}

# Authored validation metadata. The rule catalog may inspect these ports, but
# it must never use them to construct or redraw this prefab at runtime.
@export var edge_markers := PackedInt32Array([0, 0, 0, 0])
@export var topology: TileTopology3DResource
@export var require_topology := false
# Keep this false for exploratory visual studies. A game-ready prefab must be
# promoted only after its baked geometry follows the canonical water-route rule.
@export var require_canonical_topology := false
@export var preview_growth_state: GrowthState = GrowthState.GROWING
# These masks are baked alongside the soil meshes. Runtime may instantiate
# plants inside them, but it never infers plantable land from material colour or
# redraws the terrain mesh.
@export var planting_masks: Array[PlantingMask3D] = []

@onready var growing_plants: Node3D = get_node_or_null("GrowingPlants")
@onready var withered_plants: Node3D = get_node_or_null("WitheredPlants")
@onready var runtime_plants: Node3D = get_node_or_null("RuntimePlants")

var _runtime_layout_active := false
var _runtime_species_states: Dictionary = {}
var _runtime_coverage := 1.0
var _suppress_spawn_animation := false


func _ready() -> void:
	_validate_authored_contract()
	set_growth_state(preview_growth_state)


func set_growth_state(state: GrowthState) -> void:
	preview_growth_state = state
	if _runtime_layout_active:
		_apply_runtime_state()
		return
	if growing_plants != null:
		growing_plants.visible = state == GrowthState.GROWING
	if withered_plants != null:
		withered_plants.visible = state == GrowthState.WITHERED


# `placements` are generated once from a stable tile seed.  They remain local
# to this prefab instance so a game restart can discard them cleanly without
# changing any authored scene or shared resource.
func set_runtime_plant_layout(placements: Array[PlantScatterPlacement3D]) -> void:
	var layer := _ensure_runtime_layer()
	for child in layer.get_children():
		child.free()
	_runtime_layout_active = true
	_runtime_species_states.clear()
	for placement_index in range(placements.size()):
		var placement := placements[placement_index]
		if placement == null or placement.profile == null or placement.profile.plant_scene == null:
			continue
		var plant := placement.profile.plant_scene.instantiate() as SowablePlant3D
		if plant == null:
			continue
		plant.name = "%s_%02d" % [placement.profile.id, placement_index + 1]
		plant.position = placement.local_position
		plant.rotation.y = deg_to_rad(placement.yaw_degrees)
		plant.scale = Vector3.ONE * placement.scale_multiplier
		plant.set_meta("reveal_threshold", placement.reveal_threshold)
		var planting_mask_id := _mask_id_for_position(placement.local_position)
		plant.set_meta("planting_mask_id", planting_mask_id)
		plant.set_meta("land_subnet_idx", land_subnet_index_for_mask_id(planting_mask_id))
		plant.set_meta("game_species", _game_species_for_profile(placement.profile.id))
		plant.set_meta("_was_visible", false)
		layer.add_child(plant)
	# 布局刚生成时的这一次状态应用是"视觉预览初始化"，紧接着会被 BARE 隐藏，
	# 不应触发出生缩放动画；真正的种植/扩张由后续 set_runtime_plant_states 驱动。
	_suppress_spawn_animation = true
	_apply_runtime_state()
	_suppress_spawn_animation = false


# Runtime state is keyed by "<land_subnet_idx>:<species>".  Keeping the LAND
# subnet in the key is required for split tiles: a grass planted on one
# disconnected lobe must not make grass appear on another lobe of the same
# prefab.  Legacy species-only entries remain supported for visual studies.
# An empty dictionary intentionally acts as a visual-study preview and shows
# every generated species for the selected global state.
func set_runtime_plant_states(states: Dictionary) -> void:
	_runtime_species_states = states.duplicate(true)
	if _runtime_layout_active:
		_apply_runtime_state()


func set_runtime_coverage(coverage: float) -> void:
	_runtime_coverage = clampf(coverage, 0.0, 1.0)
	if _runtime_layout_active:
		_apply_runtime_state()


func get_runtime_plants() -> Array[SowablePlant3D]:
	var result: Array[SowablePlant3D] = []
	if runtime_plants == null:
		return result
	for child in runtime_plants.get_children():
		if child is SowablePlant3D:
			result.append(child as SowablePlant3D)
	return result


func get_runtime_plant_count() -> int:
	return get_runtime_plants().size()


func has_runtime_plant_layout() -> bool:
	return _runtime_layout_active


func land_subnet_index_for_mask(mask: PlantingMask3D) -> int:
	if mask == null:
		return -1
	return land_subnet_index_for_mask_id(mask.id)


func land_subnet_index_for_mask_id(mask_id: StringName) -> int:
	if mask_id.is_empty():
		return -1
	if topology != null:
		var region_ids: PackedStringArray = topology.land_region_ids
		var mask_id_text := String(mask_id)
		for region_index in range(region_ids.size()):
			if mask_id_text.contains("_%s_" % String(region_ids[region_index])):
				return region_index
		if region_ids.size() == 1:
			return 0
	return 0 if planting_masks.size() == 1 else -1


func edge_marker_at(world_edge: int, quarter_turns := 0) -> int:
	if edge_markers.size() != 4:
		return -1
	return edge_markers[int(posmod(world_edge - quarter_turns, 4))]


func has_valid_authored_contract() -> bool:
	for node_path in [
		NodePath("Base"),
		NodePath("Meadow"),
		NodePath("LandSoil"),
		NodePath("Water/RiverBed"),
		NodePath("Water/AnimatedSurface"),
		NodePath("Decorations"),
		NodePath("GrowingPlants"),
		NodePath("WitheredPlants"),
	]:
		if get_node_or_null(node_path) == null:
			return false
	if topology == null:
		return not require_topology
	if not topology.matches_edge_markers(edge_markers):
		return false
	return not require_canonical_topology or topology.is_canonical()


func _validate_authored_contract() -> void:
	if not has_valid_authored_contract():
		push_error("3D tile prefab '%s' violates its static layer or topology contract." % name)


func _ensure_runtime_layer() -> Node3D:
	if runtime_plants != null:
		return runtime_plants
	var existing := get_node_or_null("RuntimePlants") as Node3D
	if existing != null:
		runtime_plants = existing
		return runtime_plants
	runtime_plants = Node3D.new()
	runtime_plants.name = "RuntimePlants"
	add_child(runtime_plants)
	return runtime_plants


static func _runtime_state_key(subnet_idx: int, species: int) -> String:
	return "%d:%d" % [subnet_idx, species]


func _runtime_state_for(species: int, subnet_idx: int) -> Dictionary:
	var scoped_state = _runtime_species_states.get(_runtime_state_key(subnet_idx, species), null)
	if scoped_state is Dictionary:
		return scoped_state as Dictionary
	# Keep old visual-study callers working, but let a legacy entry opt into a
	# specific lobe while projects migrate to the explicit composite key.
	var legacy_state = _runtime_species_states.get(species, null)
	if legacy_state is Dictionary:
		var legacy := legacy_state as Dictionary
		if legacy.has("subnet_idx") and int(legacy["subnet_idx"]) != subnet_idx:
			return {}
		return legacy
	return {}


func _apply_runtime_state() -> void:
	if growing_plants != null:
		growing_plants.visible = false
	if withered_plants != null:
		withered_plants.visible = false
	if runtime_plants == null:
		return
	runtime_plants.visible = preview_growth_state != GrowthState.BARE
	for plant in get_runtime_plants():
		var species := int(plant.get_meta("game_species", -1))
		var subnet_idx := int(plant.get_meta("land_subnet_idx", -1))
		var entry := _runtime_state_for(species, subnet_idx)
		var has_state := not entry.is_empty()
		var desired_state := preview_growth_state
		var owner_color := plant.owner_color
		var water_stressed := false
		if has_state:
			desired_state = int(entry.get("growth_state", GrowthState.GROWING))
			owner_color = entry.get("owner_color", owner_color)
			water_stressed = bool(entry.get("water_stressed", false))
		var should_show := preview_growth_state != GrowthState.BARE
		if not _runtime_species_states.is_empty() and not has_state:
			should_show = false
		should_show = should_show and float(plant.get_meta("reveal_threshold", 1.0)) <= _runtime_coverage
		plant.set_owner_color(owner_color)
		plant.set_water_stressed(water_stressed)
		plant.set_growth_state(
			SowablePlant3D.GrowthState.WILTED if desired_state == GrowthState.WITHERED else SowablePlant3D.GrowthState.GROWING
		)
		var was_visible := bool(plant.get_meta("_was_visible", false))
		plant.set_meta("_was_visible", should_show)
		plant.visible = should_show
		if should_show and not was_visible and not _suppress_spawn_animation:
			plant.play_spawn_grow()


func _mask_id_for_position(position: Vector3) -> StringName:
	var point := Vector2(position.x, position.z)
	for mask in planting_masks:
		if mask != null and mask.contains_surface_point(point):
			return mask.id
	return &""


static func _game_species_for_profile(profile_id: StringName) -> int:
	match profile_id:
		&"soil_herb":
			return 0
		&"soil_flower":
			return 1
		&"soil_sapling":
			return 2
		_:
			return -1
