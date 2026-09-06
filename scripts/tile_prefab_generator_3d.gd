class_name TilePrefabGenerator3D
extends RefCounted

# Editor/build-time only. A TileSpec3D becomes a normal, independently editable
# 3D .tscn plus frozen meshes/resources; gameplay never invokes this generator.
const EMPTY := 0
const LAND := 1
const WATER := 2
const RIVER := 3
const NORTH := 0
const EAST := 1
const SOUTH := 2
const WEST := 3

const TILE_HALF_SIZE := 2.45
const MEADOW_HEIGHT := 0.140
const SOIL_HEIGHT := 0.152
const RIVERBED_HEIGHT := 0.150
const WATER_HEIGHT := 0.175
const WATER_WIDTH := 0.48
# RIVER stays a water-like, continuous AnimatedSurface but deliberately uses
# its own, wider fixed port contract. A mixed river tile may additionally
# expose narrow WATER branches, which use the standard small-water contract.
const RIVER_WIDTH := 1.08
# The riverbed is an underwater support layer, not a visible grey shoreline.
# Keeping it inset from the visible WATER polygon means the foam edge meets
# MEADOW/LAND directly while the static support mesh remains part of every
# fixed prefab contract.
const RIVERBED_EDGE_INSET := 0.040
const RIVERBED_MIN_WIDTH_RATIO := 0.25
const RIVERBED_END_INSET := 0.040
# The top sheet intentionally clears grass.  Its perimeter is therefore
# closed by opaque water faces that continue beneath the terrain rather than
# leaving a dark air slit visible from an oblique player camera.
const WATER_EDGE_SEAL_WORLD_FLOOR := -0.012
const WATER_EDGE_SEAL_LOCAL_FLOOR := WATER_EDGE_SEAL_WORLD_FLOOR - WATER_HEIGHT
# A channel endpoint on the fixed tile boundary is a port, not a shore. Its
# top sheet meets the matching neighbour directly; only actual banks receive
# foam coordinates and a vertical seal, so a pair of prefabs cannot z-fight.
const PORT_UV2_NON_SHORE_DISTANCE := 1.0
const PORT_BOUNDARY_EPSILON := 0.001
const WATER_SUBDIVISIONS := 3
# 折线拐角斜接的最大放大倍数（90° 转角实际约为 1.414）。
const RIBBON_MITER_LIMIT := 3.0
# 每条水道先保留边中心附近的直线锁定段，再只在地块内部形成少量可读折线。
# 这样同类端口仍能严丝合缝，水路也不会退化成机械的中心直带。
const CHANNEL_PORT_LOCK_LENGTH := 0.70
const CHANNEL_HUB_LOCK_LENGTH := 0.42
const WATER_MEANDER_MIN_SEGMENT_LENGTH := 1.18
const RIVER_MEANDER_MIN_SEGMENT_LENGTH := 1.32
const WATER_MEANDER_MAX_OFFSET := 0.105
const RIVER_MEANDER_MAX_OFFSET := 0.245
# Independent channel legs can approach a common hub with different tangents.
# This small shared polygon prevents their ribbons from leaving a meadow wedge
# while remaining far inside every fixed edge lock.
# Keep the hub strictly inside the fixed half-width of its widest port; it
# fills a tangent mismatch without accidentally presenting a wider RIVER state.
const CENTRAL_HUB_RADIUS_RATIO := 0.47
const CENTRAL_HUB_SEGMENTS := 8
# 开着 Godot 编辑器批量生成时，后台重导入会在 Windows 上短暂锁住刚写入的
# .tres/.tscn，失败点会在不同文件间随机漂移。保存统一走带重试的包装。
const SAVE_RETRY_COUNT := 8
const SAVE_RETRY_DELAY_MS := 150

# Centre feature kinds. A tile normally has no centre feature; a lake tile
# carries a still central pond, and a pure-water tile routes every water port
# through the central hub (its water continues to LAND on neighbouring tiles).
const CENTER_NONE := 0
const CENTER_LAKE := 1
const CENTER_HUB := 2
const CENTER_RIVER := 3
const LAKE_RADIUS := 1.25
const LAKE_SEGMENTS := 48

const TILE_ARTWORK_SCRIPT := preload("res://scripts/tile_artwork_3d.gd")
const TOPOLOGY_SCRIPT := preload("res://scripts/tile_topology_3d.gd")
const PLANTING_MASK_SCRIPT := preload("res://scripts/planting_mask_3d.gd")
const BASE_MATERIAL := preload("res://art/materials/terrain/tile_base.tres")
const MEADOW_MATERIAL := preload("res://art/materials/terrain/meadow.tres")
const SOIL_MATERIAL := preload("res://art/materials/terrain/fertile_soil.tres")
const RIVERBED_MATERIAL := preload("res://art/materials/terrain/river_bank.tres")
const WATER_MATERIAL_TEMPLATE := preload("res://art/materials/water/north_east_land_south_water.tres")

const EDGE_NAMES := {"NORTH": NORTH, "EAST": EAST, "SOUTH": SOUTH, "WEST": WEST}
const EDGE_KINDS := {"EMPTY": EMPTY, "LAND": LAND, "WATER": WATER, "RIVER": RIVER}


