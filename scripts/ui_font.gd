class_name UiFont
extends RefCounted

# Godot's built-in fallback font carries no CJK glyphs, so every piece of
# on-screen Chinese text has to be drawn with a font that actually has them.
# This helper resolves one font once and caches it for the whole session.

const CJK_FONT_NAMES: Array[String] = [
	"Microsoft YaHei",
	"Microsoft YaHei UI",
	"PingFang SC",
	"Hiragino Sans GB",
	"Noto Sans CJK SC",
	"Noto Sans SC",
	"Source Han Sans SC",
	"WenQuanYi Micro Hei",
	"Heiti SC",
	"SimHei",
	"SimSun",
]

const WINDOWS_FONT_PATHS: Array[String] = [
	"C:/Windows/Fonts/msyh.ttc",
	"C:/Windows/Fonts/msyhl.ttc",
	"C:/Windows/Fonts/msyhbd.ttc",
	"C:/Windows/Fonts/simhei.ttf",
	"C:/Windows/Fonts/simsun.ttc",
]

# Sample the full visible vocabulary so a partial CJK fallback cannot be
# selected just because it contains the most common interface characters.
const SAMPLE_CHARACTERS := "青菱沃野本地双人拼接地块相接边口必须一致每张须与地图至少共用一条边且所有相接的两条边类型完全相同同一台设备轮流游玩第回合玩家当前没有剩余条土地个水口边口图例占满整水流中心窄空地开阔草牌堆进度已放置旋转重开点击高亮空格放置键或右侧右为但相接该位置已经有这张灌溉定义无效新现有地图一边都匹配已放下了最后一块轮到请下一块度冲积十字溪畔小地双岸地块分流水渠三边水渠沃土中心河畔田野生长中裸土枯萎"

static var _resolved_font = null


static func ui_font():
	if _resolved_font == null:
		_resolved_font = _resolve_font()
	return _resolved_font


static func _resolve_font():
	var system_font := SystemFont.new()
	system_font.font_names = CJK_FONT_NAMES
	if _covers_chinese(system_font):
		return system_font

	for path in WINDOWS_FONT_PATHS:
		if not FileAccess.file_exists(path):
			continue
		var font_file := FontFile.new()
		if font_file.load_dynamic_font(path) != OK:
			continue
		if _covers_chinese(font_file):
			return font_file

	return ThemeDB.fallback_font


static func _covers_chinese(font) -> bool:
	if font == null:
		return false
	for index in range(SAMPLE_CHARACTERS.length()):
		if not font.has_char(SAMPLE_CHARACTERS.unicode_at(index)):
			return false
	return true
