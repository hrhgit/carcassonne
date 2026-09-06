class_name VegetationWind3D
extends Node

## One shared presentation-only wind signal for sowable vegetation.  The
## direction lives in world space so rotating a tile or a plant instance never
## turns its apparent wind direction away from the other plants.
@export_category("Shared Wind")
@export var world_direction := Vector3(0.82, 0.0, -0.58)
@export_range(0.05, 3.0, 0.01, "suffix: Hz") var sway_frequency_hz := 0.333
@export_range(0.0, 18.0, 0.1, "suffix: degrees") var maximum_angle_degrees := 6.0

var _elapsed_seconds := 0.0


func _process(delta: float) -> void:
	_elapsed_seconds += maxf(delta, 0.0)


func get_world_direction() -> Vector3:
	var horizontal := Vector3(world_direction.x, 0.0, world_direction.z)
	return horizontal.normalized() if horizontal.length_squared() > 0.000001 else Vector3.FORWARD


func get_current_bend_basis(strength := 1.0) -> Basis:
	var axis := Vector3.UP.cross(get_world_direction())
	if axis.length_squared() <= 0.000001:
		return Basis.IDENTITY
	var phase := _elapsed_seconds * TAU * sway_frequency_hz
	var angle := sin(phase) * deg_to_rad(maximum_angle_degrees) * maxf(strength, 0.0)
	return Basis(axis.normalized(), angle)


# Kept public for deterministic visual studies and smoke tests.  Gameplay does
# not set an individual plant phase: every enabled plant samples this one clock.
func set_phase_seconds(seconds: float) -> void:
	_elapsed_seconds = maxf(seconds, 0.0)
