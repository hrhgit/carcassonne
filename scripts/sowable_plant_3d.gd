class_name SowablePlant3D
extends Node3D

enum GrowthState {
	GROWING,
	WILTED,
}

# Every species names one visible mesh surface as its owner-colour component.
# The selected component differs by silhouette: flower top petal, tree canopy,
# and the complete grass clump. The dry form is still its own neutral,
# sculpted state, so player colour never becomes the only state signal.
@export var species_id: StringName
@export var owner_color := Color(0.18, 0.52, 0.86, 1.0):
	set(value):
		owner_color = value
		_apply_owner_color()
@export var growth_state: GrowthState = GrowthState.GROWING:
	set(value):
		growth_state = value
		_apply_growth_state()
@export_category("Ownership Colour")
@export var owner_color_mesh_name: StringName
@export_range(0, 31, 1) var owner_color_surface_index := 0
@export_category("Withered State")
@export var withered_material: Material

@onready var growing_parts: Node3D = get_node_or_null("GrowingParts") as Node3D
@onready var withered_parts: Node3D = get_node_or_null("WitheredParts") as Node3D

var _owner_color_materials: Array[StandardMaterial3D] = []


func _ready() -> void:
	_cache_owner_color_materials()
	_apply_withered_material()
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
		and not owner_color_mesh_name.is_empty()
		and not _owner_color_materials.is_empty()
	)


func owner_color_is_applied(expected_color: Color) -> bool:
	for material in _owner_color_materials:
		if material.albedo_color.is_equal_approx(expected_color):
			return true
	return false


func _apply_owner_color() -> void:
	for material in _owner_color_materials:
		material.albedo_color = owner_color


func _cache_owner_color_materials() -> void:
	_owner_color_materials.clear()
	if growing_parts == null or owner_color_mesh_name.is_empty():
		return
	for child in growing_parts.find_children(String(owner_color_mesh_name), "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		if owner_color_surface_index >= mesh_instance.mesh.get_surface_count():
			push_error("Plant '%s' requested owner-colour surface %d on mesh '%s', but it does not exist." % [species_id, owner_color_surface_index, owner_color_mesh_name])
			continue
		var source_material := mesh_instance.get_surface_override_material(owner_color_surface_index)
		if source_material == null:
			source_material = mesh_instance.get_active_material(owner_color_surface_index)
		if not source_material is StandardMaterial3D:
			push_error("Plant '%s' owner-colour mesh '%s' must use StandardMaterial3D." % [species_id, owner_color_mesh_name])
			continue
		var local_material := (source_material as StandardMaterial3D).duplicate() as StandardMaterial3D
		mesh_instance.set_surface_override_material(owner_color_surface_index, local_material)
		_owner_color_materials.append(local_material)


func _apply_withered_material() -> void:
	if withered_parts == null or withered_material == null:
		return
	for child in withered_parts.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		for surface_index in range(mesh_instance.mesh.get_surface_count()):
			mesh_instance.set_surface_override_material(surface_index, withered_material)


func _apply_growth_state() -> void:
	if not is_inside_tree():
		return
	if growing_parts != null:
		growing_parts.visible = growth_state == GrowthState.GROWING
	if withered_parts != null:
		withered_parts.visible = growth_state == GrowthState.WILTED
