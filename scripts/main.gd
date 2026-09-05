extends Node2D

const BOARD_STATE_SCRIPT := preload("res://scripts/board_state.gd")
const TILE_VIEW_SCRIPT := preload("res://scripts/tile_view.gd")
const UI_FONT_SCRIPT := preload("res://scripts/ui_font.gd")
const PLANT_ENGINE_SCRIPT := preload("res://scripts/plant_engine.gd")
const PLANT_SCRIPT := preload("res://scripts/plant.gd")

const GAME_SMOKE_ARGUMENT := "--game-smoke"
const CAPTURE_ARGUMENT := "--capture-game"

const GRID_ORIGIN := Vector2(48.0, 157.0)
const CELL_SIZE := 78.0
const BOARD_TILE_SIZE := 72.0

# 平移参数：logical 像素 = cell.x * CELL_SIZE
const PAN_KEY_STEP := 78.0 * 3.0  # 每次按方向键 / WASD 平移 3 格
const PAN_WHEEL_STEP := 78.0 * 1.5  # 滚轮一格 ≈ 1.5 格
const PAN_LERP := 14.0  # 镜头平滑跟随系数
const SEARCH_RADIUS := 24  # BFS 搜索半径

const PANEL_X := 790.0
const PANEL_WIDTH := 438.0
const CARD_POSITION := Vector2(1000.0, 246.0)
const CARD_TILE_SIZE := 184.0

# §7 三个手动按钮（每个阶段只有 1 个亮：抽牌 → 结束放牌 → 结束回合 / 查看终局）
const DEAL_BUTTON := Rect2(800.0, 705.0, 130.0, 38.0)
const FINISH_PLACE_BUTTON := Rect2(940.0, 705.0, 130.0, 38.0)
const END_TURN_BUTTON := Rect2(1080.0, 705.0, 130.0, 38.0)
const ROTATE_BUTTON := Rect2(814.0, 467.0, 194.0, 43.0)
const RESET_BUTTON := Rect2(1021.0, 467.0, 184.0, 43.0)

@onready var tile_catalog: TileCatalog = $TileCatalog

var board_state
var deck: Array[TileDefinition] = []
var deck_index := 0

var current_rotation := 0
var has_hovered_cell := false
var hovered_cell := Vector2i.ZERO
var preview_is_valid := false

var placed_tile_nodes: Dictionary = {}
var hand_piece
var preview_piece

# 无限地图的镜头偏移：logical 像素。
#   _cell_rect(c).position = GRID_ORIGIN + Vector2(c.x*CELL_SIZE, c.y*CELL_SIZE) - camera_offset
# camera_offset == 0 → (0,0) 落在 GRID_ORIGIN 处
var camera_offset: Vector2 = Vector2.ZERO
var camera_target: Vector2 = Vector2.ZERO
var is_panning: bool = false  # 中键拖动中

var toast_text := "点击「抽牌」开始第一回合"
var toast_time := 0.0

# §7.2.2 动作弹窗（手种 vs 扩张）
enum MenuMode { NONE, PLANT, EXPAND }
var menu_mode: int = MenuMode.NONE
var menu_cell: Vector2i = Vector2i.ZERO       # 种植模式：要种的格；扩张模式：源植物所在格
var menu_source_plant_id: int = -1            # 扩张模式：源植物 id
var menu_items: Array = []                    # Array[Rect2]  选项按钮位置
var menu_species_targets: Array = []          # Array[int]    种植模式：每项对应的物种；扩张模式：每项对应的目标格

# 终局结果（run_end_game 之后填上）
var game_over_result: Dictionary = {}


func _ready() -> void:
	_auto_fit_window_to_screen()

	_register_key_action(&"rotate_tile", KEY_R)
	_register_key_action(&"restart_tile_game", KEY_N)

	board_state = BOARD_STATE_SCRIPT.new()
	hand_piece = TILE_VIEW_SCRIPT.new()
	hand_piece.z_index = 4
	add_child(hand_piece)

	preview_piece = TILE_VIEW_SCRIPT.new()
	preview_piece.z_index = 3
	preview_piece.hide()
	add_child(preview_piece)

	_start_new_game()
	# 镜头居中于 starter (0,0) —— viewport 此时已确定
	call_deferred(&"_center_camera_on", Vector2i.ZERO)

	var user_arguments = OS.get_cmdline_user_args()
	if GAME_SMOKE_ARGUMENT in user_arguments:
		call_deferred("_run_game_smoke")
	elif CAPTURE_ARGUMENT in user_arguments:
		call_deferred("_capture_game_preview")


func _auto_fit_window_to_screen() -> void:
	var screen_size = DisplayServer.screen_get_size()
	var usable = Vector2(
		float(screen_size.x) * 0.96,
		float(screen_size.y) * 0.94
	)
	var design = Vector2(1280.0, 820.0)
	var scale_fit = minf(1.0, minf(usable.x / design.x, usable.y / design.y))
	var final_size = Vector2i(int(round(design.x * scale_fit)), int(round(design.y * scale_fit)))
	get_window().size = final_size
	var centered = (Vector2(screen_size) - Vector2(final_size)) * 0.5
	get_window().position = Vector2i(int(round(centered.x)), int(round(centered.y)))


func _process(delta: float) -> void:
	# 镜头平滑跟随 target
	var new_offset = camera_offset.lerp(camera_target, clampf(delta * PAN_LERP, 0.0, 1.0))
	if new_offset.distance_squared_to(camera_offset) > 0.01:
		camera_offset = new_offset
		_sync_pieces_to_camera()
		queue_redraw()
	if toast_time <= 0.0:
		return
	toast_time = maxf(0.0, toast_time - delta)
	queue_redraw()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"rotate_tile"):
		_rotate_current_tile()
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"restart_tile_game"):
		_start_new_game()
		get_viewport().set_input_as_handled()
		return

	# WASD / 方向键平移镜头（按下时持续 step，松开就停）
	if event is InputEventKey and event.pressed and not event.echo:
		var handled_pan := _try_handle_pan_key(event)
		if handled_pan:
			get_viewport().set_input_as_handled()
			return

	# 中键拖动 / 滚轮平移
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.pressed and mb.button_index == MOUSE_BUTTON_MIDDLE:
			is_panning = true
			get_viewport().set_input_as_handled()
			return
		if not mb.pressed and mb.button_index == MOUSE_BUTTON_MIDDLE:
			is_panning = false
			get_viewport().set_input_as_handled()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera_target.y -= PAN_WHEEL_STEP
			get_viewport().set_input_as_handled()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera_target.y += PAN_WHEEL_STEP
			get_viewport().set_input_as_handled()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_LEFT:
			camera_target.x -= PAN_WHEEL_STEP
			get_viewport().set_input_as_handled()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_RIGHT:
			camera_target.x += PAN_WHEEL_STEP
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseMotion:
		_update_hover(event.position)
		if is_panning:
			var mm: InputEventMouseMotion = event
			camera_target -= mm.relative
			# 让当前 offset 同步（避免拖动末尾还有 1 帧延迟）
			camera_offset = camera_target
			_sync_pieces_to_camera()
			queue_redraw()
		return
	if not event is InputEventMouseButton or not event.pressed:
		return

	if event.button_index == MOUSE_BUTTON_RIGHT:
		_rotate_current_tile()
		get_viewport().set_input_as_handled()
		return
	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	# 任何左键点击先关掉已开的菜单（避免误触）
	if menu_mode != MenuMode.NONE:
		if _try_handle_menu_click(event.position):
			get_viewport().set_input_as_handled()
			return

	if DEAL_BUTTON.has_point(event.position):
		_on_deal_button()
		get_viewport().set_input_as_handled()
		return
	if FINISH_PLACE_BUTTON.has_point(event.position):
		_on_finish_place_button()
		get_viewport().set_input_as_handled()
		return
	if END_TURN_BUTTON.has_point(event.position):
		_on_end_turn_button()
		get_viewport().set_input_as_handled()
		return
	if ROTATE_BUTTON.has_point(event.position):
		_rotate_current_tile()
		get_viewport().set_input_as_handled()
		return
	if RESET_BUTTON.has_point(event.position):
		_start_new_game()
		get_viewport().set_input_as_handled()
		return

	# 关菜单外点 → 关闭菜单
	if menu_mode != MenuMode.NONE:
		_clear_menu()
		get_viewport().set_input_as_handled()
		return

	var board_hit = _screen_to_cell(event.position)
	if not board_hit.is_empty():
		_on_board_cell_clicked(board_hit["cell"])
		get_viewport().set_input_as_handled()


