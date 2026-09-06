extends Control
## 开始页面：选择游玩人数与每位玩家颜色，再进入对局。
## UI 全部用代码构建，字体与音效复用游戏内既有辅助。

const UI_FONT_SCRIPT := preload("res://scripts/ui_font.gd")

# 5 色池：玩家色不提供绿色，避免与草地、可种植土地混淆。
const COLOR_POOL := [
	Color("#ed9b70"),  # 暖橙
	Color("#6cb4d8"),  # 水蓝
	Color("#b58fc4"),  # 藤紫
	Color("#e8c66a"),  # 暖黄
	Color("#d97766"),  # 砖红
]
const COLOR_NAMES := ["暖橙", "水蓝", "藤紫", "暖黄", "砖红"]
const PLAYER_COUNT_OPTIONS := [2, 3, 4]
const DEFAULT_PLAYER_COUNT := 2
const SMOKE_ARGS := ["--game-smoke", "--river-setup-smoke", "--capture-game", "--capture-planting", "--planting-input-smoke"]
const BG_COLOR := Color(0.035, 0.102, 0.086, 1.0)

var selected_count := DEFAULT_PLAYER_COUNT
# 每位玩家在 COLOR_POOL 中的下标；按玩家序排列。
var player_color_indices: Array[int] = []

var count_buttons: Array[Button] = []
var player_rows_container: VBoxContainer = null
var player_rows: Array = []                       # [{label: Label, buttons: Array[Button]}]
var btn_start: Button = null
var hint_label: Label = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# 命令行冒烟 / 截图测试：跳过菜单直接进游戏，交由 main.gd 处理。
	# _ready 期间场景刚进入树，直接同步 change_scene 在 headless 下不可靠，
	# 推迟一帧（await process_frame）再切更稳。
	if _is_smoke_run():
		GameConfig.player_count = 2
		GameConfig.player_colors = []
		await get_tree().process_frame
		get_tree().change_scene_to_file("res://scenes/main.tscn")
		return
	_build_ui()
	_apply_default_colors()


