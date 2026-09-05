"""Build fixed Godot-ready herb meshes from Quaternius' CC0 Grass_4 source.

Usage from the repository root:
  blender --background --python tools/blender/build_soil_herb_from_quaternius.py -- \
    art/source/quaternius/ultimate_crops/Grass_4.blend \
    art/models/plants/soil_herb_quaternius_growing.glb \
    art/models/plants/soil_herb_quaternius_withered.glb

The output deliberately contains plant geometry only.  Player ownership stays
in the Godot ``OwnerMarker`` child so recolouring never changes the species or
growth-state silhouette.
"""

from __future__ import annotations

import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector


def _arguments() -> tuple[Path, Path, Path]:
    arguments = sys.argv
    separator = arguments.index("--") if "--" in arguments else len(arguments)
    values = arguments[separator + 1 :]
    if len(values) != 3:
        raise SystemExit(
            "expected: source Grass_4.blend, growing output .glb, withered output .glb"
        )
    return tuple(Path(value).resolve() for value in values)  # type: ignore[return-value]


def _clear_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)


def _material(name: str, color: tuple[float, float, float]) -> bpy.types.Material:
    material = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    material.use_nodes = True
    material.diffuse_color = (*color, 1.0)
    principled = material.node_tree.nodes.get("Principled BSDF")
    if principled is not None:
        principled.inputs["Base Color"].default_value = (*color, 1.0)
        principled.inputs["Roughness"].default_value = 0.88
        principled.inputs["Specular IOR Level"].default_value = 0.15
    return material


def _source_mesh(source_path: Path) -> bpy.types.Mesh:
    bpy.ops.wm.open_mainfile(filepath=str(source_path))
    source = bpy.data.objects.get("Grass_4")
    if source is None or source.type != "MESH":
        meshes = [object_ for object_ in bpy.context.scene.objects if object_.type == "MESH"]
        if len(meshes) != 1:
            raise RuntimeError("Grass_4.blend must contain exactly one discoverable mesh")
        source = meshes[0]
    return source.data.copy()


def _mesh_copy(
    source: bpy.types.Mesh,
    name: str,
    material: bpy.types.Material,
    lean: Vector | None = None,
) -> bpy.types.Mesh:
    mesh = source.copy()
    mesh.name = name
    mesh.materials.clear()
    mesh.materials.append(material)
    if lean is None:
        return mesh

    lower = min(vertex.co.z for vertex in mesh.vertices)
    upper = max(vertex.co.z for vertex in mesh.vertices)
    span = max(upper - lower, 0.001)
    for vertex in mesh.vertices:
        phase = max(0.0, min(1.0, (vertex.co.z - lower) / span))
        bend = phase * phase
        vertex.co.x += lean.x * bend
        vertex.co.y += lean.y * bend
        vertex.co.z = lower + (vertex.co.z - lower) * (1.0 - 0.36 * phase)
    mesh.update()
    return mesh


def _add_blade(
    root: bpy.types.Object,
    mesh: bpy.types.Mesh,
    name: str,
    location: tuple[float, float, float],
    scale: float,
    rotation_degrees: float,
) -> bpy.types.Object:
    object_ = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(object_)
    object_.parent = root
    object_.location = location
    object_.scale = (scale, scale, scale)
    object_.rotation_euler[2] = math.radians(rotation_degrees)
    return object_


def _add_seed_head(
    root: bpy.types.Object,
    material: bpy.types.Material,
    name: str,
    location: tuple[float, float, float],
    tilt_degrees: float = 0.0,
    rotation_degrees: float = 0.0,
) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cone_add(
        vertices=5,
        radius1=0.034,
        radius2=0.022,
        depth=0.13,
        location=location,
        rotation=(0.0, math.radians(tilt_degrees), math.radians(rotation_degrees)),
    )
    object_ = bpy.context.active_object
    object_.name = name
    object_.parent = root
    object_.data.materials.append(material)
    return object_


def _root(name: str) -> bpy.types.Object:
    root = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(root)
    return root


def _build_growing(source: bpy.types.Mesh) -> bpy.types.Object:
    root = _root("SoilHerbGrowing")
    leaf = _material("SoilHerbLeaf", (0.15, 0.36, 0.09))
    grain = _material("SoilHerbGrain", (0.57, 0.43, 0.15))
    blade_specs = (
        ((0.00, 0.00, 0.00), 0.48, 0.0),
        ((-0.085, 0.028, 0.00), 0.43, 24.0),
        ((0.090, -0.020, 0.00), 0.41, -27.0),
        ((0.022, -0.095, 0.00), 0.38, 9.0),
    )
    for index, (location, scale, rotation) in enumerate(blade_specs):
        _add_blade(
            root,
            _mesh_copy(source, "SoilHerbGrowingBladeMesh%02d" % index, leaf),
            "GrowingBlade%02d" % index,
            location,
            scale,
            rotation,
        )
    for index, location in enumerate(
        ((0.00, 0.00, 0.46), (-0.07, 0.025, 0.39), (0.075, -0.018, 0.37))
    ):
        _add_seed_head(root, grain, "GrowingSeedHead%02d" % index, location)
    return root


def _build_withered(source: bpy.types.Mesh) -> bpy.types.Object:
    root = _root("SoilHerbWithered")
    dry_leaf = _material("SoilHerbDryLeaf", (0.27, 0.16, 0.06))
    dry_grain = _material("SoilHerbDryGrain", (0.46, 0.31, 0.12))
    blade_specs = (
        ((-0.030, 0.005, 0.00), 0.43, 31.0, Vector((0.18, 0.03, 0.0))),
        ((0.075, -0.035, 0.00), 0.39, -36.0, Vector((0.15, -0.08, 0.0))),
        ((-0.105, 0.045, 0.00), 0.35, 47.0, Vector((-0.10, 0.12, 0.0))),
    )
    for index, (location, scale, rotation, lean) in enumerate(blade_specs):
        _add_blade(
            root,
            _mesh_copy(source, "SoilHerbWitheredBladeMesh%02d" % index, dry_leaf, lean),
            "WitheredBlade%02d" % index,
            location,
            scale,
            rotation,
        )
    _add_seed_head(root, dry_grain, "WitheredSeedHead00", (0.070, -0.020, 0.25), 52.0, 12.0)
    _add_seed_head(root, dry_grain, "WitheredSeedHead01", (-0.095, 0.040, 0.22), 58.0, -35.0)
    return root


def _export(root: bpy.types.Object, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.object.select_all(action="DESELECT")
    root.select_set(True)
    for descendant in root.children_recursive:
        descendant.select_set(True)
    bpy.context.view_layer.objects.active = root
    bpy.ops.export_scene.gltf(
        filepath=str(output_path),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_materials="EXPORT",
    )
    print("EXPORTED", output_path)


def main() -> None:
    source_path, growing_path, withered_path = _arguments()
    if not source_path.is_file():
        raise FileNotFoundError(source_path)
    source = _source_mesh(source_path)

    _clear_scene()
    _export(_build_growing(source), growing_path)
    _clear_scene()
    _export(_build_withered(source), withered_path)


if __name__ == "__main__":
    main()