static func build_from_spec_file(spec_path: String) -> Dictionary:
	var file := FileAccess.open(spec_path, FileAccess.READ)
	if file == null:
		return _failure("Could not open TileSpec3D: %s" % spec_path)
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not json.data is Dictionary:
		return _failure("TileSpec3D must be a JSON object: %s" % json.get_error_message())
	var normalized := validate_spec(json.data)
	if not normalized["ok"]:
		return normalized
	var spec: Dictionary = normalized["spec"]
	var paths := _paths_for(String(spec["id"]))
	for directory in [
		paths["mesh_directory"], paths["topology_directory"], paths["material_directory"], paths["planting_mask_directory"], paths["scene_directory"],
	]:
		var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if directory_error != OK:
			return _failure("Could not create output directory %s: %s" % [directory, error_string(directory_error)])

	var land_mesh_paths: Array[String] = []
	var planting_mask_paths: Array[String] = []
	for region in spec["regions"]:
		var polygons := _merged_region_polygons(region["edges"])
		if polygons.is_empty():
			return _failure("Land region %s could not produce a surface." % region["id"])
		var land_mesh := _build_land_mesh(polygons)
		if land_mesh.get_surface_count() == 0:
			return _failure("Land region %s produced an empty mesh." % region["id"])
		var land_path: String = paths["land_prefix"] + String(region["id"]) + ".tres"
		var land_save_error := _save_resource(land_mesh, land_path)
		if land_save_error != OK:
			return _failure("Could not save land mesh: %s" % error_string(land_save_error))
		land_mesh_paths.append(land_path)
		for polygon_index in range(polygons.size()):
			var mask := PLANTING_MASK_SCRIPT.new() as PlantingMask3D
			mask.id = StringName("%s_%s_%02d" % [spec["id"], region["id"], polygon_index + 1])
			mask.boundary = polygons[polygon_index]
			mask.edge_clearance = 0.14
			mask.surface_height = SOIL_HEIGHT
			var mask_path: String = "%s%s_%02d.tres" % [paths["planting_mask_prefix"], region["id"], polygon_index + 1]
			var mask_save_error := _save_resource(mask, mask_path)
			if mask_save_error != OK:
				return _failure("Could not save LAND planting mask: %s" % error_string(mask_save_error))
			planting_mask_paths.append(mask_path)

	# Geometry variation belongs to the build artifact, never to a placed tile at
	# runtime. The fixed spec seed makes a card's path reproducible across every
	# rebuild and its 90-degree rotations.
	var water_paths := _water_paths(spec["regions"], spec["routes"], int(spec["seed"]))
	var central_hub_width: float = _central_hub_width(spec["routes"])
	var water_layers := _build_water_layers(water_paths, int(spec["center"]), central_hub_width)
	var riverbed_outlines: Array = water_layers["riverbed_outlines"]
	var water_outlines: Array = water_layers["surface_outlines"]
	var riverbed_mesh: ArrayMesh
	var water_mesh: ArrayMesh
	var shoreline_length := 0.0
	var riverbed_path := ""
	var water_path := ""
	var water_material_path := ""
	if not water_outlines.is_empty():
		riverbed_mesh = _build_water_mesh(riverbed_outlines)
		var water_result := _build_water_mesh_with_length(water_outlines)
		water_mesh = water_result["mesh"]
		shoreline_length = float(water_result["shoreline_length"])
		if riverbed_mesh.get_surface_count() == 0 or water_mesh.get_surface_count() == 0 or shoreline_length <= 0.0:
			return _failure("Water routes produced an empty river or shoreline field.")
		riverbed_path = paths["bank_mesh"]
		water_path = paths["water_mesh"]
		var riverbed_save_error := _save_resource(riverbed_mesh, riverbed_path)
		var water_save_error := _save_resource(water_mesh, water_path)
		if riverbed_save_error != OK or water_save_error != OK:
			return _failure("Could not save generated river meshes (riverbed=%s, water=%s)." % [
				error_string(riverbed_save_error), error_string(water_save_error),
			])
		var water_material := WATER_MATERIAL_TEMPLATE.duplicate(true) as ShaderMaterial
		water_material.set_shader_parameter("foam_shoreline_length", shoreline_length)
		water_material.set_shader_parameter("foam_network_s_offset", 0.0)
		water_material.set_shader_parameter("foam_network_shoreline_length", 0.0)
		water_material.set_shader_parameter("foam_network_phase_offset", 0.0)
		water_material.set_shader_parameter("foam_network_speed_scale", 1.0)
		# A pure RIVER is a broad, quiet water ribbon.  Keep its white shoreline
		# foam, but remove the deep/middle/shallow blue bands from the centre.
		if int(spec["center"]) == CENTER_RIVER:
			water_material.set_shader_parameter("facet_bands_enabled", false)
		water_material_path = paths["water_material"]
		var material_save_error := _save_resource(water_material, water_material_path)
		if material_save_error != OK:
			return _failure("Could not save generated water material: %s" % error_string(material_save_error))

	var topology := _build_topology(spec)
	var topology_path: String = paths["topology"]
	var topology_save_error := _save_resource(topology, topology_path)
	if topology_save_error != OK:
		return _failure("Could not save generated topology: %s" % error_string(topology_save_error))
	var saved_topology := load(topology_path) as Resource
	if saved_topology == null:
		return _failure("Generated topology could not be loaded after saving.")

	var root := _build_scene(spec, saved_topology, land_mesh_paths, riverbed_path, water_path, water_material_path, planting_mask_paths)
	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	if pack_error != OK:
		root.free()
		return _failure("Could not pack generated 3D tile: %s" % error_string(pack_error))
	var scene_path: String = paths["scene"]
	var scene_save_error := _save_resource(packed, scene_path)
	root.free()
	if scene_save_error != OK:
		return _failure("Could not save generated 3D tile scene: %s" % error_string(scene_save_error))

	var saved_scene := load(scene_path) as PackedScene
	var saved_root := saved_scene.instantiate() as Node3D if saved_scene != null else null
	if saved_root == null or not bool(saved_root.call("has_valid_authored_contract")):
		if saved_root != null:
			saved_root.free()
		return _failure("Generated scene did not preserve its fixed 3D prefab contract.")
	saved_root.free()
	return {
		"ok": true,
		"spec": spec,
		"scene_path": scene_path,
		"topology_path": topology_path,
		"shoreline_length": shoreline_length,
	}


