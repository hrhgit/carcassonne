class_name TilePrefabGenerator3D
extends RefCounted

# Editor/build-time only. A TileSpec3D becomes a normal, independently editable
# 3D .tscn plus frozen meshes/resources; gameplay never invokes this generator.
const EMPTY := 0
const LAND := 1
const WATER := 2
const NORTH := 0
const EAST := 1
const SOUTH := 2
const WEST := 3

const TILE_HALF_SIZE := 2.45
const SOIL_HEIGHT := 0.152
const BANK_HEIGHT := 0.150
const WATER_HEIGHT := 0.175
const BANK_WIDTH := 0.72
const WATER_WIDTH := 0.48
const WATER_SUBDIVISIONS := 3

# Centre feature kinds. A tile normally has no centre feature; a lake tile
# carries a still central pond, and a pure-water tile routes every water port
# through the central hub (its water continues to LAND on neighbouring tiles).
const CENTER_NONE := 0
const CENTER_LAKE := 1
const CENTER_HUB := 2
const LAKE_RADIUS := 1.25
const LAKE_BANK_WIDTH := 0.34
const LAKE_SEGMENTS := 48

const TILE_ARTWORK_SCRIPT := preload("res://scripts/tile_artwork_3d.gd")
const TOPOLOGY_SCRIPT := preload("res://scripts/tile_topology_3d.gd")
const BASE_MATERIAL := preload("res://art/materials/terrain/tile_base.tres")
const MEADOW_MATERIAL := preload("res://art/materials/terrain/meadow.tres")
const SOIL_MATERIAL := preload("res://art/materials/terrain/fertile_soil.tres")
const BANK_MATERIAL := preload("res://art/materials/terrain/river_bank.tres")
const WATER_MATERIAL_TEMPLATE := preload("res://art/materials/water/north_east_land_south_water.tres")
const SAPLING_SCENE := preload("res://scenes/plants/soil_sapling.tscn")
const FLOWER_SCENE := preload("res://scenes/plants/soil_flower.tscn")

