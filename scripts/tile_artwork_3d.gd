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

@onready var growing_plants: Node3D = get_node_or_null("GrowingPlants")
@onready var withered_plants: Node3D = get_node_or_null("WitheredPlants")


func _ready() -> void:
	_validate_authored_contract()
	set_growth_state(preview_growth_state)


func set_growth_state(state: GrowthState) -> void:
	preview_growth_state = state
	if growing_plants != null:
		growing_plants.visible = state == GrowthState.GROWING
	if withered_plants != null:
		withered_plants.visible = state == GrowthState.WITHERED


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
