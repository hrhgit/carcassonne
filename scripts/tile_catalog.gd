class_name TileCatalog
extends Node2D

const TILE_DEFINITION_SCRIPT := preload("res://scripts/tile_definition.gd")
const TILES_CSV_PATH := "res://data/tiles_classic.csv"

const EMPTY := TileDefinition.EdgeKind.EMPTY
const LAND := TileDefinition.EdgeKind.LAND
const WATER := TileDefinition.EdgeKind.WATER
const RIVER := TileDefinition.EdgeKind.RIVER
const BANK := TileDefinition.EdgeKind.BANK

const CENTER_EMPTY := TileDefinition.CenterKind.EMPTY
const CENTER_LAND := TileDefinition.CenterKind.LAND
const CENTER_LAKE := TileDefinition.CenterKind.LAKE
const CENTER_RIVER := TileDefinition.CenterKind.RIVER

# 缓存解析后的所有定义（去重：同 id 只构造一次）
var _definitions: Dictionary = {}
var _starter_id: StringName = &""


func _ready() -> void:
	# 启动时即加载一次，方便调试时从外部直接访问
	_load_from_csv()


func starter_tile() -> TileDefinition:
	if _starter_id != &"":
		return _definitions.get(_starter_id, _fallback_starter())
	# 没指定 starter id 时，取 CSV 中第一条 card_type=starter 的记录
	for def_id in _definitions.keys():
		var def: TileDefinition = _definitions[def_id]
		if def.card_type == "starter":
			return def
	return _fallback_starter()


func build_deck(card_type := "tile") -> Array[TileDefinition]:
	# 按 count 展开成实际牌堆数组
	var deck: Array[TileDefinition] = []
	for def_id in _definitions.keys():
		var def: TileDefinition = _definitions[def_id]
		if def.card_type != card_type:
			continue
		for _i in range(def.count):
			deck.append(def)
	return deck


func river_setup_deck() -> Array[TileDefinition]:
	return build_deck("river")


func has_definition(id: StringName) -> bool:
	return _definitions.has(id)


func get_definition(id: StringName) -> TileDefinition:
	return _definitions.get(id, null)


func all_definitions() -> Array[TileDefinition]:
	var list: Array[TileDefinition] = []
	for def_id in _definitions.keys():
		list.append(_definitions[def_id])
	return list


# === CSV 加载 ===

func _load_from_csv() -> void:
	_definitions.clear()
	if not FileAccess.file_exists(TILES_CSV_PATH):
		push_error("Tile CSV missing: %s" % TILES_CSV_PATH)
		return
	var file := FileAccess.open(TILES_CSV_PATH, FileAccess.READ)
	if file == null:
		push_error("Cannot open %s (err %d)" % [TILES_CSV_PATH, FileAccess.get_open_error()])
		return

	var header_line := file.get_line()
	var headers := _parse_csv_line(header_line)
	var column_index := _index_columns(headers)

	var line_number := 1
	while not file.eof_reached():
		var line := file.get_line()
		line_number += 1
		if line.strip_edges().is_empty() or line.begins_with("#"):
			continue
		var fields := _parse_csv_line(line)
		if fields.size() < headers.size():
			push_warning("Skipping short row %d: %s" % [line_number, line])
			continue
		var def := _build_definition_from_row(fields, column_index)
		if def == null:
			continue
		if _definitions.has(def.id):
			push_warning("Duplicate tile id %s in CSV; keeping the first one." % def.id)
			continue
		_definitions[def.id] = def
		if def.card_type == "starter":
			_starter_id = def.id


func _build_definition_from_row(fields: PackedStringArray, idx: Dictionary) -> TileDefinition:
	var def := TILE_DEFINITION_SCRIPT.new()
	var id := StringName(fields[idx["id"]])
	var name := fields[idx["display_name"]]
	var card_type := fields[idx["card_type"]]
	var count := int(fields[idx["count"]])
	var edges := _parse_edge_list(fields, idx)
	var ir_edges := _parse_ir_list(fields, idx)
	var center := _parse_center(fields[idx["center"]])
	var is_river_tile := fields[idx["is_river_tile"]] == "1"
	var visual_seed := int(fields[idx["visual_seed"]])
	var prefab_rotation := int(fields[idx["prefab_rotation"]])
	var initial_growth := fields[idx["initial_growth"]] == "1"
	var notes := fields[idx["notes"]]

	# 内部连通性：CSV 用 N/E/S/W 字母串表示一个或多个子网（多个子网用逗号分隔）；
	# 例如 "NESW" 表示一个含全部四条边的子网，"W,N" 表示两个独立子网。
	var water_subnets := _parse_subnet_letters(fields, idx, "water_subnets")
	var land_subnets := _parse_subnet_letters(fields, idx, "land_subnets")

	var scene_path := fields[idx["prefab_scene"]]
	var scene: PackedScene = null
	if scene_path != "":
		if ResourceLoader.exists(scene_path):
			scene = load(scene_path)
		else:
			push_warning("Tile %s references missing scene %s; rendering placeholder." % [id, scene_path])

	# 当提供了美术 prefab 时验证边标记是否匹配（保留原有保护逻辑）
	if scene != null:
		var matches := _prefab_matches_rule(scene, edges, prefab_rotation)
		if not matches:
			push_warning("Tile %s: prefab edge markers do not match rule edges; using placeholder rendering." % id)
			scene = null

	def.configure(
		id,
		name,
		card_type,
		count,
		edges,
		ir_edges,
		center,
		is_river_tile,
		initial_growth,
		visual_seed,
		PackedInt32Array(),
		scene,
		prefab_rotation,
		notes,
		water_subnets,
		land_subnets,
	)

	if not def.is_playable():
		push_error("Tile %s is not playable; check CSV row." % id)
		return null
	return def


