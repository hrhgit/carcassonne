extends Node3D

const BOARD_STATE_SCRIPT := preload("res://scripts/board_state.gd")
const UI_FONT_SCRIPT := preload("res://scripts/ui_font.gd")
const PLANT_ENGINE_SCRIPT := preload("res://scripts/plant_engine.gd")
const PLANT_SCRIPT := preload("res://scripts/plant.gd")
const RUNTIME_PLANT_SCATTER_SCRIPT := preload("res://scripts/runtime_plant_scatter_3d.gd")
const WATER_NETWORK_RENDERER_SCRIPT := preload("res://scripts/water_network_renderer_3d.gd")

const GAME_SMOKE_ARGUMENT := "--game-smoke"
const CAPTURE_ARGUMENT := "--capture-game"
const PLANTING_CAPTURE_ARGUMENT := "--capture-planting"

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

# 正交相机缩放参数（size 为竖直方向可见高度的一半）
const CAMERA_ORTHO_SIZE := 16.0
const CAMERA_ORTHO_SIZE_MIN := 8.0
const CAMERA_ORTHO_SIZE_MAX := 30.0
const CAMERA_ORTHO_ZOOM_STEP := 1.2

# 平移参数：logical 像素 = cell.x * CELL_SIZE
const PAN_KEY_STEP := 78.0 * 3.0
const PAN_WHEEL_STEP := 78.0 * 1.5
const PAN_LERP := 14.0
const SEARCH_RADIUS := 24

# §7 动作窗口：主动种植或跳过；植物扩张由放牌事件自动触发。
enum MenuMode { NONE, PLANT }

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
var land_outline_nodes: Array[Node3D] = []
var land_outline_signature := ""

var has_hovered_cell := false
var hovered_cell := Vector2i.ZERO
var preview_is_valid := false
var preview_border: Node3D = null

var camera_target := Vector3.ZERO
var camera_distance := CAMERA_DISTANCE

var toast_text := ""
var toast_time := 0.0

var menu_mode := MenuMode.NONE
var menu_cell := Vector2i.ZERO
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
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = CAMERA_ORTHO_SIZE
	_build_highlight_quad()
	_build_hud()
	_update_camera()

	_start_new_game()

	var user_arguments := OS.get_cmdline_user_args()
	if GAME_SMOKE_ARGUMENT in user_arguments:
		call_deferred("_run_game_smoke")
	elif PLANTING_CAPTURE_ARGUMENT in user_arguments:
		call_deferred("_capture_planting_interaction_preview")
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
			camera.size = clampf(camera.size - CAMERA_ORTHO_ZOOM_STEP, CAMERA_ORTHO_SIZE_MIN, CAMERA_ORTHO_SIZE_MAX)
			_update_camera()
			get_viewport().set_input_as_handled()
			return
		if mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.size = clampf(camera.size + CAMERA_ORTHO_ZOOM_STEP, CAMERA_ORTHO_SIZE_MIN, CAMERA_ORTHO_SIZE_MAX)
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
		var now_sec := float(Time.get_ticks_msec()) / 1000.0
		if int(board_state.phase) == BoardState.Phase.ACTION_WINDOW \
				and now_sec - last_right_click_time <= RIGHT_DOUBLE_CLICK_INTERVAL:
			# 双击右键：地块放置完成后快速结束回合
			last_right_click_time = -1.0
			_on_end_turn_button()
			get_viewport().set_input_as_handled()
			return
		last_right_click_time = now_sec
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

# 双击右键结束回合（仅动作窗口阶段生效）
const RIGHT_DOUBLE_CLICK_INTERVAL := 0.35
var last_right_click_time := -1.0


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
	# 把屏幕位移换算成世界平面位移（近似）；正交下按 size 换算
	var scale := camera.size / maxf(float(get_viewport().size.y), 1.0) * 2.0
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
	# 预览不覆盖颜色，只保留地块原貌；合法/非法仅由边框标示。
	if preview_border != null:
		var border_color := Color(0.35, 0.95, 0.55, 1.0) if preview_is_valid else Color(0.95, 0.30, 0.25, 1.0)
		for mi in preview_border.find_children("*", "MeshInstance3D", true, false):
			var bmat := StandardMaterial3D.new()
			bmat.albedo_color = border_color
			bmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			bmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			bmat.cull_mode = BaseMaterial3D.CULL_DISABLED
			(mi as MeshInstance3D).material_override = bmat


