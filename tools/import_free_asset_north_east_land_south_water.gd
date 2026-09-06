extends SceneTree

# Imports the Blender-authored free-asset V2 into the fixed-prefab
# contract.  The GLB supplies geometry only; topology, LAND mask, shared
# terrain materials and water behavior remain Godot-owned resources.
const SOURCE_SCENE_PATH := "res://art/models/tiles_blender/north_east_land_south_water_free_v2.glb"
const MANIFEST_PATH := "res://art/models/tiles_blender/north_east_land_south_water_free_v2.manifest.json"
const OUTPUT_DIRECTORY := "res://art/generated/free_asset_v2"
const MATERIAL_DIRECTORY := "res://art/materials/water/free_asset_v2"
const TERRAIN_MATERIAL_DIRECTORY := "res://art/materials/terrain/free_asset_v2"
const MASK_DIRECTORY := "res://art/planting_masks/free_asset_v2"
const SCENE_DIRECTORY := "res://scenes/tiles_3d/free_asset_v2"
const SCENE_OUTPUT := SCENE_DIRECTORY + "/north_east_land_south_water_free_v2.tscn"

const OUTPUTS := {
	"Base": OUTPUT_DIRECTORY + "/north_east_land_south_water_free_v2_base.tres",
	"Meadow": OUTPUT_DIRECTORY + "/north_east_land_south_water_free_v2_meadow.tres",
	"NorthEastField": OUTPUT_DIRECTORY + "/north_east_land_south_water_free_v2_land.tres",
	"RiverBed": OUTPUT_DIRECTORY + "/north_east_land_south_water_free_v2_river_bed.tres",
	"AnimatedSurface": OUTPUT_DIRECTORY + "/north_east_land_south_water_free_v2_water.tres",
}
const WATER_MATERIAL_OUTPUT := MATERIAL_DIRECTORY + "/north_east_land_south_water_free_v2.tres"
const PLANTING_MASK_OUTPUT := MASK_DIRECTORY + "/north_east_land_south_water_free_v2_field.tres"
const BASE_MATERIAL_OUTPUT := TERRAIN_MATERIAL_DIRECTORY + "/tile_base_free_v2.tres"
const MEADOW_MATERIAL_OUTPUT := TERRAIN_MATERIAL_DIRECTORY + "/meadow_free_v2.tres"
const SOIL_MATERIAL_OUTPUT := TERRAIN_MATERIAL_DIRECTORY + "/fertile_soil_free_v2.tres"
const BANK_MATERIAL_OUTPUT := TERRAIN_MATERIAL_DIRECTORY + "/river_bank_free_v2.tres"
const GRASS_MATERIAL_OUTPUT := TERRAIN_MATERIAL_DIRECTORY + "/kaykit_grass_free_v2.tres"
const ROCK_MATERIAL_OUTPUT := TERRAIN_MATERIAL_DIRECTORY + "/kaykit_rock_free_v2.tres"

const TILE_ARTWORK_SCRIPT := preload("res://scripts/tile_artwork_3d.gd")
const TOPOLOGY := preload("res://art/topologies/generated/procedural_north_east_land_south_water.tres")
const BASE_MATERIAL := preload("res://art/materials/terrain/tile_base.tres")
const MEADOW_MATERIAL := preload("res://art/materials/terrain/meadow.tres")
const SOIL_MATERIAL := preload("res://art/materials/terrain/fertile_soil.tres")
const BANK_MATERIAL := preload("res://art/materials/terrain/river_bank.tres")
const WATER_MATERIAL_TEMPLATE := preload("res://art/materials/water/north_east_land_south_water.tres")
const V2_SOIL_SHADER := preload("res://shaders/free_asset_soil_v2.gdshader")
const GRASS_A := preload("res://art/models/kaykit/forest_free/Grass_1_A_Color1.gltf")
const GRASS_B := preload("res://art/models/kaykit/forest_free/Grass_1_B_Color1.gltf")
const GRASS_C := preload("res://art/models/kaykit/forest_free/Grass_2_A_Color1.gltf")
const ROCK_A := preload("res://art/models/kaykit/forest_free/Rock_1_A_Color1.gltf")
const ROCK_B := preload("res://art/models/kaykit/forest_free/Rock_2_A_Color1.gltf")
const ROCK_C := preload("res://art/models/kaykit/forest_free/Rock_3_A_Color1.gltf")

