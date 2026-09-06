extends Node3D
# 独立截图场景：不依赖 main.gd（当前 main.gd 有未提交改动导致的编译错误）。
# 用 TileCatalog + BoardState 摆几张有土地的地块并种上草/花/树，俯视截图。
# 运行：godot --path . -- res://scenes/capture_scene.tscn --write-movie 不行；直接用：
#   godot --path . -- res://scenes/capture_scene.tscn
# 场景会自摆牌、自截图到 artifacts/ 后自动退出。

const BOARD_STATE_SCRIPT := preload("res://scripts/board_state.gd")
const PLANT_ENGINE_SCRIPT := preload("res://scripts/plant_engine.gd")
const PLANT_SCRIPT := preload("res://scripts/plant.gd")
const RUNTIME_PLANT_SCATTER_SCRIPT := preload("res://scripts/runtime_plant_scatter_3d.gd")
const TILE_ARTWORK_SCRIPT := preload("res://scripts/tile_artwork_3d.gd")

const TILE_SIZE := 4.9
const PLAYER_COLORS := [Color("#7ecf91"), Color("#ed9b70")]

const CAPTURE_PATH := "res://artifacts/gameplay_screenshot.png"
const CAPTURE_SIZE := Vector2i(1280, 820)

@onready var tile_catalog: Node = $TileCatalog
@onready var board_root: Node3D = $Board
@onready var camera: Camera3D = $Camera3D

var board_state
var placed_tile_nodes: Dictionary = {}   # cell -> Node3D


func _ready() -> void:
	board_state = BOARD_STATE_SCRIPT.new()
	# 用一块四边全土地的地块作起点，保证画面一开始就是可种植土地。
	var starter: TileDefinition = _find_definition(&"land_four_edges")
	if starter == null:
		starter = tile_catalog.starter_tile()
	board_state.start_with(starter, 2)
	_add_tile_visual(Vector2i.ZERO)
	_build_scene_and_plant()
	# 等一帧让所有节点就绪后再截图
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	_capture()
	get_tree().quit()


func _find_definition(id: StringName) -> TileDefinition:
	var def: TileDefinition = tile_catalog.get_definition(id)
	return def


# 复刻 main.gd 的 _add_placed_tile_visual 核心（实例化预制件 + 布置运行时植物层）。
func _add_tile_visual(cell: Vector2i) -> void:
	var placement: Dictionary = board_state.get_placement(cell)
	var definition: TileDefinition = placement["definition"]
	var rotation: int = int(placement["rotation"])
	var piece: Node3D = definition.visual_scene.instantiate() as Node3D
	if piece == null:
		push_error("Tile %s has no instantiable prefab." % definition.id)
		return
	piece.position = _cell_world_position(cell)
	piece.rotation.y = -float(definition.visual_rotation_quarters + rotation) * PI * 0.5
	board_root.add_child(piece)
	if piece is TILE_ARTWORK_SCRIPT:
		var artwork := piece
		var plant_seed := RUNTIME_PLANT_SCATTER_SCRIPT.seed_for_tile(definition.visual_seed, cell)
		artwork.set_runtime_plant_layout(
			RUNTIME_PLANT_SCATTER_SCRIPT.generate_for_tile(artwork, plant_seed)
		)
		artwork.set_runtime_plant_states({})
		artwork.set_growth_state(TILE_ARTWORK_SCRIPT.GrowthState.BARE)
	else:
		piece.call("set_growth_state", 0)
	placed_tile_nodes[cell] = piece


# 复刻 main.gd 的 _refresh_tile_growth：把 board_state 的植物映射到预制件显示。
func _refresh_tile_growth(cell: Vector2i) -> void:
	if not placed_tile_nodes.has(cell):
		return
	var tile: Node3D = placed_tile_nodes[cell]
	var plants: Array = board_state.list_plants_in_tile(cell)
	if plants.is_empty():
		if tile.has_method("set_runtime_plant_states"):
			tile.call("set_runtime_plant_states", {})
		tile.call("set_growth_state", 0)
		return
	var runtime_states: Dictionary = {}
	for p in plants:
		runtime_states[int(p.species)] = {
			"growth_state": TILE_ARTWORK_SCRIPT.GrowthState.GROWING,
			"owner_color": _player_color(int(p.owner)),
		}
	if tile.has_method("has_runtime_plant_layout") and bool(tile.call("has_runtime_plant_layout")):
		tile.call("set_runtime_plant_states", runtime_states)
		tile.call("set_growth_state", TILE_ARTWORK_SCRIPT.GrowthState.GROWING)
		return
	tile.call("set_growth_state", 1)
	var color := _player_color(int(plants[0].owner))
	for plant_node in tile.find_children("*", "SowablePlant3D", true, false):
		plant_node.call("set_owner_color", color)


func _player_color(player_id: int) -> Color:
	return PLAYER_COLORS[player_id % PLAYER_COLORS.size()]