func _refresh_preview_piece() -> void:
	if preview_node != null:
		preview_node.queue_free()
		preview_node = null
	preview_border = null
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
	preview_border = _build_preview_border()
	preview_node.add_child(preview_border)
	_sync_preview()


func _build_preview_border() -> Node3D:
	# 沿地块边缘的一圈细描边，颜色叠加变轻后仍能一眼看出合法(绿)/非法(红)。
	var border := Node3D.new()
	border.name = "PreviewBorder"
	var thickness := 0.06
	var half := TILE_SIZE * 0.5
	var y := HIGHLIGHT_Y
	var edges := [
		Vector3(TILE_SIZE, thickness, thickness),
		Vector3(TILE_SIZE, thickness, thickness),
		Vector3(thickness, thickness, TILE_SIZE),
		Vector3(thickness, thickness, TILE_SIZE),
	]
	var positions := [
		Vector3(0.0, y, -half),
		Vector3(0.0, y, half),
		Vector3(-half, y, 0.0),
		Vector3(half, y, 0.0),
	]
	for i in edges.size():
		var box := BoxMesh.new()
		box.size = edges[i]
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.position = positions[i]
		border.add_child(mi)
	return border


func _update_hover(screen_position: Vector2) -> void:
	var phase := int(board_state.phase)
	if phase != BoardState.Phase.PLACE and phase != BoardState.Phase.ACTION_WINDOW:
		_clear_hover_visuals()
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
	if phase == BoardState.Phase.PLACE:
		_update_place_hover()
	else:
		_update_action_hover()
	_sync_preview()


func _update_place_hover() -> void:
	_clear_connected_land_outline()
	if not has_hovered_cell:
		hover_highlight.visible = false
		return
	hover_highlight.position = _cell_world_position(hovered_cell)
	var valid := false
	if board_state.tile_to_place != null and not board_state.has_tile(hovered_cell):
		valid = bool(board_state.can_place(board_state.tile_to_place, hovered_cell, current_rotation)["valid"])
	hover_highlight.visible = true
	var mat := hover_highlight.mesh.material as StandardMaterial3D
	mat.albedo_color = Color(0.45, 0.90, 0.60, 0.35) if valid else Color(1.0, 0.49, 0.42, 0.40)


func _update_action_hover() -> void:
	hover_highlight.visible = false
	if not has_hovered_cell or not board_state.has_tile(hovered_cell):
		_clear_connected_land_outline()
		return
	var connected_cells: Array[Vector2i] = board_state.connected_land_cells_at(hovered_cell)
	if connected_cells.is_empty():
		_clear_connected_land_outline()
		return
	var check: Dictionary = board_state.can_plant_any_species_at(hovered_cell, board_state.active_player)
	var outline_color := Color("#b8f47d") if bool(check["valid"]) else Color("#f0b46c")
	_show_connected_land_outline(connected_cells, outline_color)


func _clear_hover_visuals() -> void:
	if has_hovered_cell:
		has_hovered_cell = false
	hover_highlight.visible = false
	_clear_connected_land_outline()
	_sync_preview()


# 只根据各个已实例化预制件自带的 planting_masks 生成交互描边。
# 它是瞬时提示层，不改写地块网格、端口或基础材质。
func _show_connected_land_outline(cells: Array[Vector2i], color: Color) -> void:
	var signature := "%s|%s" % [color.to_html(true), str(cells)]
	if signature == land_outline_signature:
		return
	_clear_connected_land_outline()
	land_outline_signature = signature
	for cell in cells:
		var tile: Node3D = placed_tile_nodes.get(cell, null)
		if tile == null:
			continue
		var layer := Node3D.new()
		layer.name = "ConnectedLandOutline"
		tile.add_child(layer)
		land_outline_nodes.append(layer)
		var artwork := tile as TileArtwork3D
		if artwork != null and not artwork.planting_masks.is_empty():
			for mask in artwork.planting_masks:
				if mask == null or not mask.is_valid():
					continue
				var outline := _make_land_mask_outline(mask, color)
				if outline != null:
					layer.add_child(outline)
		else:
			var fallback := _make_fallback_land_outline(color)
			if fallback != null:
				layer.add_child(fallback)


