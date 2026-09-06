extends Node3D

const BOARD_STATE_SCRIPT := preload("res://scripts/board_state.gd")
const UI_FONT_SCRIPT := preload("res://scripts/ui_font.gd")
const PLANT_ENGINE_SCRIPT := preload("res://scripts/plant_engine.gd")
const PLANT_SCRIPT := preload("res://scripts/plant.gd")
const RUNTIME_PLANT_SCATTER_SCRIPT := preload("res://scripts/runtime_plant_scatter_3d.gd")
const WATER_NETWORK_RENDERER_SCRIPT := preload("res://scripts/water_network_renderer_3d.gd")

const GAME_SMOKE_ARGUMENT := "--game-smoke"
const RIVER_SETUP_SMOKE_ARGUMENT := "--river-setup-smoke"
const CAPTURE_ARGUMENT := "--capture-game"
const RULES_SCREENSHOT_ARGUMENT := "--rules-screenshot"
const PLANTING_CAPTURE_ARGUMENT := "--capture-planting"
const PLANTING_INPUT_SMOKE_ARGUMENT := "--planting-input-smoke"
const SPLIT_LAND_INPUT_SMOKE_ARGUMENT := "--split-land-input-smoke"
const SPLIT_LAND_CAPTURE_ARGUMENT := "--capture-split-land"
const DISCARD_REDRAW_SMOKE_ARGUMENT := "--discard-redraw-smoke"

# One grid cell spans one fixed 3D tile (4.9 world units). NORTH faces -Z,
# EAST +X, SOUTH +Z, WEST -X, matching the authored prefab edge order.
const TILE_SIZE := 4.9
const HIGHLIGHT_Y := 0.17
const LAND_OUTLINE_HEIGHT_OFFSET := 0.045
const LAND_OUTLINE_WIDTH := 3.0

# 直接从 main 场景启动（冒烟测试 / 调试）时使用的兼容回退色。
# 正常从开始页进入对局时，玩家颜色由 GameConfig.player_colors 决定。
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
var river_setup_deck: Array[TileDefinition] = []
var river_setup_index := 0
var river_setup_skipped := 0
var river_setup_active := false
var deck_random := RandomNumberGenerator.new()
var current_rotation := 0

var placed_tile_nodes: Dictionary = {}   # cell -> Node3D (prefab instance)
var preview_node: Node3D = null
var hover_highlight: MeshInstance3D = null
var land_outline_canvas: CanvasLayer = null
var land_outline_mask_viewport: SubViewport = null
var land_outline_mask_root: Node2D = null
var land_outline_texture_rect: TextureRect = null
var land_outline_world_polygons: Array = []
var land_outline_color := Color(0.0, 0.0, 0.0, 0.0)
var land_outline_viewport_size := Vector2.ZERO
var land_outline_signature := ""

var has_hovered_cell := false
var hovered_cell := Vector2i.ZERO
var hovered_subnet_idx := -1          # 悬停命中的格内第几块地（§5.1 split 卡）；-1 = 未确定/整格
var preview_is_valid := false
var preview_border: Node3D = null

var camera_target := Vector3.ZERO
var camera_distance := CAMERA_DISTANCE

var toast_text := ""
var toast_time := 0.0

var menu_mode := MenuMode.NONE
var menu_cell := Vector2i.ZERO
var menu_subnet_idx := -1              # 种植菜单针对的格内第几块地
var menu_species_targets: Array = []

var game_over_result: Dictionary = {}

# HUD 控件引用
var ui_layer: CanvasLayer
var label_title: Label
var label_status: Label
var label_current_tile: Label
var label_seeds: Label
var label_toast: Label
var btn_deal: Button
var btn_finish_place: Button
var btn_end_turn: Button
var btn_rotate: Button
var btn_discard_redraw: Button
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
	_build_land_outline_overlay()
	_update_camera()

	_start_new_game()

	var user_arguments := OS.get_cmdline_user_args()
	if GAME_SMOKE_ARGUMENT in user_arguments:
		call_deferred("_run_game_smoke")
	elif RIVER_SETUP_SMOKE_ARGUMENT in user_arguments:
		call_deferred("_run_river_setup_smoke")
	elif RULES_SCREENSHOT_ARGUMENT in user_arguments:
		call_deferred("_capture_rules_screenshots")
	elif PLANTING_INPUT_SMOKE_ARGUMENT in user_arguments:
		call_deferred("_run_planting_input_smoke")
	elif SPLIT_LAND_INPUT_SMOKE_ARGUMENT in user_arguments or SPLIT_LAND_CAPTURE_ARGUMENT in user_arguments:
		call_deferred("_run_split_land_input_smoke")
	elif DISCARD_REDRAW_SMOKE_ARGUMENT in user_arguments:
		call_deferred("_run_discard_redraw_smoke")
	elif PLANTING_CAPTURE_ARGUMENT in user_arguments:
		call_deferred("_capture_planting_interaction_preview")
	elif CAPTURE_ARGUMENT in user_arguments:
		call_deferred("_capture_game_preview")


func _process(delta: float) -> void:
	if toast_time > 0.0:
		toast_time = maxf(0.0, toast_time - delta)
		_refresh_toast()
	if not land_outline_world_polygons.is_empty() \
			and land_outline_viewport_size != get_viewport().get_visible_rect().size:
		_refresh_connected_land_outline_projection()


func _input(event: InputEvent) -> void:
	# 种植目标位于 3D 世界，不能依赖 _unhandled_input：某些 HUD 控件会先
	# 消耗鼠标事件。这里先处理不在 UI 上的指针事件，UI 区仍交给 Control。
	if event is InputEventMouseMotion:
		var motion: InputEventMouseMotion = event
		if is_panning:
			_pan_camera_by_screen(motion.relative)
			get_viewport().set_input_as_handled()
			return
		if _pointer_is_over_ui(motion.position):
			_clear_hover_visuals()
			return
		_update_hover(motion.position)
		return

	if not event is InputEventMouseButton:
		return
	var mouse_button: InputEventMouseButton = event
	if not mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_MIDDLE:
		is_panning = false
		get_viewport().set_input_as_handled()
		return
	if _pointer_is_over_ui(mouse_button.position):
		return
	if mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP:
		camera.size = clampf(camera.size - CAMERA_ORTHO_ZOOM_STEP, CAMERA_ORTHO_SIZE_MIN, CAMERA_ORTHO_SIZE_MAX)
		_update_camera()
		get_viewport().set_input_as_handled()
		return
	if mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		camera.size = clampf(camera.size + CAMERA_ORTHO_ZOOM_STEP, CAMERA_ORTHO_SIZE_MIN, CAMERA_ORTHO_SIZE_MAX)
		_update_camera()
		get_viewport().set_input_as_handled()
		return
	if mouse_button.pressed and mouse_button.button_index == MOUSE_BUTTON_MIDDLE:
		is_panning = true
		get_viewport().set_input_as_handled()
		return
	if not mouse_button.pressed:
		return
	if mouse_button.button_index == MOUSE_BUTTON_RIGHT:
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
	if mouse_button.button_index != MOUSE_BUTTON_LEFT:
		return

	# 即使用户没有在点击前产生鼠标移动，也同步一次悬停状态，保证种植
	# 反馈和实际选中的格子来自同一条射线链路。
	_update_hover(mouse_button.position)
	var board_hit := _screen_to_cell(mouse_button.position)
	if board_hit.is_empty():
		return
	var subnet_idx := _subnet_idx_at(board_hit["cell"], board_hit["world"])
	_on_board_cell_clicked(board_hit["cell"], subnet_idx)
	get_viewport().set_input_as_handled()


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


var is_panning := false

# 双击右键结束回合（仅动作窗口阶段生效）
const RIGHT_DOUBLE_CLICK_INTERVAL := 0.35
var last_right_click_time := -1.0


func _pointer_is_over_ui(screen_position: Vector2) -> bool:
	var hovered_control := get_viewport().gui_get_hovered_control()
	if hovered_control != null \
		and hovered_control.is_visible_in_tree() \
		and hovered_control.mouse_filter != Control.MOUSE_FILTER_IGNORE:
		return true
	return _ui_tree_contains_pointer(ui_layer, screen_position)


func _ui_tree_contains_pointer(node: Node, screen_position: Vector2) -> bool:
	if node == null:
		return false
	for child in node.get_children():
		if child is Control:
			var control := child as Control
			if control.is_visible_in_tree() \
					and control.mouse_filter != Control.MOUSE_FILTER_IGNORE \
					and control.get_global_rect().has_point(screen_position):
				return true
		if _ui_tree_contains_pointer(child, screen_position):
			return true
	return false


# === 相机 ===

func _update_camera() -> void:
	var horizontal := camera_distance * cos(CAMERA_ELEVATION)
	camera.position = camera_target + Vector3(
		horizontal * sin(CAMERA_AZIMUTH),
		camera_distance * sin(CAMERA_ELEVATION),
		horizontal * cos(CAMERA_AZIMUTH),
	)
	camera.look_at(camera_target, Vector3.UP)
	_refresh_connected_land_outline_projection()


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


