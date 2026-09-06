extends Node3D

const BOARD_STATE_SCRIPT := preload("res://scripts/board_state.gd")
const UI_FONT_SCRIPT := preload("res://scripts/ui_font.gd")
const PLANT_ENGINE_SCRIPT := preload("res://scripts/plant_engine.gd")
const PLANT_SCRIPT := preload("res://scripts/plant.gd")
const RUNTIME_PLANT_SCATTER_SCRIPT := preload("res://scripts/runtime_plant_scatter_3d.gd")
const WATER_NETWORK_RENDERER_SCRIPT := preload("res://scripts/water_network_renderer_3d.gd")

const GAME_SMOKE_ARGUMENT := "--game-smoke"
const CAPTURE_ARGUMENT := "--capture-game"

# One grid cell spans one fixed 3D tile (4.9 world units). NORTH faces -Z,
# EAST +X, SOUTH +Z, WEST -X, matching the authored prefab edge order.
const TILE_SIZE := 4.9
const HIGHLIGHT_Y := 0.17

const PLAYER_COLORS := [Color("#7ecf91"), Color("#ed9b70")]

# 相机参数（俯视桌面 diorama 风格）
const CAMERA_ELEVATION := deg_to_rad(55.0)
const CAMERA_AZIMUTH := deg_to_rad(37.0)
const CAMERA_DISTANCE := 17.0
const CAMERA_DISTANCE_MIN := 8.0
const CAMERA_DISTANCE_MAX := 32.0
const CAMERA_PAN_STEP := 4.9
const CAMERA_ZOOM_STEP := 1.2

# 平移参数：logical 像素 = cell.x * CELL_SIZE
const PAN_KEY_STEP := 78.0 * 3.0
const PAN_WHEEL_STEP := 78.0 * 1.5
const PAN_LERP := 14.0
const SEARCH_RADIUS := 24

# §7 三个阶段按钮
enum MenuMode { NONE, PLANT, EXPAND }

@onready var tile_catalog: TileCatalog = $TileCatalog
@onready var camera: Camera3D = $Camera3D
@onready var board_root: Node3D = $Board

var board_state
var water_network_renderer: WaterNetworkRenderer3D
var deck: Array[TileDefinition] = []
var deck_index := 0
var current_rotation := 0

var placed_tile_nodes: Dictionary = {}   # cell -> Node3D (prefab instance)
var preview_node: Node3D = null
var hover_highlight: MeshInstance3D = null

var has_hovered_cell := false
var hovered_cell := Vector2i.ZERO
var preview_is_valid := false

var camera_target := Vector3.ZERO
var camera_distance := CAMERA_DISTANCE

var toast_text := ""
var toast_time := 0.0

var menu_mode := MenuMode.NONE
var menu_cell := Vector2i.ZERO
var menu_source_plant_id := -1
var menu_species_targets: Array = []

var game_over_result: Dictionary = {}

# HUD 控件引用
var label_title: Label
var label_status: Label
var label_current_tile: Label
var label_seeds: Label
var label_toast: Label
var btn_deal: Button
var btn_finish_place: Button
var btn_end_turn: Button
var btn_rotate: Button
var btn_reset: Button
var menu_panel: PanelContainer
var menu_box: VBoxContainer
var player_row_labels: Array[Label] = []


func _ready() -> void:
	_register_key_action(&"rotate_tile", KEY_R)
	_register_key_action(&"restart_tile_game", KEY_N)

	board_state = BOARD_STATE_SCRIPT.new()
	water_network_renderer = WATER_NETWORK_RENDERER_SCRIPT.new() as WaterNetworkRenderer3D
	_build_highlight_quad()
	_build_hud()
	_update_camera()

	_start_new_game()

	var user_arguments := OS.get_cmdline_user_args()
	if GAME_SMOKE_ARGUMENT in user_arguments:
		call_deferred("_run_game_smoke")
	elif CAPTURE_ARGUMENT in user_arguments:
		call_deferred("_capture_game_preview")


func _process(delta: float) -> void:
	if toast_time > 0.0:
		toast_time = maxf(0.0, toast_time - delta)
		_refresh_toast()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"rotate_tile"):
		_rotate_current_tile()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"restart_tile_game"):
		_start_new_game()
		get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if _try_handle_pan_key(event):
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_distance = clampf(camera_distance - CAMERA_ZOOM_STEP, CAMERA_DISTANCE_MIN, CAMERA_DISTANCE_MAX)
			_update_camera()
			get_viewport().set_input_as_handled()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_distance = clampf(camera_distance + CAMERA_ZOOM_STEP, CAMERA_DISTANCE_MIN, CAMERA_DISTANCE_MAX)
			_update_camera()
			get_viewport().set_input_as_handled()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_MIDDLE:
			is_panning = true
			get_viewport().set_input_as_handled()
			return
		if not mb.pressed and mb.button_index == MOUSE_BUTTON_MIDDLE:
			is_panning = false
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		if is_panning:
			_pan_camera_by_screen(mm.relative)
			return
		_update_hover(event.position)
		return

	if not event is InputEventMouseButton or not event.pressed:
		return

	if event.button_index == MOUSE_BUTTON_RIGHT:
		_rotate_current_tile()
		get_viewport().set_input_as_handled()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	var board_hit := _screen_to_cell(event.position)
	if board_hit.is_empty():
		return
	_on_board_cell_clicked(board_hit["cell"])
	get_viewport().set_input_as_handled()