static func validate_spec(raw_spec: Dictionary) -> Dictionary:
	var raw_edges: Array = raw_spec.get("edges", [])
	if raw_edges.size() != 4:
		return _failure("edges must contain four values in NORTH/EAST/SOUTH/WEST order.")
	var edges := PackedInt32Array()
	var has_river := false
	for raw_edge in raw_edges:
		var edge_kind := _edge_kind(raw_edge)
		if edge_kind < EMPTY:
			return _failure("edges accepts only EMPTY, LAND, WATER, or RIVER.")
		edges.append(edge_kind)
		has_river = has_river or edge_kind == RIVER

	var id := String(raw_spec.get("id", "")).strip_edges()
	if id.is_empty() or not id.is_valid_identifier():
		return _failure("id must be a non-empty identifier using letters, digits, and underscores.")
	var center_kind := _center_kind(raw_spec.get("center", ""))
	if center_kind < CENTER_NONE:
		return _failure("center must be none, lake, hub, or river.")
	var river_width := float(raw_spec.get("river_width", RIVER_WIDTH))
	if river_width < WATER_WIDTH * 1.75 or river_width > TILE_HALF_SIZE * 0.70:
		return _failure("river_width must keep the RIVER port visibly wider than WATER and inside the tile boundary contract.")
	var is_river_tile := has_river
	if is_river_tile:
		if not has_river or center_kind != CENTER_RIVER:
			return _failure("A river tile needs CENTER_RIVER and at least one RIVER edge.")
		for edge in edges:
			if edge != EMPTY and edge != RIVER and edge != WATER:
				return _failure("A river tile cannot contain LAND edges.")
	elif center_kind == CENTER_RIVER:
		return _failure("CENTER_RIVER is reserved for a RIVER tile.")

	var raw_regions: Array = raw_spec.get("land_regions", [])
	var regions: Array = []
	var region_index_by_id := {}
	var claimed_land := {}
	for region_index in range(raw_regions.size()):
		if not raw_regions[region_index] is Dictionary:
			return _failure("Each land_regions entry must be an object with id and edges.")
		var raw_region: Dictionary = raw_regions[region_index]
		var region_id := String(raw_region.get("id", "")).strip_edges()
		var region_edges: Array = raw_region.get("edges", [])
		if region_id.is_empty() or not region_id.is_valid_identifier() or region_edges.is_empty():
			return _failure("Each land region needs an identifier and one or more LAND edges.")
		if region_index_by_id.has(region_id):
			return _failure("Land region identifiers must be unique.")
		var normalized_edges := PackedInt32Array()
		for raw_edge in region_edges:
			var edge := _edge_index(raw_edge)
			if edge < NORTH or edges[edge] != LAND or claimed_land.has(edge):
				return _failure("Each LAND edge must belong to exactly one land region.")
			claimed_land[edge] = true
			normalized_edges.append(edge)
		region_index_by_id[region_id] = regions.size()
		regions.append({"id": region_id, "edges": normalized_edges})
	for edge in range(4):
		if edges[edge] == LAND and not claimed_land.has(edge):
			return _failure("Every LAND edge must be assigned to a land region.")
	if claimed_land.is_empty() and not raw_regions.is_empty():
		return _failure("A no-land tile cannot define land_regions.")
	if is_river_tile and not regions.is_empty():
		return _failure("A river tile must not define LAND regions or planting masks.")

	var raw_routes: Array = raw_spec.get("water_routes", [])
	var routes: Array = []
	var routed_channels := {}
	for raw_route in raw_routes:
		if not raw_route is Dictionary:
			return _failure("Each water_routes entry must contain a channel edge and an allowed target.")
		var route: Dictionary = raw_route
		var from_edge := _edge_index(route.get("from", ""))
		var via_hub := bool(route.get("via_hub", false))
		if from_edge < NORTH or routed_channels.has(from_edge):
			return _failure("Each visible channel edge needs exactly one route.")
		var source_kind := edges[from_edge]
		if source_kind != WATER and source_kind != RIVER:
			return _failure("A route may only start at WATER or RIVER.")
		var target_id := String(route.get("to_region", ""))
		var route_width := RIVER_WIDTH if source_kind == RIVER else WATER_WIDTH
		if is_river_tile:
			if (source_kind != RIVER and source_kind != WATER) or not via_hub or not target_id.is_empty():
				return _failure("RIVER and WATER routes must run from their fixed port to the central river hub.")
			routed_channels[from_edge] = true
			routes.append({"from": from_edge, "to_region": -1, "via_hub": true, "width": river_width if source_kind == RIVER else WATER_WIDTH})
			continue
		if source_kind != WATER:
			return _failure("Only a CENTER_RIVER tile may use RIVER routes.")
		if via_hub and target_id.is_empty() and regions.is_empty():
			# Pure-water and lake-outlet routes reach the central hub.  They
			# continue to LAND on a neighbour or merge into the central lake.
			if center_kind != CENTER_HUB and center_kind != CENTER_LAKE:
				return _failure("A no-LAND WATER route needs a central hub or lake.")
			routed_channels[from_edge] = true
			routes.append({"from": from_edge, "to_region": -1, "via_hub": true, "width": route_width})
			continue
		if not region_index_by_id.has(target_id):
			return _failure("Every water route must target an existing LAND region.")
		routed_channels[from_edge] = true
		routes.append({
			"from": from_edge,
			"to_region": int(region_index_by_id[target_id]),
			"via_hub": via_hub,
			"width": route_width,
		})
	for edge in range(4):
		var kind := edges[edge]
		if (kind == WATER or kind == RIVER) and not routed_channels.has(edge):
			return _failure("Every visible channel port must reach a LAND region, lake, or central hub.")
	if not is_river_tile and not routed_channels.is_empty() and regions.is_empty() and center_kind != CENTER_HUB and center_kind != CENTER_LAKE:
		return _failure("Water cannot exist without a target LAND region, lake, or central hub.")
	return {
		"ok": true,
		"spec": {
			"id": id,
			"display_name": String(raw_spec.get("display_name", id)),
			"seed": int(raw_spec.get("seed", 0)),
			"center": center_kind,
			"edges": edges,
			"regions": regions,
			"routes": routes,
			"river_width": river_width,
		},
	}


static func _build_topology(spec: Dictionary) -> Resource:
	var topology := TOPOLOGY_SCRIPT.new() as Resource
	topology.set("id", StringName(String(spec["id"])))
	topology.set("edge_markers", spec["edges"])
	var region_ids := PackedStringArray()
	var region_masks := PackedInt32Array()
	for region in spec["regions"]:
		region_ids.append(StringName(String(region["id"])))
		var mask := 0
		for edge in region["edges"]:
			mask |= 1 << edge
		region_masks.append(mask)
	topology.set("land_region_ids", region_ids)
	topology.set("land_region_edge_masks", region_masks)
	var land_ending := PackedInt32Array()
	var via_hub := PackedInt32Array()
	for route in spec["routes"]:
		if route["via_hub"]:
			via_hub.append(route["from"])
		else:
			land_ending.append(route["from"])
	topology.set("water_edges_ending_at_land", land_ending)
	topology.set("water_edges_via_central_hub", via_hub)
	var land_count := 0
	for edge in spec["edges"]:
		if edge == LAND:
			land_count += 1
	var double_land_topology := 0
	if land_count == 2:
		double_land_topology = 1 if spec["regions"].size() == 1 else 2
	topology.set("double_land_topology", double_land_topology)
	topology.set("visual_geometry_is_verified", true)
	return topology


