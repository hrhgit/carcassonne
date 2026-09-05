# 地块预制件

游戏内地块的美术来源都在这个目录。`TileCatalog` 为每个规则定义指定一个固定 `.tscn`，`TileView` 只负责实例化、等比缩放和按 90° 旋转。

可直接在 Godot 中编辑下列场景的 `Polygon2D`（土地）和 `Line2D`（水流），而不需要修改放置规则：

- `alluvial_cross.tscn`：四边土地。
- `brook_nook.tscn`：单边土地与单水口。
- `opposite_banks.tscn`：双边对置土地与单水口分渠。
- `river_cross.tscn`：双水口主水道与两侧土地。
- `three_side_canal.tscn`：三边土地与单水口。
- `corner_bank.tscn`：相邻双边土地与单水口。

编辑时保持两个约束：土地形状必须覆盖它对应的整条边；每条水线必须从边中心进入并在地块内抵达土地。每个根节点的 `edge_markers` 是该预制件的静态校验元数据；规则边标记仍在 `scripts/tile_catalog.gd` 中维护。若你改变了边口方向，同时更新两者，运行时会拒绝不匹配的预制件。
