class_name TileCatalog
extends Node2D

const TILE_DEFINITION_SCRIPT := preload("res://scripts/tile_definition.gd")
const ALLUVIAL_CROSS_SCENE := preload("res://scenes/tiles/alluvial_cross.tscn")
const BROOK_NOOK_SCENE := preload("res://scenes/tiles/brook_nook.tscn")
const OPPOSITE_BANKS_SCENE := preload("res://scenes/tiles/opposite_banks.tscn")
const RIVER_CROSS_SCENE := preload("res://scenes/tiles/river_cross.tscn")
const THREE_SIDE_CANAL_SCENE := preload("res://scenes/tiles/three_side_canal.tscn")
const THREE_LAND_RIVER_GARDEN_SCENE := preload("res://scenes/tiles/three_land_river_garden.tscn")
const CORNER_BANK_SCENE := preload("res://scenes/tiles/corner_bank.tscn")
const EMPTY := 0
const LAND := 1
const WATER := 2

func starter_tile() -> TileDefinition:
	# The neutral starter gives every player an accessible land edge on turn one.
	return _definition(
		&"starter_alluvial_cross",
		"冲积十字",
		PackedInt32Array([LAND, LAND, LAND, LAND]),
		ALLUVIAL_CROSS_SCENE,
		4001,
	)


func build_deck() -> Array[TileDefinition]:
	# Each entry points at authored art. Rotation offsets only align a pre-authored
	# prefab with its rule orientation; no runtime code rebuilds its terrain.
	return [
		_definition(&"brook_nook_a", "溪畔小地", PackedInt32Array([LAND, EMPTY, WATER, EMPTY]), BROOK_NOOK_SCENE, 1103),
		_definition(&"bank_pair_a", "双岸地块", PackedInt32Array([LAND, WATER, LAND, EMPTY]), OPPOSITE_BANKS_SCENE, 2221),
		_definition(&"split_canal_a", "分流水渠", PackedInt32Array([WATER, LAND, WATER, LAND]), RIVER_CROSS_SCENE, 3371, 1),
		_definition(&"three_land_river_garden_a", "三边灌溉田", PackedInt32Array([LAND, LAND, WATER, LAND]), THREE_LAND_RIVER_GARDEN_SCENE, 4493),
		_definition(&"heartland_a", "沃土中心", PackedInt32Array([LAND, LAND, LAND, LAND]), ALLUVIAL_CROSS_SCENE, 5519),
		_definition(&"brook_nook_b", "溪畔小地", PackedInt32Array([LAND, EMPTY, WATER, EMPTY]), BROOK_NOOK_SCENE, 6131),
		_definition(&"bank_pair_b", "双岸地块", PackedInt32Array([WATER, LAND, EMPTY, LAND]), OPPOSITE_BANKS_SCENE, 7247, 3),
		_definition(&"three_side_b", "三边水渠", PackedInt32Array([LAND, WATER, LAND, LAND]), THREE_SIDE_CANAL_SCENE, 8363, 3),
		_definition(&"river_field_a", "河畔田野", PackedInt32Array([LAND, WATER, LAND, WATER]), RIVER_CROSS_SCENE, 9479),
		_definition(&"heartland_b", "沃土中心", PackedInt32Array([LAND, LAND, LAND, LAND]), ALLUVIAL_CROSS_SCENE, 10501),
		_definition(&"brook_nook_c", "溪畔小地", PackedInt32Array([WATER, EMPTY, LAND, EMPTY]), BROOK_NOOK_SCENE, 11617, 2),
		_definition(&"bank_pair_c", "双岸地块", PackedInt32Array([LAND, LAND, WATER, EMPTY]), CORNER_BANK_SCENE, 12733),
		_definition(&"three_side_c", "三边水渠", PackedInt32Array([WATER, LAND, LAND, LAND]), THREE_SIDE_CANAL_SCENE, 13849, 2),
		_definition(&"river_field_b", "河畔田野", PackedInt32Array([LAND, WATER, LAND, WATER]), RIVER_CROSS_SCENE, 14963),
		_definition(&"heartland_c", "沃土中心", PackedInt32Array([LAND, LAND, LAND, LAND]), ALLUVIAL_CROSS_SCENE, 16073),
		_definition(&"brook_nook_d", "溪畔小地", PackedInt32Array([LAND, EMPTY, WATER, EMPTY]), BROOK_NOOK_SCENE, 17189),
	]


func _definition(
	id: StringName,
	title: String,
	edges: PackedInt32Array,
	visual_scene: PackedScene,
	seed: int,
	visual_rotation_quarters := 0,
) -> TileDefinition:
	var definition := TILE_DEFINITION_SCRIPT.new()
	var prefab_matches_rule := _prefab_matches_rule(visual_scene, edges, visual_rotation_quarters)
	definition.configure(
		id,
		title,
		edges,
		false,
		seed,
		PackedInt32Array(),
		visual_scene if prefab_matches_rule else null,
		visual_rotation_quarters,
	)
	if not prefab_matches_rule:
		push_error("Tile catalog rejected %s because its fixed prefab ports do not match its rule edges." % title)
	elif not definition.is_playable():
		push_error("Tile catalog rejected %s because it needs valid irrigation and a fixed prefab." % title)
	return definition


func _prefab_matches_rule(visual_scene: PackedScene, edges: PackedInt32Array, visual_rotation_quarters: int) -> bool:
	if visual_scene == null:
		return false
	var artwork := visual_scene.instantiate()
	if not artwork.has_method("edge_marker_at"):
		artwork.free()
		return false

	var matches := true
	for edge in range(4):
		if int(artwork.call("edge_marker_at", edge, visual_rotation_quarters)) != edges[edge]:
			matches = false
			break
	artwork.free()
	return matches