func _clear_connected_land_outline() -> void:
	for node in land_outline_nodes:
		if is_instance_valid(node):
			node.queue_free()
	land_outline_nodes.clear()
	land_outline_signature = ""


func _make_land_mask_outline(mask: PlantingMask3D, color: Color) -> MeshInstance3D:
	return _make_polygon_outline(mask.boundary, mask.surface_height + 0.032, color)


func _make_fallback_land_outline(color: Color) -> MeshInstance3D:
	var half := TILE_SIZE * 0.5 - 0.14
	var boundary := PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half),
		Vector2(half, half), Vector2(-half, half),
	])
	return _make_polygon_outline(boundary, HIGHLIGHT_Y + 0.02, color)


func _make_polygon_outline(boundary: PackedVector2Array, height: float, color: Color) -> MeshInstance3D:
	if boundary.size() < 3:
		return null
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half_width := 0.035
	for index in range(boundary.size()):
		var start := boundary[index]
		var finish := boundary[(index + 1) % boundary.size()]
		var direction := finish - start
		if direction.length_squared() < 0.000001:
			continue
		var side := Vector2(-direction.y, direction.x).normalized() * half_width
		var a := Vector3(start.x + side.x, height, start.y + side.y)
		var b := Vector3(start.x - side.x, height, start.y - side.y)
		var c := Vector3(finish.x - side.x, height, finish.y - side.y)
		var d := Vector3(finish.x + side.x, height, finish.y + side.y)
		tool.add_vertex(a)
		tool.add_vertex(b)
		tool.add_vertex(c)
		tool.add_vertex(a)
		tool.add_vertex(c)
		tool.add_vertex(d)
	var mesh := tool.commit()
	if mesh == null:
		return null
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	return instance


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
	if water_network_renderer == null:
		return
	var refresh_result: Dictionary = water_network_renderer.refresh(board_state, placed_tile_nodes)
	# 棋盘上存在供水网络时循环播放水流环境音，网络消失时停止。
	if int(refresh_result.get("network_count", 0)) > 0:
		Sfx.play_loop("water_flow_loop", -9.0)
	else:
		Sfx.stop_loop("water_flow_loop")


# === §7 流程 ===

func _start_new_game() -> void:
	_clear_connected_land_outline()
	for tile_node in placed_tile_nodes.values():
		if is_instance_valid(tile_node):
			tile_node.queue_free()
	placed_tile_nodes.clear()
	if preview_node != null:
		preview_node.queue_free()
		preview_node = null
	preview_border = null

	deck = tile_catalog.build_deck()
	deck_index = 0
	current_rotation = 0
	game_over_result = {}
	_clear_menu()

	board_state.start_with(tile_catalog.starter_tile())
	_add_placed_tile_visual(Vector2i.ZERO)

	_set_toast("新对局 · 玩家 1 先行 · 点「抽牌」开始", 3.0)
	Sfx.play("turn_start")
	_refresh_hud()
	call_deferred("_center_camera_on", Vector2i.ZERO)


func _rotate_current_tile() -> void:
	if int(board_state.phase) != BoardState.Phase.PLACE or board_state.tile_to_place == null:
		return
	current_rotation = int(posmod(current_rotation + 1, 4))
	Sfx.play("tile_rotate")
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
	_clear_connected_land_outline()
	_refresh_preview_piece()
	Sfx.play("tile_pickup")
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
	_set_toast("进入动作窗口 · 悬停查看连通土地，左键点空土地种植", 2.5)
	_refresh_hud()


