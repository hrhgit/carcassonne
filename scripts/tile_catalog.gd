class_name TileCatalog
extends Node

const TILE_DEFINITION_SCRIPT := preload("res://scripts/tile_definition.gd")
const TILES_CSV_PATH := "res://data/tiles.csv"
const GENERATED_PREFAB_TEMPLATE := "res://scenes/tiles_3d/generated/procedural_%s.tscn"

const EMPTY := TileDefinition.EdgeKind.EMPTY
const LAND := TileDefinition.EdgeKind.LAND
const WATER := TileDefinition.EdgeKind.WATER
const RIVER := TileDefinition.EdgeKind.RIVER

const CENTER_EMPTY := TileDefinition.CenterKind.EMPTY
const CENTER_LAND := TileDefinition.CenterKind.LAND
const CENTER_RIVER := TileDefinition.CenterKind.RIVER
const REQUIRED_COLUMNS := ["id", "display_name", "card_type", "count",
	"N", "E", "S", "W", "N_ir", "E_ir", "S_ir", "W_ir", "center"]

# 缓存解析后的所有定义（去重：同 id 只构造一次）
var _definitions: Dictionary = {}
var _definition_ids: Array[StringName] = []
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
		if def.card_type == TileDefinition.CARD_STARTER:
			return def
	return _fallback_starter()


func build_deck(card_type: int = TileDefinition.CARD_TILE) -> Array[TileDefinition]:
	# 按 count 展开成实际牌堆数组，保留表内顺序供配置检查和确定性测试使用。
	var deck: Array[TileDefinition] = []
	for def_id in _definition_ids:
		var def: TileDefinition = _definitions[def_id]
		if def.card_type != card_type:
			continue
		for _i in range(def.count):
			deck.append(def)
	return deck


func build_shuffled_deck(
	card_type: int = TileDefinition.CARD_TILE,
	random_source: RandomNumberGenerator = null,
) -> Array[TileDefinition]:
	var deck := build_deck(card_type)
	_shuffle_in_place(deck, random_source)
	return deck


# 开局河头是棋盘上的 starter_river；河流牌堆只洗中段，表中唯一的
# river_setup_terminal 始终留在末尾，作为与河头同款的河尾。
func river_setup_deck(random_source: RandomNumberGenerator = null) -> Array[TileDefinition]:
	var middle: Array[TileDefinition] = []
	var terminals: Array[TileDefinition] = []
	for definition in build_deck(TileDefinition.CARD_RIVER):
		if definition.river_setup_terminal:
			terminals.append(definition)
		else:
			middle.append(definition)
	if terminals.size() != 1:
		push_error("River setup deck requires exactly one river_setup_terminal, found %d." % terminals.size())
		return []
	_shuffle_in_place(middle, random_source)
	middle.append(terminals[0])
	return middle


func _shuffle_in_place(deck: Array[TileDefinition], random_source: RandomNumberGenerator = null) -> void:
	var rng := random_source
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	for index in range(deck.size() - 1, 0, -1):
		var swap_index := rng.randi_range(0, index)
		var held := deck[index]
		deck[index] = deck[swap_index]
		deck[swap_index] = held


func has_definition(id: StringName) -> bool:
	return _definitions.has(id)


func get_definition(id: StringName) -> TileDefinition:
	return _definitions.get(id, null)


func all_definitions() -> Array[TileDefinition]:
	var list: Array[TileDefinition] = []
	for def_id in _definition_ids:
		list.append(_definitions[def_id])
	return list


# === CSV 加载 ===