static func _build_scene(
	spec: Dictionary,
	topology: Resource,
	land_mesh_paths: Array[String],
	riverbed_path: String,
	water_path: String,
	water_material_path: String,
	planting_mask_paths: Array[String],
) -> Node3D:
	var root := TILE_ARTWORK_SCRIPT.new() as Node3D
	root.name = _pascal_case(String(spec["id"]))
	root.set("edge_markers", spec["edges"])
	root.set("topology", topology)
	root.set("require_topology", true)
	root.set("require_canonical_topology", true)
	root.set("preview_growth_state", 1)
	var planting_masks: Array[PlantingMask3D] = []
	for mask_path in planting_mask_paths:
		var mask := load(mask_path) as PlantingMask3D
		if mask != null:
			planting_masks.append(mask)
	root.set("planting_masks", planting_masks)

	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(4.9, 0.3, 4.9)
	base_mesh.material = BASE_MATERIAL
	var base := MeshInstance3D.new()
	base.name = "Base"
	base.position = Vector3(0.0, -0.15, 0.0)
	base.mesh = base_mesh
	_add(root, base, root)

	var meadow_mesh := PlaneMesh.new()
	meadow_mesh.size = Vector2(4.9, 4.9)
	meadow_mesh.material = MEADOW_MATERIAL
	var meadow := MeshInstance3D.new()
	meadow.name = "Meadow"
	meadow.position = Vector3(0.0, MEADOW_HEIGHT, 0.0)
	meadow.mesh = meadow_mesh
	_add(root, meadow, root)

	var land_root := Node3D.new()
	land_root.name = "LandSoil"
	_add(root, land_root, root)
	for region_index in range(spec["regions"].size()):
		var region: Dictionary = spec["regions"][region_index]
		var land := MeshInstance3D.new()
		land.name = _pascal_case(String(region["id"]))
		land.mesh = load(land_mesh_paths[region_index]) as ArrayMesh
		land.material_override = SOIL_MATERIAL
		_add(land_root, land, root)

	var water_root := Node3D.new()
	water_root.name = "Water"
	_add(root, water_root, root)
	if riverbed_path.is_empty():
		var empty_bank := Node3D.new()
		empty_bank.name = "RiverBed"
		_add(water_root, empty_bank, root)
		var empty_surface := Node3D.new()
		empty_surface.name = "AnimatedSurface"
		_add(water_root, empty_surface, root)
	else:
		var riverbed := MeshInstance3D.new()
		riverbed.name = "RiverBed"
		riverbed.position.y = RIVERBED_HEIGHT
		riverbed.mesh = load(riverbed_path) as ArrayMesh
		riverbed.material_override = RIVERBED_MATERIAL
		_add(water_root, riverbed, root)
		var surface := MeshInstance3D.new()
		surface.name = "AnimatedSurface"
		surface.position.y = WATER_HEIGHT
		surface.mesh = load(water_path) as ArrayMesh
		surface.material_override = load(water_material_path) as ShaderMaterial
		surface.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_add(water_root, surface, root)

	var decorations := Node3D.new()
	decorations.name = "Decorations"
	_add(root, decorations, root)
	var growing_plants := Node3D.new()
	growing_plants.name = "GrowingPlants"
	_add(root, growing_plants, root)
	var withered_plants := Node3D.new()
	withered_plants.name = "WitheredPlants"
	_add(root, withered_plants, root)
	return root


static func _build_land_mesh(polygons: Array) -> ArrayMesh:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for polygon in polygons:
		var indices := Geometry2D.triangulate_polygon(polygon)
		for index in range(0, indices.size(), 3):
			for point in [polygon[indices[index]], polygon[indices[index + 1]], polygon[indices[index + 2]]]:
				tool.set_normal(Vector3.UP)
				tool.set_uv(Vector2((point.x + TILE_HALF_SIZE) / (TILE_HALF_SIZE * 2.0), (point.y + TILE_HALF_SIZE) / (TILE_HALF_SIZE * 2.0)))
				tool.add_vertex(Vector3(point.x, SOIL_HEIGHT, point.y))
	return tool.commit()


static func _build_water_layers(water_paths: Array, center_kind: int, central_hub_width := 0.0) -> Dictionary:
	# Every generated tile gets the same two-layer water contract: a fully
	# submerged RiverBed support and the visible AnimatedSurface. The support is
	# inset rather than expanded, so it cannot become a separate grey bank in
	# top-down play or at a 90-degree seam.
	var surface_parts: Array = []
	var riverbed_parts: Array = []
	if center_kind == CENTER_LAKE:
		surface_parts.append(_circle_outline(LAKE_RADIUS, LAKE_SEGMENTS))
		riverbed_parts.append(_circle_outline(LAKE_RADIUS - RIVERBED_EDGE_INSET, LAKE_SEGMENTS))
	elif central_hub_width > 0.0:
		var hub_radius := central_hub_width * CENTRAL_HUB_RADIUS_RATIO
		surface_parts.append(_circle_outline(hub_radius, CENTRAL_HUB_SEGMENTS))
		riverbed_parts.append(_circle_outline(maxf(hub_radius - RIVERBED_EDGE_INSET, hub_radius * RIVERBED_MIN_WIDTH_RATIO), CENTRAL_HUB_SEGMENTS))
	surface_parts.append_array(_merged_ribbon_outlines(water_paths))
	riverbed_parts.append_array(_merged_ribbon_outlines(_inset_water_path_ends(water_paths, RIVERBED_END_INSET)))
	return {
		"riverbed_outlines": _merge_polygons(riverbed_parts),
		"surface_outlines": _merge_polygons(surface_parts),
	}


static func _central_hub_width(routes: Array) -> float:
	var route_count := 0
	var maximum_width := 0.0
	for route in routes:
		if not bool(route.get("via_hub", false)):
			continue
		route_count += 1
		maximum_width = maxf(maximum_width, float(route.get("width", WATER_WIDTH)))
	# A one-port route already has one continuous ribbon through its hub. The
	# shared patch is only needed when multiple independently bent ribbons meet.
	return maximum_width if route_count >= 2 else 0.0


static func _inset_water_path_ends(paths: Array, inset: float) -> Array:
	var result: Array = []
	for source_path in paths:
		var source_points := PackedVector2Array()
		var source_width := WATER_WIDTH
		if source_path is Dictionary:
			source_points = (source_path as Dictionary).get("points", PackedVector2Array())
			source_width = float((source_path as Dictionary).get("width", WATER_WIDTH))
		else:
			source_points = source_path
		var path: PackedVector2Array = source_points.duplicate()
		if path.size() >= 2:
			var start_segment := path[1] - path[0]
			if start_segment.length() > 0.00001:
				path[0] = path[0].move_toward(path[1], minf(inset, start_segment.length() * 0.45))
			var end_segment := path[path.size() - 2] - path[path.size() - 1]
			if end_segment.length() > 0.00001:
				path[path.size() - 1] = path[path.size() - 1].move_toward(path[path.size() - 2], minf(inset, end_segment.length() * 0.45))
		result.append({"points": path, "width": _riverbed_width(source_width)})
	return result


