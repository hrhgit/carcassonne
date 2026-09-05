extends Node2D

const BOARD_STATE_SCRIPT := preload("res://scripts/board_state.gd")
const TILE_VIEW_SCRIPT := preload("res://scripts/tile_view.gd")
const UI_FONT_SCRIPT := preload("res://scripts/ui_font.gd")

const GAME_SMOKE_ARGUMENT := "--game-smoke"
const CAPTURE_ARGUMENT := "--capture-game"

const BOARD_COLUMNS := 9
const BOARD_ROWS := 7
const BOARD_CENTER := Vector2i(4, 3)
const GRID_ORIGIN := Vector2(48.0, 157.0)
const CELL_SIZE := 78.0
const BOARD_TILE_SIZE := 72.0

const PANEL_X := 790.0
const PANEL_WIDTH := 438.0
const CARD_POSITION := Vector2(1000.0, 246.0)
const CARD_TILE_SIZE := 184.0
const ROTATE_BUTTON := Rect2(814.0, 467.0, 194.0, 43.0)
const RESET_BUTTON := Rect2(1021.0, 467.0, 184.0, 43.0)

@onready var tile_catalog: TileCatalog = $TileCatalog

var board_state
var deck: Array[TileDefinition] = []
var current_tile = null
var deck_index := 0
var current_player := 0
var turn_number := 1
var current_rotation := 0
var game_over := false

var placed_tile_nodes: Dictionary = {}
var hand_piece
var preview_piece
var has_hovered_cell := false
var hovered_cell := Vector2i.ZERO
var preview_is_valid := false

var toast_text := "点击高亮的空格以放置地块"
var toast_time := 0.0


func _ready() -> void:
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

	var user_arguments := OS.get_cmdline_user_args()
	if GAME_SMOKE_ARGUMENT in user_arguments:
		call_deferred("_run_game_smoke")
	elif CAPTURE_ARGUMENT in user_arguments:
		call_deferred("_capture_game_preview")


func _process(delta: float) -> void:
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

	if event is InputEventMouseMotion:
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

	if ROTATE_BUTTON.has_point(event.position):
		_rotate_current_tile()
		get_viewport().set_input_as_handled()
		return
	if RESET_BUTTON.has_point(event.position):
		_start_new_game()
		get_viewport().set_input_as_handled()
		return

	var board_hit := _screen_to_cell(event.position)
	if not board_hit.is_empty():
		_try_place_current_tile(board_hit["cell"])
		get_viewport().set_input_as_handled()


func _draw() -> void:
	var canvas_size := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, canvas_size), Color("#09221c"))
	draw_circle(Vector2(126.0, 105.0), 350.0, Color(0.14, 0.34, 0.25, 0.18))
	draw_circle(Vector2(1140.0, 760.0), 420.0, Color(0.02, 0.10, 0.085, 0.52))
	for x in range(-280, int(canvas_size.x) + 310, 82):
		draw_line(Vector2(x, 0.0), Vector2(x + 410.0, canvas_size.y), Color(0.42, 0.72, 0.54, 0.035), 1.0)

	_draw_header()
	_draw_board()
	_draw_panel()
	_draw_footer()


func _start_new_game() -> void:
	for tile_node in placed_tile_nodes.values():
		tile_node.queue_free()
	placed_tile_nodes.clear()

	deck = tile_catalog.build_deck()
	deck_index = 0
	current_player = 0
	turn_number = 1
	current_rotation = 0
	game_over = false
	has_hovered_cell = false
	preview_piece.hide()

	board_state.start_with(tile_catalog.starter_tile())
	_add_placed_tile_visual(Vector2i.ZERO)
	current_tile = deck[deck_index]
	_sync_hand_piece()
	_set_toast("玩家 1 先行", 2.0)
	queue_redraw()


func _rotate_current_tile() -> void:
	if game_over or current_tile == null:
		return
	current_rotation = int(posmod(current_rotation + 1, 4))
	_sync_hand_piece()
	_refresh_preview()
	_set_toast("旋转至 %d°" % (current_rotation * 90), 1.35)