var is_panning := false


# === 相机 ===

func _update_camera() -> void:
	var horizontal := camera_distance * cos(CAMERA_ELEVATION)
	camera.position = camera_target + Vector3(
		horizontal * sin(CAMERA_AZIMUTH),
		camera_distance * sin(CAMERA_ELEVATION),
		horizontal * cos(CAMERA_AZIMUTH),
	)
	camera.look_at(camera_target, Vector3.UP)


func _pan_camera_by_screen(screen_delta: Vector2) -> void:
	# 把屏幕位移换算成世界平面位移（近似）
	var scale := camera_distance / maxf(float(get_viewport().size.y), 1.0) * 2.2
	var right := Vector3(cos(CAMERA_AZIMUTH), 0.0, -sin(CAMERA_AZIMUTH))
	var forward := Vector3(-sin(CAMERA_AZIMUTH), 0.0, -cos(CAMERA_AZIMUTH))
	camera_target += (-right * screen_delta.x + forward * screen_delta.y) * scale
	_update_camera()


func _try_handle_pan_key(event: InputEventKey) -> bool:
	var kc: int = event.keycode
	var move := Vector3.ZERO
	if kc == KEY_W or kc == KEY_UP:
		move += Vector3(0.0, 0.0, -CAMERA_PAN_STEP)
	elif kc == KEY_S or kc == KEY_DOWN:
		move += Vector3(0.0, 0.0, CAMERA_PAN_STEP)
	elif kc == KEY_A or kc == KEY_LEFT:
		move += Vector3(-CAMERA_PAN_STEP, 0.0, 0.0)
	elif kc == KEY_D or kc == KEY_RIGHT:
		move += Vector3(CAMERA_PAN_STEP, 0.0, 0.0)
	else:
		return false
	camera_target += move
	_update_camera()
	return true


func _center_camera_on(cell: Vector2i) -> void:
	camera_target = _cell_world_position(cell)
	_update_camera()


# === 网格 / 拾取 ===

func _cell_world_position(cell: Vector2i) -> Vector3:
	return Vector3(float(cell.x) * TILE_SIZE, 0.0, float(cell.y) * TILE_SIZE)


func _screen_to_cell(screen_position: Vector2) -> Dictionary:
	var origin := camera.project_ray_origin(screen_position)
	var direction := camera.project_ray_normal(screen_position)
	if absf(direction.y) < 0.0001:
		return {}
	var t := -origin.y / direction.y
	if t < 0.0:
		return {}
	var world := origin + direction * t
	var cell := Vector2i(roundi(world.x / TILE_SIZE), roundi(world.z / TILE_SIZE))
	return {"cell": cell, "world": world}


# === 视觉 ===

func _build_highlight_quad() -> void:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.45, 0.90, 0.60, 0.35)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(TILE_SIZE - 0.35, TILE_SIZE - 0.35)
	mesh.material = material
	hover_highlight = MeshInstance3D.new()
	hover_highlight.mesh = mesh
	hover_highlight.position.y = HIGHLIGHT_Y
	hover_highlight.visible = false
	add_child(hover_highlight)


func _add_placed_tile_visual(cell: Vector2i) -> void:
	var placement: Dictionary = board_state.get_placement(cell)
	var definition: TileDefinition = placement["definition"]
	var rotation: int = int(placement["rotation"])

	var piece: Node3D = definition.visual_scene.instantiate() as Node3D
	if piece == null:
		push_error("Tile %s has no instantiable 3D prefab." % definition.id)
		return
	piece.position = _cell_world_position(cell)
	piece.rotation.y = -float(definition.visual_rotation_quarters + rotation) * PI * 0.5
	board_root.add_child(piece)
	if piece is TileArtwork3D:
		var artwork := piece as TileArtwork3D
		var plant_seed := RUNTIME_PLANT_SCATTER_SCRIPT.seed_for_tile(definition.visual_seed, cell)
		artwork.set_runtime_plant_layout(RUNTIME_PLANT_SCATTER_SCRIPT.generate_for_tile(artwork, plant_seed))
		artwork.set_runtime_plant_states({})
		artwork.set_growth_state(TileArtwork3D.GrowthState.BARE)
	else:
		piece.call("set_growth_state", 0)  # 兼容旧的研究预制件
	placed_tile_nodes[cell] = piece
	_refresh_water_network()


func _sync_preview() -> void:
	if preview_node == null:
		return
	var should_show: bool = int(board_state.phase) == BoardState.Phase.PLACE \
		and board_state.tile_to_place != null and has_hovered_cell and not board_state.has_tile(hovered_cell)
	if not should_show:
		preview_node.visible = false
		return
	var result: Dictionary = board_state.can_place(board_state.tile_to_place, hovered_cell, current_rotation)
	preview_is_valid = bool(result["valid"])
	preview_node.visible = true
	preview_node.position = _cell_world_position(hovered_cell)
	preview_node.rotation.y = -float(board_state.tile_to_place.visual_rotation_quarters + current_rotation) * PI * 0.5
	var tint := Color(0.76, 1.0, 0.84, 0.60) if preview_is_valid else Color(1.0, 0.49, 0.42, 0.55)
	_modulate_instances(preview_node, tint)


func _modulate_instances(root: Node3D, color: Color) -> void:
	for mesh_instance in root.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = mesh_instance
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat


func _refresh_preview_piece() -> void:
	if preview_node != null:
		preview_node.queue_free()
		preview_node = null
	if board_state == null or board_state.tile_to_place == null:
		return
	var definition: TileDefinition = board_state.tile_to_place
	if definition.visual_scene == null:
		return
	preview_node = definition.visual_scene.instantiate() as Node3D
	if preview_node == null:
		return
	preview_node.name = "PreviewTile"
	preview_node.visible = false
	board_root.add_child(preview_node)
	preview_node.call("set_growth_state", 0)
	_sync_preview()


func _update_hover(screen_position: Vector2) -> void:
	if int(board_state.phase) != BoardState.Phase.PLACE:
		if has_hovered_cell:
			has_hovered_cell = false
			hover_highlight.visible = false
			_sync_preview()
		return
	var hit := _screen_to_cell(screen_position)
	var new_has_hover := not hit.is_empty()
	var new_cell := hovered_cell
	if new_has_hover:
		new_cell = hit["cell"]
	if new_has_hover == has_hovered_cell and (not new_has_hover or new_cell == hovered_cell):
		return
	has_hovered_cell = new_has_hover
	hovered_cell = new_cell
	if has_hovered_cell:
		hover_highlight.position = _cell_world_position(hovered_cell)
		var valid := false
		if board_state.tile_to_place != null and not board_state.has_tile(hovered_cell):
			valid = bool(board_state.can_place(board_state.tile_to_place, hovered_cell, current_rotation)["valid"])
		hover_highlight.visible = true
		var mat := hover_highlight.mesh.material as StandardMaterial3D
		mat.albedo_color = Color(0.45, 0.90, 0.60, 0.35) if valid else Color(1.0, 0.49, 0.42, 0.40)
	else:
		hover_highlight.visible = false
	_sync_preview()


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
			"growth_state": TileArtwork3D.GrowthState.GROWING if int(p.form) == PLANT_SCRIPT.Form.HEALTHY else TileArtwork3D.GrowthState.WITHERED,
			"owner_color": _player_color(int(p.owner)),
		}
	if tile.has_method("has_runtime_plant_layout") and bool(tile.call("has_runtime_plant_layout")):
		tile.call("set_runtime_plant_states", runtime_states)
		tile.call("set_growth_state", TileArtwork3D.GrowthState.GROWING)
		return
	var any_healthy := plants.any(func(p): return int(p.form) == PLANT_SCRIPT.Form.HEALTHY)
	tile.call("set_growth_state", 1 if any_healthy else 2)
	var color := _player_color(int(plants[0].owner))
	for plant_node in tile.find_children("*", "SowablePlant3D", true, false):
		plant_node.call("set_owner_color", color)


func _refresh_water_network() -> void:
	if water_network_renderer != null:
		water_network_renderer.refresh(board_state, placed_tile_nodes)


# === §7 流程 ===

func _start_new_game() -> void:
	for tile_node in placed_tile_nodes.values():
		if is_instance_valid(tile_node):
			tile_node.queue_free()
	placed_tile_nodes.clear()
	if preview_node != null:
		preview_node.queue_free()
		preview_node = null

	deck = tile_catalog.build_deck()
	deck_index = 0
	current_rotation = 0
	game_over_result = {}
	_clear_menu()

	board_state.start_with(tile_catalog.starter_tile())
	_add_placed_tile_visual(Vector2i.ZERO)

	_set_toast("新对局 · 玩家 1 先行 · 点「抽牌」开始", 3.0)
	_refresh_hud()
	call_deferred("_center_camera_on", Vector2i.ZERO)


func _rotate_current_tile() -> void:
	if int(board_state.phase) != BoardState.Phase.PLACE or board_state.tile_to_place == null:
		return
	current_rotation = int(posmod(current_rotation + 1, 4))
	_refresh_preview_piece()
	_set_toast("旋转至 %d°" % (current_rotation * 90), 1.2)
	_refresh_hud()


func _on_deal_button() -> void:
	if int(board_state.phase) != BoardState.Phase.DEAL:
		_set_toast("当前阶段不应抽牌。", 2.0)
		return
	if deck_index >= deck.size():
		_set_toast("牌堆已空。", 2.0)
		return
	var result: Dictionary = board_state.deal_tile(deck[deck_index])
	if not bool(result["valid"]):
		_set_toast("抽牌失败：%s" % result["reason"], 2.5)
		return
	current_rotation = 0
	has_hovered_cell = false
	hover_highlight.visible = false
	_refresh_preview_piece()
	_set_toast("玩家 %d 抽到地块 · 进入放置阶段" % (board_state.active_player + 1), 2.2)
	_refresh_hud()


func _on_finish_place_button() -> void:
	if int(board_state.phase) != BoardState.Phase.PLACE:
		_set_toast("当前不在放置阶段。", 2.0)
		return
	if board_state.turn_placed_cells.is_empty():
		_set_toast("本回合必须至少放置 1 块。", 2.0)
		return
	var result: Dictionary = board_state.finish_placement()
	if not bool(result["valid"]):
		_set_toast("完成放置失败：%s" % result["reason"], 2.5)
		return
	_clear_menu()
	_set_toast("进入动作窗口 · 可种植物 / 扩张 / 跳过", 2.5)
	_refresh_hud()


