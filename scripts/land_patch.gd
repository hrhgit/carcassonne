class_name LandPatch
extends Node2D

enum GrowthState {
	BARE,
	GROWING,
	WILTED,
}

signal planted(field_id: StringName)

var field_id: StringName
var outline := PackedVector2Array()
var growth_state := GrowthState.BARE
var visual_seed := 0
var local_time := 0.0

var soil_marks: Array[Dictionary] = []
var crop_points := PackedVector2Array()


func _ready() -> void:
	set_process_unhandled_input(true)
	if soil_marks.is_empty() and not outline.is_empty():
		_build_details()
	queue_redraw()


func _process(delta: float) -> void:
	if growth_state != GrowthState.GROWING:
		return
	local_time = fposmod(local_time + delta, 20.0)
	queue_redraw()


func configure(
	new_field_id: StringName,
	new_outline: PackedVector2Array,
	initial_state: int,
	new_visual_seed: int,
) -> void:
	field_id = new_field_id
	outline = new_outline.duplicate()
	growth_state = initial_state
	visual_seed = new_visual_seed
	_build_details()
	queue_redraw()


func sow() -> void:
	if growth_state != GrowthState.BARE:
		return
	growth_state = GrowthState.GROWING
	planted.emit(field_id)
	queue_redraw()


func wilt() -> void:
	growth_state = GrowthState.WILTED
	queue_redraw()


func seed_click_position() -> Vector2:
	# All current prototype plots are convex. Their average vertex position is a stable in-plot click target.
	var center := Vector2.ZERO
	for point in outline:
		center += point
	return to_global(center / float(outline.size()))


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton:
		return
	if event.button_index != MOUSE_BUTTON_LEFT or not event.pressed:
		return
	if growth_state != GrowthState.BARE:
		return
	if not Geometry2D.is_point_in_polygon(to_local(event.position), outline):
		return
	sow()
	get_viewport().set_input_as_handled()


func _draw() -> void:
	if outline.size() < 3:
		return

	# The soil itself is the "land" game element. The surrounding green is empty meadow.
	draw_colored_polygon(_translated_outline(Vector2(3.0, 5.0)), Color(0.10, 0.08, 0.045, 0.32))
	draw_colored_polygon(outline, Color("#b56e3c"))
	draw_polyline(_closed_outline(), Color("#60371f"), 5.0, true)
	draw_polyline(_closed_outline(), Color(1.0, 0.78, 0.43, 0.52), 1.2, true)

	if growth_state == GrowthState.GROWING:
		draw_colored_polygon(outline, Color(0.16, 0.46, 0.16, 0.30))
	elif growth_state == GrowthState.WILTED:
		draw_colored_polygon(outline, Color(0.37, 0.30, 0.17, 0.42))

	_draw_soil_texture()
	match growth_state:
		GrowthState.GROWING:
			_draw_growing_plants()
		GrowthState.WILTED:
			_draw_wilted_plants()


func _build_details() -> void:
	soil_marks.clear()
	crop_points.clear()
	if outline.size() < 3:
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = visual_seed
	var bounds := _outline_bounds()
	var attempts := 0
	while soil_marks.size() < 54 and attempts < 1800:
		attempts += 1
		var point := Vector2(
			rng.randf_range(bounds.position.x + 8.0, bounds.end.x - 8.0),
			rng.randf_range(bounds.position.y + 8.0, bounds.end.y - 8.0),
		)
		if not Geometry2D.is_point_in_polygon(point, outline):
			continue
		soil_marks.append({
			"point": point,
			"radius": rng.randf_range(1.0, 2.8),
			"color": [
				Color(0.32, 0.16, 0.07, 0.28),
				Color(0.96, 0.71, 0.36, 0.30),
				Color(0.46, 0.25, 0.10, 0.24),
			][rng.randi_range(0, 2)],
		})

	attempts = 0
	while crop_points.size() < 35 and attempts < 2600:
		attempts += 1
		var point := Vector2(
			rng.randf_range(bounds.position.x + 12.0, bounds.end.x - 12.0),
			rng.randf_range(bounds.position.y + 12.0, bounds.end.y - 12.0),
		)
		if Geometry2D.is_point_in_polygon(point, outline):
			crop_points.append(point)


func _draw_soil_texture() -> void:
	for mark in soil_marks:
		var point: Vector2 = mark["point"]
		var radius: float = mark["radius"]
		var color: Color = mark["color"]
		draw_circle(point, radius, color)


func _draw_growing_plants() -> void:
	for index in range(crop_points.size()):
		_draw_crop(crop_points[index], index)


func _draw_crop(position: Vector2, index: int) -> void:
	var scale := 0.58 + float(index % 4) * 0.07
	var sway := sin(local_time * 1.7 + float(index) * 1.37) * 1.8
	var root := position + Vector2(0.0, 5.0 * scale)
	var crown := position + Vector2(sway, -7.0 * scale)
	draw_circle(root + Vector2(1.0, 2.0), 4.4 * scale, Color(0.05, 0.15, 0.06, 0.22))
	draw_line(root, crown, Color("#265c30"), 1.8 * scale, true)
	_draw_leaf(crown + Vector2(0.0, 2.0), crown + Vector2(-7.0 * scale, -1.0 * scale), 2.8 * scale, Color("#4d9b46"))
	_draw_leaf(crown + Vector2(0.0, 1.0), crown + Vector2(7.0 * scale, -3.0 * scale), 2.7 * scale, Color("#65ae50"))
	_draw_leaf(crown, crown + Vector2(-3.0 * scale, -8.0 * scale), 2.35 * scale, Color("#3d873e"))


func _draw_wilted_plants() -> void:
	for index in range(crop_points.size()):
		var root := crop_points[index] + Vector2(0.0, 4.0)
		var fallen_tip := root + Vector2(float((index % 3) - 1) * 5.0, 5.0)
		draw_line(root, fallen_tip, Color("#705432"), 1.4, true)
		draw_circle(fallen_tip, 2.2, Color("#887044"))


func _draw_leaf(base: Vector2, tip: Vector2, width: float, color: Color) -> void:
	var direction := (tip - base).normalized()
	var normal := Vector2(-direction.y, direction.x) * width
	var middle := base.lerp(tip, 0.48)
	draw_colored_polygon(PackedVector2Array([
		base,
		middle + normal,
		tip,
		middle - normal,
	]), color)


func _outline_bounds() -> Rect2:
	var minimum := outline[0]
	var maximum := outline[0]
	for point in outline:
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return Rect2(minimum, maximum - minimum)


func _translated_outline(offset: Vector2) -> PackedVector2Array:
	var translated := PackedVector2Array()
	for point in outline:
		translated.append(point + offset)
	return translated


func _closed_outline() -> PackedVector2Array:
	var closed := outline.duplicate()
	closed.append(outline[0])
	return closed