const TILE_HALF_SIZE := 2.45
const WATER_PORT_HALF_WIDTH := 0.24
const POSITION_EPSILON := 0.0002
const LAND_SURFACE_HEIGHT := 0.190
const RIVERBED_EDGE_INSET := 0.040
const RIVERBED_END_INSET := 0.040
const RIVERBED_MIN_SUBMERGENCE := 0.006
const WATER_EDGE_SEAL_FLOOR := -0.012


func _init() -> void:
	call_deferred("_import")


func _import() -> void:
	for directory in [OUTPUT_DIRECTORY, MATERIAL_DIRECTORY, TERRAIN_MATERIAL_DIRECTORY, MASK_DIRECTORY, SCENE_DIRECTORY]:
		var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
		if error != OK:
			_fail("Could not create %s: %s" % [directory, error_string(error)])
			return

	var manifest := _load_manifest()
	if manifest.is_empty():
		return
	var packed_source := load(SOURCE_SCENE_PATH) as PackedScene
	if packed_source == null:
		_fail("Blender GLB was not imported as a PackedScene.")
		return
	var source_root := packed_source.instantiate()
	var meshes := _collect_meshes(source_root)
	for required_name in OUTPUTS:
		if not meshes.has(required_name):
			source_root.free()
			_fail("Blender GLB is missing mesh object %s; found %s" % [required_name, meshes.keys()])
			return

	if not _validate_edge_contract(meshes):
		source_root.free()
		return
	for object_name in OUTPUTS:
		var saved_mesh := _deindex_water_mesh(meshes[object_name] as ArrayMesh) if object_name == "AnimatedSurface" else (meshes[object_name] as ArrayMesh).duplicate(true) as ArrayMesh
		var save_error := ResourceSaver.save(saved_mesh, OUTPUTS[object_name])
		if save_error != OK:
			source_root.free()
			_fail("Could not save %s: %s" % [OUTPUTS[object_name], error_string(save_error)])
			return
	var pilot_mask := PlantingMask3D.new()
	pilot_mask.id = &"north_east_land_south_water_free_v2_field"
	pilot_mask.surface_height = 0.190
	var planting_boundary := PackedVector2Array()
	for value in manifest.get("planting_boundary", []):
		if value is Array and value.size() == 2:
			planting_boundary.append(Vector2(float(value[0]), float(value[1])))
	if planting_boundary.size() < 3:
		source_root.free()
		_fail("Blender manifest did not provide a baked convex LAND planting boundary.")
		return
	pilot_mask.boundary = planting_boundary
	for point in pilot_mask.boundary:
		if not _is_covered(meshes["NorthEastField"] as ArrayMesh, point):
			source_root.free()
			_fail("Existing LAND mask no longer fits the naturalized soil at %s." % point)
			return
	var mask_error := ResourceSaver.save(pilot_mask, PLANTING_MASK_OUTPUT)
	if mask_error != OK:
		source_root.free()
		_fail("Could not save pilot LAND mask: %s" % error_string(mask_error))
		return

	if not _save_terrain_materials():
		source_root.free()
		return

	var water_material := WATER_MATERIAL_TEMPLATE.duplicate(true) as ShaderMaterial
	water_material.set_shader_parameter("foam_shoreline_length", float(manifest["shoreline_length"]))
	water_material.set_shader_parameter("foam_network_s_offset", 0.0)
	water_material.set_shader_parameter("foam_network_shoreline_length", 0.0)
	water_material.set_shader_parameter("foam_network_phase_offset", 0.0)
	water_material.set_shader_parameter("foam_network_speed_scale", 1.0)
	var material_error := ResourceSaver.save(water_material, WATER_MATERIAL_OUTPUT)
	if material_error != OK:
		source_root.free()
		_fail("Could not save pilot water material: %s" % error_string(material_error))
		return

	var scene_error := _save_scene()
	source_root.free()
	if scene_error != OK:
		_fail("Could not save pilot scene: %s" % error_string(scene_error))
		return
	print("FREE_ASSET_TILE_IMPORT_PASS: V2 meshes, KayKit decorations, canonical anchors, UV2 water data, material instances, and static prefab were saved.")
	quit()


