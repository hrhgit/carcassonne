## 针对性验证：开始页配置的玩家色必须驱动对局中的归属标志色。
## 用法：godot --headless --path . --scene tools/verify_player_color_config.tscn
extends Node

const MAIN_SCRIPT := preload("res://scripts/main.gd")
const START_MENU_SCENE := preload("res://scenes/start_menu.tscn")
const CONFIGURED_COLORS := [Color("#ed9b70"), Color("#6cb4d8")]
const REMOVED_GREEN := Color("#7ecf91")


func _ready() -> void:
	var original_count := GameConfig.player_count
	var original_colors: Array = GameConfig.player_colors.duplicate()
	GameConfig.player_count = CONFIGURED_COLORS.size()
	GameConfig.player_colors = CONFIGURED_COLORS.duplicate()

	var main := MAIN_SCRIPT.new()
	var passed := true
	for player_id in range(CONFIGURED_COLORS.size()):
		var actual: Color = main.call("_player_color", player_id)
		var expected: Color = CONFIGURED_COLORS[player_id]
		if not actual.is_equal_approx(expected):
			printerr("[FAIL] P%d expected %s, got %s" % [player_id + 1, expected, actual])
			passed = false

	main.free()
	if not await _start_menu_has_no_green_option():
		passed = false
	GameConfig.player_count = original_count
	GameConfig.player_colors = original_colors
	if passed:
		print("[PASS] Configured player colours reach the game; start menu has no green option.")
	get_tree().quit(0 if passed else 1)


func _start_menu_has_no_green_option() -> bool:
	var menu := START_MENU_SCENE.instantiate()
	add_child(menu)
	await get_tree().process_frame
	var rows: Array = menu.get("player_rows") as Array
	var passed := true
	if rows.size() != 2:
		printerr("[FAIL] Start menu should build two default player rows, got %d." % rows.size())
		passed = false
	for row in rows:
		var buttons: Array = row["buttons"]
		if buttons.size() != 5:
			printerr("[FAIL] Start menu should expose five colour options, got %d." % buttons.size())
			passed = false
		for button in buttons:
			var style := (button as Button).get_theme_stylebox(&"normal") as StyleBoxFlat
			if style != null and style.bg_color.is_equal_approx(REMOVED_GREEN):
				printerr("[FAIL] Start menu still exposes the removed green option.")
				passed = false
	menu.queue_free()
	await get_tree().process_frame
	return passed
