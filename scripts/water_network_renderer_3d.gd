class_name WaterNetworkRenderer3D
extends RefCounted

# Updating a network is deliberately a material-only operation. The fixed
# ArrayMesh still owns the river silhouette and its UV2.x=d / UV2.y=s field.
const TILE_HALF_SIZE := 2.45
const NETWORK_SEED := 41_719


func refresh(board: BoardState, placed_tile_nodes: Dictionary) -> Dictionary:
	var visited: Dictionary = {}
	var component_count := 0
	var updated_surface_count := 0
	for cell in board.occupied_cells():
		if visited.has(cell) or not _has_renderable_water(board, placed_tile_nodes, cell):
			continue
		var component := _collect_component(board, placed_tile_nodes, cell, visited)
		if component.is_empty():
			continue
		component_count += 1
		updated_surface_count += _apply_component(board, placed_tile_nodes, component)
	return {
		"network_count": component_count,
		"surface_count": updated_surface_count,
	}


func _collect_component(
	board: BoardState,
	placed_tile_nodes: Dictionary,
	root_cell: Vector2i,
	visited: Dictionary,
) -> Array[Vector2i]:
	var component: Array[Vector2i] = []
	var queue: Array[Vector2i] = [root_cell]
	visited[root_cell] = true
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		component.append(cell)
		for edge in range(4):
			if not _edge_carries_water(board, cell, edge):
				continue
			var neighbour := BoardState.neighbour_for_edge(cell, edge)
			if visited.has(neighbour) or not _has_renderable_water(board, placed_tile_nodes, neighbour):
				continue
			if not _edge_carries_water(board, neighbour, BoardState.opposite_edge(edge)):
				continue
			visited[neighbour] = true
			queue.append(neighbour)
	component.sort_custom(_cell_before)
	return component


func _apply_component(board: BoardState, placed_tile_nodes: Dictionary, component: Array[Vector2i]) -> int:
	var local_lengths: Dictionary = {}
	var total_length := 0.0
	for cell in component:
		var surface := _surface_for(placed_tile_nodes, cell)
		var length := _local_shoreline_length(surface)
		local_lengths[cell] = length
		total_length += length
	if total_length <= 0.0:
		return 0

	# A spanning traversal aligns the global s coordinate at every newly joined
	# port. This is enough for branches as well: they all inherit the same phase
	# field, while cycles retain the stable first path rather than flickering.
	var offsets: Dictionary = {}
	var queue: Array[Vector2i] = [component[0]]
	offsets[component[0]] = 0.0
	while not queue.is_empty():
		var cell: Vector2i = queue.pop_front()
		for edge in range(4):
			if not _edge_carries_water(board, cell, edge):
				continue
			var neighbour := BoardState.neighbour_for_edge(cell, edge)
			if not local_lengths.has(neighbour) or not _edge_carries_water(board, neighbour, BoardState.opposite_edge(edge)):
				continue
			if offsets.has(neighbour):
				continue
			var source_s := _port_shoreline_s(_surface_for(placed_tile_nodes, cell), cell, edge, float(local_lengths[cell]))
			var target_s := _port_shoreline_s(_surface_for(placed_tile_nodes, neighbour), neighbour, BoardState.opposite_edge(edge), float(local_lengths[neighbour]))
			offsets[neighbour] = float(offsets[cell]) + source_s - target_s
			queue.append(neighbour)

	var average_length := total_length / float(component.size())
	var speed_scale := average_length / total_length
	var phase_offset := _phase_for(component[0])
	var updated := 0
	for cell in component:
		var surface := _surface_for(placed_tile_nodes, cell)
		var material := _network_material(surface)
		if material == null:
			continue
		material.set_shader_parameter("foam_network_s_offset", float(offsets.get(cell, 0.0)))
		material.set_shader_parameter("foam_network_shoreline_length", total_length)
		material.set_shader_parameter("foam_network_phase_offset", phase_offset)
		material.set_shader_parameter("foam_network_speed_scale", speed_scale)
		updated += 1
	return updated


func _has_renderable_water(board: BoardState, placed_tile_nodes: Dictionary, cell: Vector2i) -> bool:
	if not board.has_tile(cell) or not _tile_has_water(board, cell):
		return false
	var surface := _surface_for(placed_tile_nodes, cell)
	return surface != null and surface.mesh != null and surface.mesh.get_surface_count() > 0