func _on_end_turn_button() -> void:
	var phase = int(board_state.phase)
	if phase == BoardState.Phase.GAME_OVER:
		if game_over_result.is_empty():
			game_over_result = board_state.run_end_game(PLANT_ENGINE_SCRIPT)
			_play_end_game_sounds(game_over_result)
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
	_play_settle_sounds(result.get("plant_analysis", null))
	deck_index = next_deck_idx
	current_rotation = 0
	_clear_menu()
	_clear_connected_land_outline()
	_refresh_all_growth()
	if deck_is_empty:
		_set_toast("牌堆已空 · 玩家 %d 终局 · 点「查看终局」" % (board_state.active_player + 1), 3.0)
	else:
		Sfx.play("turn_start")
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
		Sfx.play("tile_invalid")
		return
	Sfx.play("tile_place")
	if _definition_carries_water(tile, current_rotation):
		Sfx.play("water_splash", -4.0)
	_add_placed_tile_visual(cell)
	var automatic_expansion: Dictionary = result.get("automatic_expansion", {})
	var species_conflict: Dictionary = result.get("species_conflict", {})
	var evicted_ids: Array = species_conflict.get("evicted_plant_ids", [])
	if not automatic_expansion.is_empty():
		Sfx.play("plant_grow")
	if not automatic_expansion.is_empty() or not evicted_ids.is_empty():
		_refresh_all_growth()
	has_hovered_cell = false
	hover_highlight.visible = false
	_clear_connected_land_outline()
	current_rotation = 0
	_refresh_preview_piece()
	_center_camera_on(cell)
	if automatic_expansion.is_empty() and evicted_ids.is_empty():
		_set_toast("已放置 · 悬停查看连通土地，左键点空土地种植", 2.8)
	elif not automatic_expansion.is_empty():
		_set_toast("已放置 · 邻接植物自动扩张；悬停查看连通土地", 2.8)
	else:
		_set_toast("已放置 · 连通区域发生物种驱逐，种子已退还", 2.8)
	_refresh_hud()
	# 放牌点击所在的位置就是最自然的第一个种植候选；无需等用户额外移动一次鼠标。
	call_deferred("_update_hover", get_viewport().get_mouse_position())


func _try_open_action_menu_for(cell: Vector2i) -> void:
	if not board_state.has_tile(cell):
		_set_toast("该位置尚未放地块。", 2.0)
		return
	_open_plant_menu(cell)


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
	menu_species_targets.clear()
	for s in species_with_seeds:
		menu_species_targets.append(int(s))
	_build_action_menu()


func _handle_menu_choice(index: int) -> void:
	var owner: int = board_state.active_player
	if menu_mode == MenuMode.PLANT:
		var species: int = int(menu_species_targets[index])
		var result: Dictionary = board_state.plant(menu_cell, species, owner)
		if bool(result["valid"]):
			Sfx.play("plant_seed")
			var species_conflict: Dictionary = result.get("species_conflict", {})
			var evicted_ids: Array = species_conflict.get("evicted_plant_ids", [])
			if evicted_ids.is_empty():
				_refresh_tile_growth(menu_cell)
				_set_toast("已种 %s（种子 −1）" % PLANT_SCRIPT.species_label(species), 2.0)
			else:
				_refresh_all_growth()
				_set_toast("已种 %s · 低优先级植物已被驱逐并退种" % PLANT_SCRIPT.species_label(species), 2.8)
		else:
			Sfx.play("tile_invalid", -6.0)
			_set_toast("种植失败：%s" % result["reason"], 2.5)
	_clear_menu()
	_clear_connected_land_outline()
	_refresh_hud()


func _clear_menu() -> void:
	menu_mode = MenuMode.NONE
	menu_cell = Vector2i.ZERO
	menu_species_targets.clear()
	if menu_panel != null:
		menu_panel.visible = false


# === HUD ===

