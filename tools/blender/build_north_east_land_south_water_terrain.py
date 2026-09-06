"""Bake the first seam-safe naturalized terrain pilot with Blender.

The TileSpec remains the rule source of truth.  This script verifies the
canonical NORTH/EAST LAND, SOUTH WATER, WEST EMPTY grammar, then adds only
interior curvature, shallow relief and bank cross-sections.  Every vertex in
the outer lock band stays on the shared tile boundary contract.

Usage from the repository root:
  blender --background --python tools/blender/build_north_east_land_south_water_terrain.py -- \
    tools/tile_specs_3d/north_east_land_south_water.json \
    art/source/generated_blender/north_east_land_south_water.blend \
    art/models/tiles_blender/north_east_land_south_water.glb \
    art/models/tiles_blender/north_east_land_south_water.manifest.json
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import Iterable, Sequence

import bpy
from mathutils import Vector
from mathutils.geometry import tessellate_polygon


TILE_HALF_SIZE = 2.45
EDGE_LOCK_BAND = 0.35
MEADOW_HEIGHT = 0.14
SOIL_HEIGHT = 0.20
WATER_HEIGHT = 0.168
WATER_PORT_WIDTH = 0.48


def _arguments() -> tuple[Path, Path, Path, Path]:
    values = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    if len(values) != 4:
        raise SystemExit("expected: TileSpec JSON, output .blend, output .glb, output manifest JSON")
    return tuple(Path(value).resolve() for value in values)  # type: ignore[return-value]


def _verify_spec(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    expected = ["LAND", "LAND", "WATER", "EMPTY"]
    if data.get("edges") != expected:
        raise ValueError(f"pilot requires edges {expected}, got {data.get('edges')}")
    regions = data.get("land_regions", [])
    routes = data.get("water_routes", [])
    if regions != [{"id": "north_east_field", "edges": ["NORTH", "EAST"]}]:
        raise ValueError("pilot requires one NORTH/EAST connected land region")
    if routes != [{"from": "SOUTH", "to_region": "north_east_field", "via_hub": False}]:
        raise ValueError("pilot requires one SOUTH-centre route ending at the field")
    return data


def _clear_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)
    for datablocks in (bpy.data.meshes, bpy.data.materials, bpy.data.curves):
        for datablock in list(datablocks):
            if datablock.users == 0:
                datablocks.remove(datablock)


def _to_blender(point: tuple[float, float], height: float) -> tuple[float, float, float]:
    # Blender glTF export maps +Z-up to Godot +Y-up and Blender -Y to Godot +Z.
    return (point[0], -point[1], height)


def _smoothstep(edge0: float, edge1: float, value: float) -> float:
    if edge0 == edge1:
        return 0.0
    t = max(0.0, min(1.0, (value - edge0) / (edge1 - edge0)))
    return t * t * (3.0 - 2.0 * t)


def _meadow_height(x: float, z: float) -> float:
    distance_to_edge = TILE_HALF_SIZE - max(abs(x), abs(z))
    fade = _smoothstep(EDGE_LOCK_BAND, EDGE_LOCK_BAND + 0.62, distance_to_edge)
    relief = math.sin(x * 1.18 + z * 0.37) * 0.018
    relief += math.sin(x * -0.43 + z * 1.04 + 0.71) * 0.011
    return MEADOW_HEIGHT + fade * relief


def _new_mesh_object(
    name: str,
    vertices: Sequence[tuple[float, float, float]],
    faces: Sequence[Sequence[int]],
    *,
    smooth: bool = False,
    uv0: Sequence[tuple[float, float]] | None = None,
    uv1: Sequence[tuple[float, float]] | None = None,
) -> bpy.types.Object:
    mesh = bpy.data.meshes.new(f"{name}Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.validate(verbose=True)
    mesh.update(calc_edges=True)
    for polygon in mesh.polygons:
        polygon.use_smooth = smooth
    if uv0 is not None:
        layer = mesh.uv_layers.new(name="UVMap")
        for loop in mesh.loops:
            layer.data[loop.index].uv = uv0[loop.vertex_index]
    if uv1 is not None:
        layer = mesh.uv_layers.new(name="UVMap.001")
        for loop in mesh.loops:
            layer.data[loop.index].uv = uv1[loop.vertex_index]
    object_ = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(object_)
    return object_


def _build_base() -> bpy.types.Object:
    half = TILE_HALF_SIZE
    bottom = -0.30
    top = 0.0
    vertices = [
        _to_blender((-half, -half), bottom),
        _to_blender((half, -half), bottom),
        _to_blender((half, half), bottom),
        _to_blender((-half, half), bottom),
        _to_blender((-half, -half), top),
        _to_blender((half, -half), top),
        _to_blender((half, half), top),
        _to_blender((-half, half), top),
    ]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    return _new_mesh_object("Base", vertices, faces)


def _build_meadow() -> bpy.types.Object:
    subdivisions = 16
    vertices: list[tuple[float, float, float]] = []
    uv: list[tuple[float, float]] = []
    for row in range(subdivisions + 1):
        z = -TILE_HALF_SIZE + 2.0 * TILE_HALF_SIZE * row / subdivisions
        for column in range(subdivisions + 1):
            x = -TILE_HALF_SIZE + 2.0 * TILE_HALF_SIZE * column / subdivisions
            vertices.append(_to_blender((x, z), _meadow_height(x, z)))
            uv.append((column / subdivisions, row / subdivisions))
    faces: list[tuple[int, int, int]] = []
    stride = subdivisions + 1
    for row in range(subdivisions):
        for column in range(subdivisions):
            a = row * stride + column
            b = a + 1
            c = a + stride + 1
            d = a + stride
            if (row + column) % 2 == 0:
                faces.extend(((a, c, b), (a, d, c)))
            else:
                faces.extend(((a, d, b), (b, d, c)))
    return _new_mesh_object("Meadow", vertices, faces, smooth=True, uv0=uv)


def _bezier(
    start: tuple[float, float],
    control_a: tuple[float, float],
    control_b: tuple[float, float],
    end: tuple[float, float],
    segments: int,
) -> list[tuple[float, float]]:
    result: list[tuple[float, float]] = []
    for index in range(segments + 1):
        t = index / segments
        inv = 1.0 - t
        x = inv**3 * start[0] + 3.0 * inv**2 * t * control_a[0] + 3.0 * inv * t**2 * control_b[0] + t**3 * end[0]
        z = inv**3 * start[1] + 3.0 * inv**2 * t * control_a[1] + 3.0 * inv * t**2 * control_b[1] + t**3 * end[1]
        result.append((x, z))
    return result


def _land_outline() -> tuple[list[tuple[float, float]], int]:
    north_west = (-TILE_HALF_SIZE, -TILE_HALF_SIZE)
    north_east = (TILE_HALF_SIZE, -TILE_HALF_SIZE)
    south_east = (TILE_HALF_SIZE, TILE_HALF_SIZE)
    # These are the existing generator's corner-derived anchors.  They are not
    # redesigned in Blender: the south/east and west/north shoulders, water
    # contact and connector points remain exact.  Added samples bow outward
    # between anchors so the old LAND mask stays fully contained.
    frontier_anchors = [
        (1.72, TILE_HALF_SIZE),
        (1.46, 1.70),
        (1.16, 1.10),
        (0.96, 0.48),
        (0.9353256, 0.2826004),
        (-0.2826004, 0.2826004),
        (-0.2826004, -0.935318),
        (-0.48, -0.96),
        (-1.10, -1.16),
        (-1.70, -1.46),
        (-TILE_HALF_SIZE, -1.72),
    ]
    rounded_frontier: list[tuple[float, float]] = [frontier_anchors[0]]
    for index in range(len(frontier_anchors) - 1):
        start = Vector(frontier_anchors[index])
        end = Vector(frontier_anchors[index + 1])
        direction = (end - start).normalized()
        outward = Vector((direction.y, -direction.x))
        bulge = min(0.055, (end - start).length * 0.08)
        for fraction in (1.0 / 3.0, 2.0 / 3.0):
            point = start.lerp(end, fraction) + outward * (bulge * math.sin(math.pi * fraction))
            rounded_frontier.append((point.x, point.y))
        rounded_frontier.append(frontier_anchors[index + 1])
    # First three vertices are the exact outer corner grammar.  The returned
    # index is where the editable interior frontier begins.
    outline = [north_west, north_east, south_east]
    outline.extend(rounded_frontier)
    return outline, 2


def _polygon_area(points: Sequence[tuple[float, float]]) -> float:
    return 0.5 * sum(
        points[index][0] * points[(index + 1) % len(points)][1]
        - points[(index + 1) % len(points)][0] * points[index][1]
        for index in range(len(points))
    )


def _outward_offset(points: Sequence[tuple[float, float]], index: int, amount: float) -> tuple[float, float]:
    previous = Vector(points[(index - 1) % len(points)])
    current = Vector(points[index])
    following = Vector(points[(index + 1) % len(points)])
    incoming = (current - previous).normalized()
    outgoing = (following - current).normalized()
    tangent = (incoming + outgoing).normalized()
    # The authored outline is counter-clockwise in Godot X/Z, so right is out.
    outward = Vector((tangent.y, -tangent.x))
    return (current.x + outward.x * amount, current.y + outward.y * amount)


def _build_land() -> bpy.types.Object:
    outline, interior_start = _land_outline()
    if _polygon_area(outline) <= 0.0:
        raise RuntimeError("land outline must remain counter-clockwise")
    vector_loop = [Vector((x, -z, 0.0)) for x, z in outline]
    triangles = tessellate_polygon([vector_loop])
    top_vertices = [_to_blender(point, SOIL_HEIGHT) for point in outline]
    top_index_by_coordinate = {(round(vertex[0], 7), round(vertex[1], 7)): index for index, vertex in enumerate(vector_loop)}
    faces: list[tuple[int, ...]] = []
    for triangle in triangles:
        if triangle and isinstance(triangle[0], int):
            # Blender 5.2 returns indices here; older supported versions return
            # the Vector values themselves.
            faces.append(tuple(reversed([int(vertex) for vertex in triangle])))
        else:
            faces.append(tuple(reversed([top_index_by_coordinate[(round(vertex.x, 7), round(vertex.y, 7))] for vertex in triangle])))

    bottom_vertices: list[tuple[float, float, float]] = []
    last_index = len(outline) - 1
    for index, point in enumerate(outline):
        if index < interior_start or index == last_index:
            bottom_point = point
        else:
            progress = (index - interior_start) / max(1, last_index - interior_start)
            amount = 0.14 * math.sin(math.pi * progress) ** 0.7
            distance_to_edge = TILE_HALF_SIZE - max(abs(point[0]), abs(point[1]))
            amount *= _smoothstep(0.0, EDGE_LOCK_BAND, distance_to_edge)
            bottom_point = _outward_offset(outline, index, amount)
            bottom_point = (
                max(-TILE_HALF_SIZE, min(TILE_HALF_SIZE, bottom_point[0])),
                max(-TILE_HALF_SIZE, min(TILE_HALF_SIZE, bottom_point[1])),
            )
        bottom_vertices.append(_to_blender(bottom_point, _meadow_height(*bottom_point) + 0.006))
    vertices = top_vertices + bottom_vertices
    count = len(outline)
    for index in range(count):
        next_index = (index + 1) % count
        # Keep the same closed vertical cross-section on every claimed LAND
        # edge.  When two valid tiles meet these faces are hidden back-to-back,
        # while their top and lower boundary vertices still match exactly.
        faces.append((index, next_index, count + next_index, count + index))
    uv = [
        ((point[0] + TILE_HALF_SIZE) / (2.0 * TILE_HALF_SIZE), (point[1] + TILE_HALF_SIZE) / (2.0 * TILE_HALF_SIZE))
        for point in outline
    ]
    uv.extend(uv)
    return _new_mesh_object("NorthEastField", vertices, faces, smooth=False, uv0=uv)


def _river_path() -> list[tuple[float, float]]:
    # The first 0.70 units are straight and fully locked to the SOUTH-centre
    # port.  Only the interior receives a shallow, topology-readable bend.
    straight = [(0.0, TILE_HALF_SIZE), (0.0, 2.10), (0.0, 1.75)]
    curved = _bezier((0.0, 1.75), (-0.07, 1.36), (0.08, 0.76), (0.0, 0.335), 14)
    return straight + curved[1:]


def _path_frames(path: Sequence[tuple[float, float]]) -> tuple[list[Vector], list[Vector], list[float]]:
    points = [Vector(point) for point in path]
    normals: list[Vector] = []
    cumulative = [0.0]
    for index in range(1, len(points)):
        cumulative.append(cumulative[-1] + (points[index] - points[index - 1]).length)
    for index in range(len(points)):
        previous = points[max(0, index - 1)]
        following = points[min(len(points) - 1, index + 1)]
        tangent = (following - previous).normalized()
        normals.append(Vector((-tangent.y, tangent.x)))
    return points, normals, cumulative


def _water_width(progress: float) -> float:
    interior = math.sin(math.pi * progress) ** 2
    return WATER_PORT_WIDTH + interior * (0.035 * math.sin(progress * math.tau) + 0.025)


def _build_river_bed() -> bpy.types.Object:
    points, normals, cumulative = _path_frames(_river_path())
    total = cumulative[-1]
    cross = (-1.0, -0.58, 0.0, 0.58, 1.0)
    vertices: list[tuple[float, float, float]] = []
    uv: list[tuple[float, float]] = []
    for row, point in enumerate(points):
        progress = cumulative[row] / total
        water_width = _water_width(progress)
        bank_width = water_width + 0.34
        # The bank lips sit just below the surface, while the channel centre is
        # genuinely recessed.  This gives the depth-aware foam a narrow bank
        # contact and guarantees a clear-water centre.
        heights = (MEADOW_HEIGHT + 0.004, 0.154, 0.075, 0.154, MEADOW_HEIGHT + 0.004)
        for column, factor in enumerate(cross):
            offset = normals[row] * (bank_width * 0.5 * factor)
            sample = point + offset
            height = heights[column]
            if row <= 2:
                # The SOUTH lock band is identical for every matching port.
                height = heights[column]
            vertices.append(_to_blender((sample.x, sample.y), height))
            uv.append((progress, (factor + 1.0) * 0.5))
    faces: list[tuple[int, int, int, int]] = []
    columns = len(cross)
    for row in range(len(points) - 1):
        for column in range(columns - 1):
            a = row * columns + column
            faces.append((a, a + 1, a + columns + 1, a + columns))
    return _new_mesh_object("RiverBed", vertices, faces, smooth=True, uv0=uv)


def _build_water() -> tuple[bpy.types.Object, float]:
    points, normals, cumulative = _path_frames(_river_path())
    total = cumulative[-1]
    columns = 9
    vertices: list[tuple[float, float, float]] = []
    uv0: list[tuple[float, float]] = []
    uv1: list[tuple[float, float]] = []
    widths: list[float] = []
    for row, point in enumerate(points):
        progress = cumulative[row] / total
        width = _water_width(progress)
        widths.append(width)
        for column in range(columns):
            across = column / (columns - 1)
            signed = across * 2.0 - 1.0
            offset = normals[row] * (width * 0.5 * signed)
            sample = point + offset
            vertices.append(_to_blender((sample.x, sample.y), WATER_HEIGHT))
            uv0.append((progress, across))
            distance = width * 0.5 * (1.0 - abs(signed))
            # Left and right banks traverse opposite directions around the one
            # fused outline.  End-cap lengths keep s continuous at both ends.
            perimeter = 2.0 * total + widths[0] + width
            if signed <= 0.0:
                shore_arc = cumulative[row]
            else:
                shore_arc = total + width + (total - cumulative[row])
            uv1.append((distance, (shore_arc / max(perimeter, 1e-6)) % 1.0))
    faces: list[tuple[int, int, int, int]] = []
    for row in range(len(points) - 1):
        for column in range(columns - 1):
            a = row * columns + column
            faces.append((a, a + 1, a + columns + 1, a + columns))
    shoreline_length = 2.0 * total + widths[0] + widths[-1]
    return _new_mesh_object("AnimatedSurface", vertices, faces, smooth=True, uv0=uv0, uv1=uv1), shoreline_length


def _save_outputs(blend_path: Path, glb_path: Path, manifest_path: Path, shoreline_length: float, spec: dict) -> None:
    for path in (blend_path, glb_path, manifest_path):
        path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(blend_path))
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.export_scene.gltf(
        filepath=str(glb_path),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_materials="NONE",
        export_extras=True,
    )
    manifest = {
        "id": spec["id"],
        "source": "Blender seam-safe terrain pilot",
        "tile_half_size": TILE_HALF_SIZE,
        "edge_lock_band": EDGE_LOCK_BAND,
        "water_port_width": WATER_PORT_WIDTH,
        "water_height": WATER_HEIGHT,
        "shoreline_length": round(shoreline_length, 6),
        "objects": ["Base", "Meadow", "NorthEastField", "RiverBed", "AnimatedSurface"],
        "edge_contract": {
            "north": "LAND full edge",
            "east": "LAND full edge",
            "south": "WATER centred width 0.48",
            "west": "EMPTY full edge",
        },
    }
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    spec_path, blend_path, glb_path, manifest_path = _arguments()
    spec = _verify_spec(spec_path)
    _clear_scene()
    _build_base()
    _build_meadow()
    _build_land()
    _build_river_bed()
    _, shoreline_length = _build_water()
    _save_outputs(blend_path, glb_path, manifest_path, shoreline_length, spec)
    print(f"BLENDER_TILE_TERRAIN_BUILT glb={glb_path} shoreline_length={shoreline_length:.6f}")


if __name__ == "__main__":
    main()
