# LowPolyChill river reference

This folder contains two river terrain meshes from the free LowPolyChill pack:

- official source page: https://loxiabun.itch.io/lowpolychill-assets
- source archive SHA-256:
  `4581dda6bd41b99c120e5f8d0b39a9407a7b2630c10392c07de26e88b8fd2c87`
- license stated by the author on the official page: CC0

The meshes are retained as Blender cross-section and silhouette references.
They are not used as the tile boundary: the final game prefab is rebuilt on
the project's 4.9-unit canonical boundary, 0.35-unit edge lock band and 0.48-
unit centred WATER port. This avoids inheriting the donor pack's unrelated
4-by-4 modular seam contract.

`ground.river.end.glb` informs the recessed channel and layered bank profile;
`ground.river.bend.glb` informs the quiet interior bend. KayKit's free grass
and rock meshes supply the visible third-party decoration in the V2 prefab.
The donor GLBs reference `../textures/gradient-texture.png`, which is staged
beside this folder so the reference meshes also remain inspectable in Godot.
