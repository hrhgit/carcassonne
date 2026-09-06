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
# 缺水视觉：把归属色轻微去饱和/变灰，传达"预估会因缺水死亡"。幅度很小，不遮蔽归属色。
@export var water_stressed := false:
	set(value):
		water_stressed = value
		_apply_owner_color()
# 灰化强度（0~1）：0 不灰化，1 完全灰。默认轻微，符合"变灰一点点"。
@export_range(0.0, 1.0, 0.01) var water_stress_gray_amount := 0.18
@export_category("Withered State")
@export var withered_material: Material
@export_category("Wind Sway")
# Plants share one global phase.  Their random placement yaw is deliberately
# excluded, otherwise a tile rotation would make adjacent plants sway in
# different apparent directions.
@export var wind_sway_enabled := false
@export_range(0.0, 2.0, 0.01) var wind_sway_strength := 1.0

@onready var growing_parts: Node3D = get_node_or_null("GrowingParts") as Node3D
@onready var withered_parts: Node3D = get_node_or_null("WitheredParts") as Node3D
@onready var vegetation_wind: Node = get_node_or_null("/root/VegetationWind")

var _owner_color_materials: Array[StandardMaterial3D] = []
var _rest_local_transform := Transform3D.IDENTITY
var _wind_transform_applied := false
var _spawn_tween: Tween
var _spawning := false


func _ready() -> void:
	_rest_local_transform = transform
	_cache_owner_color_materials()
	_apply_withered_material()
	_apply_owner_color()
	_apply_growth_state()


func _process(_delta: float) -> void:
	if _spawning:
		return
	if not wind_sway_enabled:
		_restore_rest_transform()
		return
	var parent_3d := get_parent() as Node3D
	var wind := vegetation_wind
	if parent_3d == null or wind == null:
		_restore_rest_transform()
		return
	# Rebuild the unbent transform from the parent every frame, then pre-multiply
	# a world-space bend.  This preserves a tile's placement animation and each
	# plant's authored/random yaw while the visible lean stays globally aligned.
	var rest_global := parent_3d.global_transform * _rest_local_transform
	var bend_basis: Basis = wind.call("get_current_bend_basis", wind_sway_strength)
	global_transform = Transform3D(bend_basis * rest_global.basis, rest_global.origin)
	_wind_transform_applied = true


func _restore_rest_transform() -> void:
	if not _wind_transform_applied:
		return
	transform = _rest_local_transform
	_wind_transform_applied = false


func set_growth_state(next_state: GrowthState) -> void:
	growth_state = next_state


func set_owner_color(next_owner_color: Color) -> void:
	owner_color = next_owner_color


func set_water_stressed(stressed: bool) -> void:
	water_stressed = stressed


# 种植/扩张时植物从地里"长出来"：缩放从近乎 0 弹性放大到目标尺寸。
# 动画期间暂停风摆，避免每帧用 rest transform 覆盖 tween 对 scale 的修改。
func play_spawn_grow() -> void:
	if _spawn_tween != null and _spawn_tween.is_valid():
		_spawn_tween.kill()
	var target_scale := _rest_local_transform.basis.get_scale()
	if target_scale.length_squared() <= 0.0:
		target_scale = Vector3.ONE
	scale = target_scale * 0.02
	_spawning = true
	_wind_transform_applied = false
	_spawn_tween = create_tween()
	_spawn_tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_spawn_tween.tween_property(self, "scale", target_scale, 0.35)
	_spawn_tween.tween_callback(func() -> void:
		_spawning = false
		_spawn_tween = null
	)


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
	# 缺水时把归属色往中灰轻微 lerp（去饱和 + 压暗一点点），幅度由 water_stress_gray_amount 控制。
	var applied := owner_color
	if water_stressed:
		var luminance := owner_color.get_luminance()
		var gray := Color(luminance, luminance, luminance, owner_color.a)
		applied = owner_color.lerp(gray, water_stress_gray_amount)
	for material in _owner_color_materials:
		material.albedo_color = applied


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