const EDGE_NAMES := {"NORTH": NORTH, "EAST": EAST, "SOUTH": SOUTH, "WEST": WEST}
const EDGE_KINDS := {"EMPTY": EMPTY, "LAND": LAND, "WATER": WATER}


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
		paths["mesh_directory"], paths["topology_directory"], paths["material_directory"], paths["scene_directory"],
	]:
		var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if directory_error != OK:
			return _failure("Could not create output directory %s: %s" % [directory, error_string(directory_error)])

	var land_mesh_paths: Array[String] = []
	var land_polygons: Array = []
	for region in spec["regions"]:
		var polygons := _merged_region_polygons(region["edges"])
		if polygons.is_empty():
			return _failure("Land region %s could not produce a surface." % region["id"])
		var land_mesh := _build_land_mesh(polygons)
		if land_mesh.get_surface_count() == 0:
			return _failure("Land region %s produced an empty mesh." % region["id"])
		var land_path: String = paths["land_prefix"] + String(region["id"]) + ".tres"
		var land_save_error := ResourceSaver.save(land_mesh, land_path)
		if land_save_error != OK:
			return _failure("Could not save land mesh: %s" % error_string(land_save_error))
		land_mesh_paths.append(land_path)
		land_polygons.append(polygons)

	var water_paths := _water_paths(spec["regions"], spec["routes"])
	var bank_outlines: Array
	var water_outlines: Array
	if int(spec["center"]) == CENTER_LAKE:
		# A still central pond: the bank is a full disk under a slightly smaller
		# water disk, so the visible bank is the ring between the two radii.
		bank_outlines = [_circle_outline(LAKE_RADIUS + LAKE_BANK_WIDTH, LAKE_SEGMENTS)]
		water_outlines = [_circle_outline(LAKE_RADIUS, LAKE_SEGMENTS)]
	else:
		bank_outlines = _merged_ribbon_outlines(water_paths, BANK_WIDTH)
		water_outlines = _merged_ribbon_outlines(water_paths, WATER_WIDTH)
	var bank_mesh: ArrayMesh
	var water_mesh: ArrayMesh
	var shoreline_length := 0.0
	var bank_path := ""
	var water_path := ""
	var water_material_path := ""
	if not water_outlines.is_empty():
		bank_mesh = _build_water_mesh(bank_outlines, BANK_WIDTH)
		var water_result := _build_water_mesh_with_length(water_outlines, WATER_WIDTH)
		water_mesh = water_result["mesh"]
		shoreline_length = float(water_result["shoreline_length"])
		if bank_mesh.get_surface_count() == 0 or water_mesh.get_surface_count() == 0 or shoreline_length <= 0.0:
			return _failure("Water routes produced an empty river or shoreline field.")
		bank_path = paths["bank_mesh"]
		water_path = paths["water_mesh"]
		var bank_save_error := ResourceSaver.save(bank_mesh, bank_path)
		var water_save_error := ResourceSaver.save(water_mesh, water_path)
		if bank_save_error != OK or water_save_error != OK:
			return _failure("Could not save generated river meshes.")
		var water_material := WATER_MATERIAL_TEMPLATE.duplicate(true) as ShaderMaterial
		water_material.set_shader_parameter("foam_shoreline_length", shoreline_length)
		water_material_path = paths["water_material"]
		var material_save_error := ResourceSaver.save(water_material, water_material_path)
		if material_save_error != OK:
			return _failure("Could not save generated water material: %s" % error_string(material_save_error))

	var topology := _build_topology(spec)
	var topology_path: String = paths["topology"]
	var topology_save_error := ResourceSaver.save(topology, topology_path)
	if topology_save_error != OK:
		return _failure("Could not save generated topology: %s" % error_string(topology_save_error))
	var saved_topology := load(topology_path) as Resource
	if saved_topology == null:
		return _failure("Generated topology could not be loaded after saving.")

	var root := _build_scene(spec, saved_topology, land_mesh_paths, bank_path, water_path, water_material_path, land_polygons)
	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	if pack_error != OK:
		root.free()
		return _failure("Could not pack generated 3D tile: %s" % error_string(pack_error))
	var scene_path: String = paths["scene"]
	var scene_save_error := ResourceSaver.save(packed, scene_path)
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
	for raw_edge in raw_edges:
		var edge_kind := _edge_kind(raw_edge)
		if edge_kind < EMPTY:
			return _failure("edges accepts only EMPTY, LAND, or WATER.")
		edges.append(edge_kind)

	var id := String(raw_spec.get("id", "")).strip_edges()
	if id.is_empty() or not id.is_valid_identifier():
		return _failure("id must be a non-empty identifier using letters, digits, and underscores.")
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

	var center_kind := _center_kind(raw_spec.get("center", ""))
	if center_kind < CENTER_NONE:
		return _failure("center must be none, lake, or hub.")

	var raw_routes: Array = raw_spec.get("water_routes", [])
	var routes: Array = []
	var routed_water := {}
	for raw_route in raw_routes:
		if not raw_route is Dictionary:
			return _failure("Each water_routes entry must contain from and, for non-hub routes, to_region.")
		var route: Dictionary = raw_route
		var from_edge := _edge_index(route.get("from", ""))
		var via_hub := bool(route.get("via_hub", false))
		if from_edge < NORTH or edges[from_edge] != WATER or routed_water.has(from_edge):
			return _failure("Each WATER edge needs exactly one valid water route.")
		var target_id := String(route.get("to_region", ""))
		if via_hub and target_id == "" and regions.is_empty():
			# Pure-water hub route: the channel reaches the central hub and
			# continues to LAND on a neighbouring tile.
			routed_water[from_edge] = true
			routes.append({"from": from_edge, "to_region": -1, "via_hub": true})
			continue
		if not region_index_by_id.has(target_id):
			return _failure("Every water route must target an existing LAND region.")
		routed_water[from_edge] = true
		routes.append({
			"from": from_edge,
			"to_region": int(region_index_by_id[target_id]),
			"via_hub": via_hub,
		})
	for edge in range(4):
		if edges[edge] == WATER and not routed_water.has(edge):
			return _failure("Every WATER edge must reach at least one LAND region or the central hub.")
	if not routed_water.is_empty() and regions.is_empty() and center_kind != CENTER_HUB:
		return _failure("Water cannot exist without a target LAND region or a central hub.")
	if center_kind == CENTER_LAKE and (not routed_water.is_empty() or not regions.is_empty()):
		return _failure("A lake tile cannot define LAND regions or WATER edges.")
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
	bank_path: String,
	water_path: String,
	water_material_path: String,
	land_polygons: Array,
) -> Node3D:
	var root := TILE_ARTWORK_SCRIPT.new() as Node3D
	root.name = _pascal_case(String(spec["id"]))
	root.set("edge_markers", spec["edges"])
	root.set("topology", topology)
	root.set("require_topology", true)
	root.set("require_canonical_topology", true)
	root.set("preview_growth_state", 1)

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
	meadow.position = Vector3(0.0, 0.14, 0.0)
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
	if bank_path.is_empty():
		var empty_bank := Node3D.new()
		empty_bank.name = "RiverBed"
		_add(water_root, empty_bank, root)
		var empty_surface := Node3D.new()
		empty_surface.name = "AnimatedSurface"
		_add(water_root, empty_surface, root)
	else:
		var bank := MeshInstance3D.new()
		bank.name = "RiverBed"
		bank.position.y = BANK_HEIGHT
		bank.mesh = load(bank_path) as ArrayMesh
		bank.material_override = BANK_MATERIAL
		_add(water_root, bank, root)
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
	_add_baked_plants(growing_plants, withered_plants, land_polygons, int(spec["seed"]), root)
	return root


