# 3D 地表共享材质

- `tile_base.tres`、`meadow.tres`、`fertile_soil.tres`、`river_bank.tres` 是所有 3D 地块共用的基础材质；其中 `river_bank.tres` 仅用于水面下的 `RiverBed` 内衬，通用生成器必须将其投影完全收在 `AnimatedSurface` 内，不能形成可见的灰色河岸条带。
- `fertile_soil_edge_band.tres` 仅用于其烘焙网格提供了 `moss_band_uv` 的土地。
- 水面**不**放入这一组共享材质：水面 Shader 共用，但每张地块的 `ShaderMaterial` 必须保留在该预制件中，因为岸线长度与水面 UV2 是随烘焙河道变化的。
- 草、花、树等植物材质和原型尚未纳入本目录；当前阶段只建设地表基础。
