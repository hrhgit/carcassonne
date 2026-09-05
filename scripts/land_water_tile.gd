class_name LandWaterTile
extends Node2D

const LAND_PATCH_SCRIPT := preload("res://scripts/land_patch.gd")
const PATCH_BARE := 0
const PATCH_GROWING := 1

signal land_sown(field_id: StringName)

const OUTER_RECT := Rect2(20.0, 20.0, 620.0, 620.0)
const INNER_RECT := Rect2(36.0, 36.0, 588.0, 588.0)
var river_points := PackedVector2Array([
	Vector2(36.0, 191.0),
	Vector2(96.0, 191.0),
	Vector2(153.0, 226.0),
	Vector2(214.0, 307.0),
	Vector2(301.0, 371.0),
	Vector2(390.0, 409.0),
	Vector2(485.0, 400.0),
	Vector2(555.0, 365.0),
	Vector2(624.0, 365.0),
])
var river_widths := PackedFloat32Array([19.0, 20.0, 22.0, 24.0, 26.0, 25.0, 23.0, 21.0, 20.0])

var water_time := 0.0
var ground_marks: Array[Dictionary] = []
var land_patches: Array = []


func _ready() -> void:
	_build_ground_marks()
	_build_land_patches()
	queue_redraw()


func _process(delta: float) -> void:
	water_time = fposmod(water_time + delta, 20.0)
	queue_redraw()


func _draw() -> void:
	_draw_tile_shadow()
	_draw_tile_frame()
	_draw_land_variation()
	_draw_river()
	_draw_bank_details()
	_draw_edge_accents()


func _draw_tile_shadow() -> void:
	draw_circle(Vector2(334.0, 659.0), 285.0, Color(0.0, 0.04, 0.025, 0.23))
	var shadow := _rounded_box(Color(0.01, 0.045, 0.032, 0.66), 30, Color.TRANSPARENT, 0)
	draw_style_box(shadow, OUTER_RECT.grow_individual(9.0, 14.0, 10.0, 17.0))


func _draw_tile_frame() -> void:
	var wood := _rounded_box(Color("#c88b4d"), 28, Color("#553524"), 4)
	draw_style_box(wood, OUTER_RECT)

	var inner_rim := _rounded_box(Color("#e3bb70"), 21, Color("#8c5a34"), 2)
	draw_style_box(inner_rim, INNER_RECT.grow(3.0))

	var land := _rounded_box(Color("#8fbd5c"), 18, Color("#577c3c"), 2)
	draw_style_box(land, INNER_RECT)

	# Grain lines keep the square tile materially distinct from its painted terrain.
	for offset in range(0, 9):
		var y := 51.0 + float(offset) * 68.0
		draw_line(Vector2(25.0, y), Vector2(31.0, y + 31.0), Color(0.28, 0.14, 0.07, 0.16), 1.2, true)
		draw_line(Vector2(635.0, y + 14.0), Vector2(629.0, y + 43.0), Color(1.0, 0.81, 0.48, 0.18), 1.2, true)


func _draw_land_variation() -> void:
	# A few broad organic patches prevent the terrain from reading as a flat green card.
	draw_colored_polygon(PackedVector2Array([
		Vector2(48.0, 49.0), Vector2(225.0, 43.0), Vector2(281.0, 121.0),
		Vector2(201.0, 188.0), Vector2(71.0, 163.0),
	]), Color(0.69, 0.82, 0.38, 0.46))
	draw_colored_polygon(PackedVector2Array([
		Vector2(402.0, 53.0), Vector2(613.0, 49.0), Vector2(615.0, 238.0),
		Vector2(534.0, 275.0), Vector2(451.0, 194.0),
	]), Color(0.47, 0.68, 0.31, 0.35))
	draw_colored_polygon(PackedVector2Array([
		Vector2(46.0, 430.0), Vector2(171.0, 398.0), Vector2(300.0, 470.0),
		Vector2(289.0, 617.0), Vector2(47.0, 618.0),
	]), Color(0.67, 0.78, 0.35, 0.38))
	draw_colored_polygon(PackedVector2Array([
		Vector2(396.0, 485.0), Vector2(608.0, 438.0), Vector2(615.0, 614.0),
		Vector2(438.0, 617.0), Vector2(356.0, 564.0),
	]), Color(0.41, 0.64, 0.31, 0.27))

	for mark in ground_marks:
		var point: Vector2 = mark["point"]
		var radius: float = mark["radius"]
		var color: Color = mark["color"]
		draw_circle(point, radius, color)