func _cell_world_position(cell: Vector2i) -> Vector3:
	return Vector3(float(cell.x) * TILE_SIZE, 0.0, float(cell.y) * TILE_SIZE)


# 找第一个合法放置（复刻 main.gd 的 _find_first_visible_legal_move）。
func _find_first_legal_move() -> Dictionary:
	if board_state.tile_to_place == null or int(board_state.phase) != BoardState.Phase.PLACE:
		return {}
	var visited: Dictionary = {}
	var queue: Array[Vector2i] = []
	for c in board_state.placements.keys():
		queue.append(c)
		visited[c] = true
	var offsets: Array[Vector2i] = [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]
	var safety := 0
	while not queue.is_empty() and safety < 4096:
		safety += 1
		var cell: Vector2i = queue.pop_front()
		for off in offsets:
			var n_cell := cell + off
			if visited.has(n_cell):
				continue
			visited[n_cell] = true
			for rotation in range(4):
				if bool(board_state.can_place(board_state.tile_to_place, n_cell, rotation)["valid"]):
					return {"cell": n_cell, "rotation": rotation}
			if abs(n_cell.x) + abs(n_cell.y) > 24:
				continue
			queue.append(n_cell)
	return {}


# 摆牌 + 种植：依次抽几张土地地块，各放一张、各种一棵（草/花/树轮换，两家颜色交替）。
func _build_scene_and_plant() -> void:
	var land_defs: Array[StringName] = [
		&"land_adjacent_edges",     # NE 土地
		&"land_opposite_edges",     # NS 土地
		&"land_three_edges",        # NES 土地
		&"land_single_edge",        # N 土地
		&"land_adjacent_edges_split",
		&"land_opposite_edges_split",
	]
	var species_cycle := [
		PLANT_SCRIPT.Species.TREE,
		PLANT_SCRIPT.Species.FLOWER,
		PLANT_SCRIPT.Species.GRASS,
	]
	for i in range(6):
		var def_id: StringName = land_defs[i]
		var def: TileDefinition = _find_definition(def_id)
		if def == null:
			continue
		if int(board_state.phase) == BoardState.Phase.DEAL:
			var deal: Dictionary = board_state.deal_tile(def)
			if not bool(deal["valid"]):
				continue
		if int(board_state.phase) != BoardState.Phase.PLACE or board_state.tile_to_place == null:
			break
		var move := _find_first_legal_move()
		if move.is_empty():
			# 这张摆不下，结束回合换下一张
			board_state.finish_action_window(PLANT_ENGINE_SCRIPT, false)
			continue
		var cell: Vector2i = move["cell"]
		var rot: int = int(move["rotation"])
		board_state.commit_placement(cell, rot)
		_add_tile_visual(cell)
		# 放置后进入 ACTION_WINDOW，尝试在刚放的地块上种一棵植物。
		if int(board_state.phase) == BoardState.Phase.ACTION_WINDOW:
			var owner: int = board_state.active_player
			var species: int = species_cycle[i % species_cycle.size()]
			var check: Dictionary = board_state.can_plant_at(cell, species, owner)
			if bool(check["valid"]):
				var pr: Dictionary = board_state.plant(cell, species, owner)
				if bool(pr["valid"]):
					_refresh_tile_growth(cell)
		board_state.finish_action_window(PLANT_ENGINE_SCRIPT, false)
	# 刷新所有地块的植物显示（含自动扩张到相邻格的情况）。
	for cell in placed_tile_nodes.keys():
		_refresh_tile_growth(cell)
	# 相机对准棋盘中心
	_center_camera_on(_board_center())


func _board_center() -> Vector2i:
	if board_state.placements.is_empty():
		return Vector2i.ZERO
	var sum := Vector2i.ZERO
	for cell in board_state.placements.keys():
		sum += cell
	return Vector2i(roundi(float(sum.x) / board_state.placements.size()),
		roundi(float(sum.y) / board_state.placements.size()))


func _center_camera_on(cell: Vector2i) -> void:
	var target := _cell_world_position(cell)
	var elevation := deg_to_rad(55.0)
	var azimuth := deg_to_rad(37.0)
	var distance := 17.0
	var horizontal := distance * cos(elevation)
	camera.position = target + Vector3(
		horizontal * sin(azimuth),
		distance * sin(elevation),
		horizontal * cos(azimuth),
	)
	camera.look_at(target, Vector3.UP)


func _capture() -> void:
	var directory := ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(directory)
	var texture := get_viewport().get_texture()
	if texture == null:
		push_error("Capture requires a rendering viewport (not headless).")
		get_tree().quit(1)
		return
	var image := texture.get_image()
	if image == null:
		push_error("Capture could not read viewport image.")
		get_tree().quit(1)
		return
	image.save_png(directory.path_join("gameplay_screenshot.png"))
	print("CAPTURE_SCENE_PASS: saved %s (%dx%d)" % [
		directory.path_join("gameplay_screenshot.png"), image.get_width(), image.get_height(),
	])
