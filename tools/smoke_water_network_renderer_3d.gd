extends SceneTree

const BOARD_STATE_SCRIPT := preload("res://scripts/board_state.gd")
const RENDERER_SCRIPT := preload("res://scripts/water_network_renderer_3d.gd")
const WATER_STRAIGHT_SCENE := preload("res://scenes/tiles_3d/generated/procedural_water_ns.tscn")
const TILE_SIZE := 4.9


func _init() -> void:
	call_deferred("_smoke")


func _smoke() -> void:
	var definition := _water_straight_definition()
	var board := BOARD_STATE_SCRIPT.new()
	board.start_with(definition)
	var second_cell := Vector2i(0, -1)
	var placement := board.place(definition, second_cell, 0, 0)
	if not bool(placement["valid"]):
		_fail("Could not form a real north/south water connection: %s" % placement["reason"])
		return
	var root_cell := Vector2i.ZERO
	var first_tile := _instantiate_tile(root_cell)
	var second_tile := _instantiate_tile(second_cell)
	get_root().add_child(first_tile)
	get_root().add_child(second_tile)
	await process_frame
	var tiles := {root_cell: first_tile, second_cell: second_tile}
	var renderer := RENDERER_SCRIPT.new() as WaterNetworkRenderer3D
	var first_refresh := renderer.refresh(board, tiles)
	if int(first_refresh["network_count"]) != 1 or int(first_refresh["surface_count"]) != 2:
		_fail("Connected water tiles did not produce one two-surface material network.")
		return
	var first_material := _water_material(first_tile)
	var second_material := _water_material(second_tile)
	if first_material == null or second_material == null or first_material == second_material:
		_fail("Each tile must receive its own cloned water material instance.")
		return
	var network_length := float(first_material.get_shader_parameter("foam_network_shoreline_length"))
	if network_length <= float(first_material.get_shader_parameter("foam_shoreline_length")):
		_fail("Connected water material did not receive its full network shoreline length.")
		return
	if not is_equal_approx(float(first_material.get_shader_parameter("foam_network_phase_offset")), float(second_material.get_shader_parameter("foam_network_phase_offset"))):
		_fail("Connected water surfaces do not share one network wave phase.")
		return
	if float(first_material.get_shader_parameter("foam_network_speed_scale")) >= 1.0:
		_fail("A multi-tile network did not normalize its foam speed to network length.")
		return
	var first_material_identity := first_material
	renderer.refresh(board, tiles)
	if _water_material(first_tile) != first_material_identity:
		_fail("Refreshing an unchanged network unnecessarily cloned another material.")
		return
	first_tile.queue_free()
	second_tile.queue_free()
	print("WATER_NETWORK_RENDERER_3D_SMOKE_PASS: connected frozen meshes share a phase via per-tile material instances; no river mesh was rebuilt.")
	quit()


func _water_straight_definition() -> TileDefinition:
	var definition := TileDefinition.new()
	definition.configure(
		&"smoke_water_ns",
		"Smoke water straight",
		TileDefinition.CARD_TILE,
		1,
		PackedInt32Array([TileDefinition.EdgeKind.WATER, TileDefinition.EdgeKind.EMPTY, TileDefinition.EdgeKind.WATER, TileDefinition.EdgeKind.EMPTY]),
		PackedInt32Array([0, 0, 0, 0]),
		TileDefinition.CenterKind.EMPTY,
		false,
		false,
		17,
		PackedInt32Array(),
		WATER_STRAIGHT_SCENE,
		0,
		"water renderer smoke",
		[5],
		[],
	)
	return definition


func _instantiate_tile(cell: Vector2i) -> TileArtwork3D:
	var tile := WATER_STRAIGHT_SCENE.instantiate() as TileArtwork3D
	tile.position = Vector3(float(cell.x) * TILE_SIZE, 0.0, float(cell.y) * TILE_SIZE)
	return tile


func _water_material(tile: TileArtwork3D) -> ShaderMaterial:
	var surface := tile.get_node_or_null(^"Water/AnimatedSurface") as MeshInstance3D
	return surface.material_override as ShaderMaterial if surface != null else null


func _fail(message: String) -> void:
	push_error("WATER_NETWORK_RENDERER_3D_SMOKE_FAIL: " + message)
	quit(1)