func _try_place_current_tile(cell: Vector2i) -> void:
	if game_over:
		_set_toast("牌堆已空 · 点击「重开」或按 N", 2.4)
		return

	var result: Dictionary = board_state.place(current_tile, cell, current_rotation, current_player)
	if not bool(result["valid"]):
		_set_toast("无法放置：%s" % result["reason"], 2.8)
		_refresh_preview()
		return

	_add_placed_tile_visual(cell)
	var placed_by := current_player + 1
	current_player = (current_player + 1) % 2
	turn_number += 1
	deck_index += 1
	current_rotation = 0

	if deck_index >= deck.size():
		game_over = true
		current_tile = null
		hand_piece.hide()
		preview_piece.hide()
		_set_toast("牌堆已空 · 玩家 %d 完成最后放置" % placed_by, 4.0)
	else:
		current_tile = deck[deck_index]
		_sync_hand_piece()
		_set_toast("玩家 %d 的回合" % (current_player + 1), 2.2)

	_refresh_preview()
	queue_redraw()


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
	if current_tile == null:
		hand_piece.hide()
		return
	hand_piece.position = CARD_POSITION + Vector2(CARD_TILE_SIZE * 0.5, CARD_TILE_SIZE * 0.5)
	hand_piece.show_tile(current_tile, current_rotation, CARD_TILE_SIZE, _player_color(current_player))
	hand_piece.modulate = Color.WHITE
	hand_piece.show()


func _update_hover(screen_position: Vector2) -> void:
	var hit := _screen_to_cell(screen_position)
	var new_has_hover := not hit.is_empty()
	var new_cell := hovered_cell
	if new_has_hover:
		new_cell = hit["cell"]
	if new_has_hover == has_hovered_cell and (not new_has_hover or new_cell == hovered_cell):
		return
	has_hovered_cell = new_has_hover
	hovered_cell = new_cell
	_refresh_preview()


func _refresh_preview() -> void:
	preview_is_valid = false
	if game_over or current_tile == null or not has_hovered_cell or board_state.has_tile(hovered_cell):
		preview_piece.hide()
		queue_redraw()
		return

	var result: Dictionary = board_state.can_place(current_tile, hovered_cell, current_rotation)
	preview_is_valid = bool(result["valid"])
	preview_piece.position = _cell_rect(hovered_cell).get_center()
	preview_piece.show_tile(current_tile, current_rotation, BOARD_TILE_SIZE, _player_color(current_player))
	preview_piece.modulate = Color(0.76, 1.0, 0.84, 0.64) if preview_is_valid else Color(1.0, 0.49, 0.42, 0.56)
	preview_piece.show()
	queue_redraw()


func _draw_header() -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	draw_string(font, Vector2(52.0, 56.0), "碧水沃野", HORIZONTAL_ALIGNMENT_LEFT, -1, 28, Color("#e7f1cf"))
	draw_line(Vector2(54.0, 84.0), Vector2(254.0, 84.0), Color("#89c99b"), 2.0)


func _draw_board() -> void:
	var board_rect := Rect2(GRID_ORIGIN - Vector2(13.0, 13.0), Vector2(BOARD_COLUMNS * CELL_SIZE + 26.0, BOARD_ROWS * CELL_SIZE + 26.0))
	draw_style_box(_rounded_box(Color(0.025, 0.10, 0.075, 0.90), Color("#325d48"), 2, 22), board_rect)

	for row in range(BOARD_ROWS):
		for column in range(BOARD_COLUMNS):
			var cell := _display_to_logical(Vector2i(column, row))
			var rect := _cell_rect(cell)
			var cell_color := Color(0.06, 0.20, 0.14, 0.52)
			if not board_state.has_tile(cell) and not game_over and current_tile != null:
				var result: Dictionary = board_state.can_place(current_tile, cell, current_rotation)
				if bool(result["valid"]):
					cell_color = Color(0.11, 0.38, 0.25, 0.76)
			draw_style_box(_rounded_box(cell_color, Color(0.26, 0.52, 0.38, 0.20), 1, 11), rect)

	if has_hovered_cell:
		var hover_rect := _cell_rect(hovered_cell).grow(-1.0)
		var outline := Color("#8ff0a3") if preview_is_valid else Color("#ff8975")
		draw_rect(hover_rect, outline, false, 3.0, true)


