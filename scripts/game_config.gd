extends Node
## GameConfig — 跨场景传递对局配置的 Autoload 单例
## 开始页面（start_menu）写入，游戏场景（main）读取。
## 直接从 main.tscn 启动（冒烟测试 / 调试）时这里保持默认值，游戏仍可运行。

# 本局游玩人数（2 / 3 / 4）
var player_count: int = 2

# 每位玩家的归属颜色，按下标对应 player_id。
# 为空时由 main.gd 回退到内置默认色，保证冒烟测试与旧调用方不受影响。
var player_colors: Array = []


## 是否有来自开始页面的真实配置（用于 main.gd 区分“从菜单进入”还是“直接启动”）。
func has_custom_config() -> bool:
	return player_colors.size() >= player_count
