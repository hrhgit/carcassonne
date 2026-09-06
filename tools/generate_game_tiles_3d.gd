extends SceneTree

# Batch driver for the compact, playable `data/tiles.csv` card table. Every
# row receives its own fixed 3D prefab at build time; runtime only selects and
# instances fixed scenes through TileCatalog (a table row may explicitly reuse
# another baked scene, such as the terminal river reusing the starter river).
#
# Usage: godot --headless --path . --script res://tools/generate_game_tiles_3d.gd
const GENERATOR := preload("res://scripts/tile_prefab_generator_3d.gd")
const CSV_PATH := "res://data/tiles.csv"
const SPEC_DIR := "res://tools/tile_specs_3d"

const EMPTY := 0
const LAND := 1
const WATER := 2
const RIVER := 3
# These are the compact card table's numeric codes, not TilePrefabGenerator3D's
# internal centre enum. The generator below translates them to string names.
const CENTER_EMPTY := 0
const CENTER_LAND := 1
const CENTER_RIVER := 2
const CENTER_LAKE := 3
const EDGE_NAMES := ["EMPTY", "LAND", "WATER", "RIVER"]
const EDGE_DIRECTIONS := ["NORTH", "EAST", "SOUTH", "WEST"]
const RIVER_WIDTH := 1.08


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var rows := _read_csv()
	if rows.is_empty():
		_fail("Could not read any tile rows from %s" % CSV_PATH)
		return
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SPEC_DIR))
	if directory_error != OK:
		_fail("Could not create spec directory %s" % SPEC_DIR)
		return

	var generated := 0
	for row in rows:
		var spec := _build_spec(row)
		if spec.is_empty():
			_fail("Could not derive a valid procedural spec for %s" % row["id"])
			return
		var json_path := "%s/%s.json" % [SPEC_DIR, spec["id"]]
		if _write_json(json_path, spec) != OK:
			_fail("Could not write spec %s" % json_path)
			return
		var result: Dictionary = GENERATOR.build_from_spec_file(json_path)
		if not bool(result["ok"]):
			_fail("%s: %s" % [spec["id"], result["error"]])
			return
		generated += 1
		print("GENERATED %s -> %s" % [spec["id"], result["scene_path"]])

	print("GENERATE_GAME_TILES_PASS: %d fixed prefabs generated from the new card table." % generated)
	quit()


func _read_csv() -> Array:
	if not FileAccess.file_exists(CSV_PATH):
		push_error("Missing CSV: %s" % CSV_PATH)
		return []
	var file := FileAccess.open(CSV_PATH, FileAccess.READ)
	if file == null:
		push_error("Cannot open CSV %s" % CSV_PATH)
		return []
	var lines: Array[String] = []
	while not file.eof_reached():
		lines.append(file.get_line())

	var header_index := -1
	for index in range(lines.size()):
		var line := lines[index].strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		header_index = index
		break
	if header_index < 0:
		return []
	var header := _split_line(lines[header_index])
	var idx := {}
	for column in range(header.size()):
		idx[header[column]] = column
	var required_field_count := 0
	for required in ["id", "N", "E", "S", "W", "N_ir", "E_ir", "S_ir", "W_ir", "center"]:
		if not idx.has(required):
			push_error("CSV missing required column %s" % required)
			return []
		required_field_count = maxi(required_field_count, int(idx[required]) + 1)

	var rows: Array = []
	for index in range(header_index + 1, lines.size()):
		var line := lines[index].strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var fields := _split_line(line)
		if fields.size() < required_field_count:
			push_warning("Skipping short row %d" % (index + 1))
			continue
		var edges := PackedInt32Array()
		for column in ["N", "E", "S", "W"]:
			edges.append(_edge_kind(fields[idx[column]]))
		var irrigation := PackedInt32Array()
		for column in ["N_ir", "E_ir", "S_ir", "W_ir"]:
			irrigation.append(1 if fields[idx[column]].strip_edges() == "1" else 0)
		var id := fields[idx["id"]].strip_edges()
		if id.is_empty() or not id.is_valid_identifier():
			push_warning("Skipping invalid tile id at row %d" % (index + 1))
			continue
		rows.append({
			"id": id,
			"edges": edges,
			"irrigation": irrigation,
			"center": _center_kind(fields[idx["center"]]),
		})
	return rows


func _build_spec(row: Dictionary) -> Dictionary:
	var edges: PackedInt32Array = row["edges"]
	var center := int(row["center"])
	var id := String(row["id"])
	if center < CENTER_EMPTY or center > CENTER_LAKE:
		return {}
	var edge_names: Array[String] = []
	var has_land := false
	var has_water := false
	var has_river := false
	for edge in edges:
		if edge < EMPTY or edge > RIVER:
			return {}
		edge_names.append(EDGE_NAMES[edge])
		has_land = has_land or edge == LAND
		has_water = has_water or edge == WATER
		has_river = has_river or edge == RIVER

	var regions := _land_regions(edges, center)
	var routes: Array = []
	if has_river:
		if not has_river or center != CENTER_RIVER or has_land:
			return {}
		for edge in range(4):
			if edges[edge] == RIVER or edges[edge] == WATER:
				routes.append({"from": EDGE_DIRECTIONS[edge], "via_hub": true})
	else:
		if center == CENTER_RIVER:
			return {}
		var water_count := 0
		for edge in edges:
			if edge == WATER:
				water_count += 1
		for edge in range(4):
			if edges[edge] != WATER:
				continue
			if regions.is_empty():
				routes.append({"from": EDGE_DIRECTIONS[edge], "via_hub": true})
			else:
				routes.append({
					"from": EDGE_DIRECTIONS[edge],
					"to_region": regions[0]["id"],
					"via_hub": water_count > 1,
				})

	var center_name := "none"
	match center:
		CENTER_LAKE:
			center_name = "lake"
		CENTER_RIVER:
			center_name = "river"
		_:
			if has_water and not has_land:
				center_name = "hub"
	return {
		"id": id,
		"display_name": "程序化：" + id,
		"seed": abs(id.hash()),
		"center": center_name,
		"river_width": RIVER_WIDTH,
		"edges": edge_names,
		"land_regions": regions,
		"water_routes": routes,
	}


func _land_regions(edges: PackedInt32Array, center: int) -> Array:
	var land_edges: Array = []
	for edge in range(4):
		if edges[edge] == LAND:
			land_edges.append(EDGE_DIRECTIONS[edge])
	if land_edges.is_empty():
		return []
	if center == CENTER_LAND or center == CENTER_LAKE:
		return [{"id": "region_0", "edges": land_edges}]
	var regions: Array = []
	for index in range(land_edges.size()):
		regions.append({"id": "region_%d" % index, "edges": [land_edges[index]]})
	return regions


func _edge_kind(token: String) -> int:
	var value := token.strip_edges()
	if not value.is_valid_int():
		return -1
	return clampi(int(value), EMPTY, RIVER)


func _center_kind(token: String) -> int:
	var value := token.strip_edges()
	return int(value) if value.is_valid_int() else -1


func _split_line(line: String) -> PackedStringArray:
	var out := PackedStringArray()
	for piece in line.split(","):
		out.append(String(piece).strip_edges())
	return out


func _write_json(path: String, spec: Dictionary) -> int:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(spec, "\t"))
	return OK


func _fail(message: String) -> void:
	push_error("GENERATE_GAME_TILES_FAIL: " + message)
	quit(1)
