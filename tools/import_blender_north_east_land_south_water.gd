extends SceneTree

# Imports the Blender-authored pilot into the project's existing fixed-prefab
# contract.  The GLB supplies geometry only; topology, LAND mask, shared
# terrain materials and water behavior remain Godot-owned resources.
const SOURCE_SCENE_PATH := "res://art/models/tiles_blender/north_east_land_south_water.glb"
const MANIFEST_PATH := "res://art/models/tiles_blender/north_east_land_south_water.manifest.json"
const OUTPUT_DIRECTORY := "res://art/generated/blender_pilot"
const MATERIAL_DIRECTORY := "res://art/materials/water/blender_pilot"
const MASK_DIRECTORY := "res://art/planting_masks/blender_pilot"
const SCENE_DIRECTORY := "res://scenes/tiles_3d/blender_pilot"
const SCENE_OUTPUT := SCENE_DIRECTORY + "/north_east_land_south_water_blender.tscn"

const OUTPUTS := {
	"Base": OUTPUT_DIRECTORY + "/north_east_land_south_water_base.tres",
	"Meadow": OUTPUT_DIRECTORY + "/north_east_land_south_water_meadow.tres",
	"NorthEastField": OUTPUT_DIRECTORY + "/north_east_land_south_water_land.tres",
	"RiverBed": OUTPUT_DIRECTORY + "/north_east_land_south_water_river_bed.tres",
	"AnimatedSurface": OUTPUT_DIRECTORY + "/north_east_land_south_water_water.tres",
}
const WATER_MATERIAL_OUTPUT := MATERIAL_DIRECTORY + "/north_east_land_south_water.tres"
const PLANTING_MASK_OUTPUT := MASK_DIRECTORY + "/north_east_land_south_water_field.tres"

const TILE_ARTWORK_SCRIPT := preload("res://scripts/tile_artwork_3d.gd")
const TOPOLOGY := preload("res://art/topologies/generated/procedural_north_east_land_south_water.tres")
const PLANTING_MASK := preload("res://art/planting_masks/generated/procedural_north_east_land_south_water_land_north_east_field_01.tres")
const BASE_MATERIAL := preload("res://art/materials/terrain/tile_base.tres")
const MEADOW_MATERIAL := preload("res://art/materials/terrain/meadow.tres")
const SOIL_MATERIAL := preload("res://art/materials/terrain/fertile_soil.tres")
const BANK_MATERIAL := preload("res://art/materials/terrain/river_bank.tres")
const WATER_MATERIAL_TEMPLATE := preload("res://art/materials/water/north_east_land_south_water.tres")
const ROCK_A := preload("res://art/models/kenney/nature_kit/rock_smallFlatA.glb")
const ROCK_B := preload("res://art/models/kenney/nature_kit/rock_smallFlatB.glb")
const ROCK_C := preload("res://art/models/kenney/nature_kit/rock_smallFlatC.glb")

const TILE_HALF_SIZE := 2.45
const WATER_PORT_HALF_WIDTH := 0.24
const POSITION_EPSILON := 0.0002


func _init() -> void:
	call_deferred("_import")


func _import() -> void:
	for directory in [OUTPUT_DIRECTORY, MATERIAL_DIRECTORY, MASK_DIRECTORY, SCENE_DIRECTORY]:
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
	var pilot_mask := PLANTING_MASK.duplicate(true) as PlantingMask3D
	pilot_mask.id = &"north_east_land_south_water_blender_field"
	pilot_mask.surface_height = 0.20
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
	print("BLENDER_TILE_IMPORT_PASS: fixed meshes, canonical anchors, UV2 water data, material instance, and static prefab were saved.")
	quit()


func _load_manifest() -> Dictionary:
	var file := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if file == null:
		_fail("Could not open Blender manifest.")
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not parsed is Dictionary or float(parsed.get("water_port_width", 0.0)) != WATER_PORT_HALF_WIDTH * 2.0 or float(parsed.get("shoreline_length", 0.0)) <= 0.0:
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