static func _riverbed_width(surface_width: float) -> float:
	return maxf(surface_width - RIVERBED_EDGE_INSET * 2.0, surface_width * RIVERBED_MIN_WIDTH_RATIO)


static func _build_water_mesh_with_length(outlines: Array, include_edge_seal := true) -> Dictionary:
	var shoreline_length := _total_outline_length(outlines)
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for outline in outlines:
		var indices := Geometry2D.triangulate_polygon(outline)
		for index in range(0, indices.size(), 3):
			_append_subdivided_triangle(
				tool,
				outline[indices[index]], outline[indices[index + 1]], outline[indices[index + 2]],
				outlines, shoreline_length, WATER_SUBDIVISIONS,
			)
	if include_edge_seal:
		_append_water_edge_seals(tool, outlines, shoreline_length)
	return {"mesh": tool.commit(), "shoreline_length": shoreline_length}


static func _build_water_mesh(outlines: Array) -> ArrayMesh:
	# RiverBed is a top-only underwater support.  Only AnimatedSurface receives
	# the opaque perimeter seal that bridges its intentional clearance above
	# meadow and soil.
	return _build_water_mesh_with_length(outlines, false)["mesh"]


static func _append_water_edge_seals(tool: SurfaceTool, outlines: Array, shoreline_length: float) -> void:
	var accumulated_length := 0.0
	var safe_length := maxf(shoreline_length, 0.0001)
	for source_outline in outlines:
		var outline: PackedVector2Array = source_outline
		if outline.size() < 3:
			continue
		var orientation := _outline_signed_area(outline)
		for index in range(outline.size()):
			var start: Vector2 = outline[index]
			var end: Vector2 = outline[(index + 1) % outline.size()]
			var edge := end - start
			var edge_length := edge.length()
			if edge_length <= 0.00001:
				continue
			var is_port := _is_port_boundary_segment(start, end)
			# A matching neighbour supplies the continuous top sheet at a port.
			# Do not place two coincident vertical walls at that locked seam: they
			# would z-fight into a dark line even though the water planes meet.
			if is_port:
				continue
			var outward := Vector2(edge.y, -edge.x).normalized()
			if orientation < 0.0:
				outward = -outward
			var side_normal := Vector3(outward.x, 0.0, outward.y)
			var start_shore := Vector2(0.0, accumulated_length / safe_length)
			var end_shore := Vector2(0.0, (accumulated_length + edge_length) / safe_length)
			_append_water_edge_seal_quad(tool, start, end, side_normal, start_shore, end_shore)
			accumulated_length += edge_length


static func _outline_signed_area(outline: PackedVector2Array) -> float:
	var twice_area := 0.0
	for index in range(outline.size()):
		var start: Vector2 = outline[index]
		var end: Vector2 = outline[(index + 1) % outline.size()]
		twice_area += start.x * end.y - end.x * start.y
	return twice_area * 0.5


static func _append_water_edge_seal_quad(
	tool: SurfaceTool,
	start: Vector2,
	end: Vector2,
	side_normal: Vector3,
	start_shore: Vector2,
	end_shore: Vector2,
) -> void:
	var start_uv := Vector2((start.x + TILE_HALF_SIZE) / (TILE_HALF_SIZE * 2.0), (start.y + TILE_HALF_SIZE) / (TILE_HALF_SIZE * 2.0))
	var end_uv := Vector2((end.x + TILE_HALF_SIZE) / (TILE_HALF_SIZE * 2.0), (end.y + TILE_HALF_SIZE) / (TILE_HALF_SIZE * 2.0))
	for vertex_data in [
		[Vector3(start.x, 0.0, start.y), start_uv, start_shore],
		[Vector3(start.x, WATER_EDGE_SEAL_LOCAL_FLOOR, start.y), start_uv, start_shore],
		[Vector3(end.x, WATER_EDGE_SEAL_LOCAL_FLOOR, end.y), end_uv, end_shore],
		[Vector3(start.x, 0.0, start.y), start_uv, start_shore],
		[Vector3(end.x, WATER_EDGE_SEAL_LOCAL_FLOOR, end.y), end_uv, end_shore],
		[Vector3(end.x, 0.0, end.y), end_uv, end_shore],
	]:
		tool.set_normal(side_normal)
		tool.set_uv(vertex_data[1] as Vector2)
		tool.set_uv2(vertex_data[2] as Vector2)
		tool.add_vertex(vertex_data[0] as Vector3)


static func _append_subdivided_triangle(tool: SurfaceTool, a: Vector2, b: Vector2, c: Vector2, outlines: Array, shoreline_length: float, subdivisions: int) -> void:
	if subdivisions > 0:
		var ab := (a + b) * 0.5
		var bc := (b + c) * 0.5
		var ca := (c + a) * 0.5
		var next := subdivisions - 1
		_append_subdivided_triangle(tool, a, ab, ca, outlines, shoreline_length, next)
		_append_subdivided_triangle(tool, ab, b, bc, outlines, shoreline_length, next)
		_append_subdivided_triangle(tool, ca, bc, c, outlines, shoreline_length, next)
		_append_subdivided_triangle(tool, ab, bc, ca, outlines, shoreline_length, next)
		return
	for point in [a, b, c]:
		tool.set_normal(Vector3.UP)
		tool.set_uv(Vector2((point.x + TILE_HALF_SIZE) / (TILE_HALF_SIZE * 2.0), (point.y + TILE_HALF_SIZE) / (TILE_HALF_SIZE * 2.0)))
		tool.set_uv2(_shoreline_sample(point, outlines, shoreline_length))
		tool.add_vertex(Vector3(point.x, 0.0, point.y))


static func _shoreline_sample(point: Vector2, outlines: Array, shoreline_length: float) -> Vector2:
	var best_distance_squared := INF
	var best_arc_length := 0.0
	var accumulated_length := 0.0
	for outline in outlines:
		for index in range(outline.size()):
			var start: Vector2 = outline[index]
			var end: Vector2 = outline[(index + 1) % outline.size()]
			var segment := end - start
			var segment_length := segment.length()
			if is_zero_approx(segment_length) or _is_port_boundary_segment(start, end):
				continue
			var closest := Geometry2D.get_closest_point_to_segment(point, start, end)
			var distance_squared := point.distance_squared_to(closest)
			if distance_squared < best_distance_squared:
				best_distance_squared = distance_squared
				best_arc_length = accumulated_length + clampf((point - start).dot(segment / segment_length), 0.0, segment_length)
			accumulated_length += segment_length
	if best_distance_squared == INF:
		return Vector2(PORT_UV2_NON_SHORE_DISTANCE, 0.0)
	return Vector2(sqrt(best_distance_squared), fposmod(best_arc_length / maxf(shoreline_length, 0.001), 1.0))


