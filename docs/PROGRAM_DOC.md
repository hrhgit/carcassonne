# 碧水沃野 — 程序文档

> 一个 Godot 4.6.3 实现的开源桌游《碧水沃野》(Verdant Waters)，Carcassonne 变体。

---

## 1. 项目概述

碧水沃野是一款两人回合制策略桌游。玩家轮流出牌、放置地块，目标是建造连通的土地与水网，并在终局前种植植物、扩张版图，以分数决胜负。

- **核心机制**：地块拼接 → 连通性分析 → 灌溉 / 种植 → 终局计分
- **目标平台**：Godot 4.6.3 (GL Compatibility 渲染)
- **运行模式**：
  - **手动对局**：玩家用鼠标 + 键盘全程操作
  - **冒烟测试**：`--game-smoke` 跑规则 / 植物 / 回合循环 3 个自动化校验
  - **截图**：`--capture-game` 自动出 7 块后导出预览图

---

## 2. 技术栈

| 类别 | 选型 |
|------|------|
| 引擎 | Godot 4.6.3.stable |
| 语言 | GDScript 4.6 |
| 渲染 | GL Compatibility |
| 数据 | CSV (`data/tiles_classic.csv`, 26 行 × 21 列, 72 张地块) |
| 资源 | `class_name` 全局脚本 + `RefCounted` 纯逻辑 + Node2D 视图层 |

---

## 3. 文件清单

```
carcassonne/
├─ project.godot                  # 引擎配置（1280×820, canvas_items stretch）
├─ scenes/
│   └─ main.tscn                  # 入口场景，仅挂 main.gd
├─ scripts/                       # 共 4883 行 GDScript
│   ├─ main.gd                    # 1380 行 · 入口 / 状态机 / 相机 / 渲染 / 冒烟
│   ├─ board_state.gd             # 440 行 · 游戏状态机（Phase enum）
│   ├─ rule_engine.gd             # 645 行 · DSU 连通性 / land_region / water_net 分析
│   ├─ plant_engine.gd            # 401 行 · 植物结算（settle / end_game / score / winner）
│   ├─ plant.gd                   # 81 行 · 植物数据（Species × Form × Score Weight）
│   ├─ tile_definition.gd         # 398 行 · TileDefinition + EdgeKind / CenterKind
│   ├─ tile_catalog.gd            # 295 行 · CSV → TileDefinition 构建
│   ├─ tile_view.gd               # 45 行 · Node2D 包装，承载地块 prefab 或占位图
│   ├─ tile_placeholder.gd        # 96 行 · 无美术 prefab 时的占位渲染
│   ├─ tile_artwork.gd            # 90 行 · 美术资源描述
│   ├─ tile_owner_marker.gd       # 17 行 · 地块所属玩家色块
│   ├─ edge_tile.gd               # 412 行 · 边语义（Empty/Land/Water/River/Bank）
│   ├─ land_patch.gd              # 210 行 · 地块内 land 群落（中心+边）
│   ├─ land_water_tile.gd         # 314 行 · 完整地块语义描述
│   └─ ui_font.gd                 # 67 行 · UI 字体加载
├─ data/
│   └─ tiles_classic.csv          # 26 行经典地块定义（72 张）
└─ docs/
    └─ 规则书.md                   # 游戏规则来源（§3 ~ §7）
```

---

## 4. 架构：三层分离

