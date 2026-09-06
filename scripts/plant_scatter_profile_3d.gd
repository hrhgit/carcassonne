class_name PlantScatterProfile3D
extends Resource

# A profile describes one sowable species. It contains authored visual
# constraints; gameplay ownership, water, and score remain outside this asset.
@export var id: StringName
@export var display_name := ""
@export var plant_scene: PackedScene
@export_range(0, 160, 1) var desired_count := 1
@export_range(0.02, 6.0, 0.01) var footprint_radius := 0.18
@export_range(0.0, 4.0, 0.01) var minimum_gap := 0.10
@export_range(0.0, 4.0, 0.01) var extra_edge_clearance := 0.0
# The broad range deliberately matches the runtime tuning study. Each placed
# tile receives one stable seed-derived multiplier for every instance.
@export_range(0.05, 8.0, 0.01) var minimum_scale := 1.0
@export_range(0.05, 8.0, 0.01) var maximum_scale := 1.0
# Flowers can prefer a short distance from earlier flowers. The hard spacing
# check still prevents visual interpenetration.
@export_range(0.0, 1.0, 0.01) var cluster_chance := 0.0
@export_range(0.0, 8.0, 0.01) var cluster_radius := 0.0
@export_range(-100, 100, 1) var placement_priority := 0


func is_valid() -> bool:
	return (
		not id.is_empty()
		and plant_scene != null
		and desired_count > 0
		and footprint_radius > 0.0
		and maximum_scale >= minimum_scale
	)
