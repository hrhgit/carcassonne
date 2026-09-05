extends SceneTree

const OUTPUT_DIRECTORY := "res://art/generated"
const NORTH_LAND_OUTPUT := OUTPUT_DIRECTORY + "/river_cross_land_north.tres"
const SOUTH_LAND_OUTPUT := OUTPUT_DIRECTORY + "/river_cross_land_south.tres"

const SEGMENTS := 18
const HALF_WIDTH := 2.45
const NORTH_BACK_Z := -2.45
const SOUTH_BACK_Z := 2.45

# Circular arc parameters (chord W=4.9, depth H=0.95, corner base 0.16)
const ARC_H := 0.95
const CORNER_BASE := 0.16
const CIRCLE_R := (HALF_WIDTH * HALF_WIDTH + ARC_H * ARC_H) / (2.0 * ARC_H)
const CIRCLE_Z0 := CIRCLE_R - ARC_H

# Preserve the existing wide edge-connected arc footprint, while keeping the
# growing substrate only a few millimetres above the meadow surface.
const SURFACE_BANDS := [0.0, 0.34, 0.70, 1.0]
const MEADOW_SURFACE_Y := 0.14
const Y_FAR_EDGE := 0.156
const Y_NEAR_RIVER := 0.151
const HEIGHT_VARIATIONS := [0.004, -0.003, 0.002, -0.001]

const WARM_EARTH_FACETS := [
	Color(0.42, 0.32, 0.21, 1.0),
	Color(0.36, 0.29, 0.19, 1.0),
	Color(0.39, 0.31, 0.20, 1.0),
]
const COOL_RIVER_EARTH_FACETS := [
	Color(0.31, 0.27, 0.19, 1.0),
	Color(0.28, 0.25, 0.17, 1.0),
	Color(0.33, 0.28, 0.19, 1.0),
]
const MOSS_EARTH_FACET := Color(0.29, 0.34, 0.21, 1.0)


func _init() -> void:
	call_deferred("_build_resources")


func _arc_depth(x: float) -> float:
	var clamped_x: float = clampf(x, -HALF_WIDTH, HALF_WIDTH)
	var term: float = maxf(0.0, CIRCLE_R * CIRCLE_R - clamped_x * clamped_x)
	var circular_depth: float = maxf(0.0, sqrt(term) - CIRCLE_Z0)
	# Add a small corner base so the land follows the full tile footprint after
	# the decorative edge frame has been removed.
	return circular_depth + CORNER_BASE


func _build_resources() -> void:
	var absolute_directory := ProjectSettings.globalize_path(OUTPUT_DIRECTORY)
	var directory_error := DirAccess.make_dir_recursive_absolute(absolute_directory)
	if directory_error != OK:
		push_error("Unable to create generated mesh directory: %s" % error_string(directory_error))
		quit(1)
		return

	var north_land := _build_land_mesh(true)
	var south_land := _build_land_mesh(false)

	var err1 := ResourceSaver.save(north_land, NORTH_LAND_OUTPUT)
	var err2 := ResourceSaver.save(south_land, SOUTH_LAND_OUTPUT)

	if err1 != OK or err2 != OK:
		push_error("Failed to save generated land meshes!")
		quit(1)
		return

	print("RIVER_CROSS_LAND_MESHES_BUILT: successfully generated low fertile-soil arc meshes.")
	quit()


func _build_land_mesh(is_north: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var rings: Array = []
	for band_index in range(SURFACE_BANDS.size()):
		var band: float = SURFACE_BANDS[band_index]
		var ring: Array[Vector3] = []
		for i in range(SEGMENTS + 1):
			var u: float = float(i) / float(SEGMENTS)
			var x: float = -HALF_WIDTH + 2.0 * HALF_WIDTH * u
			var d: float = _arc_depth(x)
			var z: float = NORTH_BACK_Z + d * band if is_north else SOUTH_BACK_Z - d * band
			ring.append(Vector3(x, _surface_height(i, band_index), z))
		rings.append(ring)

	for band_index in range(SURFACE_BANDS.size() - 1):
		var ring_a: Array[Vector3] = rings[band_index]
		var ring_b: Array[Vector3] = rings[band_index + 1]
		for i in range(SEGMENTS):
			var facet: Color = _facet_color(is_north, i, band_index)
			if is_north:
				_add_colored_quad(st, ring_a[i], ring_a[i + 1], ring_b[i + 1], ring_b[i], facet)
			else:
				_add_colored_quad(st, ring_b[i], ring_b[i + 1], ring_a[i + 1], ring_a[i], facet)

	st.generate_normals()
	return st.commit()


func _surface_height(segment_index: int, band_index: int) -> float:
	# Both contact rings share the meadow plane exactly. This closes the soil/grass
	# boundary at the tile edge and at the river-facing arc without adding a side
	# wall or a decorative filler strip.
	if band_index == 0 or band_index == SURFACE_BANDS.size() - 1:
		return MEADOW_SURFACE_Y
	var baseline := lerpf(Y_FAR_EDGE, Y_NEAR_RIVER, SURFACE_BANDS[band_index])
	var group_index := (segment_index / 3 + band_index * 2) % HEIGHT_VARIATIONS.size()
	return baseline + HEIGHT_VARIATIONS[group_index]


func _facet_color(is_north: bool, segment_index: int, band_index: int) -> Color:
	# River-side bands are darker and a touch cooler. Grouped values create broad
	# readable facets instead of repetitive texture noise. Moss appears only on
	# occasional facets rather than becoming a band around the whole zone.
	var palette: Array = COOL_RIVER_EARTH_FACETS if band_index >= 2 else WARM_EARTH_FACETS
	var offset := 1 if is_north else 2
	var facet_index := segment_index / 3 * 2 + band_index * 3 + offset
	if facet_index % 7 == 0:
		return MOSS_EARTH_FACET
	return palette[facet_index % palette.size()]


func _add_colored_quad(st: SurfaceTool, v0: Vector3, v1: Vector3, v2: Vector3, v3: Vector3, color: Color) -> void:
	st.set_color(color)
	st.add_vertex(v0)
	st.set_color(color)
	st.add_vertex(v1)
	st.set_color(color)
	st.add_vertex(v2)
	st.set_color(color)
	st.add_vertex(v0)
	st.set_color(color)
	st.add_vertex(v2)
	st.set_color(color)
	st.add_vertex(v3)