func _build_hud() -> void:
	var ui := CanvasLayer.new()
	ui.name = "UI"
	add_child(ui)

	# 信息面板（右上：玩家信息 + 操作按钮）
	var panel := PanelContainer.new()
	panel.name = "InfoPanel"
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	# 显式固定右上偏移并强制向左生长，避免内容撑大后越出屏幕右侧
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.offset_left = -388
	panel.offset_right = -16
	panel.offset_top = 16
	panel.offset_bottom = 16
	panel.custom_minimum_size = Vector2(372, 0)
	panel.add_theme_stylebox_override("panel", _make_panel_style())
	ui.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	label_title = _make_label("碧水沃野 · 3D", 22, Color("#e7f1cf"))
	label_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(label_title)
	label_status = _make_label("", 14, Color("#cde9a2"))
	label_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(label_status)
	box.add_child(_make_separator())

	label_current_tile = _make_label("", 14, Color("#eff3d2"))
	box.add_child(label_current_tile)
	label_seeds = _make_label("", 13, Color(0.74, 0.89, 0.78, 0.9))
	box.add_child(label_seeds)
	box.add_child(_make_separator())

	for pid in range(2):
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", _make_player_chip_style(pid))
		var pl := _make_label("", 13, Color("#eff3d2"))
		chip.add_child(pl)
		box.add_child(chip)
		player_row_labels.append(pl)
	box.add_child(_make_separator())

	# 操作按钮（信息面板下方）
	var button_grid := GridContainer.new()
	button_grid.name = "ButtonGrid"
	button_grid.columns = 3
	button_grid.add_theme_constant_override("h_separation", 8)
	button_grid.add_theme_constant_override("v_separation", 8)
	btn_deal = _make_button("抽  牌", _on_deal_button, true)
	btn_finish_place = _make_button("完成放置", _on_finish_place_button)
	btn_end_turn = _make_button("回合结束", _on_end_turn_button, true)
	btn_rotate = _make_button("旋转 R", _rotate_current_tile)
	btn_reset = _make_button("重开 N", _start_new_game)
	for b in [btn_deal, btn_finish_place, btn_end_turn, btn_rotate, btn_reset]:
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button_grid.add_child(b)
	box.add_child(button_grid)

	label_toast = _make_label("", 15, Color(0.95, 1.0, 0.86, 1))
	label_toast.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	label_toast.set_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 12)
	label_toast.position = Vector2(20, -50)
	label_toast.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	label_toast.add_theme_constant_override("shadow_offset", 2)
	ui.add_child(label_toast)

	menu_panel = PanelContainer.new()
	menu_panel.name = "ActionMenu"
	menu_panel.visible = false
	menu_panel.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	menu_panel.add_theme_stylebox_override("panel", _make_panel_style())
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


func _make_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.13, 0.10, 0.9)
	style.set_corner_radius_all(14)
	style.set_border_width_all(1)
	style.border_color = Color(0.62, 0.82, 0.55, 0.35)
	style.set_content_margin_all(14)
	style.shadow_color = Color(0, 0, 0, 0.4)
	style.shadow_size = 10
	style.shadow_offset = Vector2(0, 4)
	return style


func _make_player_chip_style(player_id: int) -> StyleBoxFlat:
	var base := _player_color(player_id)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(base.r, base.g, base.b, 0.14)
	style.set_corner_radius_all(8)
	style.border_width_left = 4
	style.border_color = Color(base.r, base.g, base.b, 0.85)
	style.content_margin_left = 10
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	return style


func _make_separator() -> HSeparator:
	var separator := HSeparator.new()
	var line := StyleBoxLine.new()
	line.color = Color(0.62, 0.82, 0.55, 0.22)
	line.thickness = 1
	separator.add_theme_stylebox_override("separator", line)
	return separator


