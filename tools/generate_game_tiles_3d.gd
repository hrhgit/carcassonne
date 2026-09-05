extends SceneTree

# Batch driver: reads the playable CSV catalog, derives one procedural spec per
# distinct edge configuration, generates a fixed 3D prefab for each, and writes
# the generated prefab path back into the CSV's prefab_scene column.
# Usage: godot --headless --path . --script res://tools/generate_game_tiles_3d.gd

const GENERATOR := preload("res://scripts/tile_prefab_generator_3d.gd")
const CSV_PATH := "res://data/tiles_classic.csv"
const SPEC_DIR := "res://tools/tile_specs_3d"

const EMPTY := 0
const LAND := 1
const WATER := 2
const CENTER_LAKE := 2
const EDGE_NAMES := ["EMPTY", "LAND", "WATER", "RIVER", "BANK"]
const EDGE_LETTERS := ["n", "e", "s", "w"]


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var rows := _read_csv()
	if rows.is_empty():
		push_error("Could not read any tile rows from %s" % CSV_PATH)
		quit(1)
		return

	var prefab_by_config := {}
	for row in rows:
		var edges: PackedInt32Array = row["edges"]
		var land_subnets: Array = row["land_subnets"]
		var center: int = int(row["center"])
		var config_key := _config_key(edges, center)
		if prefab_by_config.has(config_key):
			continue
		var spec := _build_spec(config_key, edges, land_subnets, center)
		var json_path := "%s/%s.json" % [SPEC_DIR, spec["id"]]
		if _write_json(json_path, spec) != OK:
			push_error("Could not write spec %s" % json_path)
			quit(1)
			return
		var result: Dictionary = GENERATOR.build_from_spec_file(json_path)
		if not bool(result["ok"]):
			push_error("GENERATE_GAME_TILES_FAIL %s: %s" % [spec["id"], result["error"]])
			quit(1)
			return
		prefab_by_config[config_key] = result["scene_path"]
		print("GENERATED %s -> %s" % [spec["id"], result["scene_path"]])

	if _rewrite_csv(rows, prefab_by_config) != OK:
		push_error("Could not rewrite the CSV with generated prefab paths.")
		quit(1)
		return
	print("GENERATE_GAME_TILES_PASS: %d distinct prefabs generated and wired into the catalog." % prefab_by_config.size())
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
	for col in range(header.size()):
		idx[header[col]] = col

	var rows: Array = []
	for index in range(header_index + 1, lines.size()):
		var line := lines[index].strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var fields := _split_line(line)
		if fields.size() < header.size():
			continue
		var edges := PackedInt32Array()
		for col in ["N", "E", "S", "W"]:
			edges.append(_edge_kind(fields[idx[col]]))
		rows.append({
			"line_index": index,
			"raw_line": lines[index],
			"fields": fields,
			"idx": idx,
			"edges": edges,
			"land_subnets": _parse_subnets(fields[idx["land_subnets"]]),
			"center": _center_kind(fields[idx["center"]]),
		})
	return rows


func _build_spec(config_key: String, edges: PackedInt32Array, land_subnets: Array, center: int) -> Dictionary:
	var spec_id := _spec_id(edges, center)
	var edge_names := PackedStringArray()
	for edge in edges:
		edge_names.append(EDGE_NAMES[edge])

	var regions: Array = []
	for subnet_index in range(land_subnets.size()):
		var region_edges: Array = []
		for edge in range(4):
			if int(land_subnets[subnet_index]) & (1 << edge):
				region_edges.append(_edge_name(edge))
		if not region_edges.is_empty():
			regions.append({"id": "region_%d" % subnet_index, "edges": region_edges})

	var has_land := false
	var has_water := false
	for edge in edges:
		if edge == LAND:
			has_land = true
		elif edge == WATER:
			has_water = true

	var routes: Array = []
	var center_name := "none"
	if center == CENTER_LAKE and not has_land and not has_water:
		center_name = "lake"
	elif has_water and not has_land:
		center_name = "hub"
		for edge in range(4):
			if edges[edge] == WATER:
				routes.append({"from": _edge_name(edge), "via_hub": true})
	else:
		var water_edge_count := 0
		for edge in range(4):
			if edges[edge] == WATER:
				water_edge_count += 1
		for edge in range(4):
			if edges[edge] != WATER:
				continue
			var route := {"from": _edge_name(edge), "to_region": regions[0]["id"], "via_hub": water_edge_count > 1}
			routes.append(route)

	return {
		"id": spec_id,
		"display_name": "程序化：" + spec_id,
		"seed": 20260905 + edges[0] * 1000 + edges[1] * 100 + edges[2] * 10 + edges[3],
		"center": center_name,
		"edges": Array(edge_names),
		"land_regions": regions,
		"water_routes": routes,
	}