func _on_end_turn_button() -> void:
	var phase = int(board_state.phase)
	if phase == BoardState.Phase.GAME_OVER:
		if game_over_result.is_empty():
			game_over_result = board_state.run_end_game(PLANT_ENGINE_SCRIPT)
		_refresh_hud()
		return
	if phase != BoardState.Phase.ACTION_WINDOW:
		_set_toast("当前不在动作窗口。", 2.0)
		return
	var next_deck_idx = deck_index + 1
	var deck_is_empty = next_deck_idx >= deck.size()
	var result: Dictionary = board_state.finish_action_window(PLANT_ENGINE_SCRIPT, deck_is_empty)
	if not bool(result["valid"]):
		_set_toast("回合结算失败：%s" % result["reason"], 2.5)
		return
	deck_index = next_deck_idx
	current_rotation = 0
	_clear_menu()
	_refresh_all_growth()
	if deck_is_empty:
		_set_toast("牌堆已空 · 玩家 %d 终局 · 点「查看终局」" % (board_state.active_player + 1), 3.0)
	else:
		_set_toast("回合已结算 · 玩家 %d 准备抽牌" % (board_state.active_player + 1), 2.2)
	_refresh_hud()


func _refresh_all_growth() -> void:
	for cell in board_state.placements.keys():
		_refresh_tile_growth(cell)


func _on_board_cell_clicked(cell: Vector2i) -> void:
	var phase = int(board_state.phase)
	if phase == BoardState.Phase.PLACE:
		_try_place_current_tile(cell)
		return
	if phase == BoardState.Phase.ACTION_WINDOW:
		_try_open_action_menu_for(cell)
		return
	if phase == BoardState.Phase.GAME_OVER:
		_set_toast("对局已结束 · 可按 N 重开", 2.0)
		return
	if phase == BoardState.Phase.DEAL:
		_set_toast("等待玩家 %d 点抽牌" % (board_state.active_player + 1), 2.0)


func _try_place_current_tile(cell: Vector2i) -> void:
	var tile = board_state.tile_to_place
	if tile == null:
		_set_toast("当前没有地块可放。", 2.0)
		return
	var result: Dictionary = board_state.commit_placement(cell, current_rotation)
	if not bool(result["valid"]):
		_set_toast("无法放置：%s" % result["reason"], 2.6)
		return
	_add_placed_tile_visual(cell)
	has_hovered_cell = false
	hover_highlight.visible = false
	current_rotation = 0
	_refresh_preview_piece()
	_center_camera_on(cell)
	_set_toast("已放置 · 进入动作窗口（种植物 / 扩张 / 跳过）", 2.4)
	_refresh_hud()


func _try_open_action_menu_for(cell: Vector2i) -> void:
	if not board_state.has_tile(cell):
		_set_toast("该位置尚未放地块。", 2.0)
		return
	var source_plant: Plant = _find_active_plant_at(cell, board_state.active_player)
	if source_plant != null:
		_open_expand_menu(cell, source_plant)
		return
	if board_state.is_turn_placed(cell):
		_open_plant_menu(cell)
		return
	_set_toast("该格不可种 / 扩：点本回合新放的格种，或点自己已有植物的格扩。", 2.8)


func _find_active_plant_at(cell: Vector2i, owner: int) -> Plant:
	for plant_id in board_state.plants:
		var p: Plant = board_state.plants[plant_id]
		if p.tile_cell == cell and int(p.owner) == owner:
			return p
	return null


func _open_plant_menu(cell: Vector2i) -> void:
	var owner: int = board_state.active_player
	var bag: Dictionary = board_state.seed_inventory.get(owner, {})
	var species_with_seeds: Array = []
	for species in [PLANT_SCRIPT.Species.GRASS, PLANT_SCRIPT.Species.FLOWER, PLANT_SCRIPT.Species.TREE]:
		var n: int = int(bag.get(species, 0))
		if n <= 0:
			continue
		var check: Dictionary = board_state.can_plant_at(cell, species, owner)
		if not bool(check["valid"]):
			continue
		species_with_seeds.append(species)
	if species_with_seeds.is_empty():
		_set_toast("该格没有合法的物种可种。", 3.0)
		return
	menu_mode = MenuMode.PLANT
	menu_cell = cell
	menu_source_plant_id = -1
	menu_species_targets.clear()
	for s in species_with_seeds:
		menu_species_targets.append(int(s))
	_build_action_menu()


func _open_expand_menu(source_cell: Vector2i, source_plant: Plant) -> void:
	var owner: int = board_state.active_player
	var bag: Dictionary = board_state.seed_inventory.get(owner, {})
	var species: int = int(source_plant.species)
	var seed_count: int = int(bag.get(species, 0))
	if seed_count <= 0:
		_set_toast("「%s」种子已耗尽，无法扩张。" % PLANT_SCRIPT.species_label(species), 2.5)
		return
	var candidates: Array = []
	for direction in range(4):
		var target_cell: Vector2i = BoardState.neighbour_for_edge(source_cell, direction)
		var check: Dictionary = board_state.can_expand_to(target_cell, species, owner, int(source_plant.id))
		if bool(check["valid"]):
			candidates.append(target_cell)
	if candidates.is_empty():
		_set_toast("源植物的土地块内暂无可扩格。", 2.0)
		return
	menu_mode = MenuMode.EXPAND
	menu_cell = source_cell
	menu_source_plant_id = int(source_plant.id)
	menu_species_targets.clear()
	for c in candidates:
		menu_species_targets.append(c)
	_build_action_menu()