func _is_smoke_run() -> bool:
	var args := OS.get_cmdline_user_args()
	for a in SMOKE_ARGS:
		if a in args:
			return true
	return false


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = BG_COLOR
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(560, 0)
	card.add_theme_stylebox_override("panel", _make_card_style())
	center.add_child(card)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 16)
	card.add_child(content)

	var title := _make_label("青菱沃野", 38, Color("#e7f1cf"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(title)
	var subtitle := _make_label("Qingling Meadow · 水网田园地块拼接", 14, Color("#9fc98a"))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(subtitle)
	content.add_child(_make_separator())

	var count_box := VBoxContainer.new()
	count_box.add_theme_constant_override("separation", 8)
	content.add_child(count_box)
	count_box.add_child(_make_label("游玩人数", 16, Color("#eff3d2")))
	var count_row := HBoxContainer.new()
	count_row.add_theme_constant_override("separation", 12)
	count_row.alignment = BoxContainer.ALIGNMENT_CENTER
	count_box.add_child(count_row)
	for n in PLAYER_COUNT_OPTIONS:
		var b := _make_count_button(n)
		count_buttons.append(b)
		count_row.add_child(b)

	content.add_child(_make_separator())

	content.add_child(_make_label("选择颜色", 16, Color("#eff3d2")))
	player_rows_container = VBoxContainer.new()
	player_rows_container.add_theme_constant_override("separation", 12)
	content.add_child(player_rows_container)

	content.add_child(_make_separator())

	btn_start = _make_primary_button("开 始 游 戏")
	btn_start.pressed.connect(_on_start)
	content.add_child(btn_start)

	hint_label = _make_label("同色不可重复 · 同一设备轮流游玩 · R 旋转 · N 重开 · 右键旋转", 12, Color(0.7, 0.82, 0.65, 0.85))
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(hint_label)


# === 样式辅助 ===

func _make_card_style() -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0.06, 0.10, 0.085, 0.92)
	s.set_corner_radius_all(18)
	s.set_border_width_all(1)
	s.border_color = Color(0.62, 0.82, 0.55, 0.30)
	s.set_content_margin_all(30)
	s.shadow_color = Color(0, 0, 0, 0.45)
	s.shadow_size = 14
	s.shadow_offset = Vector2(0, 6)
	return s


func _make_label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_override("font", UI_FONT_SCRIPT.ui_font())
	return l


func _make_separator() -> HSeparator:
	var sep := HSeparator.new()
	var line := StyleBoxLine.new()
	line.color = Color(0.62, 0.82, 0.55, 0.20)
	line.thickness = 1
	sep.add_theme_stylebox_override("separator", line)
	return sep


func _button_stylebox(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(10)
	s.set_border_width_all(1)
	s.border_color = Color(bg.r + 0.14, bg.g + 0.14, bg.b + 0.12, 0.6)
	s.set_content_margin_all(8)
	return s


func _make_count_button(n: int) -> Button:
	var b := Button.new()
	b.text = "%d 人" % n
	b.add_theme_font_override("font", UI_FONT_SCRIPT.ui_font())
	b.add_theme_font_size_override("font_size", 16)
	b.custom_minimum_size = Vector2(96, 40)
	b.pressed.connect(_on_count_selected.bind(n))
	b.pressed.connect(func() -> void: Sfx.play("ui_click"))
	b.mouse_entered.connect(func() -> void: Sfx.play("ui_hover"))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	return b


func _refresh_count_buttons() -> void:
	for b in count_buttons:
		var n := int(b.text.split(" ")[0])
		var selected := (n == selected_count)
		var base := Color("#3f7d4e") if selected else Color("#2c4630")
		b.add_theme_stylebox_override("normal", _button_stylebox(base))
		b.add_theme_stylebox_override("hover", _button_stylebox(base.lightened(0.16)))
		b.add_theme_stylebox_override("hover_pressed", _button_stylebox(base.lightened(0.16)))
		b.add_theme_stylebox_override("pressed", _button_stylebox(base.darkened(0.18)))
		b.add_theme_color_override("font_color", Color("#eef6dd") if selected else Color(0.85, 0.92, 0.8, 0.85))
		b.add_theme_color_override("font_hover_color", Color("#ffffff"))


func _make_primary_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", UI_FONT_SCRIPT.ui_font())
	b.add_theme_font_size_override("font_size", 20)
	b.custom_minimum_size = Vector2(0, 48)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var base := Color("#3f7d4e")
	b.add_theme_stylebox_override("normal", _button_stylebox(base))
	b.add_theme_stylebox_override("hover", _button_stylebox(base.lightened(0.16)))
	b.add_theme_stylebox_override("hover_pressed", _button_stylebox(base.lightened(0.16)))
	b.add_theme_stylebox_override("pressed", _button_stylebox(base.darkened(0.18)))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", Color("#eef6dd"))
	b.add_theme_color_override("font_hover_color", Color("#ffffff"))
	b.mouse_entered.connect(func() -> void: Sfx.play("ui_hover"))
	return b


# === 状态 ===

func _apply_default_colors() -> void:
	# 默认每位玩家依次取色池前 N 色，开局即互不重复。
	player_color_indices.clear()
	for i in range(selected_count):
		player_color_indices.append(i)
	_rebuild_player_rows()
	_refresh_count_buttons()


func _rebuild_player_rows() -> void:
	for child in player_rows_container.get_children():
		child.queue_free()
	player_rows.clear()
	for p in range(selected_count):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var label := _make_label("玩家 %d" % (p + 1), 14, Color("#eff3d2"))
		label.custom_minimum_size = Vector2(72, 0)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(label)
		var btns: Array[Button] = []
		for c in range(COLOR_POOL.size()):
			var b := Button.new()
			b.text = ""
			b.custom_minimum_size = Vector2(40, 40)
			b.tooltip_text = COLOR_NAMES[c]
			b.pressed.connect(_on_color_pressed.bind(p, c))
			b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
			row.add_child(b)
			btns.append(b)
		player_rows_container.add_child(row)
		player_rows.append({"label": label, "buttons": btns})
	_refresh_color_buttons()
	_update_player_labels()


func _refresh_color_buttons() -> void:
	for p in range(player_color_indices.size()):
		var row = player_rows[p]
		var chosen: int = player_color_indices[p]
		var btns: Array[Button] = row["buttons"]
		for c in range(COLOR_POOL.size()):
			var b: Button = btns[c]
			var selected := (chosen == c)
			var taken := _color_taken_by(c, p)
			b.disabled = taken and not selected
			b.add_theme_stylebox_override("normal", _color_btn_style(COLOR_POOL[c], selected))
			b.add_theme_stylebox_override("hover", _color_btn_style(COLOR_POOL[c].lightened(0.10), selected))
			b.add_theme_stylebox_override("pressed", _color_btn_style(COLOR_POOL[c].darkened(0.12), selected))
			b.add_theme_stylebox_override("hover_pressed", _color_btn_style(COLOR_POOL[c].lightened(0.10), selected))
			b.add_theme_stylebox_override("disabled", _color_btn_disabled_style(COLOR_POOL[c]))


func _color_taken_by(c_idx: int, except_p: int) -> bool:
	for i in range(player_color_indices.size()):
		if i == except_p:
			continue
		if player_color_indices[i] == c_idx:
			return true
	return false


func _color_btn_style(color: Color, selected: bool) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(9)
	if selected:
		s.set_border_width_all(3)
		s.border_color = Color(1.0, 1.0, 1.0, 0.95)
	else:
		s.set_border_width_all(1)
		s.border_color = Color(0.0, 0.0, 0.0, 0.25)
	s.set_content_margin_all(0)
	return s


func _color_btn_disabled_style(color: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(color.r, color.g, color.b, 0.16)
	s.set_corner_radius_all(9)
	s.set_border_width_all(1)
	s.border_color = Color(0.0, 0.0, 0.0, 0.20)
	s.set_content_margin_all(0)
	return s


func _update_player_labels() -> void:
	for p in range(player_color_indices.size()):
		var row = player_rows[p]
		var label: Label = row["label"]
		label.add_theme_color_override("font_color", COLOR_POOL[player_color_indices[p]])


# === 回调 ===

func _on_count_selected(n: int) -> void:
	if n == selected_count:
		return
	selected_count = n
	_apply_default_colors()


func _on_color_pressed(p_idx: int, c_idx: int) -> void:
	if _color_taken_by(c_idx, p_idx):
		return
	if player_color_indices[p_idx] == c_idx:
		return
	player_color_indices[p_idx] = c_idx
	Sfx.play("ui_click")
	_refresh_color_buttons()
	_update_player_labels()


func _on_start() -> void:
	GameConfig.player_count = selected_count
	GameConfig.player_colors = []
	for idx in player_color_indices:
		GameConfig.player_colors.append(COLOR_POOL[idx])
	Sfx.play("turn_start")
	get_tree().change_scene_to_file("res://scenes/main.tscn")
