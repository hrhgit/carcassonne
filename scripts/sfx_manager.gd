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
	if files.is_empty():
		push_warning("SfxManager: 音效目录为空或不可读 " + SFX_DIR)
		return
	for file_name in files:
		var ext := file_name.get_extension().to_lower()
		if ext == "wav" or ext == "ogg":
			var stream: AudioStream = load(SFX_DIR + file_name)
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