func _button_stylebox(bg: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(8)
	style.set_border_width_all(1)
	style.border_color = Color(bg.r + 0.14, bg.g + 0.14, bg.b + 0.12, 0.6)
	style.set_content_margin_all(6)
	return style


func _make_button(text: String, callback: Callable, accent: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_override("font", UI_FONT_SCRIPT.ui_font())
	button.add_theme_font_size_override("font_size", 15)
	button.custom_minimum_size = Vector2(0, 36)
	var base := Color("#3f7d4e") if accent else Color("#2c4630")
	button.add_theme_stylebox_override("normal", _button_stylebox(base))
	button.add_theme_stylebox_override("hover", _button_stylebox(base.lightened(0.16)))
	button.add_theme_stylebox_override("hover_pressed", _button_stylebox(base.lightened(0.16)))
	button.add_theme_stylebox_override("pressed", _button_stylebox(base.darkened(0.18)))
	button.add_theme_stylebox_override("disabled", _button_stylebox(Color(base.r, base.g, base.b, 0.35)))
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_theme_color_override("font_color", Color("#eef6dd"))
	button.add_theme_color_override("font_hover_color", Color("#ffffff"))
	button.add_theme_color_override("font_pressed_color", Color("#d8e8c4"))
	button.add_theme_color_override("font_disabled_color", Color(0.85, 0.92, 0.8, 0.4))
	button.pressed.connect(callback)
	button.pressed.connect(func() -> void: Sfx.play("ui_click"))
	button.mouse_entered.connect(func() -> void: Sfx.play("ui_hover"))
	return button


func _build_action_menu() -> void:
	for child in menu_box.get_children():
		child.queue_free()
	if menu_mode == MenuMode.PLANT:
		var title := _make_label("种植到 (%d,%d) · 选物种" % [menu_cell.x, menu_cell.y], 14, Color("#e7f1cf"))
		menu_box.add_child(title)
		for i in range(menu_species_targets.size()):
			var species: int = int(menu_species_targets[i])
			var bag: Dictionary = board_state.seed_inventory[board_state.active_player]
			var b := _make_button("%s（剩 %d）" % [PLANT_SCRIPT.species_label(species), int(bag.get(species, 0))], _menu_choice(i))
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
		var active_mark := "▶ " if pid == board_state.active_player else "　"
		player_row_labels[pid].text = "%sP%d · 已放 %d · 草 %d · 花 %d · 树 %d" % [
			active_mark,
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
			return "动作窗口 · 双击右键结束回合"
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

# 回合结算音效：全封闭土地块清场退种 → harvest；缺水升级枯萎 → plant_wilt
func _play_settle_sounds(plant_analysis) -> void:
	if plant_analysis == null:
		return
	if not plant_analysis.plants_removed.is_empty():
		Sfx.play("harvest")
	if not plant_analysis.closed_regions_stage_a.is_empty():
		Sfx.play("plant_wilt")


# 终局音效：先得分提示音，稍作停顿后播放胜负音乐
func _play_end_game_sounds(result: Dictionary) -> void:
	Sfx.play("score_point")
	var winner: Dictionary = result.get("winner", {})
	if bool(winner.get("is_tie", true)):
		# 平局：无胜负音乐，用高一点的得分音收尾
		get_tree().create_timer(0.8).timeout.connect(
			func() -> void: Sfx.play("score_point", 0.0, 1.18, 0.0))
	else:
		get_tree().create_timer(0.8).timeout.connect(
			func() -> void: Sfx.play("victory", 0.0, 1.0, 0.0))


# 判断地块（含旋转）是否带水面：用于放置时的水花音效
func _definition_carries_water(definition, rotation: int) -> bool:
	if definition == null:
		return false
	if definition.center_kind == TileDefinition.CenterKind.LAKE:
		return true
	for edge in range(4):
		if definition.edge_kind_at(edge, rotation) == TileDefinition.EdgeKind.WATER:
			return true
	return false


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
		push_error("Plants smoke failed: planting before a tile was placed was accepted.")
		return false

	var deal: Dictionary = board.deal_tile(starter)
	if not bool(deal["valid"]):
		push_error("Plants smoke failed: deal was rejected: %s" % deal["reason"])
		return false
	var place: Dictionary = board.commit_placement(Vector2i.RIGHT, 0)
	if not bool(place["valid"]):
		push_error("Plants smoke failed: placement was rejected: %s" % place["reason"])
		return false
	var connected: Array[Vector2i] = board.connected_land_cells_at(Vector2i.ZERO)
	if not connected.has(Vector2i.ZERO) or not connected.has(Vector2i.RIGHT):
		push_error("Plants smoke failed: connected LAND hover query did not include both joined tiles: %s" % str(connected))
		return false

	# 目标是开局就存在的格，而不是本回合刚放的 (1,0)：验证 r16 的任意历史地块种植。
	var r1 = board.plant(Vector2i.ZERO, GD.Species.GRASS, 0)
	if not bool(r1["valid"]):
		push_error("Plants smoke failed: planting grass on an older legal tile was rejected: %s" % r1["reason"])
		return false
	if int(board.seed_inventory[0][GD.Species.GRASS]) != 1:
		push_error("Plants smoke failed: P1 grass seed not consumed.")
		return false

	var r_repeat = board.plant(Vector2i.RIGHT, GD.Species.GRASS, 0)
	if bool(r_repeat["valid"]):
		push_error("Plants smoke failed: a second active planting action was accepted.")
		return false
	board.planting_action_used = false
	var r_other = board.plant(Vector2i.ZERO, GD.Species.GRASS, 1)
	if bool(r_other["valid"]):
		push_error("Plants smoke failed: P2 planting on P1's occupied tile was accepted.")
		return false
	if not board.tile_has_any_plant(Vector2i.ZERO):
		push_error("Plants smoke failed: successful planting did not occupy the target tile.")
		return false
	board.planting_action_used = true
	var finish: Dictionary = board.finish_action_window(PLANT_ENGINE_SCRIPT, false)
	if not bool(finish["valid"]):
		push_error("Plants smoke failed: could not finish the planting turn: %s" % finish["reason"])
		return false
	var deal_auto: Dictionary = board.deal_tile(starter)
	if not bool(deal_auto["valid"]):
		push_error("Plants smoke failed: auto-expansion deal was rejected: %s" % deal_auto["reason"])
		return false
	var auto_place: Dictionary = board.commit_placement(Vector2i.LEFT, 0)
	if not bool(auto_place["valid"]):
		push_error("Plants smoke failed: auto-expansion placement was rejected: %s" % auto_place["reason"])
		return false
	if Dictionary(auto_place.get("automatic_expansion", {})).is_empty() or not board.tile_has_any_plant(Vector2i.LEFT):
		push_error("Plants smoke failed: directly adjacent connected LAND did not auto-expand.")
		return false
	if int(board.seed_inventory[0][GD.Species.GRASS]) != 1:
		push_error("Plants smoke failed: automatic expansion consumed a grass seed.")
		return false
	# 目标格本身空着即可种入已有植物的 land_region；花会立即驱逐该区域的草。
	var flower_into_grass: Dictionary = board.plant(Vector2i.RIGHT, GD.Species.FLOWER, board.active_player)
	if not bool(flower_into_grass["valid"]):
		push_error("Plants smoke failed: planting into an occupied land region was rejected: %s" % flower_into_grass["reason"])
		return false
	if not board.tile_has_any_plant(Vector2i.RIGHT) or board.tile_has_any_plant(Vector2i.ZERO) or board.tile_has_any_plant(Vector2i.LEFT):
		push_error("Plants smoke failed: flower/grass conflict did not keep only the higher-priority flower.")
		return false
	if int(board.seed_inventory[0][GD.Species.GRASS]) != 2:
		push_error("Plants smoke failed: grass seed was not refunded once for the evicted land region.")
		return false

	print("PLANTS_SMOKE_PASS.")
	return true


func _capture_planting_interaction_preview() -> void:
	# 真实场景内的可见验收：先显示旧地块的连通 LAND 描边，再在该旧地块种植。
	# 不伪造 2D 图层；调用的正是鼠标悬停与状态机所使用的生产方法。
	var starter := tile_catalog.starter_tile()
	var deal: Dictionary = board_state.deal_tile(starter)
	if not bool(deal["valid"]):
		push_error("Planting capture: deal failed: %s" % deal["reason"])
		get_tree().quit(1)
		return
	_try_place_current_tile(Vector2i.RIGHT)
	if int(board_state.phase) != BoardState.Phase.ACTION_WINDOW:
		push_error("Planting capture: placement did not reach action window.")
		get_tree().quit(1)
		return

	has_hovered_cell = true
	hovered_cell = Vector2i.ZERO
	_update_action_hover()
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	var capture_directory := ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(capture_directory)
	var hover_image := get_viewport().get_texture().get_image()
	hover_image.save_png(capture_directory.path_join("planting_hover_connected_land_3d.png"))

	_on_board_cell_clicked(Vector2i.ZERO)
	var flower_choice := menu_species_targets.find(PLANT_SCRIPT.Species.FLOWER)
	if menu_mode != MenuMode.PLANT or flower_choice < 0:
		push_error("Planting capture: clicking an older legal tile did not open the species menu.")
		get_tree().quit(1)
		return
	_handle_menu_choice(flower_choice)
	if not board_state.tile_has_any_plant(Vector2i.ZERO):
		push_error("Planting capture: selecting a species did not plant on the older tile.")
		get_tree().quit(1)
		return
	_clear_connected_land_outline()
	_refresh_hud()
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	var planted_image := get_viewport().get_texture().get_image()
	planted_image.save_png(capture_directory.path_join("planting_success_older_tile_3d.png"))
	print("PLANTING_INTERACTION_CAPTURE_PASS: hover outline and older-tile planting captured.")
	get_tree().quit()


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
