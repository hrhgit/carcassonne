extends SceneTree

## 一次性验证：audio/sfx/ 下全部音效可被 Godot 加载，
## 且 water_flow_loop 可正确设置无缝循环。
## 用法：
##   Godot --headless --path . --script tools/test_sfx_load.gd

const SFX_NAMES := [
	"ui_click", "ui_hover", "tile_pickup", "tile_place", "tile_rotate", "tile_invalid",
	"plant_seed", "plant_grow", "plant_wilt", "harvest",
	"water_drop", "water_splash", "water_flow_loop",
	"score_point", "turn_start", "victory", "defeat",
]


func _initialize() -> void:
	var failed := 0
	for n in SFX_NAMES:
		var s: AudioStream = load("res://audio/sfx/%s.wav" % n)
		if s == null:
			push_error("FAIL load: " + n)
			failed += 1
		else:
			print("OK %s (%.2fs)" % [n, s.get_length()])

	var loop := load("res://audio/sfx/water_flow_loop.wav") as AudioStreamWAV
	loop.loop_mode = AudioStreamWAV.LOOP_FORWARD
	loop.loop_begin = 0
	loop.loop_end = int(loop.get_length() * loop.mix_rate)  # 与压缩格式无关
	print("water_flow_loop: %d 帧可循环（格式 %d, %d Hz）" % [loop.loop_end, loop.format, loop.mix_rate])

	# autoload 注册检查（Sfx 由 project.godot 注册；--script 模式下可能未实例化）
	if ProjectSettings.has_setting("autoload/Sfx"):
		print("OK autoload/Sfx 已注册: " + str(ProjectSettings.get_setting("autoload/Sfx")))
	else:
		push_error("FAIL: autoload/Sfx 未注册")
		failed += 1

	# 说明：SfxManager 的 DirAccess 枚举在 --script 模式下不可靠（res:// 列举受限），
	# 因此管理器的运行时加载行为改由「真实上下文」--headless --quit 验证
	# （会打印 "[Sfx] 已加载 17 个音效"）。本脚本只覆盖资源可加载性 + 循环配置。

	quit(0 if failed == 0 else 1)