func _tile_has_water(board: BoardState, cell: Vector2i) -> bool:
	var placement := board.get_placement(cell)
	if placement.is_empty():
		return false
	var definition := placement["definition"] as TileDefinition
	if definition == null:
		return false
	if definition.center_kind == TileDefinition.CenterKind.LAKE:
		return true
	for edge in range(4):
		if _edge_carries_water(board, cell, edge):
			return true
	return false


func _edge_carries_water(board: BoardState, cell: Vector2i, edge: int) -> bool:
	var placement := board.get_placement(cell)
	if placement.is_empty():
		return false
	var definition := placement["definition"] as TileDefinition
	if definition == null:
		return false
	var kind := definition.edge_kind_at(edge, int(placement["rotation"]))
	return kind == TileDefinition.EdgeKind.WATER or (
		kind == TileDefinition.EdgeKind.BANK and (placement.get("water_rewrite_at", []) as Array).has(edge)
	)


func _surface_for(placed_tile_nodes: Dictionary, cell: Vector2i) -> MeshInstance3D:
	var tile := placed_tile_nodes.get(cell, null) as Node3D
	if tile == null or not is_instance_valid(tile):
		return null
	return tile.get_node_or_null(^"Water/AnimatedSurface") as MeshInstance3D


func _local_shoreline_length(surface: MeshInstance3D) -> float:
	if surface == null:
		return 0.0
	var material := surface.material_override as ShaderMaterial
	if material == null and surface.mesh != null and surface.mesh.get_surface_count() > 0:
		material = surface.get_active_material(0) as ShaderMaterial
	return float(material.get_shader_parameter("foam_shoreline_length")) if material != null else 0.0


func _network_material(surface: MeshInstance3D) -> ShaderMaterial:
	if surface == null:
		return null
	var cached: Variant = surface.get_meta("water_network_material") if surface.has_meta("water_network_material") else null
	if cached is ShaderMaterial:
		return cached as ShaderMaterial
	var source := surface.material_override as ShaderMaterial
	if source == null and surface.mesh != null and surface.mesh.get_surface_count() > 0:
		source = surface.get_active_material(0) as ShaderMaterial
	if source == null:
		return null
	var local_material := source.duplicate() as ShaderMaterial
	surface.material_override = local_material
	surface.set_meta("water_network_material", local_material)
	return local_material


func _port_shoreline_s(surface: MeshInstance3D, cell: Vector2i, edge: int, local_length: float) -> float:
	if surface == null or surface.mesh == null or surface.mesh.get_surface_count() == 0:
		return 0.0
	var arrays := surface.mesh.surface_get_arrays(0)
	var vertices := arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array
	var shoreline := arrays[Mesh.ARRAY_TEX_UV2] as PackedVector2Array
	if vertices.is_empty() or vertices.size() != shoreline.size():
		return 0.0
	var direction := _edge_direction(edge)
	var tile := surface.get_parent().get_parent() as Node3D
	if tile == null:
		return 0.0
	var world_port := tile.global_position + Vector3(direction.x * TILE_HALF_SIZE, 0.0, direction.y * TILE_HALF_SIZE)
	var local_port := surface.to_local(world_port)
	var nearest_index := 0
	var nearest_distance := INF
	for vertex_index in range(vertices.size()):
		var vertex := vertices[vertex_index]
		var delta := Vector2(vertex.x - local_port.x, vertex.z - local_port.z)
		var distance := delta.length_squared()
		if distance < nearest_distance:
			nearest_distance = distance
			nearest_index = vertex_index
	return shoreline[nearest_index].y * local_length


func _phase_for(root_cell: Vector2i) -> float:
	var value := NETWORK_SEED + root_cell.x * 92_821 + root_cell.y * 68_917
	value = value ^ (value >> 13)
	return float(posmod(value, 10_000)) / 10_000.0


func _edge_direction(edge: int) -> Vector2:
	match edge:
		TileDefinition.Edge.NORTH:
			return Vector2.UP
		TileDefinition.Edge.EAST:
			return Vector2.RIGHT
		TileDefinition.Edge.SOUTH:
			return Vector2.DOWN
		_:
			return Vector2.LEFT


func _cell_before(first: Vector2i, second: Vector2i) -> bool:
	return first.x < second.x if first.y == second.y else first.y < second.y