func _draw_panel() -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var panel_rect := Rect2(PANEL_X, 126.0, PANEL_WIDTH, 596.0)
	draw_style_box(_rounded_box(Color(0.035, 0.13, 0.095, 0.92), Color("#315f49"), 2, 22), panel_rect)

	var turn_title := "牌堆已空" if game_over else "第 %d 回合 · 玩家 %d" % [turn_number, current_player + 1]
	var turn_color := Color("#d7f0c0") if game_over else _player_color(current_player)
	draw_string(font, Vector2(PANEL_X + 28.0, 161.0), turn_title, HORIZONTAL_ALIGNMENT_LEFT, -1, 19, turn_color)

	_draw_player_row(Vector2(PANEL_X + 24.0, 205.0), 0)
	_draw_player_row(Vector2(PANEL_X + 224.0, 205.0), 1)

	draw_string(font, Vector2(PANEL_X + 28.0, 261.0), "当前地块", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.74, 0.89, 0.78, 0.66))
	if current_tile != null:
		draw_string(font, Vector2(PANEL_X + 28.0, 285.0), current_tile.display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("#eff3d2"))
	else:
		draw_string(font, Vector2(PANEL_X + 28.0, 285.0), "没有剩余地块", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color("#eff3d2"))

	_draw_button(ROTATE_BUTTON, "旋转  R", false)
	_draw_button(RESET_BUTTON, "重开  N", false)

	draw_string(font, Vector2(PANEL_X + 28.0, 556.0), "边口", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.74, 0.89, 0.78, 0.66))
	draw_line(Vector2(PANEL_X + 30.0, 579.0), Vector2(PANEL_X + 76.0, 579.0), Color("#b66f3f"), 10.0, true)
	draw_string(font, Vector2(PANEL_X + 91.0, 584.0), "土地", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.81, 0.90, 0.74, 0.75))
	draw_line(Vector2(PANEL_X + 30.0, 610.0), Vector2(PANEL_X + 76.0, 610.0), Color("#2697b5"), 6.0, true)
	draw_circle(Vector2(PANEL_X + 53.0, 610.0), 4.0, Color("#d3fff0"))
	draw_string(font, Vector2(PANEL_X + 91.0, 615.0), "水流", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.72, 0.90, 0.91, 0.75))
	draw_line(Vector2(PANEL_X + 30.0, 641.0), Vector2(PANEL_X + 76.0, 641.0), Color("#8fbd5d"), 8.0, true)
	draw_string(font, Vector2(PANEL_X + 91.0, 646.0), "空地", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.75, 0.89, 0.72, 0.75))

	draw_string(font, Vector2(PANEL_X + 28.0, 687.0), "剩余地块：%d" % (deck.size() - deck_index), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.70, 0.86, 0.75, 0.62))


func _draw_player_row(origin: Vector2, player_id: int) -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var active := not game_over and current_player == player_id
	var fill := Color(0.09, 0.27, 0.18, 0.90) if active else Color(0.045, 0.16, 0.115, 0.75)
	draw_style_box(_rounded_box(fill, _player_color(player_id).darkened(0.22), 1, 10), Rect2(origin, Vector2(177.0, 42.0)))
	draw_circle(origin + Vector2(16.0, 20.0), 8.0, _player_color(player_id))
	draw_string(font, origin + Vector2(31.0, 18.0), "玩家 %d" % (player_id + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("#eff3d2"))
	draw_string(font, origin + Vector2(31.0, 33.0), "已放 %d 块" % board_state.owned_tile_count(player_id), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.72, 0.87, 0.75, 0.65))


func _draw_button(rect: Rect2, label: String, _disabled: bool) -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var hovered := rect.has_point(get_viewport().get_mouse_position())
	var fill := Color(0.15, 0.38, 0.25, 0.95) if hovered else Color(0.09, 0.28, 0.19, 0.94)
	draw_style_box(_rounded_box(fill, Color("#78bc85"), 1, 10), rect)
	draw_string(font, rect.position + Vector2(18.0, 27.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("#e8f1d0"))


func _draw_footer() -> void:
	var font: Font = UI_FONT_SCRIPT.ui_font()
	var footer_y := 762.0
	draw_string(font, Vector2(52.0, footer_y), "点击高亮空格放置 · R / 右键旋转 · 边口需匹配", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.70, 0.86, 0.75, 0.62))
	if toast_time > 0.0:
		var alpha := minf(1.0, toast_time * 1.4)
		draw_string(font, Vector2(52.0, footer_y + 30.0), toast_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.96, 0.82, alpha))


func _cell_rect(cell: Vector2i) -> Rect2:
	var display_cell := _logical_to_display(cell)
	return Rect2(
		GRID_ORIGIN + Vector2(display_cell.x * CELL_SIZE, display_cell.y * CELL_SIZE),
		Vector2(CELL_SIZE, CELL_SIZE),
	)


func _logical_to_display(cell: Vector2i) -> Vector2i:
	return cell + BOARD_CENTER


func _display_to_logical(display_cell: Vector2i) -> Vector2i:
	return display_cell - BOARD_CENTER