func _handle_menu_choice(index: int) -> void:
	var owner: int = board_state.active_player
	if menu_mode == MenuMode.PLANT:
		var species: int = int(menu_species_targets[index])
		var result: Dictionary = board_state.plant(menu_cell, species, owner)
		if bool(result["valid"]):
			_refresh_tile_growth(menu_cell)
			_set_toast("已种 %s（种子 −1）" % PLANT_SCRIPT.species_label(species), 2.0)
		else:
			_set_toast("种植失败：%s" % result["reason"], 2.5)
	elif menu_mode == MenuMode.EXPAND:
		var target_cell: Vector2i = menu_species_targets[index]
		var source_plant: Plant = board_state.plants[menu_source_plant_id]
		var result: Dictionary = board_state.expand(target_cell, int(source_plant.species), owner, menu_source_plant_id)
		if bool(result["valid"]):
			_refresh_tile_growth(target_cell)
			_set_toast("已扩张到 (%d,%d)" % [target_cell.x, target_cell.y], 2.0)
		else:
			_set_toast("扩张失败：%s" % result["reason"], 2.5)
	_clear_menu()
	_refresh_hud()


func _clear_menu() -> void:
	menu_mode = MenuMode.NONE
	menu_cell = Vector2i.ZERO
	menu_source_plant_id = -1
	menu_species_targets.clear()
	if menu_panel != null:
		menu_panel.visible = false


# === HUD ===

func _build_hud() -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var ui := CanvasLayer.new()
	ui.name = "UI"
	add_child(ui)

	var panel := PanelContainer.new()
	panel.name = "InfoPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	panel.position = Vector2(20, 20)
	panel.custom_minimum_size = Vector2(340, 0)
	ui.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	label_title = _make_label("碧水沃野 · 3D", 24, Color("#e7f1cf"))
	box.add_child(label_title)
	label_status = _make_label("", 15, Color("#cde9a2"))
	box.add_child(label_status)
	label_current_tile = _make_label("", 14, Color("#eff3d2"))
	box.add_child(label_current_tile)
	label_seeds = _make_label("", 13, Color(0.74, 0.89, 0.78, 0.9))
	box.add_child(label_seeds)

	for _i in range(2):
		var pl := _make_label("", 13, Color("#eff3d2"))
		box.add_child(pl)
		player_row_labels.append(pl)

	# 按钮行（右下）
	var button_row := HBoxContainer.new()
	button_row.name = "ButtonRow"
	button_row.add_theme_constant_override("separation", 8)

	btn_deal = _make_button("抽  牌", _on_deal_button)
	btn_finish_place = _make_button("完成放置", _on_finish_place_button)
	btn_end_turn = _make_button("回合结束", _on_end_turn_button)
	btn_rotate = _make_button("旋转 R", _rotate_current_tile)
	btn_reset = _make_button("重开 N", _start_new_game)
	for b in [btn_deal, btn_finish_place, btn_end_turn, btn_rotate, btn_reset]:
		button_row.add_child(b)
	ui.add_child(button_row)
	button_row.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	button_row.set_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 12)

	label_toast = _make_label("", 15, Color(0.95, 1.0, 0.86, 1))
	label_toast.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	label_toast.set_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	label_toast.position = Vector2(20, -50)
	ui.add_child(label_toast)

	menu_panel = PanelContainer.new()
	menu_panel.name = "ActionMenu"
	menu_panel.visible = false
	menu_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	ui.add_child(menu_panel)
	menu_box = VBoxContainer.new()
	menu_box.add_theme_constant_override("separation", 6)
	menu_panel.add_child(menu_box)


func _make_label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_override("font", UI_FONT_SCRIPT.ui_font())
	return label