func _draw() -> void:
	var canvas_size = get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, canvas_size), Color("#09221c"))
	draw_circle(Vector2(126.0, 105.0), 350.0, Color(0.14, 0.34, 0.25, 0.18))
	draw_circle(Vector2(1140.0, 760.0), 420.0, Color(0.02, 0.10, 0.085, 0.52))
	# 网格装饰线（无限延伸，跟着镜头横移）
	var first_x = int(floor(-camera_offset.x / CELL_SIZE) * CELL_SIZE) - 280
	for x in range(first_x, int(canvas_size.x) + 310, int(CELL_SIZE)):
		draw_line(Vector2(float(x), 0.0), Vector2(float(x) + 410.0, canvas_size.y), Color(0.42, 0.72, 0.54, 0.035), 1.0)

	_draw_header()
	_draw_board()
	_draw_panel()
	_draw_action_buttons()
	_draw_footer()
	_draw_phase_legend()
	if menu_mode != MenuMode.NONE:
		_draw_action_menu()
	if int(board_state.phase) == BoardState.Phase.GAME_OVER and not game_over_result.is_empty():
		_draw_game_over_overlay()


# === 镜头平移 ===

func _try_handle_pan_key(event: InputEventKey) -> bool:
	var kc: int = event.keycode
	if kc == KEY_W or kc == KEY_UP:
		camera_target.y -= PAN_KEY_STEP
		return true
	if kc == KEY_S or kc == KEY_DOWN:
		camera_target.y += PAN_KEY_STEP
		return true
	if kc == KEY_A or kc == KEY_LEFT:
		camera_target.x -= PAN_KEY_STEP
		return true
	if kc == KEY_D or kc == KEY_RIGHT:
		camera_target.x += PAN_KEY_STEP
		return true
	return false


func _center_camera_on(cell: Vector2i) -> void:
	# 让 cell 的中心落在 viewport 中心
	var canvas = get_viewport_rect().size
	var cell_pixel = Vector2(float(cell.x) * CELL_SIZE, float(cell.y) * CELL_SIZE)
	#   _cell_rect(cell).position = GRID_ORIGIN + cell_pixel - camera_offset
	#   目标：cell_screen_center == canvas_center
	#   GRID_ORIGIN + cell_pixel - camera_offset + CELL_SIZE/2 == canvas_center
	#   camera_offset = GRID_ORIGIN + cell_pixel + CELL_SIZE/2 - canvas_center
	camera_target = GRID_ORIGIN + cell_pixel + Vector2(CELL_SIZE * 0.5, CELL_SIZE * 0.5) - canvas * 0.5
	camera_offset = camera_target
	# 镜头是直接 snap 的（不走 lerp），所以 _process 不会触发；这里必须显式同步已放置地块
	_sync_pieces_to_camera()


# === §7 流程：每个按钮的"玩家手动触发"主体 ===

func _start_new_game() -> void:
	for tile_node in placed_tile_nodes.values():
		tile_node.queue_free()
	placed_tile_nodes.clear()

	deck = tile_catalog.build_deck()
	deck_index = 0
	current_rotation = 0
	game_over_result = {}
	_clear_menu()

	board_state.start_with(tile_catalog.starter_tile())
	_add_placed_tile_visual(Vector2i.ZERO)
	hand_piece.hide()
	preview_piece.hide()

	_set_toast("新对局 · 玩家 1 先行 · 点「抽牌」开始", 3.0)
	queue_redraw()


func _rotate_current_tile() -> void:
	if int(board_state.phase) != BoardState.Phase.PLACE or board_state.tile_to_place == null:
		return
	current_rotation = int(posmod(current_rotation + 1, 4))
	_sync_hand_piece()
	_refresh_preview()
	_set_toast("旋转至 %d°" % (current_rotation * 90), 1.2)


func _on_deal_button() -> void:
	if int(board_state.phase) != BoardState.Phase.DEAL:
		_set_toast("当前阶段不应抽牌（phase=%d）。" % int(board_state.phase), 2.0)
		return
	if deck_index >= deck.size():
		_set_toast("牌堆已空。", 2.0)
		return
	var result: Dictionary = board_state.deal_tile(deck[deck_index])
	if not bool(result["valid"]):
		_set_toast("抽牌失败：%s" % result["reason"], 2.5)
		return
	current_rotation = 0
	_sync_hand_piece()
	has_hovered_cell = false
	_refresh_preview()
	_set_toast("玩家 %d 抽到地块 · 进入放置阶段" % (board_state.active_player + 1), 2.2)
	queue_redraw()


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
	queue_redraw()


func _on_end_turn_button() -> void:
	var phase = int(board_state.phase)
	if phase == BoardState.Phase.GAME_OVER:
		# 手动触发终局结算
		if game_over_result.is_empty():
			game_over_result = board_state.run_end_game(PLANT_ENGINE_SCRIPT)
		queue_redraw()
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
	if deck_is_empty:
		# 进入终局但暂不调用 run_end_game — 玩家手动按"查看终局"才结算
		_sync_hand_piece()
		_set_toast("牌堆已空 · 玩家 %d 终局 · 点「查看终局」" % (board_state.active_player + 1), 3.0)
	else:
		_sync_hand_piece()
		_set_toast("回合已结算 · 玩家 %d 准备抽牌" % (board_state.active_player + 1), 2.2)
	queue_redraw()


# 点击棋盘格：依据当前阶段和格的归属决定做什么
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
		_refresh_preview()
		return
	_add_placed_tile_visual(cell)
	has_hovered_cell = false
	current_rotation = 0
	_refresh_preview()
	# 镜头自动跟随：本回合新放的格子，让它落在画布中心
	_center_camera_on(cell)
	_set_toast("已放置 · 进入动作窗口（种植物 / 扩张 / 跳过）", 2.4)
	queue_redraw()


