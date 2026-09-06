"""Bake the free-asset V2 seam-safe terrain with Blender.

The TileSpec remains the rule source of truth.  This script verifies the
canonical NORTH/EAST LAND, SOUTH WATER, WEST EMPTY grammar, then adds only
interior curvature, shallow relief and bank cross-sections.  Every vertex in
the outer lock band stays on the shared tile boundary contract.

Usage from the repository root:
  blender --background --python tools/blender/build_free_asset_north_east_land_south_water_terrain.py -- \
    tools/tile_specs_3d/north_east_land_south_water.json \
    art/source/generated_blender/north_east_land_south_water_free_v2.blend \
    art/models/tiles_blender/north_east_land_south_water_free_v2.glb \
    art/models/tiles_blender/north_east_land_south_water_free_v2.manifest.json
"""

from __future__ import annotations

import json
import math
import sys
from pathlib import Path
from typing import Iterable, Sequence

import bpy
from mathutils import Vector


TILE_HALF_SIZE = 2.45
EDGE_LOCK_BAND = 0.35
MEADOW_HEIGHT = 0.14
SOIL_HEIGHT = 0.190
WATER_HEIGHT = 0.151
# Keep the south-edge port at its shared 0.151 height while every interior
# water sample clears the actual meadow relief by at least the same amount.
WATER_OVER_MEADOW_CLEARANCE = WATER_HEIGHT - MEADOW_HEIGHT
WATER_HEIGHT_SAMPLE_ACROSS = 16
WATER_HEIGHT_SAMPLE_ALONG = 8
WATER_PORT_WIDTH = 0.48
LAND_SLOPE_OUTSET = 0.24
PLANTING_BOUNDARY_SCALE = 0.80
LAND_MEADOW_CLEARANCE = 0.014
LAND_MEADOW_RELIEF_FADE = 0.18
LAND_TOP_TONE = 0.52
LAND_SLOPE_FACE_TONES = (0.38, 0.58, 0.45, 0.64, 0.42, 0.55, 0.49, 0.61)

_LAND_SLOPE_FOOTPRINT: list[tuple[float, float]] | None = None


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
    relief = math.sin(x * 1.18 + z * 0.37) * 0.023
    relief += math.sin(x * -0.43 + z * 1.04 + 0.71) * 0.014
    # The complete MEADOW mesh remains below the fixed LAND prefab, but its
    # relief is flattened under the whole soil footprint and returns only
    # outside the polygonal slope. This prevents grass triangles from cutting
    # through a low soil edge while retaining quiet terrain variation nearby.
    return MEADOW_HEIGHT + fade * _land_meadow_relief_weight(Vector((x, z))) * relief


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
    subdivisions = 24
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


def _land_outline() -> tuple[list[tuple[float, float]], int]:
    north_west = (-TILE_HALF_SIZE, -TILE_HALF_SIZE)
    north_east = (TILE_HALF_SIZE, -TILE_HALF_SIZE)
    south_east = (TILE_HALF_SIZE, TILE_HALF_SIZE)
    # A deliberately low-poly convex chain. The seven straight segments read
    # as a broad natural bend without Bézier smoothing, concave notches or
    # donor-pack boundary coordinates.
    frontier = [
        (1.383, 1.883),
        (0.384, 1.250),
        (-0.500, 0.500),
        (-1.250, -0.384),
        (-1.883, -1.383),
    ]
    outline = [north_west, north_east, south_east]
    outline.extend(frontier)
    return outline, 2


def _polygon_area(points: Sequence[tuple[float, float]]) -> float:
    return 0.5 * sum(
        points[index][0] * points[(index + 1) % len(points)][1]
        - points[(index + 1) % len(points)][0] * points[index][1]
        for index in range(len(points))
    )


def _polygon_centroid(points: Sequence[tuple[float, float]]) -> tuple[float, float]:
    twice_area = 0.0
    x_sum = 0.0
    z_sum = 0.0
    for index, point in enumerate(points):
        following = points[(index + 1) % len(points)]
        cross = point[0] * following[1] - following[0] * point[1]
        twice_area += cross
        x_sum += (point[0] + following[0]) * cross
        z_sum += (point[1] + following[1]) * cross
    if abs(twice_area) <= 1e-8:
        raise RuntimeError("cannot compute LAND centroid for a zero-area polygon")
    return (x_sum / (3.0 * twice_area), z_sum / (3.0 * twice_area))