func _index_columns(headers: PackedStringArray) -> Dictionary:
	var idx := {}
	for i in range(headers.size()):
		idx[headers[i]] = i
	# 必要列缺失即报错
	var required := ["id", "display_name", "card_type", "count",
		"N", "E", "S", "W", "N_ir", "E_ir", "S_ir", "W_ir",
		"center", "is_river_tile", "prefab_scene", "prefab_rotation",
		"visual_seed", "initial_growth", "notes",
		"water_subnets", "land_subnets"]
	for col in required:
		if not idx.has(col):
			push_error("CSV missing required column '%s'" % col)
	return idx


func _parse_csv_line(line: String) -> PackedStringArray:
	# 简单 CSV 解析：逗号分隔，不支持引号转义（本数据无逗号冲突）
	var out := PackedStringArray()
	for piece in line.split(","):
		out.append(String(piece).strip_edges())
	return out


func _parse_edge_list(fields: PackedStringArray, idx: Dictionary) -> PackedInt32Array:
	var edges := PackedInt32Array()
	for col in ["N", "E", "S", "W"]:
		var name := fields[idx[col]]
		var kind := _parse_edge_kind(name)
		if kind < 0:
			push_error("Unknown edge kind %s in column %s" % [name, col])
			return PackedInt32Array([EMPTY, EMPTY, EMPTY, EMPTY])
		edges.append(kind)
	return edges


func _parse_ir_list(fields: PackedStringArray, idx: Dictionary) -> PackedInt32Array:
	var ir := PackedInt32Array()
	for col in ["N_ir", "E_ir", "S_ir", "W_ir"]:
		var v := int(fields[idx[col]])
		ir.append(1 if v == 1 else 0)
	return ir


func _parse_edge_kind(name: String) -> int:
	match name:
		"EMPTY": return EMPTY
		"LAND":  return LAND
		"WATER": return WATER
		"RIVER": return RIVER
		"BANK":  return BANK
	return -1


func _parse_center(name: String) -> int:
	match name:
		"EMPTY": return CENTER_EMPTY
		"LAND":  return CENTER_LAND
		"LAKE":  return CENTER_LAKE
		"RIVER": return CENTER_RIVER
	return CENTER_EMPTY


# 把 CSV 中"用 N/E/S/W 字母表示一个子网、; 分隔多子网"的字段解析为位掩码数组。
# 例: "NESW" -> [15]; "W;N" -> [8, 1]; "" -> []
# 注意：用 ; 分隔多子网，避免与 CSV 字段分隔符 , 冲突。
func _parse_subnet_letters(fields: PackedStringArray, idx: Dictionary, col: String) -> Array:
	if not idx.has(col):
		return []
	var raw := fields[idx[col]].strip_edges()
	if raw.is_empty():
		return []
	var out: Array = []
	# 支持多子网（; 分隔）
	for group in raw.split(";"):
		var letters := String(group).strip_edges()
		if letters.is_empty():
			continue
		var mask := 0
		for ch in letters:
			var upper := String(ch).to_upper()
			match upper:
				"N": mask |= TileDefinition.edge_bitmask(TileDefinition.Edge.NORTH)
				"E": mask |= TileDefinition.edge_bitmask(TileDefinition.Edge.EAST)
				"S": mask |= TileDefinition.edge_bitmask(TileDefinition.Edge.SOUTH)
				"W": mask |= TileDefinition.edge_bitmask(TileDefinition.Edge.WEST)
				_:
					push_warning("Unknown edge letter '%s' in %s column; ignored." % [ch, col])
		if mask != 0:
			out.append(mask)
	return out


func _prefab_matches_rule(visual_scene: PackedScene, edges: PackedInt32Array, visual_rotation_quarters: int) -> bool:
	if visual_scene == null:
		return false
	var artwork := visual_scene.instantiate()
	if not artwork.has_method("edge_marker_at"):
		artwork.free()
		return false

	var matches := true
	for edge in range(4):
		if int(artwork.call("edge_marker_at", edge, visual_rotation_quarters)) != edges[edge]:
			matches = false
			break
	artwork.free()
	return matches


func _fallback_starter() -> TileDefinition:
	# 极端兜底：CSV 缺失或没 starter 行时返回一个最小可玩定义
	var def := TILE_DEFINITION_SCRIPT.new()
	def.configure(
		&"_fallback_starter",
		"默认起手",
		"starter",
		1,
		PackedInt32Array([LAND, LAND, LAND, LAND]),
		PackedInt32Array([0, 0, 0, 0]),
		CENTER_EMPTY,
		false,
		false,
		0,
		PackedInt32Array(),
		null,
		0,
		"",
	)
	return def