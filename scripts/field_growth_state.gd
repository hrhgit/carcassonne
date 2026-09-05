class_name FieldGrowthState
extends Node2D

# This component never creates crop geometry at runtime. Its authored child
# layers are switched as one field changes state, so a tile prefab stays
# independently editable from its placement rules.
enum GrowthState {
	BARE,
	GROWING,
	WILTED,
}

@export var field_id: StringName
@export var growth_state: GrowthState = GrowthState.BARE:
	set(value):
		growth_state = value
		_apply_growth_state()


func _ready() -> void:
	_apply_growth_state()


func sow() -> void:
	if growth_state == GrowthState.BARE:
		growth_state = GrowthState.GROWING


func wilt() -> void:
	growth_state = GrowthState.WILTED


func restore_bare_soil() -> void:
	growth_state = GrowthState.BARE


func set_growth_state(next_state: GrowthState) -> void:
	growth_state = next_state


func _apply_growth_state() -> void:
	if not is_inside_tree():
		return
	_set_layer_visible(^"BareDetails", growth_state == GrowthState.BARE)
	_set_layer_visible(^"GrowingDetails", growth_state == GrowthState.GROWING)
	_set_layer_visible(^"WiltedDetails", growth_state == GrowthState.WILTED)


func _set_layer_visible(layer_path: NodePath, should_be_visible: bool) -> void:
	var layer := get_node_or_null(layer_path) as CanvasItem
	if layer != null:
		layer.visible = should_be_visible