def _verify_convex(points: Sequence[tuple[float, float]]) -> None:
    cross_sign = 0.0
    for index in range(len(points)):
        a = Vector(points[index])
        b = Vector(points[(index + 1) % len(points)])
        c = Vector(points[(index + 2) % len(points)])
        first = b - a
        second = c - b
        cross = first.x * second.y - first.y * second.x
        if abs(cross) <= 1e-6:
            continue
        if cross_sign == 0.0:
            cross_sign = math.copysign(1.0, cross)
        elif cross * cross_sign < 0.0:
            raise RuntimeError(f"LAND outline is not convex at vertex {index}: cross={cross}")


def _planting_boundary(points: Sequence[tuple[float, float]]) -> list[tuple[float, float]]:
    # Scaling a convex polygon around an interior centroid preserves convexity
    # and gives crops a quiet setback from all visible soil edges.
    centre = Vector((
        sum(point[0] for point in points) / len(points),
        sum(point[1] for point in points) / len(points),
    ))
    return [tuple(centre + (Vector(point) - centre) * PLANTING_BOUNDARY_SCALE) for point in points]


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


def _land_slope_points(
    outline: Sequence[tuple[float, float]], interior_start: int
) -> tuple[list[tuple[float, float]], list[tuple[float, float]], list[tuple[float, float]]]:
    shoulder_points: list[tuple[float, float]] = []
    lower_points: list[tuple[float, float]] = []
    bottom_points: list[tuple[float, float]] = []
    last_index = len(outline) - 1
    for index, point in enumerate(outline):
        if index < interior_start or index == last_index:
            shoulder_point = point
            lower_point = point
            bottom_point = point
        else:
            progress = (index - interior_start) / max(1, last_index - interior_start)
            distance_to_edge = TILE_HALF_SIZE - max(abs(point[0]), abs(point[1]))
            # The entire lock band remains untouched; the broad side slope
            # starts only after the shared seam contract ends.
            unlocked = _smoothstep(EDGE_LOCK_BAND, EDGE_LOCK_BAND + 0.28, distance_to_edge)
            bulge = math.sin(math.pi * progress) ** 0.72
            shoulder_point = _outward_offset(outline, index, LAND_SLOPE_OUTSET * 0.34 * bulge * unlocked)
            lower_point = _outward_offset(outline, index, LAND_SLOPE_OUTSET * 0.70 * bulge * unlocked)
            bottom_point = _outward_offset(outline, index, LAND_SLOPE_OUTSET * bulge * unlocked)
        shoulder_points.append(shoulder_point)
        lower_points.append(lower_point)
        bottom_points.append(bottom_point)
    return shoulder_points, lower_points, bottom_points


def _land_slope_footprint() -> list[tuple[float, float]]:
    global _LAND_SLOPE_FOOTPRINT
    if _LAND_SLOPE_FOOTPRINT is None:
        outline, interior_start = _land_outline()
        _, _, _LAND_SLOPE_FOOTPRINT = _land_slope_points(outline, interior_start)
    return _LAND_SLOPE_FOOTPRINT


def _point_in_polygon(point: Vector, polygon: Sequence[tuple[float, float]]) -> bool:
    inside = False
    for index, start in enumerate(polygon):
        end = polygon[(index + 1) % len(polygon)]
        if (start[1] > point.y) == (end[1] > point.y):
            continue
        crossing_x = (end[0] - start[0]) * (point.y - start[1]) / (end[1] - start[1]) + start[0]
        if point.x < crossing_x:
            inside = not inside
    return inside


def _distance_to_segment(point: Vector, start: Vector, end: Vector) -> float:
    segment = end - start
    length_squared = segment.length_squared
    if length_squared <= 1e-8:
        return (point - start).length
    progress = max(0.0, min(1.0, (point - start).dot(segment) / length_squared))
    return (point - (start + segment * progress)).length


def _land_meadow_relief_weight(point: Vector) -> float:
    footprint = _land_slope_footprint()
    if _point_in_polygon(point, footprint):
        return 0.0
    distance = min(
        _distance_to_segment(point, Vector(footprint[index]), Vector(footprint[(index + 1) % len(footprint)]))
        for index in range(len(footprint))
    )
    return _smoothstep(0.0, LAND_MEADOW_RELIEF_FADE, distance)


