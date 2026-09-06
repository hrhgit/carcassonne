extends Node3D


func _ready() -> void:
	$Camera3D.look_at(Vector3(0.0, 0.1, 1.35), Vector3.UP)
	if "--capture" in OS.get_cmdline_user_args():
		call_deferred("_capture")


func _capture() -> void:
	for frame in range(6):
		await get_tree().process_frame
	await get_tree().create_timer(0.30).timeout
	var output_path := ProjectSettings.globalize_path("res://artifacts/free_asset_v2_three_seams.png")
	var image := get_viewport().get_texture().get_image()
	if image == null or image.save_png(output_path) != OK:
		push_error("Could not capture the free-asset V2 seam study.")
		get_tree().quit(1)
		return
	print("FREE_ASSET_SEAM_CAPTURE: %s" % output_path)
	get_tree().quit()