func _make_button(text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_override("font", UI_FONT_SCRIPT.ui_font())
	button.add_theme_font_size_override("font_size", 15)
	button.pressed.connect(callback)
	return button


func _build_action_menu() -> void:
	for child in menu_box.get_children():
		child.queue_free()
	var font: Font = UI_FONT_SCRIPT.ui_font()
	if menu_mode == MenuMode.PLANT:
		var title := _make_label("种植到 (%d,%d) · 选物种" % [menu_cell.x, menu_cell.y], 14, Color("#e7f1cf"))
		menu_box.add_child(title)
		for i in range(menu_species_targets.size()):
			var species: int = int(menu_species_targets[i])
			var bag: Dictionary = board_state.seed_inventory[board_state.active_player]
			var b := _make_button("%s（剩 %d）" % [PLANT_SCRIPT.species_label(species), int(bag.get(species, 0))], _menu_choice(i))
			menu_box.add_child(b)
	elif menu_mode == MenuMode.EXPAND:
		var species: int = int(board_state.plants[menu_source_plant_id].species)
		var title := _make_label("扩张 %s@(%d,%d) · 选目标" % [PLANT_SCRIPT.species_label(species), menu_cell.x, menu_cell.y], 14, Color("#e7f1cf"))
		menu_box.add_child(title)
		for i in range(menu_species_targets.size()):
			var target: Vector2i = menu_species_targets[i]
			var b := _make_button("→ (%d,%d)" % [target.x, target.y], _menu_choice(i))
			menu_box.add_child(b)
	menu_panel.visible = true


func _menu_choice(index: int) -> Callable:
	return func() -> void: _handle_menu_choice(index)


func _refresh_hud() -> void:
	var phase := int(board_state.phase)
	var player_label := "玩家 %d" % (board_state.active_player + 1) if phase != BoardState.Phase.GAME_OVER else "玩家 %d（终局）" % (board_state.active_player + 1)
	label_status.text = "第 %d 回合 · %s · %s" % [board_state.turn_number, player_label, _phase_label(phase)]

	if phase == BoardState.Phase.GAME_OVER:
		label_current_tile.text = "牌堆已空"
	elif board_state.tile_to_place != null:
		var t: TileDefinition = board_state.tile_to_place
		label_current_tile.text = "当前地块：%s · 旋转 %d°" % [t.display_name, current_rotation * 90]
	else:
		label_current_tile.text = "等待抽牌"

	for pid in range(2):
		var bag: Dictionary = board_state.seed_inventory.get(pid, {})
		player_row_labels[pid].text = "P%d · 已放 %d · 草 %d · 花 %d · 树 %d" % [
			pid + 1,
			board_state.owned_tile_count(pid),
			int(bag.get(PLANT_SCRIPT.Species.GRASS, 0)),
			int(bag.get(PLANT_SCRIPT.Species.FLOWER, 0)),
			int(bag.get(PLANT_SCRIPT.Species.TREE, 0)),
		]
		player_row_labels[pid].add_theme_color_override("font_color", _player_color(pid))

	btn_deal.disabled = phase != BoardState.Phase.DEAL
	btn_finish_place.disabled = not (phase == BoardState.Phase.PLACE and not board_state.turn_placed_cells.is_empty())
	btn_end_turn.disabled = not (phase == BoardState.Phase.ACTION_WINDOW or phase == BoardState.Phase.GAME_OVER)
	btn_end_turn.text = "查看终局" if phase == BoardState.Phase.GAME_OVER else "回合结束"
	btn_rotate.disabled = phase != BoardState.Phase.PLACE

	if phase == BoardState.Phase.GAME_OVER and not game_over_result.is_empty():
		label_current_tile.text = "终局已结算"


func _phase_label(phase: int) -> String:
	match phase:
		BoardState.Phase.DEAL:
			return "等待抽牌"
		BoardState.Phase.PLACE:
			return "等待放置"
		BoardState.Phase.ACTION_WINDOW:
			return "动作窗口"
		BoardState.Phase.GAME_OVER:
			return "终局"
		_:
			return "未知"


func _set_toast(message: String, duration: float) -> void:
	toast_text = message
	toast_time = duration
	_refresh_toast()


func _refresh_toast() -> void:
	if label_toast == null:
		return
	if toast_time > 0.0:
		label_toast.text = toast_text
		label_toast.visible = true
	else:
		label_toast.visible = false


# === Helpers ===

func _player_color(player_id: int) -> Color:
	return PLAYER_COLORS[player_id % PLAYER_COLORS.size()]


func _register_key_action(action: StringName, keycode: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var key_event := InputEventKey.new()
	key_event.physical_keycode = keycode
	InputMap.action_add_event(action, key_event)


func _find_first_visible_legal_move() -> Dictionary:
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
		var cell = queue.pop_front()
		for off in offsets:
			var n_cell = cell + off
			if visited.has(n_cell):
				continue
			visited[n_cell] = true
			for rotation in range(4):
				if bool(board_state.can_place(board_state.tile_to_place, n_cell, rotation)["valid"]):
					return {"cell": n_cell, "rotation": rotation}
			if abs(n_cell.x) + abs(n_cell.y) > SEARCH_RADIUS:
				continue
			queue.append(n_cell)
	return {}


# === 冒烟测试 ===

func _run_game_smoke() -> void:
	if not _run_rule_contract_smoke():
		get_tree().quit(1)
		return
	if not _run_rule_engine_smoke():
		get_tree().quit(1)
		return
	if not _run_plants_smoke():
		get_tree().quit(1)
		return
	if not await _run_full_turn_loop_smoke():
		get_tree().quit(1)
		return
	print("GAME_SMOKE_PASS: full §7 turn loop manual emulation succeeded; tiles placed=%d, turn=%d." % [_smoke_last_placed, _smoke_last_turn])
	get_tree().quit()


var _smoke_last_placed: int = 0
var _smoke_last_turn: int = 0


func _run_full_turn_loop_smoke() -> bool:
	var sandbox = BOARD_STATE_SCRIPT.new()
	var starter: TileDefinition = tile_catalog.starter_tile()
	sandbox.start_with(starter)
	var board = board_state

	for owner in [0, 1]:
		for species in [PLANT_SCRIPT.Species.GRASS, PLANT_SCRIPT.Species.FLOWER, PLANT_SCRIPT.Species.TREE]:
			board.seed_inventory[owner][species] = 4

	var placed_count = 0
	var hard_caps = 200
	while int(board.phase) != BoardState.Phase.GAME_OVER and hard_caps > 0:
		hard_caps -= 1
		if deck_index >= deck.size():
			break
		var deal: Dictionary = board.deal_tile(deck[deck_index])
		if not bool(deal["valid"]):
			push_error("Loop smoke: deal rejected: %s" % deal["reason"])
			return false

		var placed_this_turn := false
		var visited: Dictionary = {}
		var queue: Array[Vector2i] = []
		for c in board.placements.keys():
			queue.append(c)
			visited[c] = true
		var offsets: Array[Vector2i] = [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]
		var scan_safety := 0
		while not queue.is_empty() and scan_safety < 4096:
			scan_safety += 1
			var cell = queue.pop_front()
			var n_cell: Vector2i = Vector2i.ZERO
			var found_neighbour := false
			for off in offsets:
				n_cell = cell + off
				if visited.has(n_cell):
					continue
				visited[n_cell] = true
				found_neighbour = true
				for rotation in range(4):
					var place: Dictionary = board.commit_placement(n_cell, rotation)
					if bool(place["valid"]):
						placed_this_turn = true
						placed_count += 1
						break
				if placed_this_turn:
					break
			if placed_this_turn:
				break
			if not found_neighbour:
				continue
			if abs(n_cell.x) + abs(n_cell.y) > SEARCH_RADIUS:
				continue
			queue.append(n_cell)
		if not placed_this_turn:
			deck_index += 1
			board.active_player = int(posmod(board.active_player + 1, board.player_count))
			board.turn_number += 1
			board.tile_to_place = null
			board.phase = BoardState.Phase.DEAL
			continue

		if not bool(board.finish_placement()["valid"]):
			push_error("Loop smoke: finish_placement rejected.")
			return false

		var planted = false
		if board.turn_placed_cells.size() > 0:
			var tnew_cell: Vector2i = board.turn_placed_cells[0]
			var chk: Dictionary = board.can_plant_at(tnew_cell, PLANT_SCRIPT.Species.GRASS, board.active_player)
			if bool(chk["valid"]):
				var pr: Dictionary = board.plant(tnew_cell, PLANT_SCRIPT.Species.GRASS, board.active_player)
				if bool(pr["valid"]):
					planted = true

		var next_deck_idx = deck_index + 1
		var deck_is_empty = next_deck_idx >= deck.size()
		var settle_result: Dictionary = board.finish_action_window(PLANT_ENGINE_SCRIPT, deck_is_empty)
		if not bool(settle_result["valid"]):
			push_error("Loop smoke: finish_action_window rejected: %s" % settle_result["reason"])
			return false
		deck_index = next_deck_idx
		await get_tree().process_frame

	if int(board.phase) != BoardState.Phase.GAME_OVER:
		push_error("Loop smoke: expected GAME_OVER after deck drained, got phase=%d." % int(board.phase))
		return false
	var gr: Dictionary = board.run_end_game(PLANT_ENGINE_SCRIPT)
	if not bool(gr["valid"]):
		push_error("Loop smoke: run_end_game rejected: %s" % gr["reason"])
		return false
	var sc: Dictionary = gr["score_result"]
	var winner: Dictionary = gr["winner"]
	if sc.get("scores", {}) == null:
		push_error("Loop smoke: score_result missing scores dict.")
		return false
	if board.plants.is_empty():
		push_error("Loop smoke: expected at least 1 plant after full loop, got 0.")
		return false
	if not board.plants.is_empty() and placed_count <= 0:
		push_error("Loop smoke: no tile placed during loop, but plants exist.")
		return false
	if winner.get("winners", []).is_empty():
		push_error("Loop smoke: no winner resolved.")
		return false

	_smoke_last_placed = placed_count
	_smoke_last_turn = board.turn_number
	if placed_count < 60:
		push_error("Loop smoke: infinite-map regression — only placed %d tiles, expected ≥60." % placed_count)
		return false
	return true


func _run_rule_contract_smoke() -> bool:
	var sandbox = BOARD_STATE_SCRIPT.new()
	var starter = tile_catalog.starter_tile()
	var sample_tile: TileDefinition = tile_catalog.build_deck()[0]
	sandbox.start_with(starter)

	if bool(sandbox.can_place(sample_tile, Vector2i(4, 4), 0)["valid"]):
		push_error("Rule smoke test failed: disconnected placement was accepted.")
		return false
	if bool(sandbox.can_place(sample_tile, Vector2i(0, -1), 0)["valid"]):
		push_error("Rule smoke test failed: water-to-land mismatch was accepted.")
		return false
	if not bool(sandbox.place(sample_tile, Vector2i(0, -1), 2, 0)["valid"]):
		push_error("Rule smoke test failed: matching land-to-land placement was rejected.")
		return false
	if not bool(sandbox.place(sample_tile, Vector2i(1, 0), 3, 1)["valid"]):
		push_error("Rule smoke test failed: second matching placement was rejected.")
		return false
	return true


func _run_rule_engine_smoke() -> bool:
	var RE = preload("res://scripts/rule_engine.gd")
	var board = BOARD_STATE_SCRIPT.new()
	var starter = tile_catalog.starter_tile()
	var road_straight = tile_catalog.get_definition(&"road_straight_a")
	var road_cross4 = tile_catalog.get_definition(&"road_cross4_a")
	if road_straight == null or road_cross4 == null:
		push_error("Rule engine smoke failed: required tile definitions missing from CSV.")
		return false

	board.start_with(starter)
	var a1 = RE.analyze(board)
	if a1.land_regions.size() != 1:
		push_error("Rule engine smoke failed: starter should yield exactly 1 land region, got %d." % a1.land_regions.size())
		return false
	var starter_lr = a1.land_regions[0]
	if starter_lr.unit_count != 5:
		push_error("Rule engine smoke failed: starter should have 5 land units, got %d." % starter_lr.unit_count)
		return false
	if starter_lr.open_edges.size() != 4:
		push_error("Rule engine smoke failed: starter should have 4 open land edges, got %d." % starter_lr.open_edges.size())
		return false

	var board2 = BOARD_STATE_SCRIPT.new()
	board2.start_with(road_cross4)
	var a2 = RE.analyze(board2)
	if a2.water_nets.size() != 1:
		push_error("Rule engine smoke failed: road_cross4 alone should yield 1 water net, got %d." % a2.water_nets.size())
		return false
	if a2.water_nets[0].P_tile != 1:
		push_error("Rule engine smoke failed: road_cross4 alone should give P_tile=1, got %d." % a2.water_nets[0].P_tile)
		return false
	if a2.water_nets[0].S_W != 1:
		push_error("Rule engine smoke failed: road_cross4 alone should give S_W=1, got %d." % a2.water_nets[0].S_W)
		return false
	if a2.water_nets[0].open_edges.size() != 4:
		push_error("Rule engine smoke failed: road_cross4 alone should have 4 open water edges, got %d." % a2.water_nets[0].open_edges.size())
		return false

	var v2 = board2.place(road_straight, Vector2i(1, 0), 1, 0)
	if not bool(v2["valid"]):
		push_error("Rule engine smoke failed: road_straight cannot be placed east of road_cross4: %s" % v2["reason"])
		return false
	var a3 = RE.analyze(board2)
	if a3.water_nets.size() != 1:
		push_error("Rule engine smoke failed: merged net should have 1 water net, got %d." % a3.water_nets.size())
		return false
	if a3.water_nets[0].P_tile != 2:
		push_error("Rule engine smoke failed: merged net should have P_tile=2, got %d." % a3.water_nets[0].P_tile)
		return false
	if a3.water_nets[0].open_edges.size() != 4:
		push_error("Rule engine smoke failed: merged net should have 4 open water edges, got %d." % a3.water_nets[0].open_edges.size())
		return false
	if a3.land_regions.size() != 0:
		push_error("Rule engine smoke failed: merged water net scenario should have 0 land regions, got %d." % a3.land_regions.size())
		return false

	print("RULE_ENGINE_SMOKE_PASS.")
	return true


func _run_plants_smoke() -> bool:
	var PE = preload("res://scripts/plant_engine.gd")
	var GD = preload("res://scripts/plant.gd")
	var board = BOARD_STATE_SCRIPT.new()
	var starter = tile_catalog.starter_tile()
	board.start_with(starter)

	for owner in range(2):
		for species in [GD.Species.GRASS, GD.Species.FLOWER, GD.Species.TREE]:
			if int(board.seed_inventory[owner][species]) != 2:
				push_error("Plants smoke failed: seed_inventory[%d][%d]=%d (expected 2)." % [owner, species, int(board.seed_inventory[owner][species])])
				return false

	var r0 = board.plant(Vector2i.ZERO, GD.Species.GRASS, 0)
	if bool(r0["valid"]):
		push_error("Plants smoke failed: planting on starter (not turn_placed) was accepted.")
		return false

	board.turn_placed_cells.append(Vector2i.ZERO)
	var r1 = board.plant(Vector2i.ZERO, GD.Species.GRASS, 0)
	if not bool(r1["valid"]):
		push_error("Plants smoke failed: planting grass on starter was rejected: %s" % r1["reason"])
		return false
	if int(board.seed_inventory[0][GD.Species.GRASS]) != 1:
		push_error("Plants smoke failed: P1 grass seed not consumed.")
		return false

	var r_repeat = board.plant(Vector2i.ZERO, GD.Species.GRASS, 0)
	if bool(r_repeat["valid"]):
		push_error("Plants smoke failed: same-species planting on same tile was accepted.")
		return false
	var r_other = board.plant(Vector2i.ZERO, GD.Species.GRASS, 1)
	if bool(r_other["valid"]):
		push_error("Plants smoke failed: P2 planting grass on P1's grass tile was accepted.")
		return false
	var r_other_species = board.plant(Vector2i.ZERO, GD.Species.FLOWER, 1)
	if not bool(r_other_species["valid"]):
		push_error("Plants smoke failed: P2 planting flower on P1's grass tile was rejected.")
		return false

	var rule = RuleEngine.analyze(board)
	var pa1 = PE.settle_with_rule(board, rule)
	if int(pa1.summary["water_short_count"]) != 2:
		push_error("Plants smoke failed: both grass+flower should be WATER_SHORT, got summary=%s" % str(pa1.summary))
		return false

	print("PLANTS_SMOKE_PASS.")
	return true


func _capture_game_preview() -> void:
	for move_index in range(7):
		if int(board_state.phase) == BoardState.Phase.DEAL:
			if deck_index >= deck.size():
				break
			var deal: Dictionary = board_state.deal_tile(deck[deck_index])
			if not bool(deal["valid"]):
				break
			deck_index += 1
			current_rotation = 0
		if int(board_state.phase) != BoardState.Phase.PLACE or board_state.tile_to_place == null:
			break
		var move = _find_first_visible_legal_move()
		if move.is_empty():
			break
		current_rotation = int(move["rotation"])
		_try_place_current_tile(move["cell"])
		board_state.finish_action_window(PLANT_ENGINE_SCRIPT, deck_index >= deck.size())
	await get_tree().create_timer(0.35).timeout
	var capture_directory = ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(capture_directory)
	var preview = get_viewport().get_texture().get_image()
	preview.save_png(capture_directory.path_join("tile_placement_preview_3d.png"))
	get_tree().quit()