def _build_land() -> bpy.types.Object:
    outline, interior_start = _land_outline()
    if _polygon_area(outline) <= 0.0:
        raise RuntimeError("land outline must remain counter-clockwise")
    _verify_convex(outline)
    count = len(outline)
    vertices: list[tuple[float, float, float]] = []
    faces: list[tuple[int, ...]] = []
    uv: list[tuple[float, float]] = []
    centre = _polygon_centroid(outline)
    # The top triangles remain deindexed for a deliberately simple, flat
    # planting surface. They all receive the same palette coordinate: visible
    # low-poly value variation belongs only to the outer slope faces.
    for index in range(count):
        next_index = (index + 1) % count
        base = len(vertices)
        vertices.extend((
            _to_blender(centre, SOIL_HEIGHT),
            _to_blender(outline[index], SOIL_HEIGHT),
            _to_blender(outline[next_index], SOIL_HEIGHT),
        ))
        uv.extend(((LAND_TOP_TONE, 1.0), (LAND_TOP_TONE, 1.0), (LAND_TOP_TONE, 1.0)))
        faces.append((base, base + 2, base + 1))

    shoulder_points, lower_points, bottom_points = _land_slope_points(outline, interior_start)

    rings = [
        (outline, [SOIL_HEIGHT] * count, 1.0),
        (shoulder_points, [SOIL_HEIGHT - 0.014] * count, 0.68),
        (lower_points, [SOIL_HEIGHT - 0.032] * count, 0.34),
        (bottom_points, [_meadow_height(*point) + LAND_MEADOW_CLEARANCE for point in bottom_points], 0.0),
    ]
    # Side quads are also deindexed so each segment can retain one controlled
    # tone while the three rings make the outward slope visibly broad.
    for ring_index in range(len(rings) - 1):
        upper_points, upper_heights, upper_v = rings[ring_index]
        lower_ring_points, lower_heights, lower_v = rings[ring_index + 1]
        for index in range(count):
            next_index = (index + 1) % count
            base = len(vertices)
            vertices.extend((
                _to_blender(upper_points[index], upper_heights[index]),
                _to_blender(upper_points[next_index], upper_heights[next_index]),
                _to_blender(lower_ring_points[next_index], lower_heights[next_index]),
                _to_blender(lower_ring_points[index], lower_heights[index]),
            ))
            tone = LAND_SLOPE_FACE_TONES[(index + ring_index + 2) % len(LAND_SLOPE_FACE_TONES)]
            uv.extend(((tone, upper_v), (tone, upper_v), (tone, lower_v), (tone, lower_v)))
            faces.append((base, base + 1, base + 2, base + 3))
    return _new_mesh_object("NorthEastField", vertices, faces, smooth=False, uv0=uv)


def _river_path() -> list[tuple[float, float]]:
    # Straight SOUTH lock section followed by three visible polygonal turns.
    # The contact point meets the convex LAND frontier at x=0; the last two
    # points form a short tapered irrigation tongue above the soil surface.
    return [
        (0.0, TILE_HALF_SIZE),
        (0.0, 2.10),
        (-0.08, 1.74),
        (0.06, 1.35),
        (0.0, 0.924),
        (0.04, 0.82),
        (0.08, 0.75),
    ]


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


def _water_width(progress: float, row: int, row_count: int) -> float:
    del progress
    width_factors = (1.0, 1.0, 0.90, 0.82, 0.72, 0.48, 0.24)
    if row_count != len(width_factors):
        raise RuntimeError("polygonal WATER width profile must match the authored path")
    return WATER_PORT_WIDTH * width_factors[row]


def _water_surface_base_height(row: int, row_count: int) -> float:
    if row == row_count - 4:
        return 0.178
    if row < row_count - 3:
        return WATER_HEIGHT
    return SOIL_HEIGHT + 0.003


def _meadow_peak_around_water_row(
    points: Sequence[Vector], normals: Sequence[Vector], widths: Sequence[float], row: int
) -> float:
    """Sample the two water spans adjoining `row` against the baked meadow.

    Each water row receives the greatest grass height beneath either adjoining
    span.  The two ends of every water quad consequently clear the full local
    grass relief, rather than only clearing the meadow at their own vertices.
    """
    peak = MEADOW_HEIGHT
    first_segment = max(0, row - 1)
    last_segment = min(row, len(points) - 2)
    for segment in range(first_segment, last_segment + 1):
        for along_index in range(WATER_HEIGHT_SAMPLE_ALONG + 1):
            along = along_index / WATER_HEIGHT_SAMPLE_ALONG
            centre = points[segment].lerp(points[segment + 1], along)
            normal = normals[segment].lerp(normals[segment + 1], along).normalized()
            width = widths[segment] + (widths[segment + 1] - widths[segment]) * along
            for across_index in range(WATER_HEIGHT_SAMPLE_ACROSS + 1):
                across = across_index / WATER_HEIGHT_SAMPLE_ACROSS - 0.5
                sample = centre + normal * (width * across)
                peak = max(peak, _meadow_height(sample.x, sample.y))
    return peak


