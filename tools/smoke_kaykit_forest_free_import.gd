extends SceneTree

const ASSETS := [
	"res://art/models/kaykit/forest_free/Grass_1_A_Color1.gltf",
	"res://art/models/kaykit/forest_free/Grass_1_B_Color1.gltf",
	"res://art/models/kaykit/forest_free/Grass_2_A_Color1.gltf",
	"res://art/models/kaykit/forest_free/Rock_1_A_Color1.gltf",
	"res://art/models/kaykit/forest_free/Rock_2_A_Color1.gltf",
	"res://art/models/kaykit/forest_free/Rock_3_A_Color1.gltf",
]


func _init() -> void:
	for path in ASSETS:
		var scene := load(path) as PackedScene
		if scene == null:
			_fail("Could not load %s." % path)
			return
		var instance := scene.instantiate()
		var meshes := instance.find_children("*", "MeshInstance3D", true, false)
		if meshes.is_empty():
			instance.free()
			_fail("Imported asset has no MeshInstance3D: %s." % path)
			return
		var has_surface := false
		for child in meshes:
			var mesh_instance := child as MeshInstance3D
			if mesh_instance.mesh != null and mesh_instance.mesh.get_surface_count() > 0:
				has_surface = true
				break
		instance.free()
		if not has_surface:
			_fail("Imported asset has no renderable surface: %s." % path)
			return
	print("KAYKIT_FOREST_FREE_IMPORT_PASS: %d reviewed grass/rock assets load as renderable Godot scenes." % ASSETS.size())
	quit()


func _fail(message: String) -> void:
	push_error("KAYKIT_FOREST_FREE_IMPORT_FAIL: " + message)
	quit(1)
