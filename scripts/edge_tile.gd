class_name EdgeTile
extends Node2D

const UI_FONT_SCRIPT := preload("res://scripts/ui_font.gd")
const TILE_RECT := Rect2(8.0, 8.0, 244.0, 244.0)
const INNER_RECT := Rect2(19.0, 19.0, 222.0, 222.0)
const NORTH := 0
const EAST := 1
const SOUTH := 2
const WEST := 3
const EMPTY := 0
const LAND := 1
const WATER := 2

enum GrowthState {
	BARE,
	GROWING,
	WILTED,
}

signal planted(tile_id: StringName)

var definition = null
var growth_state := GrowthState.BARE
var land_regions: Array = []
var ground_marks: Array[Dictionary] = []
var soil_marks: Array[Dictionary] = []
var crop_points := PackedVector2Array()
var water_time := 0.0


func configure(new_definition) -> void:
	definition = new_definition
	growth_state = GrowthState.GROWING if definition.starts_grown else GrowthState.BARE
	_rebuild_visual_data()
	queue_redraw()


func is_bare() -> bool:
	return growth_state == GrowthState.BARE


func is_growing() -> bool:
	return growth_state == GrowthState.GROWING


func sow() -> void:
	if growth_state != GrowthState.BARE:
		return
	growth_state = GrowthState.GROWING
	planted.emit(definition.id)
	queue_redraw()


func wilt() -> void:
	growth_state = GrowthState.WILTED
	queue_redraw()


func seed_click_position() -> Vector2:
	if land_regions.is_empty():
		return to_global(INNER_RECT.get_center())
	var region: PackedVector2Array = land_regions[0]
	var center := Vector2.ZERO
	for point in region:
		center += point
	return to_global(center / float(region.size()))


func _process(delta: float) -> void:
	water_time = fposmod(water_time + delta, 20.0)
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse_event := event as InputEventMouseButton
	if mouse_event.button_index != MOUSE_BUTTON_LEFT or not mouse_event.pressed:
		return
	if growth_state != GrowthState.BARE:
		return
	if not _is_land_point(to_local(mouse_event.position)):
		return
	sow()
	get_viewport().set_input_as_handled()


func _draw() -> void:
	if definition == null:
		return
	_draw_tile_frame()
	_draw_empty_meadow()
	_draw_land()
	_draw_water()
	_draw_edge_ports()
	_draw_label()


func _draw_tile_frame() -> void:
	draw_circle(Vector2(132.0, 257.0), 116.0, Color(0.0, 0.04, 0.025, 0.28))
	draw_style_box(_rounded_box(Color("#c98c4e"), 21, Color("#503224"), 3), TILE_RECT)
	draw_style_box(_rounded_box(Color("#e8bb6b"), 16, Color("#845231"), 1), INNER_RECT.grow(3.0))
	draw_style_box(_rounded_box(Color("#8fbd5d"), 13, Color("#55753a"), 2), INNER_RECT)


func _draw_empty_meadow() -> void:
	draw_colored_polygon(PackedVector2Array([
		Vector2(24.0, 24.0), Vector2(133.0, 21.0), Vector2(160.0, 88.0),
		Vector2(99.0, 135.0), Vector2(22.0, 114.0),
	]), Color(0.70, 0.83, 0.39, 0.38))
	draw_colored_polygon(PackedVector2Array([
		Vector2(155.0, 21.0), Vector2(236.0, 25.0), Vector2(237.0, 139.0),
		Vector2(191.0, 174.0), Vector2(143.0, 102.0),
	]), Color(0.39, 0.63, 0.29, 0.22))
	draw_colored_polygon(PackedVector2Array([
		Vector2(20.0, 169.0), Vector2(91.0, 137.0), Vector2(170.0, 183.0),
		Vector2(149.0, 238.0), Vector2(22.0, 239.0),
	]), Color(0.65, 0.78, 0.35, 0.30))
	for mark in ground_marks:
		draw_circle(mark["point"], mark["radius"], mark["color"])