func _load_manifest() -> Dictionary:
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		_fail("Could not open Blender manifest.")
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or float(parsed.get("water_port_width", 0.0)) != WATER_PORT_HALF_WIDTH * 2.0 or float(parsed.get("shoreline_length", 0.0)) <= 0.0 or float(parsed.get("water_edge_seal_floor", 0.0)) > WATER_EDGE_SEAL_FLOOR + POSITION_EPSILON or float(parsed.get("riverbed_edge_inset", 0.0)) < RIVERBED_EDGE_INSET - POSITION_EPSILON or float(parsed.get("riverbed_end_inset", 0.0)) < RIVERBED_END_INSET - POSITION_EPSILON or float(parsed.get("riverbed_min_submergence", 0.0)) < RIVERBED_MIN_SUBMERGENCE - POSITION_EPSILON or float(parsed.get("land_slope_outset", 0.0)) < 0.20 or not parsed.has("planting_boundary") or parsed.get("geometry_language", "") != "convex LAND polygon and polyline WATER bands":
		_fail("Blender manifest lost the canonical water width or shoreline length.")
		return {}
	return parsed


func _collect_meshes(root: Node) -> Dictionary:
	var result := {}
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance := child as MeshInstance3D
		if mesh_instance.mesh is ArrayMesh:
			result[mesh_instance.name] = mesh_instance.mesh as ArrayMesh
			print("BLENDER_IMPORT_MESH: %s aabb=%s" % [mesh_instance.name, mesh_instance.mesh.get_aabb()])
	return result


func _deindex_water_mesh(source: ArrayMesh) -> ArrayMesh:
	# Blender/glTF stores indexed vertices with per-loop UV sets. Re-emitting the
	# triangles through SurfaceTool gives Godot the same explicit per-vertex UV2
	# layout used by the existing water baker and avoids driver-side UV2 loss.
	var arrays := source.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var triangle_indices := indices if not indices.is_empty() else PackedInt32Array(range(vertices.size()))
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	for source_index in triangle_indices:
		if not normals.is_empty():
			tool.set_normal(normals[source_index])
		tool.set_uv(uv[source_index])
		tool.set_uv2(uv2[source_index])
		tool.add_vertex(vertices[source_index])
	return tool.commit()


func _save_terrain_materials() -> bool:
	var base := BASE_MATERIAL.duplicate(true) as StandardMaterial3D
	base.resource_name = "Free V2 Tile Base"
	base.albedo_color = Color(0.22, 0.17, 0.12, 1.0)
	var meadow := MEADOW_MATERIAL.duplicate(true) as ShaderMaterial
	meadow.resource_name = "Free V2 Meadow"
	meadow.set_shader_parameter("grass_color", Color(0.20, 0.31, 0.145, 1.0))
	meadow.set_shader_parameter("color_variation", 0.026)
	var soil := ShaderMaterial.new()
	soil.resource_name = "Free V2 Fertile Soil"
	soil.shader = V2_SOIL_SHADER
	soil.set_shader_parameter("dark_earth", Color(0.275, 0.168, 0.098, 1.0))
	soil.set_shader_parameter("middle_earth", Color(0.285, 0.175, 0.103, 1.0))
	soil.set_shader_parameter("light_earth", Color(0.295, 0.182, 0.108, 1.0))
	soil.set_shader_parameter("face_contrast", 0.015)
	soil.set_shader_parameter("slope_shadow", 0.10)
	var bank := BANK_MATERIAL.duplicate(true) as StandardMaterial3D
	bank.resource_name = "Free V2 Submerged Riverbed"
	bank.albedo_color = Color(0.105, 0.175, 0.075, 1.0)
	var grass := StandardMaterial3D.new()
	grass.resource_name = "Muted KayKit Grass"
	grass.albedo_color = Color(0.12, 0.22, 0.065, 1.0)
	grass.roughness = 0.96
	var rock := StandardMaterial3D.new()
	rock.resource_name = "Muted KayKit Rock"
	rock.albedo_color = Color(0.33, 0.355, 0.32, 1.0)
	rock.roughness = 0.91
	for pair in [
		[base, BASE_MATERIAL_OUTPUT],
		[meadow, MEADOW_MATERIAL_OUTPUT],
		[soil, SOIL_MATERIAL_OUTPUT],
		[bank, BANK_MATERIAL_OUTPUT],
		[grass, GRASS_MATERIAL_OUTPUT],
		[rock, ROCK_MATERIAL_OUTPUT],
	]:
		var error := ResourceSaver.save(pair[0] as Resource, pair[1] as String)
		if error != OK:
			_fail("Could not save V2 terrain material %s: %s" % [pair[1], error_string(error)])
			return false
	return true