static func _total_outline_length(outlines: Array) -> float:
	var total := 0.0
	for outline in outlines:
		for index in range(outline.size()):
			var start: Vector2 = outline[index]
			var end: Vector2 = outline[(index + 1) % outline.size()]
			if not _is_port_boundary_segment(start, end):
				total += start.distance_to(end)
	return total


static func _is_port_boundary_segment(start: Vector2, end: Vector2) -> bool:
	# All generated channel endpoints are locked to one tile edge.  Excluding
	# only these collinear boundary segments leaves actual banks (including a
	# lake rim) in the d/s field while preventing a false shoreline at a seam.
	return (
		(absf(start.x - TILE_HALF_SIZE) <= PORT_BOUNDARY_EPSILON and absf(end.x - TILE_HALF_SIZE) <= PORT_BOUNDARY_EPSILON)
		or (absf(start.x + TILE_HALF_SIZE) <= PORT_BOUNDARY_EPSILON and absf(end.x + TILE_HALF_SIZE) <= PORT_BOUNDARY_EPSILON)
		or (absf(start.y - TILE_HALF_SIZE) <= PORT_BOUNDARY_EPSILON and absf(end.y - TILE_HALF_SIZE) <= PORT_BOUNDARY_EPSILON)
		or (absf(start.y + TILE_HALF_SIZE) <= PORT_BOUNDARY_EPSILON and absf(end.y + TILE_HALF_SIZE) <= PORT_BOUNDARY_EPSILON)
	)


static func _merged_region_polygons(edges: PackedInt32Array) -> Array:
	var outlines: Array = []
	for edge in edges:
		outlines.append(_edge_soil_outline(edge))
	if edges.size() > 1:
		outlines.append(_region_connector(edges))
	return _merge_polygons(outlines)


static func _edge_soil_outline(edge: int) -> PackedVector2Array:
	var north := PackedVector2Array([
		Vector2(-TILE_HALF_SIZE, -TILE_HALF_SIZE), Vector2(TILE_HALF_SIZE, -TILE_HALF_SIZE),
		Vector2(TILE_HALF_SIZE, -1.72), Vector2(1.70, -1.46), Vector2(1.10, -1.16),
		Vector2(0.48, -0.96), Vector2(0.0, -0.90), Vector2(-0.48, -0.96),
		Vector2(-1.10, -1.16), Vector2(-1.70, -1.46), Vector2(-TILE_HALF_SIZE, -1.72),
	])
	return _rotate_points(north, edge)


static func _region_connector(edges: PackedInt32Array) -> PackedVector2Array:
	if edges.size() >= 3:
		return PackedVector2Array([Vector2(-1.18, -1.18), Vector2(1.18, -1.18), Vector2(1.18, 1.18), Vector2(-1.18, 1.18)])
	if (edges[0] - edges[1]) % 2 == 0:
		if edges.has(NORTH):
			return PackedVector2Array([Vector2(-0.52, -1.12), Vector2(0.52, -1.12), Vector2(0.52, 1.12), Vector2(-0.52, 1.12)])
		return PackedVector2Array([Vector2(-1.12, -0.52), Vector2(1.12, -0.52), Vector2(1.12, 0.52), Vector2(-1.12, 0.52)])
	var corner_direction := (_edge_direction(edges[0]) + _edge_direction(edges[1])).normalized() * 0.76
	return PackedVector2Array([
		corner_direction + Vector2(-0.82, -0.82), corner_direction + Vector2(0.82, -0.82),
		corner_direction + Vector2(0.82, 0.82), corner_direction + Vector2(-0.82, 0.82),
	])


static func _water_paths(regions: Array, routes: Array, tile_seed := 0) -> Array:
	var result: Array = []
	var hub_targets := {}
	for route_index in range(routes.size()):
		var route: Dictionary = routes[route_index]
		var from_edge := int(route["from"])
		var inlet := _edge_direction(from_edge) * TILE_HALF_SIZE
		var target_index := int(route["to_region"])
		var width := float(route.get("width", WATER_WIDTH))
		if route["via_hub"]:
			result.append({
				"points": _meandered_path(PackedVector2Array([inlet, Vector2.ZERO]), width, tile_seed, route_index),
				"width": width,
			})
			if target_index >= 0:
				hub_targets[target_index] = width
		else:
			var contact := _region_contact(regions[target_index]["edges"], from_edge)
			# 地块构成规范 §4.1：拐弯或分叉的水流必须先到中央汇点、再折向目标，
			# 不得贴边即转弯。单水口同样适用——水陆分居两条垂直边时（如西水北土），
			# 直接连成一条斜线会让拓扑无法读出，必须拆成"边中心 → 中央 → 土地"折线。
			result.append({
				"points": _meandered_path(_polyline_through_center(inlet, contact), width, tile_seed, route_index),
				"width": width,
			})
	var sorted_hub_targets: Array = hub_targets.keys()
	sorted_hub_targets.sort()
	for target_index in range(sorted_hub_targets.size()):
		var region_index := int(sorted_hub_targets[target_index])
		result.append({
			"points": _meandered_path(
				PackedVector2Array([Vector2.ZERO, _region_contact(regions[region_index]["edges"], -1)]),
				float(hub_targets[region_index]),
				tile_seed,
				routes.size() + target_index,
			),
			"width": float(hub_targets[region_index]),
		})
	return result


# The legacy north/east-land/south-water art used a locked south port followed
# by an authored Bezier. Procedural cards keep the same boundary discipline,
# but express the bend as two deterministic low-poly interior points: this
# follows the card grammar without introducing a smooth curve or runtime mesh
# mutation.
static func _meandered_path(anchors: PackedVector2Array, width: float, tile_seed: int, channel_index: int) -> PackedVector2Array:
	if anchors.size() < 2:
		return anchors
	var result := PackedVector2Array([anchors[0]])
	for segment_index in range(anchors.size() - 1):
		var segment := _meandered_segment(
			anchors[segment_index], anchors[segment_index + 1], width,
			tile_seed, channel_index, segment_index,
		)
		for point_index in range(1, segment.size()):
			result.append(segment[point_index])
	return result