func _load_from_csv() -> void:
	_definitions.clear()
	_definition_ids.clear()
	_starter_id = &""
	var csv_path := TILES_CSV_PATH
	if not FileAccess.file_exists(csv_path):
		# CSV Translation imports intentionally omit their source text from a PCK.
		# Keep exported builds self-contained by accepting the raw table next to the
		# executable; editor runs continue to use the canonical res:// path.
		var external_csv_path := OS.get_executable_path().get_base_dir().path_join("data/tiles.csv")
		if FileAccess.file_exists(external_csv_path):
			csv_path = external_csv_path
	if not FileAccess.file_exists(csv_path):
		push_error("Tile CSV missing: %s" % TILES_CSV_PATH)
		return
	var file := FileAccess.open(csv_path, FileAccess.READ)
	if file == null:
		push_error("Cannot open %s (err %d)" % [csv_path, FileAccess.get_open_error()])
		return

	var header_line := ""
	var line_number := 1
	# 跳过顶部注释行（# 开头），找到首条数据 header
	while not file.eof_reached():
		header_line = file.get_line()
		# 兼容带 UTF-8 BOM 的文件（Excel 友好）：去掉首行 BOM 再判注释
		if header_line.begins_with(String.chr(0xFEFF)):
			header_line = header_line.substr(1)
		line_number += 1
		if header_line.strip_edges().is_empty():
			continue
		if not header_line.begins_with("#"):
			break
	var headers := _parse_csv_line(header_line)
	var column_index := _index_columns(headers)
	if column_index.is_empty():
		return
	var required_field_count := _required_field_count(column_index)

	while not file.eof_reached():
		var line := file.get_line()
		line_number += 1
		if line.strip_edges().is_empty() or line.begins_with("#"):
			continue
		var fields := _parse_csv_line(line)
		if fields.size() < required_field_count:
			push_warning("Skipping short row %d: %s" % [line_number, line])
			continue
		var def := _build_definition_from_row(fields, column_index)
		if def == null:
			continue
		if _definitions.has(def.id):
			push_warning("Duplicate tile id %s in CSV; keeping the first one." % def.id)
			continue
		_definitions[def.id] = def
		_definition_ids.append(def.id)
		if def.card_type == TileDefinition.CARD_STARTER:
			_starter_id = def.id


func _build_definition_from_row(fields: PackedStringArray, idx: Dictionary) -> TileDefinition:
	var def := TILE_DEFINITION_SCRIPT.new()
	var id := StringName(fields[idx["id"]])
	var name := fields[idx["display_name"]]
	var card_type := _parse_card_type(fields[idx["card_type"]])
	var count := int(fields[idx["count"]])
	var edges := _parse_edge_list(fields, idx)
	var ir_edges := _parse_ir_list(fields, idx)
	var center := _parse_center(fields[idx["center"]])
	var is_river_tile := _field(fields, idx, "is_river_tile") == "1" \
		or card_type == TileDefinition.CARD_RIVER or center == CENTER_RIVER
	var visual_seed := int(_field(fields, idx, "visual_seed", str(abs(String(id).hash()))))
	var prefab_rotation := int(_field(fields, idx, "prefab_rotation", "0"))
	var initial_growth := _field(fields, idx, "initial_growth", "0") == "1"
	var notes := _field(fields, idx, "notes", "新卡牌表生成定义")
	var river_setup_terminal := _field(fields, idx, "river_setup_terminal", "0") == "1"

	# 内部连通性：CSV 用整数位掩码表示一个子网，多个子网用 ; 分隔。
	# 位分配：bit0=N bit1=E bit2=S bit3=W；例如 15=NESW 一个子网；"1;2" = N+E 两个独立子网。
	var water_subnets := _parse_subnet_mask(fields, idx, "water_subnets")
	var land_subnets := _parse_subnet_mask(fields, idx, "land_subnets")
	if water_subnets.is_empty():
		water_subnets = _derived_subnets(edges, WATER, true)
	if land_subnets.is_empty():
		land_subnets = _derived_subnets(edges, LAND, center == CENTER_LAND)

	var scene_path := _field(fields, idx, "prefab_scene")
	if scene_path.is_empty():
		scene_path = GENERATED_PREFAB_TEMPLATE % id
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
		river_setup_terminal,
	)

	if not def.is_playable():
		push_error("Tile %s is not playable; check CSV row." % id)
		return null
	return def