func _draw_water() -> void:
	for path in _water_paths():
		draw_polyline(path, Color("#32583d"), 18.0, true)
		draw_polyline(path, Color("#6cae9b"), 12.0, true)
		draw_polyline(path, Color("#2697b5"), 8.0, true)
		draw_polyline(path, Color("#3eb6c8"), 4.0, true)
		_draw_water_motion(path)


func _draw_water_motion(path: PackedVector2Array) -> void:
	if path.size() < 2:
		return
	var midpoint := _path_midpoint(path)
	var direction := (path[path.size() - 1] - path[0]).normalized()
	var normal := Vector2(-direction.y, direction.x)
	var drift := sin(water_time * 2.1 + float(definition.visual_seed)) * 3.0
	var point := midpoint + direction * drift
	draw_line(point - direction * 6.0, point + direction * 7.0, Color(0.87, 1.0, 0.98, 0.7), 1.4, true)
	draw_line(point + direction * 7.0, point + direction * 2.5 + normal * 3.0, Color(0.87, 1.0, 0.98, 0.6), 1.0, true)
	draw_line(point + direction * 7.0, point + direction * 2.5 - normal * 3.0, Color(0.87, 1.0, 0.98, 0.6), 1.0, true)


func _draw_land() -> void:
	for region in land_regions:
		var shape: PackedVector2Array = region
		draw_colored_polygon(_translated(shape, Vector2(2.0, 3.0)), Color(0.11, 0.07, 0.03, 0.32))
		draw_colored_polygon(shape, Color("#b66f3f"))
		draw_polyline(_closed(shape), Color("#623a21"), 3.2, true)
		draw_polyline(_closed(shape), Color(1.0, 0.78, 0.43, 0.45), 0.9, true)
		if growth_state == GrowthState.GROWING:
			draw_colored_polygon(shape, Color(0.15, 0.47, 0.16, 0.30))
		elif growth_state == GrowthState.WILTED:
			draw_colored_polygon(shape, Color(0.39, 0.30, 0.16, 0.46))

	for mark in soil_marks:
		draw_circle(mark["point"], mark["radius"], mark["color"])

	if growth_state == GrowthState.GROWING:
		for index in range(crop_points.size()):
			_draw_crop(crop_points[index], index)
	elif growth_state == GrowthState.WILTED:
		for index in range(crop_points.size()):
			var root := crop_points[index] + Vector2(0.0, 2.5)
			draw_line(root, root + Vector2(float(index % 3 - 1) * 3.0, 4.0), Color("#735437"), 1.0, true)


func _draw_crop(position: Vector2, index: int) -> void:
	var scale := 0.52 + float(index % 3) * 0.08
	var sway := sin(water_time * 1.8 + float(index) * 1.57) * 1.3
	var root := position + Vector2(0.0, 3.5 * scale)
	var crown := position + Vector2(sway, -5.0 * scale)
	draw_line(root, crown, Color("#275c30"), 1.4 * scale, true)
	_draw_leaf(crown, crown + Vector2(-5.0 * scale, -1.0), 2.2 * scale, Color("#4e9c46"))
	_draw_leaf(crown, crown + Vector2(5.4 * scale, -2.2), 2.1 * scale, Color("#65ae51"))
	_draw_leaf(crown, crown + Vector2(-2.0 * scale, -6.0 * scale), 1.9 * scale, Color("#3e843e"))


func _draw_edge_ports() -> void:
	# Land color reaches the entire side; water gets one narrow, centered endpoint.
	for edge in definition.edge_indices(WATER):
		var port := _edge_center(edge)
		draw_circle(port, 4.0, Color("#d3fff0"))


func _draw_label() -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	draw_string(font, Vector2(9.0, 272.0), definition.display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color("#ecf3d1"))
	var status := "生长中" if growth_state == GrowthState.GROWING else "裸土"
	if growth_state == GrowthState.WILTED:
		status = "枯萎"
	draw_string(font, Vector2(9.0, 291.0), "%d 条土地边 · %s" % [definition.land_edge_count(), status], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.75, 0.88, 0.74, 0.67))