func _validate_edge_contract(meshes: Dictionary) -> bool:
	var meadow := meshes["Meadow"] as ArrayMesh
	var land := meshes["NorthEastField"] as ArrayMesh
	var riverbed := meshes["RiverBed"] as ArrayMesh
	var water := meshes["AnimatedSurface"] as ArrayMesh
	var meadow_vertices: PackedVector3Array = meadow.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var land_arrays := land.surface_get_arrays(0)
	var land_vertices: PackedVector3Array = land_arrays[Mesh.ARRAY_VERTEX]
	var land_uv: PackedVector2Array = land_arrays[Mesh.ARRAY_TEX_UV]
	var land_indices: PackedInt32Array = land_arrays[Mesh.ARRAY_INDEX] if land_arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var land_triangles := land_indices if not land_indices.is_empty() else PackedInt32Array(range(land_vertices.size()))
	var water_arrays := water.surface_get_arrays(0)
	var water_vertices: PackedVector3Array = water_arrays[Mesh.ARRAY_VERTEX]
	var water_uv2: PackedVector2Array = water_arrays[Mesh.ARRAY_TEX_UV2]
	if water_uv2.size() != water_vertices.size() or water_uv2.is_empty():
		_fail("Blender water mesh did not preserve its second UV channel for d/s.")
		return false
	if land_uv.size() != land_vertices.size() or land_uv.is_empty():
		_fail("Blender LAND did not preserve its palette UV channel.")
		return false
	var top_tones := {}
	var slope_tones := {}
	for index in range(0, land_triangles.size(), 3):
		var a_index := land_triangles[index]
		var b_index := land_triangles[index + 1]
		var c_index := land_triangles[index + 2]
		var a := land_vertices[a_index]
		var b := land_vertices[b_index]
		var c := land_vertices[c_index]
		var normal := (b - a).cross(c - a)
		if normal.length_squared() <= POSITION_EPSILON * POSITION_EPSILON:
			continue
		var is_top := (
			absf(a.y - 0.190) <= POSITION_EPSILON
			and absf(b.y - 0.190) <= POSITION_EPSILON
			and absf(c.y - 0.190) <= POSITION_EPSILON
		)
		for vertex_index in [a_index, b_index, c_index]:
			if is_top:
				if absf(normal.normalized().y) < 0.98:
					_fail("Blender LAND top triangle is not a flat horizontal surface.")
					return false
				if absf(land_vertices[vertex_index].y - 0.190) > POSITION_EPSILON:
					_fail("Blender LAND top triangle left the fixed planting height.")
					return false
				top_tones[int(roundf(land_uv[vertex_index].x * 100.0))] = true
			else:
				slope_tones[int(roundf(land_uv[vertex_index].x * 100.0))] = true
	if top_tones.size() != 1:
		_fail("Blender LAND top must use one uniform palette tone: %s" % [top_tones.keys()])
		return false
	if slope_tones.size() < 4:
		_fail("Blender LAND outer slope lost its faceted palette variation: %s" % [slope_tones.keys()])
		return false
	var water_reaches_land := false
	for vertex in water_vertices:
		if vertex.y > 0.190 and vertex.z < 0.90:
			water_reaches_land = true
			break
	if not water_reaches_land:
		_fail("The polygonal WATER tongue does not visibly rise onto the LAND contact.")
		return false
	if not _water_has_broad_land_mouth(water, land):
		_fail("The WATER tongue no longer makes a broad, direct contact on the flat LAND surface.")
		return false
	for vertex in meadow_vertices:
		if is_equal_approx(absf(vertex.x), TILE_HALF_SIZE) or is_equal_approx(absf(vertex.z), TILE_HALF_SIZE):
			if absf(vertex.y - 0.14) > POSITION_EPSILON:
				_fail("Meadow noise moved a boundary-lock vertex: %s" % vertex)
				return false
	for probe in [
		Vector2(-2.44, -2.44), Vector2(0.0, -2.44), Vector2(2.44, -2.44),
		Vector2(2.44, 0.0), Vector2(2.44, 2.44),
	]:
		if not _is_covered(land, probe):
			_fail("Blender land lost a required NORTH/EAST corner or full edge at %s." % probe)
			return false
	for probe in [Vector2(-2.44, 0.0), Vector2(-1.5, 2.44), Vector2(1.1, 2.44)]:
		if _is_covered(land, probe):
			_fail("Blender land invaded the WEST EMPTY or SOUTH WATER/MEADOW edge at %s." % probe)
			return false
	var south_edge_x := PackedFloat32Array()
	for vertex in water_vertices:
		if absf(vertex.z - TILE_HALF_SIZE) <= POSITION_EPSILON:
			south_edge_x.append(vertex.x)
	south_edge_x.sort()
	if south_edge_x.is_empty() or absf(south_edge_x[0] + WATER_PORT_HALF_WIDTH) > POSITION_EPSILON or absf(south_edge_x[-1] - WATER_PORT_HALF_WIDTH) > POSITION_EPSILON:
		_fail("SOUTH water port is not centred at the canonical 0.48 width: %s" % south_edge_x)
		return false
	if not _has_water_edge_seal(water):
		_fail("AnimatedSurface lost its continuous terrain-buried edge seal.")
		return false
	var riverbed_submergence := _minimum_surface_submergence(riverbed, water)
	if riverbed_submergence == -INF or riverbed_submergence < RIVERBED_MIN_SUBMERGENCE - POSITION_EPSILON:
		_fail("RiverBed escaped the visible AnimatedSurface or rose too high (minimum submergence %.5f)." % riverbed_submergence)
		return false
	return true