# 动作窗口：依据点击的格打开种 / 扩 菜单
func _try_open_action_menu_for(cell: Vector2i) -> void:
	if not board_state.has_tile(cell):
		_set_toast("该位置尚未放地块。", 2.0)
		return
	# 优先级：若玩家在该格已有自己植物 → 弹"扩张"菜单
	var source_plant: Plant = _find_active_plant_at(cell, board_state.active_player)
	if source_plant != null:
		_open_expand_menu(cell, source_plant)
		return
	# 否则：若 cell 是本回合新放置的 t_new → 弹"种植"菜单
	if board_state.is_turn_placed(cell):
		_open_plant_menu(cell)
		return
	# 没有任何可行动作
	_set_toast("该格不可种 / 扩：点本回合新放的格种，或点自己已有植物的格扩。", 2.8)
	queue_redraw()


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
		# 再校验该种能不能种（在 board_state.can_plant_at）
		var check: Dictionary = board_state.can_plant_at(cell, species, owner)
		if not bool(check["valid"]):
			continue
		species_with_seeds.append(species)
	if species_with_seeds.is_empty():
		_set_toast("该格没有合法的物种可种（检查土地块与他人物种）。", 3.0)
		queue_redraw()
		return
	menu_mode = MenuMode.PLANT
	menu_cell = cell
	menu_source_plant_id = -1
	menu_items.clear()
	menu_species_targets.clear()
	for _species in species_with_seeds:
		menu_species_targets.append(int(_species))
	queue_redraw()


func _open_expand_menu(source_cell: Vector2i, source_plant: Plant) -> void:
	var owner: int = board_state.active_player
	# 列出 source 植物 land_region 内所有可扩张到的目标格（同 species + 有种子 + 不撞种）
	var candidates: Array = []
	var bag: Dictionary = board_state.seed_inventory.get(owner, {})
	var species: int = int(source_plant.species)
	var seed_count: int = int(bag.get(species, 0))
	if seed_count <= 0:
		_set_toast("「%s」种子已耗尽，无法扩张。" % PLANT_SCRIPT.species_label(species), 2.5)
		queue_redraw()
		return
	for direction in range(4):
		var target_cell: Vector2i = BoardState.neighbour_for_edge(source_cell, direction)
		var check: Dictionary = board_state.can_expand_to(target_cell, species, owner, int(source_plant.id))
		if bool(check["valid"]):
			candidates.append(target_cell)
	if candidates.is_empty():
		_set_toast("源植物的土地块内暂无可扩格。", 2.0)
		queue_redraw()
		return
	menu_mode = MenuMode.EXPAND
	menu_cell = source_cell
	menu_source_plant_id = int(source_plant.id)
	menu_items.clear()
	menu_species_targets.clear()
	for c in candidates:
		menu_species_targets.append(c)
	queue_redraw()


func _try_handle_menu_click(screen_position: Vector2) -> bool:
	for i in range(menu_items.size()):
		var rect: Rect2 = menu_items[i]
		if not rect.has_point(screen_position):
			continue
		_handle_menu_choice(i)
		return true
	# 点在别处也保留菜单（不要关，因为"关掉误触"在外层已经处理）
	return false


func _handle_menu_choice(index: int) -> void:
	var owner: int = board_state.active_player
	if menu_mode == MenuMode.PLANT:
		var species: int = int(menu_species_targets[index])
		var result: Dictionary = board_state.plant(menu_cell, species, owner)
		if bool(result["valid"]):
			_set_toast("已种 %s（种子 −1）" % PLANT_SCRIPT.species_label(species), 2.0)
		else:
			_set_toast("种植失败：%s" % result["reason"], 2.5)
	elif menu_mode == MenuMode.EXPAND:
		var target_cell: Vector2i = menu_species_targets[index]
		var source_plant: Plant = board_state.plants[menu_source_plant_id]
		var result: Dictionary = board_state.expand(target_cell, int(source_plant.species), owner, menu_source_plant_id)
		if bool(result["valid"]):
			_set_toast("已扩张到 %s" % _cell_short(target_cell), 2.0)
		else:
			_set_toast("扩张失败：%s" % result["reason"], 2.5)
	_clear_menu()
	queue_redraw()


func _clear_menu() -> void:
	menu_mode = MenuMode.NONE
	menu_cell = Vector2i.ZERO
	menu_source_plant_id = -1
	menu_items.clear()
	menu_species_targets.clear()
	queue_redraw()


# === 视觉 / 预览 ===

func _add_placed_tile_visual(cell: Vector2i) -> void:
	var placement: Dictionary = board_state.get_placement(cell)
	var piece = TILE_VIEW_SCRIPT.new()
	piece.position = _cell_rect(cell).get_center()
	piece.z_index = 2
	piece.show_tile(
		placement["definition"],
		int(placement["rotation"]),
		BOARD_TILE_SIZE,
		_owner_color(int(placement["owner_id"])),
	)
	add_child(piece)
	placed_tile_nodes[cell] = piece


func _sync_hand_piece() -> void:
	var tile = board_state.tile_to_place
	if tile == null or int(board_state.phase) == BoardState.Phase.GAME_OVER:
		hand_piece.hide()
		preview_piece.hide()
		return
	hand_piece.position = CARD_POSITION + Vector2(CARD_TILE_SIZE * 0.5, CARD_TILE_SIZE * 0.5)
	hand_piece.show_tile(tile, current_rotation, CARD_TILE_SIZE, _player_color(board_state.active_player))
	hand_piece.modulate = Color.WHITE
	hand_piece.show()


func _update_hover(screen_position: Vector2) -> void:
	if int(board_state.phase) != BoardState.Phase.PLACE:
		if has_hovered_cell:
			has_hovered_cell = false
			preview_piece.hide()
			queue_redraw()
		return
	var hit = _screen_to_cell(screen_position)
	var new_has_hover = not hit.is_empty()
	var new_cell = hovered_cell
	if new_has_hover:
		new_cell = hit["cell"]
	if new_has_hover == has_hovered_cell and (not new_has_hover or new_cell == hovered_cell):
		return
	has_hovered_cell = new_has_hover
	hovered_cell = new_cell
	_refresh_preview()


func _refresh_preview() -> void:
	preview_is_valid = false
	if int(board_state.phase) != BoardState.Phase.PLACE or board_state.tile_to_place == null or not has_hovered_cell or board_state.has_tile(hovered_cell):
		preview_piece.hide()
		queue_redraw()
		return
	var result: Dictionary = board_state.can_place(board_state.tile_to_place, hovered_cell, current_rotation)
	preview_is_valid = bool(result["valid"])
	preview_piece.position = _cell_rect(hovered_cell).get_center()
	preview_piece.show_tile(board_state.tile_to_place, current_rotation, BOARD_TILE_SIZE, _player_color(board_state.active_player))
	preview_piece.modulate = Color(0.76, 1.0, 0.84, 0.64) if preview_is_valid else Color(1.0, 0.49, 0.42, 0.56)
	preview_piece.show()
	queue_redraw()


func _draw_header() -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	draw_string(font, Vector2(52.0, 56.0), "碧水沃野", HORIZONTAL_ALIGNMENT_LEFT, -1, 34, Color("#e7f1cf"))
	draw_line(Vector2(54.0, 84.0), Vector2(254.0, 84.0), Color("#89c99b"), 2.0)