static func _add_baked_plants(growing_root: Node3D, withered_root: Node3D, regions: Array, seed: int, scene_owner: Node) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var plant_index := 0
	for region_index in range(regions.size()):
		var positions := _plant_positions(regions[region_index], rng, 5)
		for position in positions:
			var plant_scene: PackedScene = FLOWER_SCENE if plant_index % 3 == 0 else SAPLING_SCENE
			var yaw := rng.randf_range(0.0, TAU)
			var size := rng.randf_range(0.82, 1.12)
			for state_index in range(2):
				var plant := plant_scene.instantiate() as Node3D
				plant.name = "Region%02dPlant%02d" % [region_index + 1, plant_index + 1]
				plant.position = Vector3(position.x, SOIL_HEIGHT, position.y)
				plant.rotation.y = yaw
				plant.scale = Vector3.ONE * size
				plant.set("growth_state", state_index)
				_add(growing_root if state_index == 0 else withered_root, plant, scene_owner)
			plant_index += 1


static func _plant_positions(polygons: Array, rng: RandomNumberGenerator, desired_count: int) -> PackedVector2Array:
	var result := PackedVector2Array()
	var attempts := 0
	while result.size() < desired_count and attempts < desired_count * 200:
		attempts += 1
		var candidate := Vector2(rng.randf_range(-2.15, 2.15), rng.randf_range(-2.15, 2.15))
		if not _point_in_any_polygon(candidate, polygons):
			continue
		var too_close := false
		for existing in result:
			if existing.distance_to(candidate) < 0.48:
				too_close = true
				break
		if not too_close:
			result.append(candidate)
	return result


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


static func _build_water_mesh_with_length(outlines: Array, width: float) -> Dictionary:
	var shoreline_length := _total_outline_length(outlines)
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for outline in outlines:
		var indices := Geometry2D.triangulate_polygon(outline)
		for index in range(0, indices.size(), 3):
			_append_subdivided_triangle(
				tool,
				outline[indices[index]], outline[indices[index + 1]], outline[indices[index + 2]],
				outlines, shoreline_length, width, WATER_SUBDIVISIONS,
			)
	return {"mesh": tool.commit(), "shoreline_length": shoreline_length}


static func _build_water_mesh(outlines: Array, width: float) -> ArrayMesh:
	return _build_water_mesh_with_length(outlines, width)["mesh"]