func _save_scene() -> int:
	var root := Node3D.new()
	root.name = "NorthEastLandSouthWaterFreeAssetV2"
	root.set_script(TILE_ARTWORK_SCRIPT)
	root.set("edge_markers", PackedInt32Array([1, 1, 2, 0]))
	root.set("topology", TOPOLOGY)
	root.set("require_topology", true)
	root.set("require_canonical_topology", true)
	var masks: Array[PlantingMask3D] = [load(PLANTING_MASK_OUTPUT) as PlantingMask3D]
	root.set("planting_masks", masks)
	root.set("preview_growth_state", 0)

	var base := _mesh_node("Base", load(OUTPUTS["Base"]) as ArrayMesh, load(BASE_MATERIAL_OUTPUT) as Material)
	_add(root, base, root)
	var meadow := _mesh_node("Meadow", load(OUTPUTS["Meadow"]) as ArrayMesh, load(MEADOW_MATERIAL_OUTPUT) as Material)
	_add(root, meadow, root)
	var land_root := Node3D.new()
	land_root.name = "LandSoil"
	_add(root, land_root, root)
	_add(land_root, _mesh_node("NorthEastField", load(OUTPUTS["NorthEastField"]) as ArrayMesh, load(SOIL_MATERIAL_OUTPUT) as Material), root)
	var water_root := Node3D.new()
	water_root.name = "Water"
	_add(root, water_root, root)
	_add(water_root, _mesh_node("RiverBed", load(OUTPUTS["RiverBed"]) as ArrayMesh, load(BANK_MATERIAL_OUTPUT) as Material), root)
	var water := _mesh_node("AnimatedSurface", load(OUTPUTS["AnimatedSurface"]) as ArrayMesh, load(WATER_MATERIAL_OUTPUT) as Material)
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(water_root, water, root)
	var decorations := Node3D.new()
	decorations.name = "Decorations"
	_add(root, decorations, root)
	# Free KayKit props stay sparse, below crop height and exclusively on MEADOW.
	# They are authored into the fixed prefab and never participate in sowing.
	_add_decoration(decorations, root, GRASS_A, "MeadowGrassA", Vector3(-1.72, 0.145, 0.42), 0.46, -18.0, load(GRASS_MATERIAL_OUTPUT) as Material)
	_add_decoration(decorations, root, GRASS_B, "MeadowGrassB", Vector3(-1.49, 0.145, 0.57), 0.36, 31.0, load(GRASS_MATERIAL_OUTPUT) as Material)
	_add_decoration(decorations, root, ROCK_A, "MeadowRockA", Vector3(-1.82, 0.145, 0.78), 0.26, -28.0, load(ROCK_MATERIAL_OUTPUT) as Material)
	_add_decoration(decorations, root, GRASS_C, "MeadowGrassC", Vector3(-0.92, 0.145, 1.70), 0.31, 9.0, load(GRASS_MATERIAL_OUTPUT) as Material)
	_add_decoration(decorations, root, ROCK_B, "MeadowRockB", Vector3(-1.14, 0.145, 1.58), 0.43, 18.0, load(ROCK_MATERIAL_OUTPUT) as Material)
	_add_decoration(decorations, root, ROCK_C, "MeadowRockC", Vector3(-1.24, 0.145, 1.82), 0.13, 44.0, load(ROCK_MATERIAL_OUTPUT) as Material)
	for layer_name in ["GrowingPlants", "WitheredPlants"]:
		var layer := Node3D.new()
		layer.name = layer_name
		_add(root, layer, root)

	var packed := PackedScene.new()
	var pack_error := packed.pack(root)
	root.free()
	if pack_error != OK:
		return pack_error
	return ResourceSaver.save(packed, SCENE_OUTPUT)


