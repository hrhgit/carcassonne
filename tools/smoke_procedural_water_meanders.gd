extends SceneTree

# Build-time geometry smoke: all card-table water routes must be repeatable,
# leave a locked straight segment at their fixed port, and use a shallow
# low-poly interior bend where the path has room. Runtime only instances the
# resulting scenes; this script never touches a placed board tile.
const GENERATOR := preload("res://scripts/tile_prefab_generator_3d.gd")
const SPEC_DIR := "res://tools/tile_specs_3d"
const CSV_PATH := "res://data/tiles.csv"
const TILE_HALF_SIZE := 2.45
const EPSILON := 0.001


func _init() -> void:
	call_deferred("_smoke")


func _smoke() -> void:
	var specs := _read_specs()
	if specs.size() != 27:
		_fail("Expected the active table's 27 generated specs, found %d." % specs.size())
		return
	for raw_spec in specs:
		var normalized: Dictionary = GENERATOR.validate_spec(raw_spec)
		if not bool(normalized.get("ok", false)):
			_fail("Invalid generated TileSpec3D: %s" % normalized.get("error", "unknown"))
			return
		var spec: Dictionary = normalized["spec"]
		var paths_a: Array = GENERATOR._water_paths(spec["regions"], spec["routes"], int(spec["seed"]))
		var paths_b: Array = GENERATOR._water_paths(spec["regions"], spec["routes"], int(spec["seed"]))
		if not _same_paths(paths_a, paths_b):
			_fail("%s changed water geometry across two builds with the same seed." % spec["id"])
			return
		if not _paths_keep_ports_locked(paths_a, spec["routes"]):
			_fail("%s moved a fixed water port or bent inside its boundary lock." % spec["id"])
			return
		if not _paths_stay_inside_tile(paths_a):
			_fail("%s produced a control point outside the tile boundary." % spec["id"])
			return
		if not _central_hub_is_filled(paths_a, spec):
			_fail("%s left an unfilled wedge where independently bent channels meet at the central hub." % spec["id"])
			return

	for id in [&"river_straight", &"water_opposite", &"land_single_edge_water_straight_irrigated"]:
		var raw_spec: Dictionary = _spec_by_id(specs, id)
		var normalized: Dictionary = GENERATOR.validate_spec(raw_spec)
		var spec: Dictionary = normalized["spec"]
		var paths: Array = GENERATOR._water_paths(spec["regions"], spec["routes"], int(spec["seed"]))
		if not _has_interior_meander(paths):
			_fail("%s still renders as an unbent centreline instead of a natural low-poly water path." % id)
			return

	print("PROCEDURAL_WATER_MEANDERS_PASS: 27 fixed prefab specs preserve locked ports, deterministic paths, and visible interior bends.")
	quit()


func _read_specs() -> Array:
	var directory := DirAccess.open(SPEC_DIR)
	if directory == null:
		return []
	var active_ids := _active_ids()
	var result: Array = []
	directory.list_dir_begin()
	var filename := directory.get_next()
	while not filename.is_empty():
		if not directory.current_is_dir() and filename.ends_with(".json"):
			var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string("%s/%s" % [SPEC_DIR, filename]))
			if raw is Dictionary:
				var raw_spec: Dictionary = raw
				if active_ids.has(String(raw_spec.get("id", ""))):
					result.append(raw_spec)
		filename = directory.get_next()
	directory.list_dir_end()
	return result


func _active_ids() -> Dictionary:
	var result: Dictionary = {}
	var lines: PackedStringArray = FileAccess.get_file_as_string(CSV_PATH).split("\n")
	var header_seen := false
	var id_column := -1
	for raw_line in lines:
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var fields: PackedStringArray = line.split(",")
		if not header_seen:
			id_column = fields.find("id")
			header_seen = id_column >= 0
			continue
		if id_column >= 0 and fields.size() > id_column:
			result[fields[id_column].strip_edges()] = true
	return result