```
┌──────────────────────────────────────────────────────────┐
│  View  ·  main.gd  (Node2D)                              │
│  - 相机 / 平移 / 镜头同步                                │
│  - 渲染（_draw + Node2D 子节点）                         │
│  - 输入处理 (鼠标 / 键盘 / 滚轮 / 中键拖动)             │
│  - 阶段按钮 / 动作菜单 / 终局遮罩                       │
└────────────────┬─────────────────────────────────────────┘
                 │ 调用
                 ▼
┌──────────────────────────────────────────────────────────┐
│  Controller  ·  board_state.gd  (RefCounted)             │
│  - 阶段状态机：DEAL / PLACE / ACTION_WINDOW / GAME_OVER  │
│  - 玩家轮换 / 抽牌 / 放置 / 完成放置 / 动作结算 / 终局   │
│  - 种子库存 / 植物字典 / 回合记录                        │
└────┬─────────────────────────────────────┬───────────────┘
     │ 算规则                              │ 算植物
     ▼                                     ▼
┌─────────────────────────┐    ┌───────────────────────────┐
│  rule_engine.gd         │    │  plant_engine.gd          │
│  - DSU 连通分量          │    │  - settle (阶段 A/B)      │
│  - LandRegion            │    │  - end_game_settle (§5.7) │
│  - WaterNet (S_W, P)     │    │  - score (§6)             │
│  - 水渠改写（BANK↔水口） │    │  - resolve_winner (5 元)  │
└─────────────────────────┘    └───────────────────────────┘
```

**关键原则**：

- `RuleEngine` 和 `PlantEngine` 都是 **无状态计算器**，每次调用拿当前 `BoardState` 重新分析。
- `BoardState` 持有 **唯一可变状态**：地块字典、植物字典、种子库存、阶段标记。
- `main.gd` 是 **唯一有渲染的入口**，所有按钮 / 菜单都通过调用 `BoardState` 的方法推进状态。

---

## 5. §7 回合循环（手动控制）

```
   ┌──────┐  抽牌   ┌──────┐  放至少1块  ┌──────────────┐  回合结束  ┌──────┐
   │ DEAL │ ──────→ │PLACE │ ──────────→ │ACTION_WINDOW │ ────────→ │ DEAL │
   └──────┘         └──────┘             └──────┬───────┘           └──────┘
                          ▲                     │                       │
                          │ 旋转 / 重选位置       │ 可种 / 可扩 / 跳       │
                          │                     ▼                       ▼
                          │              PlantEngine.settle         切玩家 +1
                          │              (植物形式变更)            deck_index+1
                          │
                          └──────────── 任意时刻按 N 重开 ────────────┘
                                                               牌堆空时
                                                                  ↓
                                                           ┌────────────┐
                                                           │ GAME_OVER  │
                                                           │ 跑 run_end │
                                                           │  显示遮罩  │
                                                           └────────────┘
```

**三个手动按钮**（每个 phase 只亮 1 个）：

| 按钮 | 触发阶段 | 调用方法 |
|------|----------|----------|
| 抽牌 | DEAL | `board_state.deal_tile(...)` |
| 完成放置 | PLACE（至少放 1 块） | `board_state.finish_placement()` |
| 回合结束 | ACTION_WINDOW / GAME_OVER | `board_state.finish_action_window()` / `run_end_game()` |

**动作窗口**（在 ACTION_WINDOW 阶段点棋盘格弹出菜单）：

- 点 **本回合新放的格** → 弹出 **种植菜单**（草 / 花 / 树，按剩余种子数 + 合法性过滤）
- 点 **自己已有植物的格** → 弹出 **扩张菜单**（同物种土地块内的可扩格）

任意点击棋盘外的位置会关闭菜单。

---

## 6. 相机与无限地图系统

### 6.1 为什么需要无限地图

经典 Carcassonne 是有限地图（玩家填满一片区域后无路可走）。本作的目标是支持无限扩张，因此去掉了 `BOARD_ROWS=7` / `BOARD_COLUMNS=9` 这种常量限制。

### 6.2 坐标系

- **逻辑格坐标** `cell: Vector2i` 是整数对，无边界。
- **屏幕像素** = `GRID_ORIGIN + cell * CELL_SIZE - camera_offset`
- `GRID_ORIGIN = (48, 157)`，每格 `78px`，原点在 `(0, 0)`。

### 6.3 相机平滑跟随

```gdscript
var camera_offset: Vector2   # 当前偏移
var camera_target: Vector2   # 目标偏移
const PAN_LERP = 14.0        # 镜头追随系数

func _process(delta):
    camera_offset = camera_offset.lerp(camera_target, delta * PAN_LERP)
    _sync_pieces_to_camera()
    queue_redraw()
```