# §5.1「一个 land_region 一株」：给定 cell 与射线命中点 world，判断落在该格
# 的哪一块规则土地。一个 land_region 的凸面可被烘焙成多张 planting mask，
# 因而不能把掩码数组下标当作规则 land_subnet_idx。
func _subnet_idx_at(cell: Vector2i, world: Vector3) -> int:
	var tile: Node3D = placed_tile_nodes.get(cell, null)
	if tile == null:
		return -1
	var artwork := tile as TileArtwork3D
	if artwork == null or artwork.planting_masks.is_empty():
		return -1
	var local := tile.to_local(world)
	var point := Vector2(local.x, local.z)
	for mask in artwork.planting_masks:
		if mask != null and mask.contains_surface_point(point):
			var subnet_idx := _land_subnet_idx_for_mask(artwork, mask)
			if subnet_idx >= 0:
				return subnet_idx
	return -1


func _land_subnet_idx_for_mask(artwork: TileArtwork3D, mask: PlantingMask3D) -> int:
	if artwork == null or mask == null:
		return -1
	return artwork.land_subnet_index_for_mask(mask)


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


func _build_land_outline_overlay() -> void:
	# 不再把每个凸分割 planting mask 的所有边直接铺到 3D 地表上。
	# 先在离屏视口中把所有 LAND 掩码绘成一张二值屏幕图，再由 shader 只提取
	# 该图的外缘。这样即使烘焙掩码由不相交的凸分割件组成，也不会显出内部曲线。
	land_outline_canvas = CanvasLayer.new()
	land_outline_canvas.name = "LandOutlineOverlay"
	land_outline_canvas.layer = 1
	add_child(land_outline_canvas)

	land_outline_mask_viewport = SubViewport.new()
	land_outline_mask_viewport.name = "LandOutlineMaskViewport"
	land_outline_mask_viewport.transparent_bg = true
	land_outline_mask_viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	land_outline_mask_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(land_outline_mask_viewport)
	land_outline_mask_root = Node2D.new()
	land_outline_mask_root.name = "ProjectedLandMasks"
	land_outline_mask_viewport.add_child(land_outline_mask_root)

	land_outline_texture_rect = TextureRect.new()
	land_outline_texture_rect.name = "ConnectedLandOuterOutline"
	land_outline_texture_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	land_outline_texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	land_outline_texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	land_outline_texture_rect.texture = land_outline_mask_viewport.get_texture()
	land_outline_texture_rect.material = _make_land_outline_material()
	land_outline_canvas.add_child(land_outline_texture_rect)


func _make_land_outline_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
render_mode unshaded;

uniform vec4 outline_color = vec4(0.72, 0.96, 0.49, 1.0);
uniform float outline_width = 3.0;