func _config_key(edges: PackedInt32Array, center: int) -> String:
	# Centre lake is the only all-EMPTY feature, so include it; centre LAND
	# shares the same full-land prefab as a four-LAND-edge tile.
	if int(center) == CENTER_LAKE:
		return "lake"
	return "%d,%d,%d,%d" % [edges[0], edges[1], edges[2], edges[3]]


func _spec_id(edges: PackedInt32Array, center: int) -> String:
	if int(center) == CENTER_LAKE:
		return "lake"
	var land_edges: Array = []
	var water_edges: Array = []
	for edge in range(4):
		if edges[edge] == LAND:
			land_edges.append(edge)
		elif edges[edge] == WATER:
			water_edges.append(edge)
	if land_edges.size() == 4:
		return "land_four"
	if land_edges.is_empty() and not water_edges.is_empty():
		return "water_" + _edge_letters(water_edges)
	var parts: Array = []
	if not land_edges.is_empty():
		parts.append("land_" + _edge_letters(land_edges))
	if not water_edges.is_empty():
		parts.append("water_" + _edge_letters(water_edges))
	return "_".join(parts)


func _edge_letters(edge_indices: Array) -> String:
	var out := ""
	for edge in edge_indices:
		out += EDGE_LETTERS[int(edge)]
	return out


func _edge_name(edge: int) -> String:
	return ["NORTH", "EAST", "SOUTH", "WEST"][edge]


func _parse_subnets(raw: String) -> Array:
	var out: Array = []
	if raw.strip_edges().is_empty():
		return out
	for group in raw.split(";"):
		var token := String(group).strip_edges()
		if token.is_valid_int() and int(token) != 0:
			out.append(int(token))
	return out


func _edge_kind(token: String) -> int:
	var s := token.strip_edges()
	if s.is_valid_int():
		return clampi(int(s), EMPTY, WATER)
	match s.to_upper():
		"LAND":
			return LAND
		"WATER":
			return WATER
	return EMPTY


func _center_kind(token: String) -> int:
	var s := token.strip_edges()
	if s.is_valid_int():
		return int(s)
	match s.to_upper():
		"LAND":
			return 1
		"LAKE":
			return 2
	return 0


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


func _rewrite_csv(rows: Array, prefab_by_config: Dictionary) -> int:
	var prefab_by_row := {}
	for row in rows:
		var config_key := _config_key(row["edges"], row["center"])
		prefab_by_row[row["line_index"]] = prefab_by_config[config_key]

	if not FileAccess.file_exists(CSV_PATH):
		return ERR_FILE_NOT_FOUND
	var file := FileAccess.open(CSV_PATH, FileAccess.READ)
	if file == null:
		return FileAccess.get_open_error()
	var lines: Array[String] = []
	while not file.eof_reached():
		lines.append(file.get_line())
	file = null

	for row in rows:
		var fields: PackedStringArray = row["fields"]
		var idx: Dictionary = row["idx"]
		var scene_col := int(idx["prefab_scene"])
		var rot_col := int(idx["prefab_rotation"])
		fields[scene_col] = prefab_by_row[row["line_index"]]
		fields[rot_col] = "0"
		lines[row["line_index"]] = ",".join(Array(fields))

	var out := FileAccess.open(CSV_PATH, FileAccess.WRITE)
	if out == null:
		return FileAccess.get_open_error()
	for line in lines:
		out.store_line(line)
	return OK