func _mesh_node(name: String, mesh: ArrayMesh, material: Material) -> MeshInstance3D:
	var result := MeshInstance3D.new()
	result.name = name
	result.mesh = mesh
	result.material_override = material
	return result


func _add(parent: Node, child: Node, owner: Node) -> void:
	parent.add_child(child)
	child.owner = owner


func _add_decoration(parent: Node, scene_owner: Node, packed: PackedScene, name: String, position: Vector3, scale_value: float, yaw_degrees: float, material: Material) -> void:
	var source_root := packed.instantiate() as Node3D
	if source_root == null:
		return
	var instance := Node3D.new()
	instance.name = name
	instance.position = position
	instance.scale = Vector3.ONE * scale_value
	instance.rotation.y = deg_to_rad(yaw_degrees)
	_add(parent, instance, scene_owner)
	var source_meshes: Array[MeshInstance3D] = []
	if source_root is MeshInstance3D:
		source_meshes.append(source_root as MeshInstance3D)
	for child in source_root.find_children("*", "MeshInstance3D", true, false):
		source_meshes.append(child as MeshInstance3D)
	for index in range(source_meshes.size()):
		var source_mesh := source_meshes[index]
		var mesh_copy := MeshInstance3D.new()
		mesh_copy.name = "%sMesh%02d" % [name, index + 1]
		mesh_copy.mesh = source_mesh.mesh
		mesh_copy.transform = source_mesh.transform
		mesh_copy.material_override = material
		_add(instance, mesh_copy, scene_owner)
	source_root.free()