static func _meandered_segment(
	start: Vector2,
	end: Vector2,
	width: float,
	tile_seed: int,
	channel_index: int,
	segment_index: int,
) -> PackedVector2Array:
	var delta := end - start
	var length := delta.length()
	var minimum_length := RIVER_MEANDER_MIN_SEGMENT_LENGTH if width > WATER_WIDTH * 1.5 else WATER_MEANDER_MIN_SEGMENT_LENGTH
	if length < minimum_length:
		return PackedVector2Array([start, end])
	var direction := delta / length
	var start_lock := _channel_lock_length(start)
	var end_lock := _channel_lock_length(end)
	var free_length := length - start_lock - end_lock
	if free_length < 0.48:
		return PackedVector2Array([start, end])

	var maximum_offset := RIVER_MEANDER_MAX_OFFSET if width > WATER_WIDTH * 1.5 else WATER_MEANDER_MAX_OFFSET
	maximum_offset = minf(maximum_offset, minf(width * 0.28, free_length * 0.18))
	if maximum_offset < 0.025:
		return PackedVector2Array([start, end])
	var rng := RandomNumberGenerator.new()
	# The salts make each port/segment distinct while keeping an unchanged spec
	# byte-for-byte reproducible after a rebuild.
	rng.seed = int(tile_seed) + channel_index * 1_000_003 + segment_index * 97_409
	var side := -1.0 if rng.randf() < 0.5 else 1.0
	var offset := maximum_offset * rng.randf_range(0.64, 0.92)
	var normal := Vector2(-direction.y, direction.x) * side
	var first_progress := start_lock + free_length * rng.randf_range(0.32, 0.43)
	var second_progress := start_lock + free_length * rng.randf_range(0.62, 0.73)
	var points := PackedVector2Array([start])
	if start_lock > 0.001:
		points.append(start + direction * start_lock)
	# Keeping both points on the same side creates a shallow natural C-bend;
	# the return to the fixed next anchor remains a visible low-poly segment.
	points.append(start + direction * first_progress + normal * offset)
	points.append(start + direction * second_progress + normal * offset * rng.randf_range(0.78, 0.96))
	if end_lock > 0.001:
		points.append(end - direction * end_lock)
	points.append(end)
	return points


static func _is_tile_boundary_point(point: Vector2) -> bool:
	return absf(absf(point.x) - TILE_HALF_SIZE) <= PORT_BOUNDARY_EPSILON \
		or absf(absf(point.y) - TILE_HALF_SIZE) <= PORT_BOUNDARY_EPSILON


static func _channel_lock_length(point: Vector2) -> float:
	if _is_tile_boundary_point(point):
		return CHANNEL_PORT_LOCK_LENGTH
	# Separate routes meet at the same central hub. Giving every final leg the
	# same radial tangent prevents a concave grass slit where two independently
	# bent ribbons otherwise meet.
	if point.length_squared() <= PORT_BOUNDARY_EPSILON * PORT_BOUNDARY_EPSILON:
		return CHANNEL_HUB_LOCK_LENGTH
	return 0.0


# 把"边中心 → 土地接触点"的直线升级为"边中心 → 中央汇点 → 土地接触点"的折线。
# 当中央汇点与端点重合、落在线段之外，或三点已经共线时，插入它既不改变形状也
# 读不出转折，此时退回原直线，避免产生零长度段让 ribbon 切线归一化出现 NaN。
static func _polyline_through_center(start: Vector2, end: Vector2) -> PackedVector2Array:
	if _is_degenerate_center_insertion(start, end):
		return PackedVector2Array([start, end])
	return PackedVector2Array([start, Vector2.ZERO, end])


static func _is_degenerate_center_insertion(start: Vector2, end: Vector2) -> bool:
	var center := Vector2.ZERO
	if start.distance_to(center) < 0.05 or end.distance_to(center) < 0.05:
		return true
	var segment := end - start
	var segment_length := segment.length()
	if segment_length < 0.05:
		return true
	var direction := segment / segment_length
	var projection := (center - start).dot(direction)
	# 汇点不落在两端点之间时，插入它只会让水道折回去。
	if projection < 0.05 or projection > segment_length - 0.05:
		return true
	# 三点近似共线时，插入汇点不改变折线形状，属于无效转折。
	return (center - start - direction * projection).length() < 0.05


# 水从 from_edge 的边中点沿中心方向进入，返回其与土地区域多边形内缘的
# 第一个交点。这才是"水路在最先接触土地处结束"的精确几何，而不是方向向量的近似。
# from_edge < 0 表示水路起点在中心 (0,0)（hub 分叉后流向土地），此时沿
# 中心到土地形心的方向求交。
static func _region_contact(edges: PackedInt32Array, from_edge: int) -> Vector2:
	if edges.size() == 1:
		# 单边：内缘中心直接取该边方向内缩（与 _edge_soil_outline 一致）。
		return _edge_direction(edges[0]) * 0.90
	var polygons := _merged_region_polygons(edges)
	var inlet: Vector2
	var toward: Vector2
	if from_edge >= NORTH and from_edge <= WEST:
		inlet = _edge_direction(from_edge) * TILE_HALF_SIZE
		toward = -_edge_direction(from_edge)
	else:
		inlet = Vector2.ZERO
		var direction := Vector2.ZERO
		for edge in edges:
			direction += _edge_direction(edge)
		toward = Vector2.ZERO if direction.is_zero_approx() else direction.normalized()
		if toward.is_zero_approx():
			return Vector2.ZERO
	var ray_end := inlet + toward * (TILE_HALF_SIZE * 2.0)
	var best_distance := INF
	var best_point := Vector2.ZERO
	for polygon in polygons:
		for index in range(polygon.size()):
			var a: Vector2 = polygon[index]
			var b: Vector2 = polygon[(index + 1) % polygon.size()]
			var hit: Variant = Geometry2D.segment_intersects_segment(inlet, ray_end, a, b)
			if hit != null:
				var d := (Vector2(hit) - inlet).length()
				# 跳过射线起点恰落在多边形外缘上的退化交点（距离≈0），
				# 取真正进入土地内部的内缘交点。
				if d > 0.01 and d < best_distance:
					best_distance = d
					best_point = Vector2(hit)
	if best_distance < INF:
		return best_point
	# 兜底：未命中时退回中心（纯水/异常配置）。
	return Vector2.ZERO