func _index_columns(headers: PackedStringArray) -> Dictionary:
	var idx := {}
	for i in range(headers.size()):
		idx[headers[i]] = i
	# 新卡牌表是紧凑规则表；其余可视化和连通性字段由固定的生成物及
	# 这里的确定性默认值补齐。扩展列仍可按旧格式显式覆盖。
	for col in REQUIRED_COLUMNS:
		if not idx.has(col):
			push_error("CSV missing required column '%s'" % col)
			return {}
	return idx


func _required_field_count(idx: Dictionary) -> int:
	var count := 0
	for col in REQUIRED_COLUMNS:
		count = maxi(count, int(idx[col]) + 1)
	return count


func _parse_csv_line(line: String) -> PackedStringArray:
	# 简单 CSV 解析：逗号分隔，不支持引号转义（本数据无逗号冲突）
	var out := PackedStringArray()
	for piece in line.split(","):
		out.append(String(piece).strip_edges())
	return out


func _field(fields: PackedStringArray, idx: Dictionary, column: String, fallback := "") -> String:
	if not idx.has(column):
		return fallback
	var field_index := int(idx[column])
	if field_index < 0 or field_index >= fields.size():
		return fallback
	var value := fields[field_index].strip_edges()
	return value if not value.is_empty() else fallback


func _derived_subnets(edges: PackedInt32Array, kind: int, merge_all: bool) -> Array:
	var mask := 0
	for edge in range(4):
		if edges[edge] == kind:
			mask |= 1 << edge
	if mask == 0:
		return []
	if merge_all:
		return [mask]
	var subnets: Array = []
	for edge in range(4):
		var bit := 1 << edge
		if (mask & bit) != 0:
			subnets.append(bit)
	return subnets


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


# 把 CSV 字符串解析为 EdgeKind。主路径：纯数字；兜底：英文 ENUM 名。
func _parse_edge_kind(token: String) -> int:
	var s := token.strip_edges()
	if s.is_valid_int():
		var v := int(s)
		if v >= 0 and v < TileDefinition.EDGE_KIND_NAMES.size():
			return v
	match s.to_upper():
		"EMPTY": return EMPTY
		"LAND":  return LAND
		"WATER": return WATER
		"RIVER": return RIVER
	return -1


# 把 CSV 字符串解析为 CenterKind。主路径：纯数字；兜底：英文 ENUM 名。
func _parse_center(token: String) -> int:
	var s := token.strip_edges()
	if s.is_valid_int():
		var v := int(s)
		if v >= 0 and v < TileDefinition.CENTER_KIND_NAMES.size():
			return v
	match s.to_upper():
		"EMPTY": return CENTER_EMPTY
		"LAND":  return CENTER_LAND
		"RIVER": return CENTER_RIVER
	return CENTER_EMPTY


# 把 CSV 字符串解析为 card_type（int）。主路径：纯数字；兜底：英文 slug。
func _parse_card_type(token: String) -> int:
	var s := token.strip_edges()
	if s.is_valid_int():
		return int(s)
	match s.to_lower():
		"starter": return TileDefinition.CARD_STARTER
		"tile":    return TileDefinition.CARD_TILE
		"river":   return TileDefinition.CARD_RIVER
	return TileDefinition.CARD_TILE


# 把 CSV 中"用整数位掩码表示一个子网，; 分隔多子网"的字段解析为位掩码数组。
# 例: "15" -> [15]；"8;1" -> [8, 1]；"" -> []
# 位分配：N=1 E=2 S=4 W=8。
func _parse_subnet_mask(fields: PackedStringArray, idx: Dictionary, col: String) -> Array:
	if not idx.has(col):
		return []
	var raw := fields[idx[col]].strip_edges()
	if raw.is_empty():
		return []
	var out: Array = []
	for group in raw.split(";"):
		var s := String(group).strip_edges()
		if s.is_empty():
			continue
		if not s.is_valid_int():
			push_warning("Non-integer subnet '%s' in %s column; ignored." % [group, col])
			continue
		var mask := int(s)
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
		TileDefinition.CARD_STARTER,
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
