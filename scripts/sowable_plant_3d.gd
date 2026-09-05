class_name SowablePlant3D
extends Node3D

enum GrowthState {
	GROWING,
	WILTED,
}

# All three species expose the same small, explicitly named owner marker.
# Their stems, foliage, petals, and dry silhouettes remain species/state
# readable even when this one material is recoloured for another player.
@export var species_id: StringName
@export var owner_color := Color(0.18, 0.52, 0.86, 1.0):
	set(value):
		owner_color = value
		_apply_owner_color()
@export var growth_state: GrowthState = GrowthState.GROWING:
	set(value):
		growth_state = value
		_apply_growth_state()

@onready var growing_parts: Node3D = get_node_or_null("GrowingParts") as Node3D
@onready var withered_parts: Node3D = get_node_or_null("WitheredParts") as Node3D
@onready var owner_marker: MeshInstance3D = get_node_or_null("OwnerMarker") as MeshInstance3D

var _owner_marker_material: StandardMaterial3D


func _ready() -> void:
	if owner_marker != null and owner_marker.material_override is StandardMaterial3D:
		_owner_marker_material = (owner_marker.material_override as StandardMaterial3D).duplicate() as StandardMaterial3D
		owner_marker.material_override = _owner_marker_material
	_apply_owner_color()
	_apply_growth_state()


func set_growth_state(next_state: GrowthState) -> void:
	growth_state = next_state


func set_owner_color(next_owner_color: Color) -> void:
	owner_color = next_owner_color


func is_authored_model_valid() -> bool:
	return (
		not species_id.is_empty()
		and growing_parts != null
		and withered_parts != null
		and owner_marker != null
		and owner_marker.material_override is StandardMaterial3D
	)


func _apply_owner_color() -> void:
	if _owner_marker_material != null:
		_owner_marker_material.albedo_color = owner_color


func _apply_growth_state() -> void:
	if not is_inside_tree():
		return
	if growing_parts != null:
		growing_parts.visible = growth_state == GrowthState.GROWING
	if withered_parts != null:
		withered_parts.visible = growth_state == GrowthState.WILTED
