class_name PlantScatterPlacement3D
extends Resource

# Saved output of the editor-time scatter pass. Keeping the seed result as
# data makes every final GrowingPlants/WitheredPlants layer inspectable and
# prevents visual layout from changing during gameplay.
@export var profile: PlantScatterProfile3D
@export var local_position := Vector3.ZERO
@export var yaw_degrees := 0.0
@export var scale_multiplier := 1.0
@export_range(0.0, 1.0, 0.001) var reveal_threshold := 1.0