void fragment() {
	float center = texture(TEXTURE, UV).a;
	vec2 step_size = TEXTURE_PIXEL_SIZE * outline_width;
	float nearby = 0.0;
	nearby = max(nearby, texture(TEXTURE, UV + vec2( step_size.x, 0.0)).a);
	nearby = max(nearby, texture(TEXTURE, UV + vec2(-step_size.x, 0.0)).a);
	nearby = max(nearby, texture(TEXTURE, UV + vec2(0.0,  step_size.y)).a);
	nearby = max(nearby, texture(TEXTURE, UV + vec2(0.0, -step_size.y)).a);
	nearby = max(nearby, texture(TEXTURE, UV + vec2( step_size.x,  step_size.y)).a);
	nearby = max(nearby, texture(TEXTURE, UV + vec2(-step_size.x,  step_size.y)).a);
	nearby = max(nearby, texture(TEXTURE, UV + vec2( step_size.x, -step_size.y)).a);
	nearby = max(nearby, texture(TEXTURE, UV + vec2(-step_size.x, -step_size.y)).a);
	float outer_edge = clamp(nearby - center, 0.0, 1.0);
	COLOR = vec4(outline_color.rgb, outer_edge * outline_color.a);
}
"""
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter(&"outline_width", LAND_OUTLINE_WIDTH)
	return material


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
	var new_subnet := -1
	if new_has_hover:
		new_cell = hit["cell"]
		new_subnet = _subnet_idx_at(new_cell, hit["world"])
	if new_has_hover == has_hovered_cell and (not new_has_hover or (new_cell == hovered_cell and new_subnet == hovered_subnet_idx)):
		return
	has_hovered_cell = new_has_hover
	hovered_cell = new_cell
	hovered_subnet_idx = new_subnet
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
	if not has_hovered_cell or not board_state.has_tile(hovered_cell) \
			or not board_state.is_turn_placed(hovered_cell) or hovered_subnet_idx < 0:
		_clear_connected_land_outline()
		return
	var check: Dictionary = board_state.can_plant_any_species_at(
		hovered_cell, board_state.active_player, hovered_subnet_idx
	)
	if not bool(check["valid"]):
		_clear_connected_land_outline()
		return
	# 只高亮悬停命中的那一块地（split 卡一格多块地时）。
	_show_land_region_outline(hovered_cell, hovered_subnet_idx, Color("#b8f47d"))


func _clear_hover_visuals() -> void:
	if has_hovered_cell:
		has_hovered_cell = false
	hovered_subnet_idx = -1
	hover_highlight.visible = false
	_clear_connected_land_outline()
	_sync_preview()


# 只根据各个已实例化预制件自带的 planting_masks 生成交互描边。
# 它是瞬时屏幕空间提示层，不改写地块网格、端口或基础材质。离屏遮罩的
# alpha 会把每个 LAND 分割件合为一个视觉区域，shader 只绘制这个区域的外缘。
func _show_connected_land_outline(cells: Array[Vector2i], color: Color) -> void:
	var signature := "%s|%s" % [color.to_html(true), str(cells)]
	if signature == land_outline_signature:
		return
	_clear_connected_land_outline()
	land_outline_signature = signature
	land_outline_color = color
	var source_polygons: Array = []
	for cell in cells:
		var tile: Node3D = placed_tile_nodes.get(cell, null)
		if tile == null:
			continue
		var artwork := tile as TileArtwork3D
		if artwork != null and not artwork.planting_masks.is_empty():
			for mask in artwork.planting_masks:
				if mask == null or not mask.is_valid():
					continue
				var polygon := _world_outline_polygon(tile, mask)
				if polygon.size() >= 3:
					source_polygons.append(polygon)
		else:
			source_polygons.append(_fallback_land_outline_polygon(tile))
	land_outline_world_polygons = source_polygons
	_refresh_connected_land_outline_projection()


func _clear_connected_land_outline() -> void:
	if land_outline_mask_root != null:
		for child in land_outline_mask_root.get_children():
			child.free()
	if land_outline_mask_viewport != null:
		land_outline_mask_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	land_outline_world_polygons.clear()
	land_outline_color = Color(0.0, 0.0, 0.0, 0.0)
	land_outline_viewport_size = Vector2.ZERO
	land_outline_signature = ""


# §5.1 只描边某格内的某一块规则土地。一个分区的多张烘焙掩码一并写入
# 屏幕空间二值层，由轮廓 shader 合并为没有内部切线的一条外缘。
func _show_land_region_outline(cell: Vector2i, subnet_idx: int, color: Color) -> void:
	var signature := "%s|%s#%d" % [color.to_html(true), str(cell), subnet_idx]
	if signature == land_outline_signature:
		return
	_clear_connected_land_outline()
	land_outline_signature = signature
	land_outline_color = color
	var source_polygons: Array = []
	var tile: Node3D = placed_tile_nodes.get(cell, null)
	if tile != null:
		var artwork := tile as TileArtwork3D
		if artwork != null:
			for mask in artwork.planting_masks:
				if mask == null or not mask.is_valid() \
						or _land_subnet_idx_for_mask(artwork, mask) != subnet_idx:
					continue
				var polygon := _world_outline_polygon(tile, mask)
				if polygon.size() >= 3:
					source_polygons.append(polygon)
		if source_polygons.is_empty():
			source_polygons.append(_fallback_land_outline_polygon(tile))
	land_outline_world_polygons = source_polygons
	_refresh_connected_land_outline_projection()


func _world_outline_polygon(tile: Node3D, mask: PlantingMask3D) -> PackedVector3Array:
	var polygon := PackedVector3Array()
	for local_point in mask.boundary:
		var world_point := tile.to_global(Vector3(
			local_point.x,
			mask.surface_height + LAND_OUTLINE_HEIGHT_OFFSET,
			local_point.y,
		))
		polygon.append(world_point)
	return polygon


func _fallback_land_outline_polygon(tile: Node3D) -> PackedVector3Array:
	var half := TILE_SIZE * 0.5 - 0.14
	var local_boundary := PackedVector2Array([
		Vector2(-half, -half), Vector2(half, -half),
		Vector2(half, half), Vector2(-half, half),
	])
	var polygon := PackedVector3Array()
	for local_point in local_boundary:
		var world_point := tile.to_global(Vector3(local_point.x, HIGHLIGHT_Y + LAND_OUTLINE_HEIGHT_OFFSET, local_point.y))
		polygon.append(world_point)
	return polygon


func _refresh_connected_land_outline_projection() -> void:
	if land_outline_mask_viewport == null or land_outline_mask_root == null or land_outline_texture_rect == null:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	land_outline_viewport_size = viewport_size
	land_outline_mask_viewport.size = Vector2i(roundi(viewport_size.x), roundi(viewport_size.y))
	for child in land_outline_mask_root.get_children():
		child.free()
	var material := land_outline_texture_rect.material as ShaderMaterial
	if material != null:
		material.set_shader_parameter(&"outline_color", land_outline_color)
	for world_polygon in land_outline_world_polygons:
		var source: PackedVector3Array = world_polygon
		if source.size() < 3:
			continue
		var projected := PackedVector2Array()
		for world_point in source:
			projected.append(camera.unproject_position(world_point))
		var mask_polygon := Polygon2D.new()
		mask_polygon.polygon = projected
		mask_polygon.color = Color.WHITE
		land_outline_mask_root.add_child(mask_polygon)
	land_outline_mask_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


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
		var state_key := "%d:%d" % [int(p.land_subnet_idx), int(p.species)]
		runtime_states[state_key] = {
			"growth_state": TileArtwork3D.GrowthState.GROWING if int(p.form) == PLANT_SCRIPT.Form.SURVIVING else TileArtwork3D.GrowthState.WITHERED,
			"owner_color": _player_color(int(p.owner)),
		}
	if tile.has_method("has_runtime_plant_layout") and bool(tile.call("has_runtime_plant_layout")):
		tile.call("set_runtime_plant_states", runtime_states)
		tile.call("set_growth_state", TileArtwork3D.GrowthState.GROWING)
		return
	var any_healthy := plants.any(func(p): return int(p.form) == PLANT_SCRIPT.Form.SURVIVING)
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

	deck_random.randomize()
	deck = tile_catalog.build_shuffled_deck(TileDefinition.CARD_TILE, deck_random)
	deck_index = 0
	river_setup_deck = tile_catalog.river_setup_deck(deck_random)
	river_setup_index = 0
	river_setup_skipped = 0
	river_setup_active = not river_setup_deck.is_empty()
	current_rotation = 0
	hovered_subnet_idx = -1
	game_over_result = {}
	_clear_menu()

	board_state.start_with(tile_catalog.starter_tile())
	_add_placed_tile_visual(Vector2i.ZERO)

	if river_setup_active:
		_set_toast("新对局 · 河流长牌阶段 · 玩家 1 点「抽河牌」开始", 3.0)
	else:
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
	if river_setup_active:
		_deal_next_river_setup_tile()
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


func _current_tile_can_be_discarded() -> bool:
	return not river_setup_active \
		and int(board_state.phase) == BoardState.Phase.PLACE \
		and board_state.tile_to_place != null \
		and not board_state.has_any_legal_placement(board_state.tile_to_place)


func _on_discard_redraw_button() -> void:
	if not _current_tile_can_be_discarded():
		_set_toast("当前地块仍有合法位置，不能弃牌重抽。", 2.4)
		_refresh_hud()
		return
	var discarded: TileDefinition = board_state.tile_to_place
	var next_deck_index := deck_index + 1
	var result: Dictionary = board_state.discard_unplaceable_tile(next_deck_index >= deck.size())
	if not bool(result["valid"]):
		_set_toast("弃牌失败：%s" % result["reason"], 2.8)
		_refresh_hud()
		return
	deck_index = next_deck_index
	current_rotation = 0
	has_hovered_cell = false
	hover_highlight.visible = false
	_clear_connected_land_outline()
	_refresh_preview_piece()
	if int(board_state.phase) == BoardState.Phase.GAME_OVER:
		_set_toast("%s 无合法位置，已弃置；牌堆已空 · 点「查看终局」" % discarded.display_name, 3.2)
		_refresh_hud()
		return
	_on_deal_button()
	if board_state.tile_to_place != null:
		var redrawn: TileDefinition = board_state.tile_to_place
		_set_toast("%s 无合法位置，已弃牌并重抽 %s" % [
			discarded.display_name,
			redrawn.display_name,
		], 3.0)
	_refresh_hud()


func _deal_next_river_setup_tile() -> void:
	if river_setup_index >= river_setup_deck.size():
		_finish_river_setup()
		return
	var definition: TileDefinition = river_setup_deck[river_setup_index]
	if not definition.is_river_tile or definition.card_type != TileDefinition.CARD_RIVER:
		push_error("River setup deck contains a non-river card: %s." % definition.id)
		_set_toast("河流牌堆配置无效。", 3.0)
		return
	var result: Dictionary = board_state.deal_tile(definition)
	if not bool(result["valid"]):
		_set_toast("抽河牌失败：%s" % result["reason"], 2.5)
		return
	current_rotation = 0
	has_hovered_cell = false
	hover_highlight.visible = false
	_clear_connected_land_outline()
	if not board_state.has_any_legal_placement(definition):
		var skipped: Dictionary = board_state.skip_unplaceable_river_setup_tile()
		if not bool(skipped["valid"]):
			_set_toast("跳过河流牌失败：%s" % skipped["reason"], 3.0)
			return
		river_setup_index += 1
		river_setup_skipped += 1
		_advance_river_setup("%s 无合法位置，已跳过" % definition.display_name)
		return
	_refresh_preview_piece()
	Sfx.play("tile_pickup")
	_set_toast("河流长牌 %d/%d · 玩家 %d 放置 %s" % [river_setup_index + 1, river_setup_deck.size(), board_state.active_player + 1, definition.display_name], 2.4)
	_refresh_hud()


func _advance_river_setup(action: String) -> void:
	if river_setup_index >= river_setup_deck.size():
		_finish_river_setup()
		return
	_set_toast("%s · 河流长牌 %d/%d 完成 · 玩家 %d 点「抽河牌」继续" % [action, river_setup_index, river_setup_deck.size(), board_state.active_player + 1], 2.8)
	Sfx.play("turn_start")
	_refresh_hud()


func _finish_river_setup() -> void:
	if not river_setup_active:
		return
	river_setup_active = false
	var placed := river_setup_deck.size() - river_setup_skipped
	_set_toast("河流长牌完成 · 已放 %d 张，跳过 %d 张 · 玩家 %d 点「抽牌」进入主牌堆" % [placed, river_setup_skipped, board_state.active_player + 1], 3.2)
	Sfx.play("turn_start")
	_refresh_hud()


func _on_finish_place_button() -> void:
	if river_setup_active:
		_set_toast("河流长牌放下后会直接轮到下一位玩家，不进入动作窗口。", 2.4)
		return
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
	_set_toast("进入动作窗口 · 悬停本回合新地块，左键种植", 2.5)
	_refresh_hud()


func _on_end_turn_button() -> void:
	if river_setup_active:
		_set_toast("河流长牌阶段没有种植或结算动作。", 2.2)
		return
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


func _on_board_cell_clicked(cell: Vector2i, subnet_idx: int = -1) -> void:
	var phase = int(board_state.phase)
	if phase == BoardState.Phase.PLACE:
		_try_place_current_tile(cell)
		return
	if phase == BoardState.Phase.ACTION_WINDOW:
		_try_open_action_menu_for(cell, subnet_idx)
		return
	if phase == BoardState.Phase.GAME_OVER:
		_set_toast("对局已结束 · 可按 N 重开", 2.0)
		return
	if phase == BoardState.Phase.DEAL:
		_set_toast("等待玩家 %d 点%s" % [board_state.active_player + 1, "抽河牌" if river_setup_active else "抽牌"], 2.0)


func _try_place_current_tile(cell: Vector2i) -> void:
	var tile = board_state.tile_to_place
	if tile == null:
		_set_toast("当前没有地块可放。", 2.0)
		return
	var is_river_setup_placement := river_setup_active
	var result: Dictionary = board_state.commit_river_setup_placement(cell, current_rotation) if is_river_setup_placement else board_state.commit_placement(cell, current_rotation)
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
	if is_river_setup_placement:
		river_setup_index += 1
		_advance_river_setup("河流牌已放置")
		return
	if automatic_expansion.is_empty() and evicted_ids.is_empty():
		_set_toast("已放置 · 悬停本回合新地块，左键种植", 2.8)
	elif not automatic_expansion.is_empty():
		_set_toast("已放置 · 邻接植物自动扩张；可在本回合新地块种植", 2.8)
	else:
		_set_toast("已放置 · 连通区域发生物种驱逐，种子已退还", 2.8)
	_refresh_hud()
	# 放牌点击所在的位置是唯一主动种植候选；无需等用户额外移动一次鼠标。
	call_deferred("_update_hover", get_viewport().get_mouse_position())


func _try_open_action_menu_for(cell: Vector2i, subnet_idx: int = -1) -> void:
	if subnet_idx < 0 or not board_state.has_tile(cell) or not board_state.is_turn_placed(cell):
		_clear_connected_land_outline()
		return
	_open_plant_menu(cell, subnet_idx)


func _open_plant_menu(cell: Vector2i, subnet_idx: int = -1) -> void:
	var owner: int = board_state.active_player
	var bag: Dictionary = board_state.seed_inventory.get(owner, {})
	var species_with_seeds: Array = []
	for species in [PLANT_SCRIPT.Species.GRASS, PLANT_SCRIPT.Species.FLOWER, PLANT_SCRIPT.Species.TREE]:
		var n: int = int(bag.get(species, 0))
		if n <= 0:
			continue
		var check: Dictionary = board_state.can_plant_at(cell, species, owner, subnet_idx)
		if not bool(check["valid"]):
			continue
		species_with_seeds.append(species)
	if species_with_seeds.is_empty():
		_set_toast("该块土地没有合法的物种可种。", 3.0)
		return
	menu_mode = MenuMode.PLANT
	menu_cell = cell
	menu_subnet_idx = subnet_idx
	menu_species_targets.clear()
	for s in species_with_seeds:
		menu_species_targets.append(int(s))
	_build_action_menu()


func _handle_menu_choice(index: int) -> void:
	var owner: int = board_state.active_player
	if menu_mode == MenuMode.PLANT:
		var species: int = int(menu_species_targets[index])
		var result: Dictionary = board_state.plant(menu_cell, species, owner, menu_subnet_idx)
		if bool(result["valid"]):
			Sfx.play("plant_seed")
			var automatic_expansions: Array = result.get("automatic_expansions", [])
			var species_conflict: Dictionary = result.get("species_conflict", {})
			var evicted_ids: Array = species_conflict.get("evicted_plant_ids", [])
			if not automatic_expansions.is_empty():
				Sfx.play("plant_grow")
			if automatic_expansions.is_empty() and evicted_ids.is_empty():
				_refresh_tile_growth(menu_cell)
				_set_toast("已种 %s（种子 −1）" % PLANT_SCRIPT.species_label(species), 2.0)
			elif evicted_ids.is_empty():
				_refresh_all_growth()
				_set_toast("已种 %s（种子 −1）· 自动扩张至 %d 块相邻土地" % [
					PLANT_SCRIPT.species_label(species), automatic_expansions.size(),
				], 2.8)
			else:
				_refresh_all_growth()
				var expansion_note := ""
				if not automatic_expansions.is_empty():
					expansion_note = " · 自动扩张至 %d 块相邻土地" % automatic_expansions.size()
				_set_toast("已种 %s%s · 低优先级植物已被驱逐并退种" % [
					PLANT_SCRIPT.species_label(species), expansion_note,
				], 3.0)
		else:
			Sfx.play("tile_invalid", -6.0)
			_set_toast("种植失败：%s" % result["reason"], 2.5)
	_clear_menu()
	_clear_connected_land_outline()
	_refresh_hud()


func _clear_menu() -> void:
	menu_mode = MenuMode.NONE
	menu_cell = Vector2i.ZERO
	menu_subnet_idx = -1
	menu_species_targets.clear()
	if menu_panel != null:
		menu_panel.visible = false


# === HUD ===

func _build_hud() -> void:
	var ui := CanvasLayer.new()
	ui.name = "UI"
	# 种植外轮廓在独立的 layer 1；界面始终位于其上，避免提示线穿过按钮。
	ui.layer = 2
	add_child(ui)
	ui_layer = ui

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
	btn_discard_redraw = _make_button("弃牌重抽", _on_discard_redraw_button, true)
	btn_discard_redraw.tooltip_text = "仅当当前地块在所有位置和朝向都无法放置时可用"
	btn_reset = _make_button("重开 N", _start_new_game)
	for b in [btn_deal, btn_finish_place, btn_end_turn, btn_rotate, btn_discard_redraw, btn_reset]:
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
	# CanvasLayer 不是 Control 父节点，中心/底部锚点不会替这个动态菜单完成
	# 可靠的最小尺寸布局。改为显式按视口定位，避免菜单被排到屏幕外。
	menu_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	menu_panel.custom_minimum_size = Vector2(300, 0)
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
	call_deferred("_position_action_menu")


func _position_action_menu() -> void:
	if menu_panel == null or not menu_panel.visible:
		return
	var viewport_size := get_viewport().get_visible_rect().size
	var minimum_size := menu_panel.get_combined_minimum_size()
	menu_panel.size = minimum_size
	menu_panel.position = Vector2(
		roundf((viewport_size.x - minimum_size.x) * 0.5),
		maxf(16.0, viewport_size.y - minimum_size.y - 28.0),
	)


func _menu_choice(index: int) -> Callable:
	return func() -> void: _handle_menu_choice(index)


func _refresh_hud() -> void:
	var phase := int(board_state.phase)
	var can_discard := _current_tile_can_be_discarded()
	var player_label := "玩家 %d" % (board_state.active_player + 1) if phase != BoardState.Phase.GAME_OVER else "玩家 %d（终局）" % (board_state.active_player + 1)
	if river_setup_active:
		label_status.text = "河流长牌 %d/%d · %s · %s" % [river_setup_index + 1, river_setup_deck.size(), player_label, _phase_label(phase)]
	else:
		label_status.text = "第 %d 回合 · %s · %s" % [board_state.turn_number, player_label, _phase_label(phase)]

	if phase == BoardState.Phase.GAME_OVER:
		label_current_tile.text = "牌堆已空"
	elif board_state.tile_to_place != null:
		var t: TileDefinition = board_state.tile_to_place
		label_current_tile.text = "当前地块：%s · 旋转 %d°" % [t.display_name, current_rotation * 90]
		if can_discard:
			label_current_tile.text += " · 无合法落点，可弃牌重抽"
	elif river_setup_active:
		label_current_tile.text = "河流牌堆剩余：%d" % (river_setup_deck.size() - river_setup_index)
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
	btn_deal.text = "抽河牌" if river_setup_active else "抽  牌"
	btn_finish_place.disabled = river_setup_active or not (phase == BoardState.Phase.PLACE and not board_state.turn_placed_cells.is_empty())
	btn_end_turn.disabled = river_setup_active or not (phase == BoardState.Phase.ACTION_WINDOW or phase == BoardState.Phase.GAME_OVER)
	btn_end_turn.text = "查看终局" if phase == BoardState.Phase.GAME_OVER else "回合结束"
	btn_rotate.disabled = phase != BoardState.Phase.PLACE
	btn_discard_redraw.visible = can_discard
	btn_discard_redraw.disabled = not can_discard

	if phase == BoardState.Phase.GAME_OVER and not game_over_result.is_empty():
		label_current_tile.text = "终局已结算"


func _phase_label(phase: int) -> String:
	match phase:
		BoardState.Phase.DEAL:
			return "等待抽河牌" if river_setup_active else "等待抽牌"
		BoardState.Phase.PLACE:
			return "放置河流" if river_setup_active else "等待放置"
		BoardState.Phase.ACTION_WINDOW:
			return "河流阶段" if river_setup_active else "动作窗口 · 双击右键结束回合"
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
	if definition.is_river_tile:
		return true
	for edge in range(4):
		if definition.edge_kind_at(edge, rotation) == TileDefinition.EdgeKind.WATER:
			return true
	return false


func _player_color(player_id: int) -> Color:
	# 开始页按玩家编号保存颜色；这里是 HUD 和植物归属标志共用的唯一解析点。
	# 只有完整配置才采用它，避免调试/冒烟流程留下的半截配置影响显示。
	if GameConfig.has_custom_config() \
			and player_id >= 0 \
			and player_id < GameConfig.player_colors.size():
		var configured_color = GameConfig.player_colors[player_id]
		if configured_color is Color:
			return configured_color
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


func _make_discard_redraw_smoke_tile(
	id: StringName,
	display_name: String,
	edges: PackedInt32Array,
) -> TileDefinition:
	var definition := TileDefinition.new()
	definition.configure(
		id,
		display_name,
		TileDefinition.CARD_TILE,
		1,
		edges,
		PackedInt32Array([0, 0, 0, 0]),
		TileDefinition.CenterKind.EMPTY,
		false,
		false,
		0,
	)
	return definition


func _run_discard_redraw_smoke() -> void:
	if not await _run_discard_redraw_smoke_core():
		get_tree().quit(1)
		return
	print("DISCARD_REDRAW_SMOKE_PASS: only an unplaceable main-deck tile can be discarded and immediately redrawn.")
	get_tree().quit()


func _run_discard_redraw_smoke_core() -> bool:
	var starter := tile_catalog.starter_tile()
	if starter == null:
		push_error("Discard redraw smoke: starter tile is missing.")
		return false
	var unplaceable := _make_discard_redraw_smoke_tile(
		&"_discard_smoke_all_water",
		"无解测试水牌",
		PackedInt32Array([
			TileDefinition.EdgeKind.WATER,
			TileDefinition.EdgeKind.WATER,
			TileDefinition.EdgeKind.WATER,
			TileDefinition.EdgeKind.WATER,
		]),
	)
	var redraw := _make_discard_redraw_smoke_tile(
		&"_discard_smoke_all_empty",
		"重抽测试空地牌",
		PackedInt32Array([
			TileDefinition.EdgeKind.EMPTY,
			TileDefinition.EdgeKind.EMPTY,
			TileDefinition.EdgeKind.EMPTY,
			TileDefinition.EdgeKind.EMPTY,
		]),
	)

	_reset_interaction_smoke_board(starter)
	deck = [unplaceable, redraw]
	_on_deal_button()
	await get_tree().process_frame
	if board_state.has_any_legal_placement(unplaceable):
		push_error("Discard redraw smoke: the all-water fixture unexpectedly has a legal placement.")
		return false
	if not _current_tile_can_be_discarded() or not btn_discard_redraw.visible or btn_discard_redraw.disabled:
		push_error("Discard redraw smoke: the no-legal-move button was not enabled.")
		return false
	var active_before: int = board_state.active_player
	var turn_before: int = board_state.turn_number
	_on_discard_redraw_button()
	await get_tree().process_frame
	if int(board_state.phase) != BoardState.Phase.PLACE or board_state.tile_to_place != redraw:
		push_error("Discard redraw smoke: discard did not immediately deal the next tile.")
		return false
	if board_state.active_player != active_before or board_state.turn_number != turn_before:
		push_error("Discard redraw smoke: a redraw incorrectly advanced the player or turn.")
		return false
	if board_state.discarded_tiles.size() != 1 or board_state.discarded_tiles[0] != unplaceable or deck_index != 1:
		push_error("Discard redraw smoke: the discarded card was not recorded and consumed exactly once.")
		return false
	if not board_state.has_any_legal_placement(redraw) or btn_discard_redraw.visible or not btn_discard_redraw.disabled:
		push_error("Discard redraw smoke: a placeable redraw left the discard control usable.")
		return false
	var forbidden: Dictionary = board_state.discard_unplaceable_tile(false)
	if bool(forbidden["valid"]) or board_state.tile_to_place != redraw or board_state.discarded_tiles.size() != 1:
		push_error("Discard redraw smoke: rules allowed a placeable tile to be discarded.")
		return false

	_reset_interaction_smoke_board(starter)
	deck = [unplaceable]
	_on_deal_button()
	await get_tree().process_frame
	_on_discard_redraw_button()
	await get_tree().process_frame
	if int(board_state.phase) != BoardState.Phase.GAME_OVER or deck_index != deck.size() \
			or board_state.discarded_tiles.size() != 1:
		push_error("Discard redraw smoke: discarding the final unplaceable card did not enter GAME_OVER.")
		return false
	return true


# === 冒烟测试 ===

func _run_game_smoke() -> void:
	if not _run_plants_smoke():
		get_tree().quit(1)
		return
	var river_setup_ok := await _run_river_setup_smoke_core()
	if not river_setup_ok:
		get_tree().quit(1)
		return
	if not await _run_full_turn_loop_smoke():
		get_tree().quit(1)
		return
	if not await _run_discard_redraw_smoke_core():
		get_tree().quit(1)
		return
	print("GAME_SMOKE_PASS: seven-card river setup and full §7 turn loop succeeded; tiles placed=%d, turn=%d." % [_smoke_last_placed, _smoke_last_turn])
	get_tree().quit()


func _run_river_setup_smoke() -> void:
	var river_setup_ok := await _run_river_setup_smoke_core()
	if not river_setup_ok:
		get_tree().quit(1)
		return
	print("RIVER_SETUP_SMOKE_PASS: fixed starter plus six shuffled middle cards and fixed terminal completed through the live game route.")
	get_tree().quit()


func _run_river_setup_smoke_core() -> bool:
	if not river_setup_active or river_setup_deck.size() != 7:
		push_error("River setup smoke: expected seven setup cards after the fixed starter, got %d." % river_setup_deck.size())
		return false
	if river_setup_deck.back().id != &"river_end" or not river_setup_deck.back().river_setup_terminal:
		push_error("River setup smoke: river_end was not kept as the fixed terminal.")
		return false
	var seeds_before: Dictionary = board_state.seed_inventory.duplicate(true)
	var safety := river_setup_deck.size() + 2
	while river_setup_active and safety > 0:
		safety -= 1
		if int(board_state.phase) != BoardState.Phase.DEAL:
			push_error("River setup smoke: expected DEAL before a river draw.")
			return false
		_on_deal_button()
		await get_tree().process_frame
		if int(board_state.phase) == BoardState.Phase.PLACE:
			var move := _find_first_visible_legal_move()
			if move.is_empty():
				push_error("River setup smoke: a dealt river card had no visible legal move.")
				return false
			current_rotation = int(move["rotation"])
			_try_place_current_tile(move["cell"])
			await get_tree().process_frame
		elif int(board_state.phase) != BoardState.Phase.DEAL:
			push_error("River setup smoke: river draw left the board in an invalid phase.")
			return false
	if river_setup_active or safety <= 0:
		push_error("River setup smoke: the setup deck did not finish.")
		return false
	if river_setup_index != 7 or river_setup_skipped != 0:
		push_error("River setup smoke: expected all seven setup cards to be placed, got index=%d skipped=%d." % [river_setup_index, river_setup_skipped])
		return false
	if board_state.placements.size() != 8 or board_state.active_player != 1 or board_state.turn_number != 8:
		push_error("River setup smoke: seven cards did not advance the board to the expected state.")
		return false
	if int(board_state.phase) != BoardState.Phase.DEAL or not board_state.plants.is_empty() or board_state.seed_inventory != seeds_before:
		push_error("River setup smoke: setup leaked a normal turn or altered plant state.")
		return false
	return true


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
			var discarded: Dictionary = board.discard_unplaceable_tile(deck_index + 1 >= deck.size())
			if not bool(discarded["valid"]):
				push_error("Loop smoke: unplaceable card could not be discarded: %s" % discarded["reason"])
				return false
			deck_index += 1
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
	var expected_main_tile_count: int = deck.size() - board.discarded_tiles.size()
	if placed_count < expected_main_tile_count:
		push_error("Loop smoke: infinite-map regression — only placed %d tiles, expected all %d legally placeable main-deck tiles." % [placed_count, expected_main_tile_count])
		return false
	return true


func _run_plants_smoke() -> bool:
	var GD = preload("res://scripts/plant.gd")
	var board = BOARD_STATE_SCRIPT.new()
	var starter = tile_catalog.get_definition(&"land_four_edges")
	var split_land = tile_catalog.get_definition(&"land_single_edge")
	if starter == null:
		push_error("Plants smoke failed: land fixture missing from the card table.")
		return false
	if split_land == null:
		push_error("Plants smoke failed: CENTER_EMPTY land fixture missing from the card table.")
		return false
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

	var old_target = board.plant(Vector2i.ZERO, GD.Species.GRASS, 0)
	if bool(old_target["valid"]) or not String(old_target["reason"]).contains("刚放置"):
		push_error("Plants smoke failed: planting on an older tile was not rejected by the new-tile rule: %s" % old_target["reason"])
		return false
	var wrong_owner = board.plant(Vector2i.RIGHT, GD.Species.GRASS, 1)
	if bool(wrong_owner["valid"]):
		push_error("Plants smoke failed: a non-active player planted the current player's new tile.")
		return false
	var r1 = board.plant(Vector2i.RIGHT, GD.Species.GRASS, 0)
	if not bool(r1["valid"]):
		push_error("Plants smoke failed: planting grass on the current player's new tile was rejected: %s" % r1["reason"])
		return false
	var manual_expansions: Array = r1.get("automatic_expansions", [])
	if manual_expansions.size() != 1 or Vector2i(manual_expansions[0].get("target_cell", Vector2i.ZERO)) != Vector2i.ZERO:
		push_error("Plants smoke failed: manual planting did not expand into its directly adjacent existing LAND tile: %s" % str(manual_expansions))
		return false
	if int(board.seed_inventory[0][GD.Species.GRASS]) != 1:
		push_error("Plants smoke failed: P1 grass seed not consumed.")
		return false

	var r_repeat = board.plant(Vector2i.RIGHT, GD.Species.GRASS, 0)
	if bool(r_repeat["valid"]):
		push_error("Plants smoke failed: a second active planting action was accepted.")
		return false
	if not board.tile_has_any_plant(Vector2i.RIGHT) or not board.tile_has_any_plant(Vector2i.ZERO):
		push_error("Plants smoke failed: manual planting did not occupy its tile and its directly connected neighbour.")
		return false
	var finish: Dictionary = board.finish_action_window(PLANT_ENGINE_SCRIPT, false)
	if not bool(finish["valid"]):
		push_error("Plants smoke failed: could not finish the planting turn: %s" % finish["reason"])
		return false
	var deal_auto: Dictionary = board.deal_tile(starter)
	if not bool(deal_auto["valid"]):
		push_error("Plants smoke failed: auto-expansion deal was rejected: %s" % deal_auto["reason"])
		return false
	var auto_cell := Vector2i(2, 0)
	var auto_place: Dictionary = board.commit_placement(auto_cell, 0)
	if not bool(auto_place["valid"]):
		push_error("Plants smoke failed: auto-expansion placement was rejected: %s" % auto_place["reason"])
		return false
	if Dictionary(auto_place.get("automatic_expansion", {})).is_empty() or not board.tile_has_any_plant(auto_cell):
		push_error("Plants smoke failed: directly adjacent connected LAND did not auto-expand.")
		return false
	if int(board.seed_inventory[0][GD.Species.GRASS]) != 1:
		push_error("Plants smoke failed: automatic expansion consumed a grass seed.")
		return false
	var occupied_new_tile = board.plant(auto_cell, GD.Species.FLOWER, board.active_player)
	if bool(occupied_new_tile["valid"]):
		push_error("Plants smoke failed: automatic expansion did not keep the new tile occupied.")
		return false
	var auto_finish: Dictionary = board.finish_action_window(PLANT_ENGINE_SCRIPT, false)
	if not bool(auto_finish["valid"]):
		push_error("Plants smoke failed: could not finish the automatically expanded turn: %s" % auto_finish["reason"])
		return false
	# Regression: CENTER_EMPTY keeps separate land regions inside one tile, but a
	# single LAND edge still joins the neighbouring planted LAND and must expand.
	var split_deal: Dictionary = board.deal_tile(split_land)
	if not bool(split_deal["valid"]):
		push_error("Plants smoke failed: CENTER_EMPTY regression deal was rejected: %s" % split_deal["reason"])
		return false
	var split_cell := Vector2i(3, 0)
	var split_place: Dictionary = board.commit_placement(split_cell, 3)
	if not bool(split_place["valid"]):
		push_error("Plants smoke failed: CENTER_EMPTY regression placement was rejected: %s" % split_place["reason"])
		return false
	if Dictionary(split_place.get("automatic_expansion", {})).is_empty() or not board.tile_has_any_plant(split_cell):
		push_error("Plants smoke failed: LAND-connected CENTER_EMPTY tile did not auto-expand.")
		return false
	if not board.connected_land_cells_at(split_cell).has(auto_cell):
		push_error("Plants smoke failed: LAND-connected CENTER_EMPTY tile did not join its neighbouring land region.")
		return false

	# 手动种植时必须一次覆盖全部直接邻居，而不是只取一个候选；同时
	# (0,0) 是新种植物 (1,1) 的对角格，用来确保本事件不会递归跨两格。
	var multi_neighbour_board = BOARD_STATE_SCRIPT.new()
	multi_neighbour_board.start_with(starter)
	for setup_cell in [Vector2i.RIGHT, Vector2i.DOWN]:
		var setup: Dictionary = multi_neighbour_board.place(starter, setup_cell, 0, 0)
		if not bool(setup["valid"]):
			push_error("Plants smoke failed: multi-neighbour setup placement at %s was rejected: %s" % [setup_cell, setup["reason"]])
			return false
	var multi_deal: Dictionary = multi_neighbour_board.deal_tile(starter)
	if not bool(multi_deal["valid"]):
		push_error("Plants smoke failed: multi-neighbour deal was rejected: %s" % multi_deal["reason"])
		return false
	var multi_place: Dictionary = multi_neighbour_board.commit_placement(Vector2i(1, 1), 0)
	if not bool(multi_place["valid"]):
		push_error("Plants smoke failed: multi-neighbour placement was rejected: %s" % multi_place["reason"])
		return false
	var multi_seed: Dictionary = multi_neighbour_board.plant(Vector2i(1, 1), GD.Species.GRASS, 0)
	if not bool(multi_seed["valid"]):
		push_error("Plants smoke failed: multi-neighbour manual planting was rejected: %s" % multi_seed["reason"])
		return false
	var multi_expansions: Array = multi_seed.get("automatic_expansions", [])
	var multi_targets: Dictionary = {}
	for expansion in multi_expansions:
		multi_targets[Dictionary(expansion).get("target_cell", Vector2i.ZERO)] = true
	if multi_expansions.size() != 2 or not multi_targets.has(Vector2i.RIGHT) or not multi_targets.has(Vector2i.DOWN):
		push_error("Plants smoke failed: manual planting did not expand to every direct LAND neighbour: %s" % str(multi_expansions))
		return false
	if not multi_neighbour_board.tile_has_any_plant(Vector2i.RIGHT) or not multi_neighbour_board.tile_has_any_plant(Vector2i.DOWN):
		push_error("Plants smoke failed: a direct LAND neighbour remained unoccupied after manual expansion.")
		return false
	if multi_neighbour_board.tile_has_any_plant(Vector2i.ZERO):
		push_error("Plants smoke failed: manual expansion recursed beyond its direct LAND neighbours.")
		return false
	if int(multi_neighbour_board.seed_inventory[0][GD.Species.GRASS]) != 1:
		push_error("Plants smoke failed: multi-neighbour automatic expansion consumed an extra grass seed.")
		return false

	print("PLANTS_SMOKE_PASS.")
	return true


func _screen_position_for_cell(cell: Vector2i) -> Vector2:
	# 与 _screen_to_cell 使用同一棋盘平面，避免测试因为地形装饰高度而绕过
	# 实际玩家的拾取路径。
	return camera.unproject_position(_cell_world_position(cell) + Vector3(0.0, HIGHLIGHT_Y, 0.0))


func _dispatch_mouse_motion(screen_position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = screen_position
	motion.global_position = screen_position
	motion.relative = Vector2.ZERO
	get_viewport().push_input(motion, true)


func _dispatch_left_click(screen_position: Vector2) -> void:
	_dispatch_mouse_motion(screen_position)
	var press := InputEventMouseButton.new()
	press.position = screen_position
	press.global_position = screen_position
	press.button_index = MOUSE_BUTTON_LEFT
	press.button_mask = MOUSE_BUTTON_MASK_LEFT
	press.pressed = true
	get_viewport().push_input(press, true)
	var release := InputEventMouseButton.new()
	release.position = screen_position
	release.global_position = screen_position
	release.button_index = MOUSE_BUTTON_LEFT
	release.button_mask = 0
	release.pressed = false
	get_viewport().push_input(release, true)


func _dispatch_left_click_to_cell(cell: Vector2i) -> void:
	_dispatch_left_click(_screen_position_for_cell(cell))


func _reset_interaction_smoke_board(starter: TileDefinition) -> void:
	_clear_connected_land_outline()
	for tile_node in placed_tile_nodes.values():
		if is_instance_valid(tile_node):
			tile_node.queue_free()
	placed_tile_nodes.clear()
	if preview_node != null:
		preview_node.queue_free()
		preview_node = null
	preview_border = null
	_clear_menu()
	board_state = BOARD_STATE_SCRIPT.new()
	river_setup_deck.clear()
	river_setup_index = 0
	river_setup_skipped = 0
	river_setup_active = false
	deck_index = 0
	current_rotation = 0
	game_over_result = {}
	board_state.start_with(starter, 2)
	_add_placed_tile_visual(Vector2i.ZERO)
	hovered_cell = Vector2i.ZERO
	hovered_subnet_idx = -1
	has_hovered_cell = false
	hover_highlight.visible = false
	_center_camera_on(Vector2i.ZERO)
	_refresh_hud()


func _run_planting_input_smoke() -> void:
	# 从 Godot 的 Input 分发入口走完整链路，而不是直接调用棋盘点击方法：
	# PLACE 的左键放牌、ACTION_WINDOW 的左键打开物种菜单都必须可用。
	var starter := tile_catalog.get_definition(&"land_four_edges")
	if starter == null:
		push_error("Planting input smoke: land fixture missing from the card table.")
		get_tree().quit(1)
		return
	_reset_interaction_smoke_board(starter)
	await get_tree().process_frame
	var deal: Dictionary = board_state.deal_tile(starter)
	if not bool(deal["valid"]):
		push_error("Planting input smoke: setup deal failed: %s" % deal["reason"])
		get_tree().quit(1)
		return
	await get_tree().process_frame
	_dispatch_left_click_to_cell(Vector2i.RIGHT)
	await get_tree().process_frame
	if int(board_state.phase) != BoardState.Phase.ACTION_WINDOW or not board_state.has_tile(Vector2i.RIGHT):
		push_error("Planting input smoke: routed left click did not place the tile and enter ACTION_WINDOW.")
		get_tree().quit(1)
		return
	_dispatch_mouse_motion(_screen_position_for_cell(Vector2i.ZERO))
	await get_tree().process_frame
	if not land_outline_world_polygons.is_empty() or menu_mode != MenuMode.NONE:
		push_error("Planting input smoke: hovering an older tile produced planting feedback.")
		get_tree().quit(1)
		return
	_dispatch_left_click_to_cell(Vector2i.ZERO)
	await get_tree().process_frame
	if menu_mode != MenuMode.NONE or menu_panel.visible:
		push_error("Planting input smoke: clicking an older tile opened a planting menu.")
		get_tree().quit(1)
		return
	_dispatch_mouse_motion(_screen_position_for_cell(Vector2i.RIGHT))
	await get_tree().process_frame
	if land_outline_world_polygons.is_empty():
		push_error("Planting input smoke: hovering the current player's new LAND tile did not show its outline.")
		get_tree().quit(1)
		return
	_dispatch_left_click_to_cell(Vector2i.RIGHT)
	await get_tree().process_frame
	if menu_mode != MenuMode.PLANT or not menu_panel.visible or menu_species_targets.is_empty():
		push_error("Planting input smoke: routed left click on the current player's new LAND tile did not open the species menu.")
		get_tree().quit(1)
		return
	var viewport_rect := Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)
	if menu_panel.get_global_rect().intersection(viewport_rect).get_area() <= 0.0:
		push_error("Planting input smoke: species menu opened outside the visible viewport.")
		get_tree().quit(1)
		return
	print("PLANTING_INPUT_SMOKE_PASS: older tiles stayed inert; the current new LAND tile opened a visible species menu.")
	get_tree().quit()


func _run_split_land_input_smoke() -> void:
	# 经真实输入分发验证 split 卡：鼠标命中的 LAND 子区才可被选中，中央
	# MEADOW 空隙既不描边，也不能回退为“任选一块土地”。
	var capture_preview := SPLIT_LAND_CAPTURE_ARGUMENT in OS.get_cmdline_user_args()
	var capture_directory := ""
	if capture_preview:
		capture_directory = ProjectSettings.globalize_path("res://artifacts")
		DirAccess.make_dir_recursive_absolute(capture_directory)
	var split := tile_catalog.get_definition(&"land_opposite_edges_split")
	if split == null:
		push_error("Split-land input smoke: split fixture missing from the card table.")
		get_tree().quit(1)
		return
	_reset_interaction_smoke_board(split)
	await get_tree().process_frame
	var deal: Dictionary = board_state.deal_tile(split)
	if not bool(deal["valid"]):
		push_error("Split-land input smoke: setup deal failed: %s" % deal["reason"])
		get_tree().quit(1)
		return
	_dispatch_left_click_to_cell(Vector2i.RIGHT)
	await get_tree().process_frame
	if int(board_state.phase) != BoardState.Phase.ACTION_WINDOW or not board_state.has_tile(Vector2i.RIGHT):
		push_error("Split-land input smoke: routed placement click did not enter ACTION_WINDOW.")
		get_tree().quit(1)
		return
	var tile: Node3D = placed_tile_nodes.get(Vector2i.RIGHT, null)
	var artwork := tile as TileArtwork3D
	if artwork == null or artwork.planting_masks.size() != 2:
		push_error("Split-land input smoke: split prefab did not expose its two baked LAND masks.")
		get_tree().quit(1)
		return
	for mask in artwork.planting_masks:
		var expected_subnet := _land_subnet_idx_for_mask(artwork, mask)
		if expected_subnet < 0:
			push_error("Split-land input smoke: a baked mask could not be mapped to its land subnet.")
			get_tree().quit(1)
			return
		var screen_position := _screen_position_for_mask(tile, mask)
		_dispatch_mouse_motion(screen_position)
		await get_tree().process_frame
		if hovered_subnet_idx != expected_subnet or land_outline_world_polygons.is_empty():
			push_error("Split-land input smoke: hovering subnet %d did not isolate its LAND outline." % expected_subnet)
			get_tree().quit(1)
			return
		if capture_preview:
			await get_tree().create_timer(0.15).timeout
			var hover_image := get_viewport().get_texture().get_image()
			hover_image.save_png(capture_directory.path_join("planting_hover_split_land_region_%d_3d.png" % expected_subnet))
		_dispatch_left_click(screen_position)
		await get_tree().process_frame
		if menu_mode != MenuMode.PLANT or menu_subnet_idx != expected_subnet:
			push_error("Split-land input smoke: clicking subnet %d opened the wrong planting target." % expected_subnet)
			get_tree().quit(1)
			return
		_clear_menu()
	var gap_position := camera.unproject_position(tile.to_global(Vector3.ZERO))
	_dispatch_mouse_motion(gap_position)
	await get_tree().process_frame
	if hovered_subnet_idx >= 0 or not land_outline_world_polygons.is_empty():
		push_error("Split-land input smoke: the gap between disconnected LAND lobes still selected a region.")
		get_tree().quit(1)
		return
	_dispatch_left_click(gap_position)
	await get_tree().process_frame
	if menu_mode != MenuMode.NONE or menu_panel.visible:
		push_error("Split-land input smoke: clicking the gap between disconnected LAND lobes opened a planting menu.")
		get_tree().quit(1)
		return
	print("SPLIT_LAND_INPUT_SMOKE_PASS: each disconnected LAND lobe selects independently; the gap stays inert.")
	get_tree().quit()


func _screen_position_for_mask(tile: Node3D, mask: PlantingMask3D) -> Vector2:
	var centroid := Vector2.ZERO
	for point in mask.boundary:
		centroid += point
	centroid /= float(mask.boundary.size())
	# Input raycasts deliberately resolve against the board plane (y=0), so use
	# the same plane rather than the raised visual soil surface here.
	return camera.unproject_position(tile.to_global(Vector3(centroid.x, 0.0, centroid.y)))


func _capture_planting_interaction_preview() -> void:
	# 真实场景内的可见验收：旧地块悬停保持无反馈；仅本回合新地块显示
	# 合并 LAND 外轮廓，并可由输入分发链路左键打开菜单并种植。
	var starter := tile_catalog.get_definition(&"land_four_edges")
	if starter == null:
		push_error("Planting capture: land fixture missing from the card table.")
		get_tree().quit(1)
		return
	_reset_interaction_smoke_board(starter)
	await get_tree().process_frame
	var deal: Dictionary = board_state.deal_tile(starter)
	if not bool(deal["valid"]):
		push_error("Planting capture: deal failed: %s" % deal["reason"])
		get_tree().quit(1)
		return
	await get_tree().process_frame
	_dispatch_left_click_to_cell(Vector2i.RIGHT)
	await get_tree().process_frame
	if int(board_state.phase) != BoardState.Phase.ACTION_WINDOW:
		push_error("Planting capture: routed placement click did not reach action window.")
		get_tree().quit(1)
		return

	_dispatch_mouse_motion(_screen_position_for_cell(Vector2i.ZERO))
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	var capture_directory := ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(capture_directory)
	if not land_outline_world_polygons.is_empty():
		push_error("Planting capture: hovering an older tile produced an outline.")
		get_tree().quit(1)
		return
	var old_hover_image := get_viewport().get_texture().get_image()
	old_hover_image.save_png(capture_directory.path_join("planting_hover_old_tile_no_reaction_3d.png"))

	_dispatch_mouse_motion(_screen_position_for_cell(Vector2i.RIGHT))
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	if land_outline_world_polygons.is_empty():
		push_error("Planting capture: the current new tile did not produce an outline.")
		get_tree().quit(1)
		return
	var hover_image := get_viewport().get_texture().get_image()
	hover_image.save_png(capture_directory.path_join("planting_hover_new_tile_3d.png"))

	_dispatch_left_click_to_cell(Vector2i.RIGHT)
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	var flower_choice := menu_species_targets.find(PLANT_SCRIPT.Species.FLOWER)
	if menu_mode != MenuMode.PLANT or flower_choice < 0:
		push_error("Planting capture: routed left click on the current new tile did not open the species menu.")
		get_tree().quit(1)
		return
	var menu_image := get_viewport().get_texture().get_image()
	menu_image.save_png(capture_directory.path_join("planting_species_menu_new_tile_3d.png"))
	_handle_menu_choice(flower_choice)
	if not board_state.tile_has_any_plant(Vector2i.RIGHT) or not board_state.tile_has_any_plant(Vector2i.ZERO):
		push_error("Planting capture: selecting a species did not plant the current new tile and its directly connected neighbour.")
		get_tree().quit(1)
		return
	_clear_connected_land_outline()
	_refresh_hud()
	await get_tree().process_frame
	await get_tree().create_timer(0.2).timeout
	var planted_image := get_viewport().get_texture().get_image()
	planted_image.save_png(capture_directory.path_join("planting_success_new_tile_3d.png"))
	print("PLANTING_INTERACTION_CAPTURE_PASS: older tiles stayed inert; new-tile outline, menu, planting, and direct-neighbour expansion captured.")
	get_tree().quit()


func _capture_game_preview() -> void:
	# 截图走完整对局流程：放牌 → 在新地块上种植物（草/花/树轮换）→ 结束回合。
	# 这样画面里既有土地又有植物，避免开局河流骨架阶段"全水无植物"的单调截图。
	await _drive_rules_setup_skeleton()
	var species_cycle := [
		PLANT_SCRIPT.Species.GRASS,
		PLANT_SCRIPT.Species.FLOWER,
		PLANT_SCRIPT.Species.TREE,
	]
	var cycle_index := 0
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
		var placed_cell: Vector2i = move["cell"]
		_try_place_current_tile(placed_cell)
		await get_tree().process_frame
		# 放置成功后进入 ACTION_WINDOW，尝试在刚放的新地块上种一棵植物。
		if int(board_state.phase) == BoardState.Phase.ACTION_WINDOW:
			var owner: int = board_state.active_player
			var planted := false
			for attempt in range(3):
				var species: int = species_cycle[(cycle_index + attempt) % species_cycle.size()]
				var check: Dictionary = board_state.can_plant_at(placed_cell, species, owner)
				if bool(check["valid"]):
					var pr: Dictionary = board_state.plant(placed_cell, species, owner)
					if bool(pr["valid"]):
						planted = true
						cycle_index = (cycle_index + attempt + 1) % species_cycle.size()
						_refresh_all_growth()
						break
			if not planted:
				cycle_index = (cycle_index + 1) % species_cycle.size()
		board_state.finish_action_window(PLANT_ENGINE_SCRIPT, deck_index >= deck.size())
		await get_tree().process_frame
	await get_tree().create_timer(0.35).timeout
	var capture_directory = ProjectSettings.globalize_path("res://artifacts")
	DirAccess.make_dir_recursive_absolute(capture_directory)
	var preview = get_viewport().get_texture().get_image()
	preview.save_png(capture_directory.path_join("tile_placement_preview_3d.png"))
	get_tree().quit()


# === 规则书截图 ===
# 共用 TileCatalog / BoardState / 视觉管线：每个场景把棋盘重置到一张
# 固定位置+种植列表上、隐藏 HUD、按固定相机视角截图到 res://artifacts/rules/。
# 跑法：godot --path . --rendering-driver opengl3 -- --rules-screenshot
const RULES_CAPTURE_DIR := "res://artifacts/rules"


func _capture_rules_screenshots() -> void:
	# 固定种子，保证多次运行截图一致
	deck_random.seed = 0x71E51D

	var capture_directory := ProjectSettings.globalize_path(RULES_CAPTURE_DIR)
	DirAccess.make_dir_recursive_absolute(capture_directory)

	# 隐藏 HUD 与浮层（按钮、菜单、toast、hover 描边）
	_hide_hud_for_capture()

	var viewport_texture := get_viewport().get_texture()
	if viewport_texture == null:
		push_error("Rules screenshot capture requires a rendering viewport; run without --headless.")
		get_tree().quit(1)
		return

	var save_screenshot := func(filename: String) -> void:
		var img := viewport_texture.get_image()
		if img == null:
			push_error("Rules screenshot capture: viewport image unavailable for %s." % filename)
			return
		img.save_png(capture_directory.path_join(filename))

	var land4 := tile_catalog.get_definition(&"land_four_edges")

	# 场景 1：开局空地 — 只有起始地块，棋盘四周全是空地
	await _reset_rules_board()
	_center_camera_on(Vector2i.ZERO)
	camera.size = 9.0
	await get_tree().create_timer(0.2).timeout
	save_screenshot.call("01_setup.png")

	# 场景 2：放牌中 — 玩家刚抽到 land_four_edges，鼠标悬停在一个合法位置
	#   先放 3 块 land_four_edges 拼出一片 LAND，再 deal 新 land_four_edges 并悬停邻位
	await _reset_rules_board()
	board_state.place(land4, Vector2i(-1, 0), 0, 0)
	_add_placed_tile_visual(Vector2i(-1, 0))
	board_state.place(land4, Vector2i(1, 0), 0, 0)
	_add_placed_tile_visual(Vector2i(1, 0))
	board_state.place(land4, Vector2i(0, -1), 0, 0)
	_add_placed_tile_visual(Vector2i(0, -1))
	# deal 新地块 → 玩家旋转到合法朝向 → 悬停在 (-2,0)
	board_state.deal_tile(land4)
	current_rotation = 2  # 让 land 边朝东
	hovered_cell = Vector2i(-2, 0)
	has_hovered_cell = true
	_refresh_preview_piece()
	_sync_preview()
	_center_camera_on(Vector2i(-1, 0))
	camera.size = 11.0
	await get_tree().create_timer(0.2).timeout
	save_screenshot.call("02_tile_placement.png")

	# 场景 3：动作窗口·种植目标描边 — 玩家已放下 land_four_edges 进入 ACTION_WINDOW，
	#   鼠标悬停在新地块上 → 描出 LAND 外轮廓（绿色高亮边）
	await _reset_rules_board()
	board_state.place(land4, Vector2i(-1, 0), 0, 0)
	_add_placed_tile_visual(Vector2i(-1, 0))
	board_state.place(land4, Vector2i(1, 0), 0, 0)
	_add_placed_tile_visual(Vector2i(1, 0))
	board_state.place(land4, Vector2i(0, -1), 0, 0)
	_add_placed_tile_visual(Vector2i(0, -1))
	# 模拟玩家刚放下 (-2,0) 进入动作窗口
	board_state.deal_tile(land4)
	board_state.commit_placement(Vector2i(-2, 0), 2)
	_add_placed_tile_visual(Vector2i(-2, 0))
	board_state.finish_placement()
	hovered_cell = Vector2i(-2, 0)
	has_hovered_cell = true
	_update_action_hover()
	_center_camera_on(Vector2i(-1, 0))
	camera.size = 9.0
	await get_tree().create_timer(0.2).timeout
	save_screenshot.call("03_planting_target.png")

	# 场景 4：自动扩张 — P1 在一片连通 LAND 中央种花，自动长满整片
	await _reset_rules_board()
	# 搭 6 格 land_four_edges 拼成 2x3 LAND 区域
	for cell in [Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1)]:
		board_state.place(land4, cell, 0, 0)
		_add_placed_tile_visual(cell)
	board_state.seed_inventory[0] = {
		PLANT_SCRIPT.Species.GRASS: 6,
		PLANT_SCRIPT.Species.FLOWER: 6,
		PLANT_SCRIPT.Species.TREE: 4,
	}
	board_state.seed_inventory[1] = {
		PLANT_SCRIPT.Species.GRASS: 6,
		PLANT_SCRIPT.Species.FLOWER: 6,
		PLANT_SCRIPT.Species.TREE: 4,
	}
	# P1 主动种一棵花到 (0,0)，触发自动扩张到 5 个邻接
	board_state.deal_tile(land4)
	board_state.commit_placement(Vector2i(0, 0), 0)
	_add_placed_tile_visual(Vector2i(0, 0))
	board_state.finish_placement()
	board_state.plant(Vector2i(0, 0), PLANT_SCRIPT.Species.FLOWER, 0)
	_refresh_all_growth()
	_center_camera_on(Vector2i(0, 0))
	camera.size = 9.0
	await get_tree().create_timer(0.35).timeout
	save_screenshot.call("04_auto_expansion.png")

	# 场景 5：物种驱逐 — P1 种花后，P2 在邻接格种树 → P1 的花被立刻驱逐
	await _reset_rules_board()
	for cell in [Vector2i(-1, 0), Vector2i(0, 0), Vector2i(1, 0)]:
		board_state.place(land4, cell, 0, 0)
		_add_placed_tile_visual(cell)
	board_state.seed_inventory[0] = {
		PLANT_SCRIPT.Species.GRASS: 6,
		PLANT_SCRIPT.Species.FLOWER: 6,
		PLANT_SCRIPT.Species.TREE: 4,
	}
	board_state.seed_inventory[1] = {
		PLANT_SCRIPT.Species.GRASS: 6,
		PLANT_SCRIPT.Species.FLOWER: 6,
		PLANT_SCRIPT.Species.TREE: 4,
	}
	# P1 在 (1,0) 种花，自动扩张到 (-1,0)/(0,0)
	board_state.deal_tile(land4)
	board_state.commit_placement(Vector2i(1, 0), 0)
	_add_placed_tile_visual(Vector2i(1, 0))
	board_state.finish_placement()
	board_state.plant(Vector2i(1, 0), PLANT_SCRIPT.Species.FLOWER, 0)
	_refresh_all_growth()
	# P2 在 (-1,0) 种树 → 树立刻把 P1 的 3 朵花都驱逐
	board_state.active_player = 1
	board_state.deal_tile(land4)
	board_state.commit_placement(Vector2i(-1, 0), 0)
	_add_placed_tile_visual(Vector2i(-1, 0))
	board_state.finish_placement()
	board_state.plant(Vector2i(-1, 0), PLANT_SCRIPT.Species.TREE, 1)
	_refresh_all_growth()
	_center_camera_on(Vector2i(0, 0))
	camera.size = 9.0
	await get_tree().create_timer(0.35).timeout
	save_screenshot.call("05_species_expulsion.png")

	# 场景 6：河流骨架 — 完整的河网搭好，作为「全封闭·供水」演示的对照背景
	await _reset_rules_board()
	await _drive_rules_setup_skeleton()
	_center_camera_on(Vector2i.ZERO)
	camera.size = 14.0
	await get_tree().create_timer(0.35).timeout
	save_screenshot.call("06_river_skeleton.png")

	print("RULES_SCREENSHOT_PASS: 6 screenshots saved under %s." % RULES_CAPTURE_DIR)
	get_tree().quit()


func _hide_hud_for_capture() -> void:
	if ui_layer != null:
		ui_layer.visible = false
	if label_toast != null:
		label_toast.visible = false
	if menu_panel != null:
		menu_panel.visible = false
	if land_outline_canvas != null:
		land_outline_canvas.visible = false


# 重置棋盘到"刚开局 + 河流骨架已搭好"的状态。供各场景复用。
func _reset_rules_board() -> void:
	_clear_connected_land_outline()
	for tile_node in placed_tile_nodes.values():
		if is_instance_valid(tile_node):
			tile_node.queue_free()
	placed_tile_nodes.clear()
	if preview_node != null:
		preview_node.queue_free()
		preview_node = null
	preview_border = null
	_clear_menu()
	board_state = BOARD_STATE_SCRIPT.new()
	deck = tile_catalog.build_shuffled_deck(TileDefinition.CARD_TILE, deck_random)
	deck_index = 0
	river_setup_deck = tile_catalog.river_setup_deck(deck_random)
	river_setup_index = 0
	river_setup_skipped = 0
	river_setup_active = not river_setup_deck.is_empty()
	board_state.start_with(tile_catalog.starter_tile(), 2)
	_add_placed_tile_visual(Vector2i.ZERO)
	_refresh_water_network()
	hovered_cell = Vector2i.ZERO
	hovered_subnet_idx = -1
	has_hovered_cell = false
	hover_highlight.visible = false
	menu_panel.visible = false
	label_toast.visible = false
	land_outline_signature = ""
	land_outline_world_polygons.clear()
	current_rotation = 0
	await get_tree().process_frame


# 把河流长牌阶段跑完，铺好河流骨架。
func _drive_rules_setup_skeleton() -> void:
	var setup_safety := river_setup_deck.size() + 4
	while river_setup_active and setup_safety > 0:
		setup_safety -= 1
		_on_deal_button()
		await get_tree().process_frame
		if int(board_state.phase) != BoardState.Phase.PLACE:
			continue
		var move := _find_first_visible_legal_move()
		if move.is_empty():
			var skipped: Dictionary = board_state.skip_unplaceable_river_setup_tile()
			if not bool(skipped.get("valid", false)):
				push_error("Rules screenshot setup could not skip an unplaceable river card.")
				break
			river_setup_index += 1
			river_setup_skipped += 1
			_advance_river_setup("河流牌无合法位置，已跳过")
			await get_tree().process_frame
			continue
		current_rotation = int(move["rotation"])
		_try_place_current_tile(move["cell"])
		await get_tree().process_frame
	await get_tree().create_timer(0.15).timeout
