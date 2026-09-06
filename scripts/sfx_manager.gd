extends Node
## SfxManager — 全局音效管理器（Autoload 名称：Sfx）
##
## 启动时自动加载 res://audio/sfx/ 下全部 .wav / .ogg。
## 用法示例：
##   Sfx.play("tile_place")                       # 播放一次
##   Sfx.play("plant_grow", volume_db=-3.0, pitch_jitter=0.06)
##   var water := Sfx.play_loop("water_flow_loop") # 循环环境音
##   Sfx.stop_loop("water_flow_loop")
##   Sfx.has_sfx("victory")

const SFX_DIR := "res://audio/sfx/"
const POOL_SIZE := 10
const PACKED_SFX_FILES := [
	"defeat.wav", "harvest.wav", "plant_grow.wav", "plant_seed.wav",
	"plant_wilt.wav", "score_point.wav", "tile_invalid.wav", "tile_pickup.wav",
	"tile_place.wav", "tile_rotate.wav", "turn_start.wav", "ui_click.wav",
	"ui_hover.wav", "victory.wav", "water_drop.wav", "water_flow_loop.wav",
	"water_splash.wav"
]

var _streams: Dictionary = {}
var _pool: Array[AudioStreamPlayer] = []
var _loop_players: Dictionary = {}


func _ready() -> void:
	_load_streams()
	_create_pool()


func _load_streams() -> void:
	# get_files_at 返回目录下全部文件名（含 .import/.uid，按扩展名过滤），
	# 比 list_dir_begin 循环更稳，在某些 headless 上下文里也能正确枚举。
	var files := DirAccess.get_files_at(SFX_DIR)
	var load_dir := SFX_DIR
	var has_audio_file := false
	for file_name in files:
		if file_name.get_extension().to_lower() == "wav" or file_name.get_extension().to_lower() == "ogg":
			has_audio_file = true
			break
	if not has_audio_file:
		# Files inside an embedded PCK are not always enumerable through DirAccess.
		# Prefer the loose audio directory shipped beside the exported executable.
		load_dir = OS.get_executable_path().get_base_dir().path_join("audio/sfx")
		files = DirAccess.get_files_at(load_dir)
	if files.is_empty():
		# Keep the packaged asset names explicit as a final fallback; this still
		# allows ResourceLoader remaps to work when the importer retained them.
		files = PackedStringArray(PACKED_SFX_FILES)
	for file_name in files:
		var ext := file_name.get_extension().to_lower()
		if ext == "wav" or ext == "ogg":
			var stream: AudioStream = load(load_dir.path_join(file_name))
			if stream == null and load_dir != SFX_DIR and ext == "wav":
				var wav_path := load_dir.path_join(file_name)
				var wav_bytes := FileAccess.get_file_as_bytes(wav_path)
				if not wav_bytes.is_empty():
					stream = AudioStreamWAV.load_from_buffer(wav_bytes)
			if stream != null:
				_streams[file_name.get_basename()] = stream
	print("[Sfx] 已加载 %d 个音效" % _streams.size())


func _create_pool() -> void:
	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_pool.append(p)


func has_sfx(sfx_name: String) -> bool:
	return _streams.has(sfx_name)


## 播放一次性音效。pitch_jitter 每次随机微调音调，避免重复播放显得机械。
func play(sfx_name: String, volume_db := 0.0, pitch_scale := 1.0, pitch_jitter := 0.04) -> void:
	var stream: AudioStream = _streams.get(sfx_name)
	if stream == null:
		push_warning("SfxManager: 未注册音效 '%s'" % sfx_name)
		return
	var p := _acquire_player()
	p.stream = stream
	p.volume_db = volume_db
	p.pitch_scale = clampf(pitch_scale + randf_range(-pitch_jitter, pitch_jitter), 0.05, 4.0)
	p.play()


## 播放循环音效（如 water_flow_loop），同名重复调用不会叠音。
func play_loop(sfx_name: String, volume_db := -6.0) -> AudioStreamPlayer:
	var stream: AudioStream = _streams.get(sfx_name)
	if stream == null:
		push_warning("SfxManager: 未注册音效 '%s'" % sfx_name)
		return null
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		# 导入可能是 16-bit 或 QOA 压缩，统一用解码后的帧数计算循环点
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = int(wav.get_length() * wav.mix_rate)
	var p: AudioStreamPlayer = _loop_players.get(sfx_name)
	if p == null:
		p = AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_loop_players[sfx_name] = p
	p.stream = stream
	p.volume_db = volume_db
	if not p.playing:
		p.play()
	return p


func stop_loop(sfx_name: String) -> void:
	var p: AudioStreamPlayer = _loop_players.get(sfx_name)
	if p != null and p.playing:
		p.stop()


func _acquire_player() -> AudioStreamPlayer:
	for p in _pool:
		if not p.playing:
			return p
	return _pool[0]  # 池全忙时抢占最旧通道
