class_name SoilPlantingBed3D
extends Node3D

enum GrowthState {
	BARE,
	GROWING,
	WILTED,
}

@export var layout: PlantScatterLayout3D
@export var owner_color := Color(0.18, 0.52, 0.86, 1.0):
	set(value):
		owner_color = value
		_apply_state()
@export var growth_state: GrowthState = GrowthState.GROWING:
	set(value):
		growth_state = value
		_apply_state()
@export_range(0.0, 1.0, 0.01) var coverage := 1.0:
	set(value):
		coverage = value
		_apply_state()

@onready var growing_plants: Node3D = get_node_or_null("GrowingPlants") as Node3D
@onready var withered_plants: Node3D = get_node_or_null("WitheredPlants") as Node3D


func _ready() -> void:
	_apply_state()


func set_growth_state(next_state: GrowthState) -> void:
	growth_state = next_state


func set_owner_color(next_owner_color: Color) -> void:
	owner_color = next_owner_color


func set_coverage(next_coverage: float) -> void:
	coverage = clampf(next_coverage, 0.0, 1.0)


func get_baked_plants() -> Array[SowablePlant3D]:
	var result: Array[SowablePlant3D] = []
	for layer in [growing_plants, withered_plants]:
		if layer == null:
			continue
		for child in layer.get_children():
			if child is SowablePlant3D:
				result.append(child)
	return result


func _apply_state() -> void:
	if not is_inside_tree():
		return
	_apply_layer(growing_plants, SowablePlant3D.GrowthState.GROWING, growth_state == GrowthState.GROWING)
	_apply_layer(withered_plants, SowablePlant3D.GrowthState.WILTED, growth_state == GrowthState.WILTED)


func _apply_layer(layer: Node3D, plant_state: SowablePlant3D.GrowthState, should_show: bool) -> void:
	if layer == null:
		return
	layer.visible = should_show
	for child in layer.get_children():
		if not child is SowablePlant3D:
			continue
		var plant := child as SowablePlant3D
		plant.set_owner_color(owner_color)
		plant.set_growth_state(plant_state)
		plant.visible = should_show and float(plant.get_meta("reveal_threshold", 1.0)) <= coverage
