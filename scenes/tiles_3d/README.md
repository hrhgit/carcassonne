# 3D 地块预制件

`river_cross_3d.tscn` 是当前低多边形视觉样板。它在运行时只被实例化、等比缩放和绕 Y 轴按 90° 旋转。

- 河道外形来自 `art/generated/river_cross_*_mesh.tres` 固定资源。
- `shaders/low_poly_water.gdshader` 只改变水面的色阶、亮纹和轻微高度波动，不读取规则边口，也不改变河道轮廓。
- `tools/build_river_cross_ribbons.gd` 是编辑阶段使用的烘焙工具，不被游戏场景加载。控制点在该工具中维护，生成后由预制件直接引用固定 `ArrayMesh`。
- 东西水口在边中心保持笔直；南北土地覆盖整边；两条短支流在地块内部进入土地。
- `GrowingPlants` 与 `WitheredPlants` 是固定美术层；裸土状态隐藏两者。

视觉比较场景为 `scenes/visual_studies/river_cross_3d_study.tscn`。运行时可按 `1 / 2 / 3` 切换 45°、55°、65° 正交视角，按 `B / G / W` 切换裸土、生长和枯萎状态。
