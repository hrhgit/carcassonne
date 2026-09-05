extends SceneTree

# Generates a fixed 3D tile prefab and its baked mesh/material/topology assets.
# Usage: godot --headless --path . --script res://tools/generate_tile_3d_prefab.gd
const DEFAULT_SPEC := "res://tools/tile_specs_3d/north_east_land_south_water.json"
const GENERATOR := preload("res://scripts/tile_prefab_generator_3d.gd")


func _init() -> void:
	call_deferred("_generate")


func _generate() -> void:
	var spec_path := DEFAULT_SPEC
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--spec="):
			spec_path = argument.trim_prefix("--spec=")
	var result := GENERATOR.build_from_spec_file(spec_path)
	if not result["ok"]:
		push_error("TILE_3D_PREFAB_GENERATION_FAILED: %s" % result["error"])
		quit(1)
		return
	print("TILE_3D_PREFAB_GENERATED: %s -> %s | shoreline_length=%.4f" % [result["spec"]["id"], result["scene_path"], result["shoreline_length"]])
	quit()