func _spec_by_id(specs: Array, id: StringName) -> Dictionary:
	for raw_spec in specs:
		if StringName(String(raw_spec.get("id", ""))) == id:
			return raw_spec
	return {}


func _same_paths(first: Array, second: Array) -> bool:
	if first.size() != second.size():
		return false
	for path_index in range(first.size()):
		var a: PackedVector2Array = Dictionary(first[path_index]).get("points", PackedVector2Array())
		var b: PackedVector2Array = Dictionary(second[path_index]).get("points", PackedVector2Array())
		if a.size() != b.size():
			return false
		for point_index in range(a.size()):
			if a[point_index].distance_to(b[point_index]) > EPSILON:
				return false
	return true


func _paths_keep_ports_locked(paths: Array, routes: Array) -> bool:
	if paths.size() < routes.size():
		return false
	for route_index in range(routes.size()):
		var route: Dictionary = routes[route_index]
		var points: PackedVector2Array = Dictionary(paths[route_index]).get("points", PackedVector2Array())
		if points.size() < 2:
			return false
		var edge := int(route["from"])
		var edge_direction := _edge_direction(edge)
		var expected_port := edge_direction * TILE_HALF_SIZE
		if points[0].distance_to(expected_port) > EPSILON:
			return false
		var locked_segment := points[1] - points[0]
		if locked_segment.length() < 0.25:
			return false
		var inward := -edge_direction
		if absf(locked_segment.normalized().cross(inward)) > EPSILON or locked_segment.normalized().dot(inward) < 0.999:
			return false
	return true


func _paths_stay_inside_tile(paths: Array) -> bool:
	for source_path in paths:
		var points: PackedVector2Array = Dictionary(source_path).get("points", PackedVector2Array())
		for point in points:
			if absf(point.x) > TILE_HALF_SIZE + EPSILON or absf(point.y) > TILE_HALF_SIZE + EPSILON:
				return false
	return true


func _central_hub_is_filled(paths: Array, spec: Dictionary) -> bool:
	var hub_width: float = float(GENERATOR._central_hub_width(spec["routes"]))
	if hub_width <= 0.0:
		return true
	var layers: Dictionary = GENERATOR._build_water_layers(paths, int(spec["center"]), hub_width)
	var outlines: Array = layers["surface_outlines"]
	# This radius is comfortably inside the shared octagonal patch, rather than
	# probing its boundary where a polygon-edge inclusion rule might differ.
	var probe_radius := hub_width * 0.28
	var directions: Array[Vector2] = [Vector2.ZERO, Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN, Vector2(1.0, 1.0).normalized(), Vector2(-1.0, 1.0).normalized()]
	for direction in directions:
		var probe: Vector2 = direction * probe_radius
		if not _point_is_in_outlines(probe, outlines):
			return false
	return true


func _point_is_in_outlines(point: Vector2, outlines: Array) -> bool:
	for outline in outlines:
		if Geometry2D.is_point_in_polygon(point, outline):
			return true
	return false


func _has_interior_meander(paths: Array) -> bool:
	for source_path in paths:
		var points: PackedVector2Array = Dictionary(source_path).get("points", PackedVector2Array())
		if points.size() < 4:
			continue
		var start := points[0]
		var end := points[points.size() - 1]
		var base := end - start
		if base.length() <= EPSILON:
			continue
		for point_index in range(1, points.size() - 1):
			if absf((points[point_index] - start).cross(base)) / base.length() > 0.025:
				return true
	return false


func _edge_direction(edge: int) -> Vector2:
	match edge:
		0:
			return Vector2.UP
		1:
			return Vector2.RIGHT
		2:
			return Vector2.DOWN
		3:
			return Vector2.LEFT
	return Vector2.ZERO


func _fail(message: String) -> void:
	push_error("PROCEDURAL_WATER_MEANDERS_FAIL: " + message)
	quit(1)