func _is_covered(mesh: ArrayMesh, probe: Vector2) -> bool:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var triangle_indices := indices if not indices.is_empty() else PackedInt32Array(range(vertices.size()))
	for index in range(0, triangle_indices.size(), 3):
		var a := vertices[triangle_indices[index]]
		var b := vertices[triangle_indices[index + 1]]
		var c := vertices[triangle_indices[index + 2]]
		if _point_in_triangle(probe, Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)):
			return true
	return false


func _minimum_surface_submergence(underlay: ArrayMesh, surface: ArrayMesh) -> float:
	var arrays := underlay.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var triangle_indices := indices if not indices.is_empty() else PackedInt32Array(range(vertices.size()))
	var minimum_submergence := INF
	for index in range(0, triangle_indices.size(), 3):
		var a := vertices[triangle_indices[index]]
		var b := vertices[triangle_indices[index + 1]]
		var c := vertices[triangle_indices[index + 2]]
		for sample in [a, b, c, (a + b) * 0.5, (b + c) * 0.5, (c + a) * 0.5, (a + b + c) / 3.0]:
			var surface_height := _surface_height_at(surface, Vector2(sample.x, sample.z))
			if surface_height == INF:
				return -INF
			minimum_submergence = minf(minimum_submergence, surface_height - sample.y)
	return minimum_submergence


func _has_water_edge_seal(mesh: ArrayMesh) -> bool:
	var vertices: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var floor_vertices := 0
	for vertex in vertices:
		if vertex.y <= WATER_EDGE_SEAL_FLOOR + POSITION_EPSILON:
			floor_vertices += 1
	return floor_vertices >= 20


func _water_has_broad_land_mouth(water: ArrayMesh, land: ArrayMesh) -> bool:
	var water_vertices: PackedVector3Array = water.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var contact_samples := 0
	for vertex in water_vertices:
		if vertex.y < LAND_SURFACE_HEIGHT + 0.002:
			continue
		var land_height := _surface_height_at(land, Vector2(vertex.x, vertex.z))
		if land_height >= LAND_SURFACE_HEIGHT - POSITION_EPSILON:
			contact_samples += 1
	return contact_samples >= 5


func _surface_height_at(mesh: ArrayMesh, probe: Vector2) -> float:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var triangle_indices := indices if not indices.is_empty() else PackedInt32Array(range(vertices.size()))
	# AnimatedSurface also carries vertical perimeter seals. A projected probe
	# can meet more than one horizontal facet at a shared edge; keep the upper
	# water sheet instead of relying on imported triangle order.
	var highest_surface := -INF
	for index in range(0, triangle_indices.size(), 3):
		var a := vertices[triangle_indices[index]]
		var b := vertices[triangle_indices[index + 1]]
		var c := vertices[triangle_indices[index + 2]]
		var denominator := (b.z - c.z) * (a.x - c.x) + (c.x - b.x) * (a.z - c.z)
		if absf(denominator) <= POSITION_EPSILON:
			continue
		var weight_a := ((b.z - c.z) * (probe.x - c.x) + (c.x - b.x) * (probe.y - c.z)) / denominator
		var weight_b := ((c.z - a.z) * (probe.x - c.x) + (a.x - c.x) * (probe.y - c.z)) / denominator
		var weight_c := 1.0 - weight_a - weight_b
		if weight_a >= -POSITION_EPSILON and weight_b >= -POSITION_EPSILON and weight_c >= -POSITION_EPSILON:
			highest_surface = maxf(highest_surface, a.y * weight_a + b.y * weight_b + c.y * weight_c)
	return INF if highest_surface == -INF else highest_surface


func _point_in_triangle(point: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (point - b).cross(c - b)
	var d2 := (point - c).cross(a - c)
	var d3 := (point - a).cross(b - a)
	return not ((d1 < 0.0 or d2 < 0.0 or d3 < 0.0) and (d1 > 0.0 or d2 > 0.0 or d3 > 0.0))


func _fail(message: String) -> void:
	push_error("BLENDER_TILE_IMPORT_FAIL: " + message)
	quit(1)