### 6.4 镜头控制方式

| 输入 | 行为 |
|------|------|
| WASD / 方向键 | 每次平移 3 格 |
| 鼠标滚轮 | 每次平移 1.5 格 |
| 中键拖动 | 自由平移，无平滑 |

### 6.5 镜头自动跟随

每放一块新地块，自动把该格移到 viewport 中心：

```gdscript
func _center_camera_on(cell):
    camera_target = GRID_ORIGIN + cell * CELL_SIZE + CELL_SIZE/2 - canvas/2
    camera_offset = camera_target  # 直接 snap，不走 lerp
    _sync_pieces_to_camera()       # 必须显式同步已放置地块
```

### 6.6 BFS 搜索半径

```gdscript
const SEARCH_RADIUS := 24  # Manhattan 距离限制
```

从所有已放块出发 BFS 4 邻居，超过半径就不再展开。冒烟测试时这个上限必须够大，否则早期游戏会"找不到可放格"。

---

## 7. 最近一次 Bug 修复：地形不跟着镜头动

**症状**：地图平移时，棋盘格背景跟着动，但**已放置地块**（含预览块）停在原位置，造成"地图动、地形不动"。

**根因**：

- 已放置地块通过 `_add_placed_tile_visual(cell)` 添加为 `Node2D` 子节点，**只在添加那一刻设了一次 `piece.position`**。
- `_draw()` 画的棋盘格背景每帧根据 `camera_offset` 重算位置，所以会动。
- Node2D 子节点的世界坐标不会因为 `camera_offset` 改变而自动调整，所以不动。

**修复**：新增 `_sync_pieces_to_camera()`，在以下时机调用：

1. `_process()` 里 `camera_offset` lerp 后
2. `_unhandled_input` 中键拖动结束 `camera_offset = camera_target` 后
3. `_center_camera_on()` 直接 snap 时（不走 lerp）

```gdscript
func _sync_pieces_to_camera() -> void:
    for cell in placed_tile_nodes.keys():
        var piece = placed_tile_nodes[cell]
        if piece != null and is_instance_valid(piece):
            piece.position = _cell_rect(cell).get_center()
    if preview_piece != null and is_instance_valid(preview_piece) \
            and preview_piece.visible and has_hovered_cell:
        preview_piece.position = _cell_rect(hovered_cell).get_center()
```

**修复过程中遇到的二次问题**：

- `Node2D.is_hidden()` 不存在；Godot 用 `visible` 属性 → 改为 `preview_piece.visible`
- 用了 `is_instance_valid(piece)` 防御地块被 `queue_free` 后引用悬空的情况

**回归保障**：3 个冒烟测试都通过（`tiles placed=72, turn=73`，说明无限地图逻辑也未被破坏）。

---

## 8. 渲染策略

| 层 | 做法 | 原因 |
|----|------|------|
| 棋盘格背景 | `_draw()` + `draw_style_box` | 必须跟随 `camera_offset`，每帧重算最简单 |
| 地块本体 | `Node2D` 子节点（prefab / 占位图） | 美术资源是 prefab，需要作为子节点 |
| 植物标记 | `_draw()` + `draw_circle` | 小色点，不需要 prefab |
| 玩家色标 | `TileOwnerMarker` 子节点 | 跟随地块 |
| 终局遮罩 | `_draw()` 一次性画 | 顶层覆盖 |

**为什么地块不用 `_draw()` 画？** 因为 prefab 是子场景，不能在 `_draw()` 里直接渲染。代价就是上面那个 bug。

---

## 9. 运行方式

### 9.1 手动对局（Godot Editor）

```bash
"D:/Godot4.6.3/Godot_v4.6.3-stable_win64.exe" --path .
```

### 9.2 冒烟测试（CI 用）