func _rebuild_visual_data() -> void:
	land_regions = _land_regions_for_definition()
	ground_marks.clear()
	soil_marks.clear()
	crop_points.clear()
	if definition == null:
		return

	var rng := RandomNumberGenerator.new()
	rng.seed = definition.visual_seed
	var attempts := 0
	while ground_marks.size() < 34 and attempts < 900:
		attempts += 1
		var point := Vector2(rng.randf_range(27.0, 233.0), rng.randf_range(27.0, 233.0))
		if _is_land_point(point) or _distance_to_water_port(point) < 16.0:
			continue
		ground_marks.append({
			"point": point,
			"radius": rng.randf_range(0.7, 1.9),
			"color": [Color(0.17, 0.42, 0.20, 0.22), Color(0.82, 0.90, 0.48, 0.20)][rng.randi_range(0, 1)],
		})

	attempts = 0
	while soil_marks.size() < 17 + definition.land_edge_count() * 7 and attempts < 1300:
		attempts += 1
		var point := Vector2(rng.randf_range(25.0, 235.0), rng.randf_range(25.0, 235.0))
		if not _is_land_point(point):
			continue
		soil_marks.append({
			"point": point,
			"radius": rng.randf_range(0.65, 1.65),
			"color": [Color(0.32, 0.16, 0.07, 0.3), Color(0.98, 0.73, 0.38, 0.30)][rng.randi_range(0, 1)],
		})

	attempts = 0
	while crop_points.size() < 8 + definition.land_edge_count() * 8 and attempts < 1800:
		attempts += 1
		var point := Vector2(rng.randf_range(29.0, 231.0), rng.randf_range(29.0, 231.0))
		if _is_land_point(point):
			crop_points.append(point)


func _land_regions_for_definition() -> Array:
	if definition == null:
		return []
	var land_edges: PackedInt32Array = definition.edge_indices(LAND)
	match land_edges.size():
		0:
			return []
		1:
			return [_single_edge_region(land_edges[0])]
		2:
			return [_single_edge_region(land_edges[0]), _single_edge_region(land_edges[1])]
		3:
			var missing_edge := NORTH
			for edge in [NORTH, EAST, SOUTH, WEST]:
				if edge not in land_edges:
					missing_edge = edge
			var turns := (missing_edge - SOUTH + 4) % 4
			return [_rotate_region(_three_edge_region_missing_south(), turns)]
		_:
			return [PackedVector2Array([
				Vector2(19.0, 19.0), Vector2(241.0, 19.0), Vector2(241.0, 241.0), Vector2(19.0, 241.0),
			])]


func _single_edge_region(edge: int) -> PackedVector2Array:
	var north_region := PackedVector2Array([
		Vector2(19.0, 19.0), Vector2(241.0, 19.0), Vector2(241.0, 61.0),
		Vector2(210.0, 81.0), Vector2(171.0, 93.0), Vector2(130.0, 100.0),
		Vector2(89.0, 93.0), Vector2(50.0, 81.0), Vector2(19.0, 61.0),
	])
	return _rotate_region(north_region, edge)


func _three_edge_region_missing_south() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(19.0, 19.0), Vector2(241.0, 19.0), Vector2(241.0, 241.0),
		Vector2(196.0, 241.0), Vector2(190.0, 204.0), Vector2(166.0, 170.0),
		Vector2(130.0, 158.0), Vector2(94.0, 170.0), Vector2(70.0, 204.0),
		Vector2(64.0, 241.0), Vector2(19.0, 241.0),
	])


func _rotate_region(source: PackedVector2Array, quarter_turns: int) -> PackedVector2Array:
	var center := INNER_RECT.get_center()
	var rotated := PackedVector2Array()
	for point in source:
		rotated.append(center + (point - center).rotated(float(quarter_turns) * PI * 0.5))
	return rotated