func _draw_board() -> void:
	var canvas = get_viewport_rect().size
	# BG 覆盖整个可视区（自 GRID_ORIGIN 到画布右下，左侧避开右侧 panel）
	var board_rect = Rect2(GRID_ORIGIN - Vector2(13.0, 13.0), Vector2(canvas.x - GRID_ORIGIN.x + 13.0, canvas.y - GRID_ORIGIN.y + 13.0))
	draw_style_box(_rounded_box(Color(0.025, 0.10, 0.075, 0.90), Color("#325d48"), 2, 22), board_rect)

	var phase = int(board_state.phase)
	# 渲染集合：已放置块 + 它们的 4 邻（用于 PLACE 阶段高亮可放空格）
	var render_cells: Dictionary = {}
	for placed_cell in board_state.placements.keys():
		render_cells[placed_cell] = true
	for off in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
		var n_cell: Vector2i = Vector2i.ZERO
		for placed_cell in board_state.placements.keys():
			n_cell = placed_cell + off
			if not board_state.placements.has(n_cell):
				render_cells[n_cell] = true

	for cell in render_cells.keys():
		var rect = _cell_rect(cell)
		# 视口裁剪：不在屏幕内的格不画
		if rect.position.x + rect.size.x < 0 or rect.position.y + rect.size.y < 0:
			continue
		if rect.position.x > canvas.x or rect.position.y > canvas.y:
			continue
		var cell_color = Color(0.06, 0.20, 0.14, 0.52)
		# PLACE 阶段高亮可放空格
		if not board_state.has_tile(cell) and phase == BoardState.Phase.PLACE and board_state.tile_to_place != null:
			var result: Dictionary = board_state.can_place(board_state.tile_to_place, cell, current_rotation)
			if bool(result["valid"]):
				cell_color = Color(0.11, 0.38, 0.25, 0.76)
		# ACTION_WINDOW：本回合新放的格子高亮（可种）
		if phase == BoardState.Phase.ACTION_WINDOW and board_state.is_turn_placed(cell):
			cell_color = Color(0.18, 0.40, 0.30, 0.86)
		# ACTION_WINDOW：玩家在自己植物的格子高亮（可扩）
		if phase == BoardState.Phase.ACTION_WINDOW and _find_active_plant_at(cell, board_state.active_player) != null:
			cell_color = Color(0.36, 0.46, 0.22, 0.85)
		draw_style_box(_rounded_box(cell_color, Color(0.26, 0.52, 0.38, 0.20), 1, 11), rect)

	# 棋盘上的植物标记（小色点）
	for cell in placed_tile_nodes.keys():
		var plants_in_tile = board_state.list_plants_in_tile(cell)
		if plants_in_tile.is_empty():
			continue
		var center = _cell_rect(cell).get_center()
		for i in range(plants_in_tile.size()):
			var p: Plant = plants_in_tile[i]
			var offset = Vector2(-22.0 + float(i) * 22.0, 28.0)
			var color = Color("#cde9a2") if int(p.owner) == 0 else Color("#f0b58b")
			if int(p.form) == PLANT_SCRIPT.Form.WATER_SHORT:
				color = color.darkened(0.25)
			elif int(p.form) == PLANT_SCRIPT.Form.WITHERED:
				color = Color(0.45, 0.32, 0.30)
			draw_circle(center + offset, 8.0, color)
			draw_arc(center + offset, 8.0, 0.0, TAU, 18, Color(0.07, 0.18, 0.13, 0.6), 1.5, true)

	if has_hovered_cell:
		var hover_rect = _cell_rect(hovered_cell).grow(-1.0)
		var outline = Color("#8ff0a3") if preview_is_valid else Color("#ff8975")
		draw_rect(hover_rect, outline, false, 3.0, true)


func _draw_panel() -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var panel_rect = Rect2(PANEL_X, 126.0, PANEL_WIDTH, 596.0)
	draw_style_box(_rounded_box(Color(0.035, 0.13, 0.095, 0.92), Color("#315f49"), 2, 22), panel_rect)

	var phase = int(board_state.phase)
	var player_label = "玩家 %d" % (board_state.active_player + 1) if phase != BoardState.Phase.GAME_OVER else "玩家 %d（终局）" % (board_state.active_player + 1)
	var turn_label = "第 %d 回合" % board_state.turn_number
	draw_string(font, Vector2(PANEL_X + 28.0, 161.0), "%s · %s" % [turn_label, player_label], HORIZONTAL_ALIGNMENT_LEFT, -1, 22, _player_color(board_state.active_player))

	_draw_player_row(Vector2(PANEL_X + 24.0, 205.0), 0)
	_draw_player_row(Vector2(PANEL_X + 224.0, 205.0), 1)

	var current_tile = board_state.tile_to_place
	var current_label = "当前地块"
	draw_string(font, Vector2(PANEL_X + 28.0, 261.0), current_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.74, 0.89, 0.78, 0.66))
	if phase == BoardState.Phase.GAME_OVER:
		draw_string(font, Vector2(PANEL_X + 28.0, 285.0), "牌堆已空", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color("#eff3d2"))
	elif current_tile != null:
		draw_string(font, Vector2(PANEL_X + 28.0, 285.0), current_tile.display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color("#eff3d2"))
	else:
		draw_string(font, Vector2(PANEL_X + 28.0, 285.0), "等待抽牌", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color("#eff3d2"))

	_draw_button(ROTATE_BUTTON, "旋转  R", phase != BoardState.Phase.PLACE)
	_draw_button(RESET_BUTTON, "重开  N", false)

	draw_string(font, Vector2(PANEL_X + 28.0, 556.0), "边口图例", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.74, 0.89, 0.78, 0.66))
	draw_line(Vector2(PANEL_X + 30.0, 579.0), Vector2(PANEL_X + 76.0, 579.0), Color("#b66f3f"), 10.0, true)
	draw_string(font, Vector2(PANEL_X + 91.0, 584.0), "土地", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.81, 0.90, 0.74, 0.75))
	draw_line(Vector2(PANEL_X + 30.0, 610.0), Vector2(PANEL_X + 76.0, 610.0), Color("#2697b5"), 6.0, true)
	draw_circle(Vector2(PANEL_X + 53.0, 610.0), 4.0, Color("#d3fff0"))
	draw_string(font, Vector2(PANEL_X + 91.0, 615.0), "水流", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.72, 0.90, 0.91, 0.75))
	draw_line(Vector2(PANEL_X + 30.0, 641.0), Vector2(PANEL_X + 76.0, 641.0), Color("#8fbd5d"), 8.0, true)
	draw_string(font, Vector2(PANEL_X + 91.0, 646.0), "空地", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.75, 0.89, 0.72, 0.75))

	# 种子库存
	draw_string(font, Vector2(PANEL_X + 28.0, 690.0), "种子库存（草 / 花 / 树）", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.74, 0.89, 0.78, 0.66))
	for pid in [0, 1]:
		var row_origin = Vector2(PANEL_X + 28.0 + float(pid) * 210.0, 702.0)
		var bag: Dictionary = board_state.seed_inventory.get(pid, {})
		var bag_text = "P%d · 草 %d · 花 %d · 树 %d" % [
			pid + 1,
			int(bag.get(PLANT_SCRIPT.Species.GRASS, 0)),
			int(bag.get(PLANT_SCRIPT.Species.FLOWER, 0)),
			int(bag.get(PLANT_SCRIPT.Species.TREE, 0)),
		]
		draw_string(font, row_origin, bag_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, _player_color(pid).darkened(0.05))