func _draw_river() -> void:
	# Keep water deliberately narrow: it is a connector and irrigation source, not the tile's main area.
	draw_colored_polygon(_river_shape(16.0), Color("#365b3f"))
	draw_colored_polygon(_river_shape(7.0), Color("#62a89a"))
	draw_colored_polygon(_river_shape(0.0), Color("#278fad"))
	draw_colored_polygon(_river_shape(-5.0), Color("#35aac2"))

	# Fine moving strokes establish that the blue path is a current rather than a road.
	for index in range(8):
		var progress := fposmod(float(index) * 0.143 + water_time * 0.065, 1.0)
		var point := _river_point_at(progress)
		var direction := _river_direction_at(progress)
		var normal := Vector2(-direction.y, direction.x)
		draw_line(point - direction * 6.0, point + direction * 9.0, Color(0.84, 1.0, 0.97, 0.58), 1.5, true)
		draw_line(point + direction * 9.0, point + direction * 4.0 + normal * 3.0, Color(0.84, 1.0, 0.97, 0.5), 1.1, true)
		draw_line(point + direction * 9.0, point + direction * 4.0 - normal * 3.0, Color(0.84, 1.0, 0.97, 0.5), 1.1, true)

	for index in range(5):
		var ripple_progress := fposmod(float(index) * 0.21 + water_time * 0.035, 1.0)
		var ripple := _river_point_at(ripple_progress)
		draw_arc(ripple, 7.0 + sin(water_time * 1.6 + float(index)) * 1.2, 0.25, 2.7, 12, Color(0.76, 0.99, 0.97, 0.22), 0.8, true)


func _draw_bank_details() -> void:
	var stones := [
		Vector2(78.0, 261.0), Vector2(139.0, 285.0), Vector2(182.0, 372.0),
		Vector2(267.0, 432.0), Vector2(378.0, 485.0), Vector2(460.0, 476.0),
		Vector2(528.0, 438.0), Vector2(577.0, 432.0),
		Vector2(81.0, 124.0), Vector2(146.0, 145.0), Vector2(237.0, 230.0),
		Vector2(334.0, 306.0), Vector2(424.0, 324.0), Vector2(510.0, 312.0),
	]
	for index in range(stones.size()):
		var stone: Vector2 = stones[index]
		var radius := 3.0 + float(index % 3) * 1.1
		draw_circle(stone + Vector2(1.5, 2.0), radius + 1.0, Color(0.09, 0.19, 0.14, 0.22))
		draw_circle(stone, radius, Color("#c8bc8a"))

	for tuft in [Vector2(69.0, 310.0), Vector2(181.0, 273.0), Vector2(252.0, 394.0), Vector2(454.0, 337.0), Vector2(569.0, 307.0), Vector2(544.0, 465.0)]:
		_draw_grass_tuft(tuft)


func _draw_edge_accents() -> void:
	# These two glints make the water exits unambiguous during a quick visual read.
	draw_line(Vector2(37.0, 163.0), Vector2(37.0, 219.0), Color(0.83, 1.0, 0.96, 0.35), 2.0, true)
	draw_line(Vector2(623.0, 338.0), Vector2(623.0, 390.0), Color(0.83, 1.0, 0.96, 0.35), 2.0, true)
	draw_circle(Vector2(36.0, 191.0), 4.0, Color("#d2fff0"))
	draw_circle(Vector2(624.0, 365.0), 4.0, Color("#d2fff0"))


func _build_ground_marks() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 80317
	while ground_marks.size() < 112:
		var point := Vector2(rng.randf_range(54.0, 606.0), rng.randf_range(54.0, 606.0))
		if _distance_to_river(point) < 58.0:
			continue
		var palette := [Color(0.18, 0.42, 0.2, 0.2), Color(0.82, 0.9, 0.48, 0.2), Color(0.32, 0.56, 0.25, 0.22)]
		ground_marks.append({
			"point": point,
			"radius": rng.randf_range(1.1, 3.5),
			"color": palette[rng.randi_range(0, palette.size() - 1)],
		})


func _build_land_patches() -> void:
	_add_land_patch(&"northwest_soil", PackedVector2Array([
		Vector2(57.0, 64.0), Vector2(252.0, 56.0), Vector2(308.0, 111.0),
		Vector2(252.0, 159.0), Vector2(145.0, 164.0), Vector2(57.0, 136.0),
	]), PATCH_BARE, 1129)
	_add_land_patch(&"northeast_garden", PackedVector2Array([
		Vector2(382.0, 70.0), Vector2(590.0, 62.0), Vector2(606.0, 226.0),
		Vector2(551.0, 273.0), Vector2(455.0, 258.0), Vector2(354.0, 194.0), Vector2(350.0, 126.0),
	]), PATCH_GROWING, 2407)
	_add_land_patch(&"southwest_garden", PackedVector2Array([
		Vector2(54.0, 422.0), Vector2(148.0, 404.0), Vector2(248.0, 444.0),
		Vector2(306.0, 510.0), Vector2(278.0, 594.0), Vector2(61.0, 604.0),
	]), PATCH_GROWING, 3689)
	_add_land_patch(&"southeast_soil", PackedVector2Array([
		Vector2(423.0, 490.0), Vector2(531.0, 452.0), Vector2(606.0, 483.0),
		Vector2(600.0, 604.0), Vector2(385.0, 606.0), Vector2(352.0, 555.0),
	]), PATCH_BARE, 4973)


