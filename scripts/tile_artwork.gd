class_name TileArtwork
extends Node2D

# The root of every editable tile prefab. It owns only the shared wooden frame
# and meadow material. Edge-specific soil and water shapes live as child nodes
# in each .tscn, so their artwork is fixed before a game ever starts.
const OUTER_RECT := Rect2(-120.0, -120.0, 240.0, 240.0)
const INNER_RECT := Rect2(-106.0, -106.0, 212.0, 212.0)

# This is authored metadata, not rendering input. It lets the catalog reject a
# prefab if somebody edits its ports but forgets to update the matching rule card.
@export var edge_markers := PackedInt32Array([0, 0, 0, 0])


func _draw() -> void:
	# Soft drop shadow (drawn first so the frame sits on top of it).
	draw_style_box(
		_rounded_box(Color(0.0, 0.02, 0.015, 0.30), Color(0, 0, 0, 0), 0, 28),
		OUTER_RECT.grow(2.0),
	)

	# Thin dark wood rim.
	draw_style_box(_rounded_box(Color("#9a6c3f"), Color("#5a3618"), 2, 26), OUTER_RECT)
	# Warm wood body.
	draw_style_box(_rounded_box(Color("#e2ad6a"), Color("#7a4a26"), 1, 22), OUTER_RECT.grow(4.5))
	# Inner shadow ring (gives the frame depth without harshness).
	draw_style_box(_rounded_box(Color(0, 0, 0, 0), Color(0.22, 0.12, 0.05, 0.55), 1, 18), INNER_RECT.grow(1.0))
	# Meadow green fill.
	draw_style_box(_rounded_box(Color("#9bc864"), Color("#3f6c2f"), 2, 15), INNER_RECT)

	# A gentle sun highlight on the upper half of the meadow.
	draw_rect(Rect2(-104.0, -104.0, 208.0, 90.0), Color(1.0, 1.0, 0.94, 0.07))
	# A subtle shading on the lower half to fake depth.
	draw_rect(Rect2(-104.0, 14.0, 208.0, 90.0), Color(0.06, 0.18, 0.08, 0.10))

	# Decorative grass tufts and pebbles scattered across the meadow. Land
	# polygons drawn by children cover these where the soil reaches.
	for tuft_origin in [
		Vector2(-86.0, 78.0), Vector2(-72.0, -82.0), Vector2(-58.0, 86.0),
		Vector2(-30.0, 92.0), Vector2(-22.0, -90.0), Vector2(8.0, 88.0),
		Vector2(36.0, -86.0), Vector2(62.0, 86.0), Vector2(86.0, -78.0),
		Vector2(82.0, 32.0), Vector2(-92.0, 24.0), Vector2(-94.0, -38.0),
		Vector2(94.0, 60.0), Vector2(76.0, -52.0), Vector2(-46.0, 78.0),
		Vector2(20.0, -94.0), Vector2(-16.0, 64.0),
	]:
		_draw_grass_tuft(tuft_origin)

	for pebble in [
		Vector2(-78.0, 90.0), Vector2(48.0, 94.0), Vector2(-32.0, 96.0),
		Vector2(90.0, -2.0), Vector2(-88.0, -54.0), Vector2(2.0, -90.0),
	]:
		draw_circle(pebble, 3.4, Color(0.84, 0.79, 0.65, 0.55))
		draw_circle(pebble + Vector2(-0.8, -0.8), 1.4, Color(0.97, 0.92, 0.78, 0.55))


func _draw_grass_tuft(origin: Vector2) -> void:
	var blade_color := Color(0.36, 0.58, 0.28, 0.65)
	var highlight := Color(0.62, 0.84, 0.46, 0.55)
	var offsets: Array[Vector2] = [Vector2(-2.0, 0.2), Vector2(0.0, -0.6), Vector2(2.0, 0.2)]
	var widths: Array[float] = [1.4, 1.7, 1.4]
	var height_factors: Array[float] = [0.7, 1.0, 0.7]
	for i in range(3):
		var off: Vector2 = offsets[i]
		var w: float = widths[i]
		var h: float = 4.0 * height_factors[i]
		var p1: Vector2 = origin + off
		var p2: Vector2 = p1 + Vector2(off.x * 0.3, -h)
		draw_line(p1, p2, blade_color, w, true)
		draw_line(p1 + Vector2(0.2, 0.0), p2 + Vector2(0.2, -0.3), highlight, 0.7, true)


func edge_marker_at(world_edge: int, quarter_turns := 0) -> int:
	if edge_markers.size() != 4:
		return -1
	return edge_markers[int(posmod(world_edge - quarter_turns, 4))]


func _rounded_box(fill: Color, border: Color, border_width: int, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.border_width_left = border_width
	box.border_width_top = border_width
	box.border_width_right = border_width
	box.border_width_bottom = border_width
	box.corner_radius_top_left = radius
	box.corner_radius_top_right = radius
	box.corner_radius_bottom_right = radius
	box.corner_radius_bottom_left = radius
	box.anti_aliasing = true
	return box