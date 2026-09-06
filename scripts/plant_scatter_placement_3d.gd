class_name PlantScatterPlacement3D
extends Resource

# One deterministic scatter record. It can be persisted for an audit study or
# held in a RuntimePlants layer; in both cases the stable seed prevents layout
# changes during gameplay state refreshes.
@export var profile: PlantScatterProfile3D
@export var local_position := Vector3.ZERO
@export var yaw_degrees := 0.0
@export var scale_multiplier := 1.0
@export_range(0.0, 1.0, 0.001) var reveal_threshold := 1.0