func _add_land_patch(field_id: StringName, outline: PackedVector2Array, initial_state: int, visual_seed: int) -> void:
	var patch := LAND_PATCH_SCRIPT.new()
	patch.configure(field_id, outline, initial_state, visual_seed)
	patch.planted.connect(_on_land_patch_planted)
	patch.z_index = 1
	add_child(patch)
	land_patches.append(patch)


func sow_all() -> void:
	for patch in land_patches:
		patch.sow()


func sow_first_bare_with_input() -> bool:
	for patch in land_patches:
		if patch.growth_state != PATCH_BARE:
			continue
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = patch.seed_click_position()
		Input.parse_input_event(click)
		return true
	return false


func is_growing(field_id: StringName) -> bool:
	for patch in land_patches:
		if patch.field_id == field_id:
			return patch.growth_state == PATCH_GROWING
	return false


func _on_land_patch_planted(field_id: StringName) -> void:
	land_sown.emit(field_id)


func _river_shape(extra_width: float) -> PackedVector2Array:
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for index in range(river_points.size()):
		var tangent: Vector2
		if index == 0:
			tangent = (river_points[1] - river_points[0]).normalized()
		elif index == river_points.size() - 1:
			tangent = (river_points[index] - river_points[index - 1]).normalized()
		else:
			tangent = (river_points[index + 1] - river_points[index - 1]).normalized()
		var normal := Vector2(-tangent.y, tangent.x)
		var width := maxf(8.0, river_widths[index] + extra_width)
		left.append(river_points[index] + normal * width)
		right.append(river_points[index] - normal * width)

	var polygon := PackedVector2Array()
	for point in left:
		polygon.append(point)
	for index in range(right.size() - 1, -1, -1):
		polygon.append(right[index])
	return polygon


func _river_point_at(progress: float) -> Vector2:
	var scaled := clampf(progress, 0.0, 0.9999) * float(river_points.size() - 1)
	var index := int(floor(scaled))
	var local_progress := scaled - float(index)
	return river_points[index].lerp(river_points[index + 1], local_progress)


func _river_direction_at(progress: float) -> Vector2:
	var scaled := clampf(progress, 0.0, 0.9999) * float(river_points.size() - 1)
	var index := int(floor(scaled))
	return (river_points[index + 1] - river_points[index]).normalized()


func _distance_to_river(point: Vector2) -> float:
	var nearest := INF
	for index in range(river_points.size() - 1):
		var start := river_points[index]
		var end := river_points[index + 1]
		var segment := end - start
		var projection := clampf((point - start).dot(segment) / segment.length_squared(), 0.0, 1.0)
		nearest = minf(nearest, point.distance_to(start.lerp(end, projection)))
	return nearest


func _draw_grass_tuft(origin: Vector2) -> void:
	for blade in range(5):
		var offset := float(blade - 2) * 2.0
		var tip := origin + Vector2(offset * 1.6, -10.0 - absf(offset) * 1.2)
		draw_line(origin + Vector2(offset, 2.0), tip, Color("#315e32"), 1.6, true)


func _draw_plant(position: Vector2, scale: float, leaf_color: Color, flower_color: Color) -> void:
	var base := position + Vector2(0.0, 14.0 * scale)
	var crown := position - Vector2(0.0, 9.0 * scale)
	draw_circle(base + Vector2(2.0, 3.0), 8.0 * scale, Color(0.08, 0.18, 0.1, 0.22))
	draw_line(base, crown, Color("#315c32"), 3.0 * scale, true)
	_draw_leaf(crown + Vector2(0.0, 7.0 * scale), crown + Vector2(-13.0 * scale, -1.0 * scale), 5.2 * scale, leaf_color)
	_draw_leaf(crown + Vector2(0.0, 5.0 * scale), crown + Vector2(14.0 * scale, -5.0 * scale), 5.1 * scale, leaf_color.lightened(0.08))
	_draw_leaf(crown + Vector2(0.0, 1.0 * scale), crown + Vector2(-7.0 * scale, -15.0 * scale), 4.6 * scale, leaf_color.darkened(0.08))
	_draw_leaf(crown + Vector2(0.0, 0.0), crown + Vector2(9.0 * scale, -17.0 * scale), 4.2 * scale, leaf_color)
	draw_circle(crown + Vector2(1.0 * scale, -3.0 * scale), 3.3 * scale, flower_color)
	draw_circle(crown + Vector2(1.0 * scale, -3.0 * scale), 1.25 * scale, Color("#f9f1b5"))


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
	draw_line(base, tip, color.darkened(0.25), 0.9, true)


func _rounded_box(fill: Color, radius: int, border: Color, border_width: int) -> StyleBoxFlat:
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
