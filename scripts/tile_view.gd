class_name TileView
extends Node2D

const DESIGN_SIZE := 240.0
const OWNER_MARKER_SCRIPT := preload("res://scripts/tile_owner_marker.gd")

var artwork: Node2D
var owner_marker


func show_tile(
	definition: TileDefinition,
	quarter_turns: int,
	target_size: float,
	owner_color := Color.TRANSPARENT,
) -> void:
	if artwork != null:
		artwork.queue_free()
		artwork = null

	if definition == null or definition.visual_scene == null:
		push_error("A placed tile needs a fixed visual prefab.")
		return

	artwork = definition.visual_scene.instantiate()
	artwork.z_index = 0
	add_child(artwork)
	# The only transformation applied to authored artwork is its tile rotation.
	artwork.rotation = float(definition.visual_rotation_quarters + quarter_turns) * PI * 0.5
	scale = Vector2.ONE * (target_size / DESIGN_SIZE)

	if owner_marker == null:
		owner_marker = OWNER_MARKER_SCRIPT.new()
		owner_marker.z_index = 1
		owner_marker.position = Vector2(-88.0, -88.0)
		add_child(owner_marker)
	owner_marker.set_marker_color(owner_color)