static func _merged_ribbon_outlines(paths: Array) -> Array:
	var outlines: Array = []
	for source_path in paths:
		var path := PackedVector2Array()
		var width := WATER_WIDTH
		if source_path is Dictionary:
			path = (source_path as Dictionary).get("points", PackedVector2Array())
			width = float((source_path as Dictionary).get("width", WATER_WIDTH))
		else:
			path = source_path
		var outline := _ribbon_outline(path, width)
		if not outline.is_empty():
			outlines.append(outline)
	return _merge_polygons(outlines)


static func _ribbon_outline(path: PackedVector2Array, width: float) -> PackedVector2Array:
	if path.size() < 2 or _open_path_length(path) < 0.001:
		# 端点重合的退化路径定义不出切线，直接不生成水面。
		return PackedVector2Array()
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for index in range(path.size()):
		var normal := _ribbon_offset(path, index, width)
		left.append(path[index] + normal)
		right.append(path[index] - normal)
	var outline := PackedVector2Array()
	for point in left:
		outline.append(point)
	for index in range(right.size() - 1, -1, -1):
		outline.append(right[index])
	return outline


# 折线拐角用斜接（miter）：内部点的偏移沿两条相邻边法线的角平分线，并按
# 1/cos(θ/2) 放大。相比中心差分法线，这让 90° 转折处的水道宽度不塌陷，外角
# 形成清晰尖角，符合规范"水路使用清晰的折线关系"的要求。放大倍数设上限，
# 防止未来出现极锐折角时拉出过长尖刺。
static func _ribbon_offset(path: PackedVector2Array, index: int, width: float) -> Vector2:
	var incoming := path[index] - path[max(index - 1, 0)]
	var outgoing := path[min(index + 1, path.size() - 1)] - path[index]
	var tangent := (incoming + outgoing).normalized()
	if index <= 0 or index >= path.size() - 1:
		return Vector2(-tangent.y, tangent.x) * width * 0.5
	var incoming_normal := Vector2(-incoming.normalized().y, incoming.normalized().x)
	var outgoing_normal := Vector2(-outgoing.normalized().y, outgoing.normalized().x)
	var bisector := incoming_normal + outgoing_normal
	if bisector.length_squared() < 0.000001:
		# 180° 折返让角平分线退化，退回中心差分法线。
		return Vector2(-tangent.y, tangent.x) * width * 0.5
	bisector = bisector.normalized()
	var miter_scale := 1.0 / maxf(bisector.dot(incoming_normal), 0.0001)
	return bisector * width * 0.5 * minf(miter_scale, RIBBON_MITER_LIMIT)


static func _open_path_length(path: PackedVector2Array) -> float:
	var total := 0.0
	for index in range(path.size() - 1):
		total += path[index].distance_to(path[index + 1])
	return total


static func _circle_outline(radius: float, segments: int) -> PackedVector2Array:
	var outline := PackedVector2Array()
	for index in range(segments):
		var angle := TAU * float(index) / float(segments)
		outline.append(Vector2(cos(angle), sin(angle)) * radius)
	return outline


static func _merge_polygons(outlines: Array) -> Array:
	var merged: Array = []
	for source_outline in outlines:
		var candidate: PackedVector2Array = source_outline
		var keep_merging := true
		while keep_merging:
			keep_merging = false
			for index in range(merged.size() - 1, -1, -1):
				var union: Array = Geometry2D.merge_polygons(merged[index], candidate)
				if union.size() == 1:
					candidate = union[0]
					merged.remove_at(index)
					keep_merging = true
					break
		merged.append(candidate)
	return merged


static func _point_in_any_polygon(point: Vector2, polygons: Array) -> bool:
	for polygon in polygons:
		if Geometry2D.is_point_in_polygon(point, polygon):
			return true
	return false


static func _edge_direction(edge: int) -> Vector2:
	match edge:
		NORTH:
			return Vector2.UP
		EAST:
			return Vector2.RIGHT
		SOUTH:
			return Vector2.DOWN
		_:
			return Vector2.LEFT


static func _rotate_points(points: PackedVector2Array, quarter_turns: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	for point in points:
		result.append(point.rotated(float(quarter_turns) * PI * 0.5))
	return result


static func _edge_kind(value: Variant) -> int:
	if value is int and value >= EMPTY and value <= RIVER:
		return value
	return int(EDGE_KINDS.get(String(value).to_upper(), -1))


static func _center_kind(value: Variant) -> int:
	if value is int:
		return value if value >= CENTER_NONE and value <= CENTER_RIVER else -1
	match String(value).strip_edges().to_lower():
		"", "none":
			return CENTER_NONE
		"lake":
			return CENTER_LAKE
		"hub":
			return CENTER_HUB
		"river":
			return CENTER_RIVER
	return -1


static func _edge_index(value: Variant) -> int:
	if value is int and value >= NORTH and value <= WEST:
		return value
	return int(EDGE_NAMES.get(String(value).to_upper(), -1))


static func _paths_for(id: String) -> Dictionary:
	var base := "procedural_%s" % id
	return {
		"mesh_directory": "res://art/generated/procedural_tiles",
		"topology_directory": "res://art/topologies/generated",
		"material_directory": "res://art/materials/water/generated",
		"planting_mask_directory": "res://art/planting_masks/generated",
		"scene_directory": "res://scenes/tiles_3d/generated",
		"land_prefix": "res://art/generated/procedural_tiles/%s_land_" % base,
		"planting_mask_prefix": "res://art/planting_masks/generated/%s_land_" % base,
		"bank_mesh": "res://art/generated/procedural_tiles/%s_river_bank.tres" % base,
		"water_mesh": "res://art/generated/procedural_tiles/%s_water.tres" % base,
		"topology": "res://art/topologies/generated/%s.tres" % base,
		"water_material": "res://art/materials/water/generated/%s.tres" % base,
		"scene": "res://scenes/tiles_3d/generated/%s.tscn" % base,
	}


static func _add(parent: Node, child: Node, scene_owner: Node) -> void:
	parent.add_child(child)
	child.owner = scene_owner


static func _pascal_case(value: String) -> String:
	var result := ""
	for part in value.split("_", false):
		result += part.capitalize()
	return result


# 批量生成会连续写入十几个资源；开着编辑器时后台重导入会短暂锁住目标文件，
# 单次 ResourceSaver.save 可能以 "Can't open" 失败。这里做有限次重试，让锁释放。
static func _save_resource(resource: Resource, path: String) -> int:
	var last_error := OK
	for attempt in range(SAVE_RETRY_COUNT):
		last_error = ResourceSaver.save(resource, path)
		if last_error == OK:
			return OK
		if attempt < SAVE_RETRY_COUNT - 1:
			OS.delay_msec(SAVE_RETRY_DELAY_MS)
	return last_error


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