def _water_surface_height(
    points: Sequence[Vector], normals: Sequence[Vector], widths: Sequence[float], row: int
) -> float:
    base_height = _water_surface_base_height(row, len(points))
    if row == 0:
        # The boundary water port is part of the immutable seam contract.
        return base_height
    return max(base_height, _meadow_peak_around_water_row(points, normals, widths, row) + WATER_OVER_MEADOW_CLEARANCE)


def _build_river_bed() -> bpy.types.Object:
    points, normals, cumulative = _path_frames(_river_path())
    total = cumulative[-1]
    cross = (-1.0, -0.58, 0.0, 0.58, 1.0)
    vertices: list[tuple[float, float, float]] = []
    uv: list[tuple[float, float]] = []
    for row, point in enumerate(points):
        progress = cumulative[row] / total
        water_width = _water_width(progress, row, len(points))
        bank_width = water_width + 0.26
        # The bank lips sit just below the surface, while the channel centre is
        # genuinely recessed.  This gives the depth-aware foam a narrow bank
        # contact and guarantees a clear-water centre.
        heights = (MEADOW_HEIGHT + 0.003, 0.132, 0.064, 0.132, MEADOW_HEIGHT + 0.003)
        if row == len(points) - 4:
            heights = (0.154, 0.147, 0.118, 0.147, 0.154)
        elif row == len(points) - 3:
            heights = (SOIL_HEIGHT + 0.002, SOIL_HEIGHT - 0.008, SOIL_HEIGHT - 0.022, SOIL_HEIGHT - 0.008, SOIL_HEIGHT + 0.002)
        elif row == len(points) - 2:
            heights = (SOIL_HEIGHT + 0.002, SOIL_HEIGHT - 0.004, SOIL_HEIGHT - 0.014, SOIL_HEIGHT - 0.004, SOIL_HEIGHT + 0.002)
        elif row == len(points) - 1:
            heights = (SOIL_HEIGHT + 0.002, SOIL_HEIGHT - 0.002, SOIL_HEIGHT - 0.008, SOIL_HEIGHT - 0.002, SOIL_HEIGHT + 0.002)
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
    return _new_mesh_object("RiverBed", vertices, faces, smooth=False, uv0=uv)


def _build_water() -> tuple[bpy.types.Object, float]:
    points, normals, cumulative = _path_frames(_river_path())
    total = cumulative[-1]
    columns = 9
    vertices: list[tuple[float, float, float]] = []
    uv0: list[tuple[float, float]] = []
    uv1: list[tuple[float, float]] = []
    widths = [_water_width(cumulative[row] / total, row, len(points)) for row in range(len(points))]
    surface_heights = [_water_surface_height(points, normals, widths, row) for row in range(len(points))]
    for row, point in enumerate(points):
        progress = cumulative[row] / total
        width = widths[row]
        for column in range(columns):
            across = column / (columns - 1)
            signed = across * 2.0 - 1.0
            offset = normals[row] * (width * 0.5 * signed)
            sample = point + offset
            vertices.append(_to_blender((sample.x, sample.y), surface_heights[row]))
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
    land_outline, _ = _land_outline()
    manifest = {
        "id": spec["id"],
        "source": "Free-asset V2: project boundary cage, LowPolyChill river-profile reference, KayKit FREE decorations",
        "license": "Project-authored geometry plus CC0 references and decorations",
        "tile_half_size": TILE_HALF_SIZE,
        "edge_lock_band": EDGE_LOCK_BAND,
        "water_port_width": WATER_PORT_WIDTH,
        "water_height": WATER_HEIGHT,
        "water_meadow_clearance": WATER_OVER_MEADOW_CLEARANCE,
        "water_land_height": SOIL_HEIGHT + 0.003,
        "shoreline_length": round(shoreline_length, 6),
        "land_slope_outset": LAND_SLOPE_OUTSET,
        "land_meadow_clearance": LAND_MEADOW_CLEARANCE,
        "land_meadow_relief_fade": LAND_MEADOW_RELIEF_FADE,
        "planting_boundary_scale": PLANTING_BOUNDARY_SCALE,
        "land_top_tone": LAND_TOP_TONE,
        "land_slope_face_tones": list(LAND_SLOPE_FACE_TONES),
        "land_outline": land_outline,
        "planting_boundary": _planting_boundary(land_outline),
        "water_path": _river_path(),
        "geometry_language": "convex LAND polygon and polyline WATER bands",
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
