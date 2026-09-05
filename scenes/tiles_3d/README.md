# 3D 地块预制件

## 3D 转换基础

- `tile_3d_base.tscn` 是新地块的层级模板：`Base`、`Meadow`、`LandSoil`、`Water/RiverBed`、`Water/AnimatedSurface`、`Decorations` 与两个植物状态层必须保留；模板本身不带任何地形网格。
- `art/materials/terrain/` 存放所有地块共用的底座、草地、沃土和河岸材质。水面 Shader 共用，但水面材质继续由各预制件持有，因为其岸线长度和 UV2 数据随烘焙网格变化。
- `art/topologies/` 是静态规则元数据，不参与运行时绘制。它显式记录边口、土地块、双边土地的中央连通类型，以及水口是先接触土地还是经由中央汇点；`visual_geometry_is_verified = false` 的视觉研究地块尚未达到正式地块标准。
- 可执行 `godot --headless --path . --script res://tools/validate_tile_3d_foundation.gd` 检查基础层级、共享材质与研究态门槛。

`river_cross_3d.tscn` 是当前低多边形视觉样板。它在运行时只被实例化、等比缩放和绕 Y 轴按 90° 旋转。

- 河道外形来自 `art/generated/river_cross_*_mesh.tres` 固定资源；主河与两条支流在烘焙时先合并为一个连续外轮廓，不保留相互覆盖的接头面。
- `shaders/stylized_soil.gdshader` 忽略烘焙网格的旧顶点色，只使用统一的肥沃土色、3 档低频世界坐标明度变化与边缘／近河的稀疏苔绿带；地块面仍完全由固定网格和方向光的平面法线塑形。
- `shaders/stylized_grass.gdshader` 为草地使用低饱和基色和极弱的三档世界坐标变化，不使用草纹理或逐面随机色。
- `tools/build_river_cross_ribbons.gd` 会把最终合并水岸的最近距离 `d` 和归一化弧长 `s` 烘焙进水网格的 `UV2`；`shaders/low_poly_water.gdshader` 使用 `p(s,t)` 作为唯一波相：它同时调制连续纯白岸线的局部宽度，并令同一岸线源点在波峰时从 `d=0` 出生、随年龄在窄带内向水中移动。水面保持不透明；烘焙岸线距离、场景深度和中央预留带共同把两层限制在水岸窄带，河道中央不生成泡沫。噪声只选择源点、半径和轻微变化，圆形距离场控制泡团轮廓，最终仍硬阈值化为纯白二值遮罩。
- `tools/build_river_cross_ribbons.gd` 与 `tools/build_river_cross_land_meshes.gd` 是编辑阶段使用的烘焙工具，不被游戏场景加载。控制点、两块弧形种植区的完整边缘占地和低多边形土壤切面均在工具中维护，生成后由预制件直接引用固定 `ArrayMesh`。
- 东西水口在边中心保持笔直；南北土地覆盖整边；两条短支流在地块内部进入土地。
- 两块种植区保留原有的大尺寸、长弧线和边缘连接，但为几乎与草地等高的自然肥沃土壤面：没有中央山脊、梯田或陡坡；土壤的轮廓阅读来自平面法线、单一主方向光和保守接触阴影，而不是每个三角形的独立配色。
- `GrowingPlants` 与 `WitheredPlants` 是固定美术层；裸土状态隐藏两者。生长态为稀疏草簇、灌木、幼树和少量野花，不呈现农田或作物行列；枯萎态切换为低矮干草束。
- 地块整体采用“清新桌面盆景（Fresh Tabletop Diorama）”风格，去除地块外沿的木质围栏；草地使用覆盖完整地块 footprint 的无厚度平面，土壤直接延伸到边缘，不以额外侧裙补缝，仅保留薄的底座厚度，并使用低矮肥沃土壤、微缩引水小闸与晶莹碧水溪流。

视觉比较场景为 `scenes/visual_studies/river_cross_3d_study.tscn`。运行时可按 `1 / 2 / 3` 切换 45°、55°、65° 正交视角，按 `B / G / W` 切换裸土、生长和枯萎状态。浮沫调试面板默认展开，可实时调整基础线宽度（最大 `0.085`）、岸线起伏（`1.40`）、波浪频率（`14`）、浮沫带宽度（`0.20`）、泡沫疏密（`16`）、泡沫半径（`0.68`）、分布阈值（`0–1`）和波动流速（`0.85`）；高值仍受河心保护带限制。默认基准为 `0.06 / 0.5 / 10.0 / 0.05 / 10.7 / 0.4 / 0.6 / 0.025`（按面板顺序）。按 `F` 折叠面板，面板内可切换显示／动态并恢复默认参数。支持 `--capture-angle=NN`、`--capture-state=bare|growing|withered` 与 `--capture-debug-ui` 命令行截图。

---

`three_land_river_3d.tscn` 是第二个低多边形地块预制件：三边土地、一边河流。

- 边口为 `LAND / LAND / WATER / LAND`（北、东、西为土地，南边中心为唯一水口），运行时同样只被实例化、等比缩放和绕 Y 轴按 90° 旋转，不按边口重绘地形。
- 一条**窄直水道**从南边中心进入，完全位于南侧绿地凹湾内，末端贴住沃土内缘但不切入土地——水流只从边的中心连接。
- 土地是一整块覆盖北、东、西完整边的**连续 U 形沃土**：南侧开出一块大而圆的绿地凹湾，复现参考布局的“棕土环抱绿地”阅读，而不是填满整块地或放置一个独立绿岛。
- 绿地凹湾在裸土、生长与枯萎状态下都保留；生长状态额外显示固定的植物层，裸土与枯萎状态则露出 U 形沃土。`shaders/stylized_soil.gdshader` 的 `moss_band_uv` 分支继续读取烘焙的跨地块坐标 `UV.x`（0 = 三条外沿，1 = 内侧轮廓），让苔藓只落在边缘窄带。
- 固定 `ArrayMesh` 分别由 `tools/build_three_land_river_ribbons.gd` 与 `tools/build_three_land_river_land_meshes.gd` 烘焙，预制件只引用 `art/generated/three_land_river_*_mesh.tres`，编辑期工具不被游戏场景加载。
- 视觉比较场景为 `scenes/visual_studies/three_land_river_3d_study.tscn`，运行与截图参数与 river_cross 一致（`--capture-angle=NN`、`--capture-state=bare|growing|withered`、`--study-smoke`），截图输出到 `artifacts/three_land_river_3d_*.png`。