func _validate_edge_contract(meshes: Dictionary) -> bool:
	var meadow := meshes["Meadow"] as ArrayMesh
	var land := meshes["NorthEastField"] as ArrayMesh
	var water := meshes["AnimatedSurface"] as ArrayMesh
	var meadow_vertices: PackedVector3Array = meadow.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var land_vertices: PackedVector3Array = land.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var water_arrays := water.surface_get_arrays(0)
	var water_vertices: PackedVector3Array = water_arrays[Mesh.ARRAY_VERTEX]
	var water_uv2: PackedVector2Array = water_arrays[Mesh.ARRAY_TEX_UV2]
	if water_uv2.size() != water_vertices.size() or water_uv2.is_empty():
		_fail("Blender water mesh did not preserve its second UV channel for d/s.")
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
	return true


func _save_scene() -> int:
	var root := Node3D.new()
	root.name = "NorthEastLandSouthWaterBlenderPilot"
	root.set_script(TILE_ARTWORK_SCRIPT)
	root.set("edge_markers", PackedInt32Array([1, 1, 2, 0]))
	root.set("topology", TOPOLOGY)
	root.set("require_topology", true)
	root.set("require_canonical_topology", true)
	var masks: Array[PlantingMask3D] = [load(PLANTING_MASK_OUTPUT) as PlantingMask3D]
	root.set("planting_masks", masks)
	root.set("preview_growth_state", 1)

	var base := _mesh_node("Base", load(OUTPUTS["Base"]) as ArrayMesh, BASE_MATERIAL)
	_add(root, base, root)
	var meadow := _mesh_node("Meadow", load(OUTPUTS["Meadow"]) as ArrayMesh, MEADOW_MATERIAL)
	_add(root, meadow, root)
	var land_root := Node3D.new()
	land_root.name = "LandSoil"
	_add(root, land_root, root)
	_add(land_root, _mesh_node("NorthEastField", load(OUTPUTS["NorthEastField"]) as ArrayMesh, SOIL_MATERIAL), root)
	var water_root := Node3D.new()
	water_root.name = "Water"
	_add(root, water_root, root)
	_add(water_root, _mesh_node("RiverBed", load(OUTPUTS["RiverBed"]) as ArrayMesh, BANK_MATERIAL), root)
	var water := _mesh_node("AnimatedSurface", load(OUTPUTS["AnimatedSurface"]) as ArrayMesh, load(WATER_MATERIAL_OUTPUT) as Material)
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_add(water_root, water, root)
	var decorations := Node3D.new()
	decorations.name = "Decorations"
	_add(root, decorations, root)
	_add_decoration(decorations, root, ROCK_A, "MeadowRockA", Vector3(-1.72, 0.145, 0.70), 0.24, -18.0)
	_add_decoration(decorations, root, ROCK_B, "MeadowRockB", Vector3(-1.48, 0.148, 1.52), 0.18, 31.0)
	_add_decoration(decorations, root, ROCK_C, "MeadowRockC", Vector3(-0.88, 0.145, 1.92), 0.14, 9.0)
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


func _add_decoration(parent: Node, scene_owner: Node, packed: PackedScene, name: String, position: Vector3, scale_value: float, yaw_degrees: float) -> void:
	var instance := packed.instantiate() as Node3D
	if instance == null:
		return
	instance.name = name
	instance.position = position
	instance.scale = Vector3.ONE * scale_value
	instance.rotation.y = deg_to_rad(yaw_degrees)
	_add(parent, instance, scene_owner)


func _is_covered(mesh: ArrayMesh, probe: Vector2) -> bool:
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var triangle_indices := indices if not indices.is_empty() else PackedInt32Array(range(vertices.size()))
	for index in range(0, triangle_indices.size(), 3):
		var a := vertices[triangle_indices[index]]
		var b := vertices[triangle_indices[index + 1]]
		var c := vertices[triangle_indices[index + 2]]
		if _point_in_triangle(probe, Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)):
			return true
	return false


func _point_in_triangle(point: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var d1 := (point - b).cross(c - b)
	var d2 := (point - c).cross(a - c)
	var d3 := (point - a).cross(b - a)
	return not ((d1 < 0.0 or d2 < 0.0 or d3 < 0.0) and (d1 > 0.0 or d2 > 0.0 or d3 > 0.0))


func _fail(message: String) -> void:
	push_error("BLENDER_TILE_IMPORT_FAIL: " + message)
	quit(1)
