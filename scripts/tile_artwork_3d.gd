class_name TileArtwork3D
extends Node3D

enum GrowthState {
	BARE,
	GROWING,
	WITHERED,
}

# Authored validation metadata. The rule catalog may inspect these ports, but
# it must never use them to construct or redraw this prefab at runtime.
@export var edge_markers := PackedInt32Array([0, 0, 0, 0])
@export var preview_growth_state: GrowthState = GrowthState.GROWING

@onready var growing_plants: Node3D = get_node_or_null("GrowingPlants")
@onready var withered_plants: Node3D = get_node_or_null("WitheredPlants")


func _ready() -> void:
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