func _screen_to_cell(screen_position: Vector2) -> Dictionary:
	var local_position := screen_position - GRID_ORIGIN
	if local_position.x < 0.0 or local_position.y < 0.0:
		return {}
	var column := int(floor(local_position.x / CELL_SIZE))
	var row := int(floor(local_position.y / CELL_SIZE))
	if column < 0 or column >= BOARD_COLUMNS or row < 0 or row >= BOARD_ROWS:
		return {}
	return {"cell": _display_to_logical(Vector2i(column, row))}


func _find_first_visible_legal_move() -> Dictionary:
	if current_tile == null or game_over:
		return {}
	for rotation in range(4):
		for row in range(BOARD_ROWS):
			for column in range(BOARD_COLUMNS):
				var cell := _display_to_logical(Vector2i(column, row))
				if bool(board_state.can_place(current_tile, cell, rotation)["valid"]):
					return {"cell": cell, "rotation": rotation}
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


func _rounded_box(fill: Color, border: Color, border_width: int, radius: int) -> StyleBoxFlat:
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


func _register_key_action(action: StringName, keycode: int) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var key_event := InputEventKey.new()
	key_event.physical_keycode = keycode
	InputMap.action_add_event(action, key_event)


func _run_game_smoke() -> void:
	if not _run_rule_contract_smoke():
		get_tree().quit(1)
		return

	var first_move := _find_first_visible_legal_move()
	if first_move.is_empty():
		push_error("Game smoke test failed: Player 1 has no visible legal move.")
		get_tree().quit(1)
		return
	current_rotation = int(first_move["rotation"])
	_sync_hand_piece()
	_dispatch_board_click(first_move["cell"])
	await get_tree().process_frame
	if current_player != 1 or board_state.owned_tile_count(0) != 1:
		push_error("Game smoke test failed: a legal Player 1 placement did not hand over the turn.")
		get_tree().quit(1)
		return

	var second_move := _find_first_visible_legal_move()
	if second_move.is_empty():
		push_error("Game smoke test failed: Player 2 has no visible legal move.")
		get_tree().quit(1)
		return
	current_rotation = int(second_move["rotation"])
	_sync_hand_piece()
	_dispatch_board_click(second_move["cell"])
	await get_tree().process_frame
	if current_player != 0 or board_state.owned_tile_count(1) != 1:
		push_error("Game smoke test failed: a legal Player 2 placement did not hand back the turn.")
		get_tree().quit(1)
		return

	while not game_over:
		var next_move := _find_first_visible_legal_move()
		if next_move.is_empty():
			push_error("Game smoke test failed: the remaining deck produced no visible legal move.")
			get_tree().quit(1)
			return
		current_rotation = int(next_move["rotation"])
		_sync_hand_piece()
		_dispatch_board_click(next_move["cell"])
		await get_tree().process_frame

	var expected_tiles_per_player := deck.size() / 2
	if deck_index != deck.size() or board_state.owned_tile_count(0) != expected_tiles_per_player or board_state.owned_tile_count(1) != expected_tiles_per_player:
		push_error("Game smoke test failed: the full shared deck did not finish with equal alternating ownership.")
		get_tree().quit(1)
		return

	print("GAME_SMOKE_PASS: marker matching rejects conflicts; UI clicks alternate both players and complete the full shared deck.")
	get_tree().quit()


func _run_rule_contract_smoke() -> bool:
	var sandbox = BOARD_STATE_SCRIPT.new()
	var starter := tile_catalog.starter_tile()
	var sample_tile: TileDefinition = tile_catalog.build_deck()[0]
	sandbox.start_with(starter)
	if not _run_three_land_river_prefab_smoke():
		return false

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
	if bool(sandbox.can_place(sample_tile, Vector2i(1, -1), 0)["valid"]):
		push_error("Rule smoke test failed: a candidate that mismatches one of two neighbours was accepted.")
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


func _dispatch_board_click(cell: Vector2i) -> void:
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = _cell_rect(cell).get_center()
	get_viewport().push_input(click, true)


func _capture_game_preview() -> void:
	for move_index in range(7):
		var move := _find_first_visible_legal_move()
		if move.is_empty():
			break
		current_rotation = int(move["rotation"])
		_try_place_current_tile(move["cell"])
	await get_tree().create_timer(0.35).timeout
	var capture_directory := ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(capture_directory)
	var preview := get_viewport().get_texture().get_image()
	preview.save_png(capture_directory.path_join("tile_placement_preview.png"))
	get_tree().quit()