```bash
"D:/Godot4.6.3/Godot_v4.6.3-stable_win64_console.exe" \
  --headless --path . -- --game-smoke
```

预期输出（最后 3 行）：

```
RULE_ENGINE_SMOKE_PASS: starter land region=1, road_cross4 alone water net=1/P=1/S=1, road_straight east merges net to P=2/4-open-edges.
PLANTS_SMOKE_PASS: seeds=2/2/2 each; plant API gates species collision & ownership; V_L=0 → WATER_SHORT; §6.4 halves flower score on unclosed land; tiebreaker prefers healthy_flower; §5.6 stage B refunds seeds and removes plants; §5.7 upgrades WATER_SHORT to WITHERED.
GAME_SMOKE_PASS: full §7 turn loop manual emulation succeeded; tile placement, plant/expand/skip, settle, end-game all green. tiles placed=72, turn=73.
```

### 9.3 截图

```bash
"D:/Godot4.6.3/Godot_v4.6.3-stable_win64_console.exe" \
  --headless --path . -- --capture-game
```

产物：`artifacts/tile_placement_preview.png`

---

## 10. 关键数据约定

### 10.1 边方向

```
        N (0)
        ↑
W (3) ←─┼─→ E (1)
        ↓
        S (2)
```

```gdscript
const NORTH = 0
const EAST = 1
const SOUTH = 2
const WEST = 3
```

### 10.2 EdgeKind

| 值 | 含义 |
|----|------|
| 0 EMPTY | 无边 / 阻断 |
| 1 LAND  | 土地 |
| 2 WATER | 水口 / 水流 |
| 3 RIVER | IR（不可走水流） |
| 4 BANK  | 河岸 |

### 10.3 CenterKind

| 值 | 含义 |
|----|------|
| 0 EMPTY | 无中心 |
| 1 LAND  | 中心为 land（计 1 unit） |
| 2 LAKE  | 中心为湖（自动并入相邻 water net） |
| 3 RIVER | 中心为河流 |

### 10.4 Plant

| 字段 | 类型 | 说明 |
|------|------|------|
| `id` | int | 唯一 id |
| `species` | Species | 0 GRASS / 1 FLOWER / 2 TREE |
| `form` | Form | 0 HEALTHY / 1 WATER_SHORT / 2 WITHERED |
| `owner` | int | 0 / 1 |
| `tile_cell` | Vector2i | 所在地块 |
| `land_region_id` | int | 所在 land 群 id |

### 10.5 计分权重

| 物种 | 权重 | 健康分 | 缺水分 | 枯萎分 |
|------|------|--------|--------|--------|
| 草 | 1.0 | 1.0 | 0 | 0 |
| 花 | 2.0 | 2.0 | 0 | 0 |
| 树 | 4.0 | 4.0 | 0 | 0 |

（花在未封闭土地上 ×0.5；详见 `rule_engine.gd` §6.4）

### 10.6 赢家裁决（5 元 tiebreaker）

1. 总分
2. healthy_tree 数
3. closed_score（全封闭分）
4. healthy_flower 数
5. healthy_grass 数

---

## 11. 已知约束

- **GL Compatibility 渲染**：prefabs 不能用 GPU 特效（粒子等）
- **没有"漏牌"按钮**：§7.1.2 规定抽到无合法位置的牌要弃置，目前冒烟测试里用代码绕过；UI 上没暴露
- **种子不可交易**：草/花/树种子不能跨玩家转
- **植物可视化很弱**：只用颜色点 + 半透明边框，未画物种形状
- **地块所属色块**：用左上角小色块表达，正式版可以做成边框

---

## 12. 后续可扩展点

- 给地块 prefab 加旋转 hover 高亮
- 把 BFS `SEARCH_RADIUS=24` 改成 viewport 自适应（自动跟随相机视野）
- 植物视觉升级：草=绿点、花=红五瓣、树=三角
- 联机：把 `BoardState` 抽出来发 RPC
- 录像回放：把每次 `commit_placement` / `plant` / `expand` 落 JSON