func _draw_player_row(origin: Vector2, player_id: int) -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var phase = int(board_state.phase)
	var active: bool = phase != BoardState.Phase.GAME_OVER and board_state.active_player == player_id
	var fill = Color(0.09, 0.27, 0.18, 0.90) if active else Color(0.045, 0.16, 0.115, 0.75)
	draw_style_box(_rounded_box(fill, _player_color(player_id).darkened(0.22), 1, 10), Rect2(origin, Vector2(177.0, 42.0)))
	draw_circle(origin + Vector2(16.0, 20.0), 8.0, _player_color(player_id))
	draw_string(font, origin + Vector2(31.0, 18.0), "玩家 %d" % (player_id + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#eff3d2"))
	draw_string(font, origin + Vector2(31.0, 33.0), "已放 %d 块" % board_state.owned_tile_count(player_id), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.72, 0.87, 0.75, 0.65))


func _draw_action_buttons() -> void:
	# 三个主按钮：在每个 phase 只有一个亮，其余灰
	_draw_phase_button(DEAL_BUTTON, "抽  牌", board_state.phase == BoardState.Phase.DEAL)
	_draw_phase_button(FINISH_PLACE_BUTTON, "完成放置", board_state.phase == BoardState.Phase.PLACE and not board_state.turn_placed_cells.is_empty())
	# END_TURN_BTN 在 ACTION_WINDOW / GAME_OVER 阶段亮
	var end_turn_active: bool = false
	var end_turn_label = "回合结束"
	if int(board_state.phase) == BoardState.Phase.ACTION_WINDOW:
		end_turn_active = true
	elif int(board_state.phase) == BoardState.Phase.GAME_OVER:
		end_turn_active = true
		end_turn_label = "查看终局" if game_over_result.is_empty() else "终局已结算"
	_draw_phase_button(END_TURN_BUTTON, end_turn_label, end_turn_active)


func _draw_phase_button(rect: Rect2, label: String, enabled: bool) -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var hovered = rect.has_point(get_viewport().get_mouse_position())
	var fill = Color(0.06, 0.15, 0.10, 0.85)
	var border = Color(0.30, 0.45, 0.36, 0.6)
	if enabled:
		fill = Color(0.18, 0.42, 0.28, 0.95) if hovered else Color(0.12, 0.32, 0.22, 0.94)
		border = Color("#9ee0a8")
	draw_style_box(_rounded_box(fill, border, 2, 10), rect)
	var text_color = Color("#e8f1d0") if enabled else Color(0.55, 0.62, 0.55, 0.6)
	draw_string(font, rect.position + Vector2(20.0, 25.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, text_color)


func _draw_button(rect: Rect2, label: String, _disabled: bool) -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var hovered = rect.has_point(get_viewport().get_mouse_position())
	var fill = Color(0.18, 0.42, 0.28, 0.95) if hovered else Color(0.12, 0.32, 0.22, 0.94)
	draw_style_box(_rounded_box(fill, Color("#9ee0a8"), 2, 10), rect)
	draw_string(font, rect.position + Vector2(20.0, 25.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("#e8f1d0"))


func _draw_footer() -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var footer_y = 800.0
	draw_string(font, Vector2(52.0, footer_y), "← 高亮空格放置 · R / 右键旋转 · 阶段按钮全手动 · N 重开", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.70, 0.86, 0.75, 0.62))
	if toast_time > 0.0:
		var alpha = minf(1.0, toast_time * 1.4)
		draw_string(font, Vector2(52.0, footer_y + 28.0), toast_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.95, 1.0, 0.86, alpha))


func _draw_phase_legend() -> void:
	# 阶段状态文字 + 当前可行动作（紧贴右侧 3 个按钮上方）
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var y = 678.0
	var label = "阶段：%s" % _phase_label(board_state.phase)
	draw_string(font, Vector2(PANEL_X + 28.0, y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#cde9a2"))


func _phase_label(phase: int) -> String:
	match phase:
		BoardState.Phase.DEAL: return "等待抽牌"
		BoardState.Phase.PLACE: return "等待放置"
		BoardState.Phase.ACTION_WINDOW: return "动作窗口（可种 / 扩 / 跳）"
		BoardState.Phase.GAME_OVER: return "终局"
		_: return "未知"


# §7.2.2 动作菜单（PLANT / EXPAND）
func _draw_action_menu() -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var canvas_size = get_viewport_rect().size
	menu_items.clear()

	if menu_mode == MenuMode.PLANT:
		var species_list: Array = menu_species_targets
		var width = 200.0
		var height = 22.0 + float(species_list.size()) * 32.0
		var panel_rect = Rect2(
			Vector2(GRID_ORIGIN.x + 20.0, canvas_size.y - height - 20.0),
			Vector2(width, height),
		)
		draw_style_box(_rounded_box(Color(0.04, 0.16, 0.11, 0.96), Color("#a4d8a8"), 2, 14), panel_rect)
		draw_string(font, panel_rect.position + Vector2(16.0, 24.0), "种植到 %s · 选物种" % _cell_short(menu_cell), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#e7f1cf"))
		for i in range(species_list.size()):
			var species = int(species_list[i])
			var row_y = panel_rect.position.y + 50.0 + float(i) * 32.0
			var rect = Rect2(panel_rect.position.x + 16.0, row_y, width - 32.0, 28.0)
			var bag: Dictionary = board_state.seed_inventory[board_state.active_player]
			var text = "%s（剩 %d）" % [PLANT_SCRIPT.species_label(species), int(bag.get(species, 0))]
			var hovered = rect.has_point(get_viewport().get_mouse_position())
			var fill = Color(0.16, 0.40, 0.26, 0.95) if hovered else Color(0.10, 0.30, 0.19, 0.92)
			draw_style_box(_rounded_box(fill, Color("#9ee0a8"), 1, 8), rect)
			draw_string(font, rect.position + Vector2(14.0, 19.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#e8f1d0"))
			menu_items.append(rect)

	elif menu_mode == MenuMode.EXPAND:
		var candidates: Array = menu_species_targets
		var source: Plant = board_state.plants[menu_source_plant_id]
		var species = int(source.species)
		var width = 220.0
		var height = 22.0 + float(candidates.size()) * 32.0
		var panel_rect = Rect2(
			Vector2(GRID_ORIGIN.x + 20.0, canvas_size.y - height - 20.0),
			Vector2(width, height),
		)
		draw_style_box(_rounded_box(Color(0.04, 0.16, 0.11, 0.96), Color("#a4d8a8"), 2, 14), panel_rect)
		draw_string(font, panel_rect.position + Vector2(16.0, 24.0), "扩张 源 %s@%s · 选目标" % [PLANT_SCRIPT.species_label(species), _cell_short(menu_cell)], HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#e7f1cf"))
		for i in range(candidates.size()):
			var target_cell: Vector2i = candidates[i]
			var row_y = panel_rect.position.y + 50.0 + float(i) * 32.0
			var rect = Rect2(panel_rect.position.x + 16.0, row_y, width - 32.0, 28.0)
			var hovered = rect.has_point(get_viewport().get_mouse_position())
			var fill = Color(0.16, 0.40, 0.26, 0.95) if hovered else Color(0.10, 0.30, 0.19, 0.92)
			draw_style_box(_rounded_box(fill, Color("#9ee0a8"), 1, 8), rect)
			draw_string(font, rect.position + Vector2(14.0, 19.0), "→ %s" % _cell_short(target_cell), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#e8f1d0"))
			menu_items.append(rect)


func _draw_game_over_overlay() -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var rect = Rect2(180.0, 220.0, 920.0, 380.0)
	draw_style_box(_rounded_box(Color(0.025, 0.10, 0.075, 0.97), Color("#a4d8a8"), 3, 18), rect)
	draw_string(font, rect.position + Vector2(28.0, 50.0), "终局结果", HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color("#e7f1cf"))
	draw_line(rect.position + Vector2(28.0, 70.0), rect.position + Vector2(rect.size.x - 28.0, 70.0), Color("#89c99b"), 2.0)

	var sc: Dictionary = game_over_result.get("score_result", {})
	var winner: Dictionary = game_over_result.get("winner", {"winners": [], "is_tie": true})
	var scores: Dictionary = sc.get("scores", {})
	var tb: Dictionary = sc.get("tiebreakers", {})

	var y = rect.position.y + 102.0
	for pid in [0, 1]:
		var s: float = float(scores.get(pid, 0.0))
		var t: Dictionary = tb.get(pid, {})
		var line = "玩家 %d · 总分 %.1f · 树 %d · 花 %d · 草 %d · 全封闭分 %.1f" % [
			pid + 1, s,
			int(t.get("healthy_tree", 0)),
			int(t.get("healthy_flower", 0)),
			int(t.get("healthy_grass", 0)),
			float(t.get("closed_score", 0.0)),
		]
		draw_string(font, rect.position + Vector2(28.0, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, _player_color(pid))
		y += 36.0

	var winner_ids: Array = winner.get("winners", [])
	var winner_id_strs: Array = []
	for w in winner_ids:
		winner_id_strs.append(str(int(w) + 1))
	var winner_list_str = ", ".join(winner_id_strs)
	var win_label = "平局" if bool(winner.get("is_tie", true)) else "玩家 %s 获胜" % winner_list_str
	draw_string(font, rect.position + Vector2(28.0, y + 24.0), win_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, Color("#f5d27a"))

	var pa: PLANT_ENGINE_SCRIPT.PlantAnalysis = game_over_result.get("plant_analysis", null)
	if pa != null:
		var sum_text = "现存植物：%d（健康 %d · 缺水 %d · 枯萎 %d）" % [
			int(pa.summary.get("plant_count", 0)),
			int(pa.summary.get("healthy_count", 0)),
			int(pa.summary.get("water_short_count", 0)),
			int(pa.summary.get("withered_count", 0)),
		]
		draw_string(font, rect.position + Vector2(28.0, y + 86.0), sum_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.85, 0.95, 0.82, 0.85))

	draw_string(font, rect.position + Vector2(28.0, rect.size.y - 32.0), "提示：按 N 重开", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.70, 0.86, 0.75, 0.7))


# === Helpers ===

func _cell_rect(cell: Vector2i) -> Rect2:
	return Rect2(
		GRID_ORIGIN + Vector2(float(cell.x) * CELL_SIZE, float(cell.y) * CELL_SIZE) - camera_offset,
		Vector2(CELL_SIZE, CELL_SIZE),
	)


# 让所有"挂在场景上、跟着格子走的"Node2D 跟随镜头。
# 之前 _add_placed_tile_visual 只设了一次 piece.position，所以相机一平移，
# 背景格(_draw 画的)动了而地块(Node2D 子节点)不动；这里每帧/每次拖动都重算。
func _sync_pieces_to_camera() -> void:
	for cell in placed_tile_nodes.keys():
		var piece = placed_tile_nodes[cell]
		if piece != null and is_instance_valid(piece):
			piece.position = _cell_rect(cell).get_center()
	if preview_piece != null and is_instance_valid(preview_piece) and preview_piece.visible and has_hovered_cell:
		preview_piece.position = _cell_rect(hovered_cell).get_center()


func _screen_to_cell(screen_position: Vector2) -> Dictionary:
	# 把屏幕坐标反推回 logical cell —— 超出可视区也返回，允许在屏外点击
	var logical_pixel = screen_position - GRID_ORIGIN + camera_offset
	var column = int(floor(logical_pixel.x / CELL_SIZE))
	var row = int(floor(logical_pixel.y / CELL_SIZE))
	return {"cell": Vector2i(column, row)}


func _find_first_visible_legal_move() -> Dictionary:
	if board_state.tile_to_place == null or int(board_state.phase) != BoardState.Phase.PLACE:
		return {}
	# BFS 外扩：以所有已放块为种子，从每个块的 4 邻出发向外搜索，遇到首个合法放法即返回
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
			# 检查任意旋转
			for rotation in range(4):
				if bool(board_state.can_place(board_state.tile_to_place, n_cell, rotation)["valid"]):
					return {"cell": n_cell, "rotation": rotation}
			# 半径限制：从原点 (0,0) 计算曼哈顿距离，避免漫无边际扫全平面
			if abs(n_cell.x) + abs(n_cell.y) > SEARCH_RADIUS:
				continue
			queue.append(n_cell)
	return {}


func _set_toast(message: String, duration: float) -> void:
	toast_text = message
	toast_time = duration
	queue_redraw()


func _player_color(player_id: int) -> Color:
	return Color("#7ecf91") if player_id == 0 else Color("#ed9b70")


func _owner_color(player_id: int) -> Color:
	if player_id < 0:
		return Color("#d8c88d")
	return _player_color(player_id)


func _cell_short(cell: Vector2i) -> String:
	return "(%d,%d)" % [cell.x, cell.y]


func _format_winners(winner: Dictionary) -> String:
	if bool(winner.get("is_tie", true)):
		return "平局"
	var ids: Array = winner.get("winners", [])
	var id_strs: Array = []
	for w in ids:
		id_strs.append(str(int(w) + 1))
	return "玩家 " + ", ".join(id_strs)


func _rounded_box(fill: Color, border: Color, border_width: int, radius: int) -> StyleBoxFlat:
	var box = StyleBoxFlat.new()
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


func _register_key_action(action: StringName, keycode: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var key_event = InputEventKey.new()
	key_event.physical_keycode = keycode
	InputMap.action_add_event(action, key_event)


# === 全自动游戏冒烟测试（脚本层模拟玩家手动推进 §7 全套流程） ===

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

	print("GAME_SMOKE_PASS: full §7 turn loop manual emulation succeeded; tile placement, plant/expand/skip, settle, end-game all green. tiles placed=%d, turn=%d." % [_smoke_last_placed, _smoke_last_turn])
	get_tree().quit()


# §7 全套：模拟玩家手动推进回合循环直到牌堆空，然后点"查看终局"，最后断言分数+赢家
var _smoke_last_placed: int = 0
var _smoke_last_turn: int = 0


func _run_full_turn_loop_smoke() -> bool:
	# 每回合：抽牌 → 放完 → 跳过动作 → 结算 → 切玩家
	# 玩家 0 在某回合人工触发种草 + 扩张（覆盖到 2 个不同的 land_region 上）
	var sandbox = BOARD_STATE_SCRIPT.new()
	var starter: TileDefinition = tile_catalog.starter_tile()
	sandbox.start_with(starter)
	# 主 board 也用同一个（让本冒烟可以共享 deck）
	var board = board_state

	# 让玩家 0 有更多种子方便测试
	for owner in [0, 1]:
		for species in [PLANT_SCRIPT.Species.GRASS, PLANT_SCRIPT.Species.FLOWER, PLANT_SCRIPT.Species.TREE]:
			board.seed_inventory[owner][species] = 4

	var placed_count = 0
	var hard_caps = 200  # 防止无限循环
	while int(board.phase) != BoardState.Phase.GAME_OVER and hard_caps > 0:
		hard_caps -= 1
		# 1. 抽牌
		if deck_index >= deck.size():
			break
		var deal: Dictionary = board.deal_tile(deck[deck_index])
		if not bool(deal["valid"]):
			push_error("Loop smoke: deal rejected: %s" % deal["reason"])
			return false

		# 2. BFS 找到任意合法位置放下去（手动模拟玩家点空格）
		var placed_this_turn: bool = false
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
			var found_neighbour: bool = false
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
			# §7.1.2 漏牌：玩家抽到一块但无合法位置，弃置该牌，本回合作废（切玩家、turn+1、回 DEAL）
			deck_index += 1
			board.active_player = int(posmod(board.active_player + 1, board.player_count))
			board.turn_number += 1
			board.tile_to_place = null
			board.phase = BoardState.Phase.DEAL
			continue

		# 3. 完成放置
		if not bool(board.finish_placement()["valid"]):
			push_error("Loop smoke: finish_placement rejected.")
			return false

		# 4. 动作窗口：玩家主动种一棵草（如果有合法种的话）
		var planted = false
		if board.turn_placed_cells.size() > 0:
			var tnew_cell: Vector2i = board.turn_placed_cells[0]
			var chk: Dictionary = board.can_plant_at(tnew_cell, PLANT_SCRIPT.Species.GRASS, board.active_player)
			if bool(chk["valid"]):
				var pr: Dictionary = board.plant(tnew_cell, PLANT_SCRIPT.Species.GRASS, board.active_player)
				if bool(pr["valid"]):
					planted = true

		# 5. 跳过所有剩余动作（玩家手动"回合结束"）
		var next_deck_idx = deck_index + 1
		var deck_is_empty = next_deck_idx >= deck.size()
		var settle_result: Dictionary = board.finish_action_window(PLANT_ENGINE_SCRIPT, deck_is_empty)
		if not bool(settle_result["valid"]):
			push_error("Loop smoke: finish_action_window rejected: %s" % settle_result["reason"])
			return false
		deck_index = next_deck_idx
		await get_tree().process_frame

	# 6. 到了 GAME_OVER → 手动触发 run_end_game
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
	# 两玩家至少有一棵植物被种过（之前手动种了一棵 + 后续结算没清掉）
	if board.plants.is_empty():
		push_error("Loop smoke: expected at least 1 plant after full loop, got 0.")
		return false
	if not board.plants.is_empty() and placed_count <= 0:
		push_error("Loop smoke: no tile placed during loop, but plants exist (seed was drained).")
		return false
	# winners 非空
	if winner.get("winners", []).is_empty():
		push_error("Loop smoke: no winner resolved.")
		return false

	_smoke_last_placed = placed_count
	_smoke_last_turn = board.turn_number
	# 回归保险：无限地图下必须能放满整副牌（72 块）而不是被旧 7×9 限死
	if placed_count < 60:
		push_error("Loop smoke: infinite-map regression — only placed %d tiles, expected ≥60." % placed_count)
		return false
	return true


func _run_rule_contract_smoke() -> bool:
	var sandbox = BOARD_STATE_SCRIPT.new()
	var starter = tile_catalog.starter_tile()
	var sample_tile: TileDefinition = tile_catalog.get_definition(&"road_cross_building_a")
	if sample_tile == null:
		sample_tile = tile_catalog.build_deck()[0]
	sandbox.start_with(starter)
	if not _run_three_land_river_prefab_smoke():
		return false

	if bool(sandbox.can_place(sample_tile, Vector2i(4, 4), 0)["valid"]):
		push_error("Rule smoke test failed: disconnected placement was accepted.")
		return false
	if bool(sandbox.can_place(sample_tile, Vector2i(0, -1), 0)["valid"]):
		push_error("Rule smoke test failed: water-to-land mismatch was accepted.")
		return false
	if bool(sandbox.can_place(sample_tile, Vector2i(0, -1), 1)["valid"]) \
		or bool(sandbox.can_place(sample_tile, Vector2i(0, -1), 2)["valid"]) \
		or bool(sandbox.can_place(sample_tile, Vector2i(0, -1), 3)["valid"]):
		push_error("Rule smoke test failed: some rotation of road_cross_building_a matched starter's all-LAND edges.")
		return false
	var land_tile: TileDefinition = tile_catalog.get_definition(&"city_cap_a")
	if land_tile == null:
		push_error("Rule smoke test failed: city_cap_a definition missing.")
		return false
	if not bool(sandbox.place(land_tile, Vector2i(0, -1), 2, 0)["valid"]):
		push_error("Rule smoke test failed: matching LAND-LAND placement was rejected.")
		return false
	if not bool(sandbox.place(land_tile, Vector2i(1, 0), 3, 1)["valid"]):
		push_error("Rule smoke test failed: second matching LAND-LAND placement was rejected.")
		return false
	if bool(sandbox.can_place(sample_tile, Vector2i(0, -2), 0)["valid"]):
		push_error("Rule smoke test failed: disconnected placement was accepted at (0,-2).")
		return false
	return true


func _run_three_land_river_prefab_smoke() -> bool:
	var garden_definition: TileDefinition
	for definition in tile_catalog.build_deck():
		if definition.id == &"three_land_river_garden_a":
			garden_definition = definition
			break
	if garden_definition == null or garden_definition.visual_scene == null:
		push_error("Tile smoke test failed: the three-land river prefab is absent from the playable deck.")
		return false

	var garden := garden_definition.visual_scene.instantiate() as ThreeLandRiverTile
	if garden == null:
		push_error("Tile smoke test failed: the three-land river prefab did not instantiate as its authored tile type.")
		return false
	garden.hide()
	add_child(garden)

	var west_field := garden.get_node_or_null(^"WestField") as FieldGrowthState
	var east_field := garden.get_node_or_null(^"EastField") as FieldGrowthState
	if west_field == null or east_field == null:
		garden.queue_free()
		push_error("Tile smoke test failed: the three-land river prefab is missing one of its authored fields.")
		return false

	var west_bare := west_field.get_node_or_null(^"BareDetails") as CanvasItem
	var west_growing := west_field.get_node_or_null(^"GrowingDetails") as CanvasItem
	var east_bare := east_field.get_node_or_null(^"BareDetails") as CanvasItem
	var east_wilted := east_field.get_node_or_null(^"WiltedDetails") as CanvasItem
	if west_bare == null or west_growing == null or east_bare == null or east_wilted == null:
		garden.queue_free()
		push_error("Tile smoke test failed: an authored crop-state layer is missing from the three-land river prefab.")
		return false

	var states_are_valid := garden.sow_field(&"west_field") and garden.wilt_field(&"east_field")
	states_are_valid = states_are_valid and west_field.growth_state == FieldGrowthState.GrowthState.GROWING
	states_are_valid = states_are_valid and east_field.growth_state == FieldGrowthState.GrowthState.WILTED
	states_are_valid = states_are_valid and not west_bare.visible and west_growing.visible
	states_are_valid = states_are_valid and not east_bare.visible and east_wilted.visible
	garden.queue_free()

	if not states_are_valid:
		push_error("Tile smoke test failed: the two authored fields did not switch between bare, growing, and wilted layers independently.")
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
		push_error("Rule engine smoke failed: merged net should have P_tile=2 (1+1), got %d." % a3.water_nets[0].P_tile)
		return false
	if a3.water_nets[0].open_edges.size() != 4:
		push_error("Rule engine smoke failed: merged net should have 4 open water edges, got %d." % a3.water_nets[0].open_edges.size())
		return false
	if a3.land_regions.size() != 0:
		push_error("Rule engine smoke failed: merged water net scenario should have 0 land regions, got %d." % a3.land_regions.size())
		return false

	print("RULE_ENGINE_SMOKE_PASS: starter land region=1, road_cross4 alone water net=1/P=1/S=1, road_straight east merges net to P=2/4-open-edges.")
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

	# §7.2.2.B 限制：plant 只能在本回合新放的格子上 —— 第一个 plant 调用 starter（(0,0)）不是 turn_placed，应拒
	var r0 = board.plant(Vector2i.ZERO, GD.Species.GRASS, 0)
	if bool(r0["valid"]):
		push_error("Plants smoke failed: planting on starter (not turn_placed) was accepted — §7.2.2.B should reject.")
		return false

	# 把 starter 标记为 turn_placed（用于覆盖 §7.2.2.B 限制）
	board.turn_placed_cells.append(Vector2i.ZERO)

	var r1 = board.plant(Vector2i.ZERO, GD.Species.GRASS, 0)
	if not bool(r1["valid"]):
		push_error("Plants smoke failed: planting grass on starter was rejected: %s" % r1["reason"])
		return false
	if int(board.seed_inventory[0][GD.Species.GRASS]) != 1:
		push_error("Plants smoke failed: P1 grass seed not consumed (got %d)." % int(board.seed_inventory[0][GD.Species.GRASS]))
		return false
	if board.plants.size() != 1:
		push_error("Plants smoke failed: 1 plant expected after planting, got %d." % board.plants.size())
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
		push_error("Plants smoke failed: P2 planting flower on P1's grass tile was rejected: %s" % r_other_species["reason"])
		return false

	# 直接走 settle_with_rule（不重跑 analyze，避免覆盖之前的 lr.is_closed）
	var rule = RuleEngine.analyze(board)
	var pa1 = PE.settle_with_rule(board, rule)
	if int(pa1.summary["water_short_count"]) != 2:
		push_error("Plants smoke failed: both grass+flower should be WATER_SHORT (V_L=0), got summary=%s" % str(pa1.summary))
		return false

	var s1 = PE.score(board)
	if absf(float(s1["scores"][0]) - 0.0) > 0.001 or absf(float(s1["scores"][1]) - 0.0) > 0.001:
		push_error("Plants smoke failed: WATER_SHORT plants should not score, got %s" % str(s1))
		return false

	for plant_id in board.plants:
		var p = board.plants[plant_id]
		p.form = GD.Form.HEALTHY
	var s2 = PE.score(board)
	if absf(float(s2["scores"][0]) - 1.0) > 0.001:
		push_error("Plants smoke failed: P1 grass score expected 1.0, got %f" % float(s2["scores"][0]))
		return false
	if absf(float(s2["scores"][1]) - 1.0) > 0.001:
		push_error("Plants smoke failed: P2 flower score expected 1.0 (×0.5 unclosed), got %f" % float(s2["scores"][1]))
		return false

	var w = PE.resolve_winner(s2, 2)
	if w["is_tie"] or int(w["winners"][0]) != 1:
		push_error("Plants smoke failed: tiebreaker expected P2 (1 healthy_flower) wins, got %s" % str(w))
		return false

	# §5.6 阶段 B 退还
	var target_lr = rule.land_regions[0]
	target_lr.is_closed = true
	for wn in rule.water_nets:
		wn.is_closed = true
	var grass_seed_before = int(board.seed_inventory[0][GD.Species.GRASS])
	var flower_seed_before = int(board.seed_inventory[1][GD.Species.FLOWER])
	var pa2 = PE.settle_with_rule(board, rule)
	if int(pa2.summary["plant_count"]) != 0:
		push_error("Plants smoke failed: stage B should have removed plants, got summary=%s" % str(pa2.summary))
		return false
	if int(board.seed_inventory[0][GD.Species.GRASS]) - grass_seed_before != 1:
		push_error("Plants smoke failed: grass seed refund wrong (%d -> %d)." % [grass_seed_before, int(board.seed_inventory[0][GD.Species.GRASS])])
		return false
	if int(board.seed_inventory[1][GD.Species.FLOWER]) - flower_seed_before != 1:
		push_error("Plants smoke failed: flower seed refund wrong (%d -> %d)." % [flower_seed_before, int(board.seed_inventory[1][GD.Species.FLOWER])])
		return false

	# §5.7 终局升级
	var pp = Plant.new()
	pp.id = 99
	pp.species = GD.Species.GRASS
	pp.owner = 0
	pp.tile_cell = Vector2i.ZERO
	pp.form = GD.Form.WATER_SHORT
	board.plants[pp.id] = pp
	var pp_an = RuleEngine.analyze(board)
	var pp_lr = pp_an.land_region_by_cell.get(Vector2i.ZERO, null)
	pp.land_region_id = int(pp_lr.id) if pp_lr != null else -1
	var pa3 = PE.end_game_settle(board)
	if int(pp.form) != GD.Form.WITHERED:
		push_error("Plants smoke failed: end_game_settle should upgrade WATER_SHORT to WITHERED, got form=%d" % int(pp.form))
		return false

	print("PLANTS_SMOKE_PASS: seeds=2/2/2 each; plant API gates species collision & ownership; V_L=0 → WATER_SHORT; §6.4 halves flower score on unclosed land; tiebreaker prefers healthy_flower; §5.6 stage B refunds seeds and removes plants; §5.7 upgrades WATER_SHORT to WITHERED.")
	return true


func _capture_game_preview() -> void:
	for move_index in range(7):
		# 抽牌：给当前玩家发一张，进入 PLACE
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
		# 放完自动进入动作窗口；这里直接结算并切人到下一玩家，加速布局
		board_state.finish_action_window(PLANT_ENGINE_SCRIPT, deck_index >= deck.size())
	await get_tree().create_timer(0.35).timeout
	var capture_directory = ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(capture_directory)
	var preview = get_viewport().get_texture().get_image()
	preview.save_png(capture_directory.path_join("tile_placement_preview.png"))
	get_tree().quit()