func _water_paths() -> Array:
	var paths: Array = []
	var water_edges: PackedInt32Array = definition.edge_indices(WATER)
	if water_edges.is_empty():
		return paths
	var junction := INNER_RECT.get_center()

	# A single inlet does not stop at the meadow centre: it runs until it reaches land.
	if water_edges.size() == 1:
		var inlet := _edge_center(water_edges[0])
		paths.append(PackedVector2Array([inlet, _first_land_contact_from(inlet, junction)]))
		return paths

	# Opposite water ports form the central trunk. Other multiple-port patterns meet at the centre.
	if water_edges.size() == 2 and (water_edges[0] - water_edges[1]) % 2 == 0:
		paths.append(PackedVector2Array([_edge_center(water_edges[0]), junction, _edge_center(water_edges[1])]))
	else:
		for edge in water_edges:
			paths.append(PackedVector2Array([_edge_center(edge), junction]))

	# A central trunk is only useful if it also irrigates land. Branch into each nearby region.
	for contact in _land_contacts_from(junction):
		paths.append(PackedVector2Array([junction, contact]))
	return paths


func _first_land_contact_from(inlet: Vector2, junction: Vector2) -> Vector2:
	var direction := (junction - inlet).normalized()
	var scan_end := junction + direction * 220.0
	var contact := _first_land_on_segment(inlet, scan_end)
	return junction if contact.x < 0.0 else contact


func _land_contacts_from(origin: Vector2) -> Array:
	var contacts: Array = []
	for direction in [Vector2.UP, Vector2.RIGHT, Vector2.DOWN, Vector2.LEFT]:
		var contact := _first_land_on_segment(origin, origin + direction * 180.0)
		if contact.x < 0.0:
			continue
		var duplicate := false
		for existing in contacts:
			if contact.distance_to(existing) < 8.0:
				duplicate = true
				break
		if not duplicate:
			contacts.append(contact)
	return contacts


func _first_land_on_segment(start: Vector2, end: Vector2) -> Vector2:
	var sample_count := maxi(1, int(ceil(start.distance_to(end) / 1.5)))
	for step in range(sample_count + 1):
		var point := start.lerp(end, float(step) / float(sample_count))
		if _is_land_point(point):
			return point
	return Vector2(-1.0, -1.0)


func _edge_center(edge: int) -> Vector2:
	match edge:
		NORTH:
			return Vector2(INNER_RECT.get_center().x, INNER_RECT.position.y)
		EAST:
			return Vector2(INNER_RECT.end.x, INNER_RECT.get_center().y)
		SOUTH:
			return Vector2(INNER_RECT.get_center().x, INNER_RECT.end.y)
		_:
			return Vector2(INNER_RECT.position.x, INNER_RECT.get_center().y)


func _is_land_point(point: Vector2) -> bool:
	for region in land_regions:
		if Geometry2D.is_point_in_polygon(point, region):
			return true
	return false


func _distance_to_water_port(point: Vector2) -> float:
	var nearest := INF
	for edge in definition.edge_indices(WATER):
		nearest = minf(nearest, point.distance_to(_edge_center(edge)))
	return nearest


func _path_midpoint(path: PackedVector2Array) -> Vector2:
	if path.size() == 2:
		return path[0].lerp(path[1], 0.5)
	return path[1]


func _translated(source: PackedVector2Array, offset: Vector2) -> PackedVector2Array:
	var translated := PackedVector2Array()
	for point in source:
		translated.append(point + offset)
	return translated


func _closed(source: PackedVector2Array) -> PackedVector2Array:
	var closed := source.duplicate()
	closed.append(source[0])
	return closed


func _draw_leaf(base: Vector2, tip: Vector2, width: float, color: Color) -> void:
	var direction := (tip - base).normalized()
	var normal := Vector2(-direction.y, direction.x) * width
	var middle := base.lerp(tip, 0.48)
	draw_colored_polygon(PackedVector2Array([base, middle + normal, tip, middle - normal]), color)


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