static func _append_subdivided_triangle(tool: SurfaceTool, a: Vector2, b: Vector2, c: Vector2, outlines: Array, shoreline_length: float, width: float, subdivisions: int) -> void:
	if subdivisions > 0:
		var ab := (a + b) * 0.5
		var bc := (b + c) * 0.5
		var ca := (c + a) * 0.5
		var next := subdivisions - 1
		_append_subdivided_triangle(tool, a, ab, ca, outlines, shoreline_length, width, next)
		_append_subdivided_triangle(tool, ab, b, bc, outlines, shoreline_length, width, next)
		_append_subdivided_triangle(tool, ca, bc, c, outlines, shoreline_length, width, next)
		_append_subdivided_triangle(tool, ab, bc, ca, outlines, shoreline_length, width, next)
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
			if is_zero_approx(segment_length):
				continue
			var closest := Geometry2D.get_closest_point_to_segment(point, start, end)
			var distance_squared := point.distance_squared_to(closest)
			if distance_squared < best_distance_squared:
				best_distance_squared = distance_squared
				best_arc_length = accumulated_length + clampf((point - start).dot(segment / segment_length), 0.0, segment_length)
			accumulated_length += segment_length
	return Vector2(sqrt(best_distance_squared), fposmod(best_arc_length / maxf(shoreline_length, 0.001), 1.0))


static func _total_outline_length(outlines: Array) -> float:
	var total := 0.0
	for outline in outlines:
		for index in range(outline.size()):
			total += outline[index].distance_to(outline[(index + 1) % outline.size()])
	return total


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


static func _water_paths(regions: Array, routes: Array) -> Array:
	var result: Array = []
	var hub_targets := {}
	for route in routes:
		var inlet := _edge_direction(route["from"]) * TILE_HALF_SIZE
		var target_index := int(route["to_region"])
		if route["via_hub"]:
			result.append(PackedVector2Array([inlet, Vector2.ZERO]))
			if target_index >= 0:
				hub_targets[target_index] = true
		else:
			var contact := _region_contact(regions[target_index]["edges"])
			result.append(PackedVector2Array([inlet, contact]))
	for region_index in hub_targets:
		result.append(PackedVector2Array([Vector2.ZERO, _region_contact(regions[region_index]["edges"])]))
	return result


static func _region_contact(edges: PackedInt32Array) -> Vector2:
	if edges.size() == 1:
		return _edge_direction(edges[0]) * 0.90
	var direction := Vector2.ZERO
	for edge in edges:
		direction += _edge_direction(edge)
	return Vector2.ZERO if direction.is_zero_approx() else direction.normalized() * 0.65


static func _merged_ribbon_outlines(paths: Array, width: float) -> Array:
	var outlines: Array = []
	for path in paths:
		outlines.append(_ribbon_outline(path, width))
	return _merge_polygons(outlines)


static func _ribbon_outline(path: PackedVector2Array, width: float) -> PackedVector2Array:
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	for index in range(path.size()):
		var tangent := (path[min(index + 1, path.size() - 1)] - path[max(index - 1, 0)]).normalized()
		var normal := Vector2(-tangent.y, tangent.x) * width * 0.5
		left.append(path[index] + normal)
		right.append(path[index] - normal)
	var outline := PackedVector2Array()
	for point in left:
		outline.append(point)
	for index in range(right.size() - 1, -1, -1):
		outline.append(right[index])
	return outline


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
	if value is int and value >= EMPTY and value <= WATER:
		return value
	return int(EDGE_KINDS.get(String(value).to_upper(), -1))


static func _center_kind(value: Variant) -> int:
	if value is int:
		return value if value >= CENTER_NONE and value <= CENTER_HUB else -1
	match String(value).strip_edges().to_lower():
		"", "none":
			return CENTER_NONE
		"lake":
			return CENTER_LAKE
		"hub":
			return CENTER_HUB
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
		"scene_directory": "res://scenes/tiles_3d/generated",
		"land_prefix": "res://art/generated/procedural_tiles/%s_land_" % base,
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


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}
