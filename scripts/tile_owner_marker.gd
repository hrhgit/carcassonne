class_name TileOwnerMarker
extends Node2D

var marker_color := Color.TRANSPARENT


func set_marker_color(new_color: Color) -> void:
	marker_color = new_color
	queue_redraw()


func _draw() -> void:
	if marker_color.a <= 0.01:
		return
	draw_circle(Vector2(1.4, 2.0), 14.5, Color(0.02, 0.05, 0.035, 0.46))
	draw_circle(Vector2.ZERO, 12.2, marker_color)
	draw_arc(Vector2.ZERO, 12.2, 0.0, TAU, 20, Color("#f1f6d7"), 2.0, true)
