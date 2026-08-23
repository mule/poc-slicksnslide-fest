extends SceneTree

const OUTPUT_PATH := "res://docs/screenshots/foundation-placeholder.png"
const CAPTURE_SIZE := Vector2i(1280, 720)


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var main_scene := load("res://session/main.tscn") as PackedScene
	if main_scene == null:
		push_error("Cannot capture foundation scene: main scene did not load")
		quit(1)
		return

	var capture_viewport := SubViewport.new()
	capture_viewport.size = CAPTURE_SIZE
	capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(capture_viewport)

	var scene_root := main_scene.instantiate()
	capture_viewport.add_child(scene_root)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw

	var image := capture_viewport.get_texture().get_image()
	var save_error := image.save_png(OUTPUT_PATH)
	if save_error != OK:
		push_error("Cannot save foundation screenshot: error %d" % save_error)
		quit(1)
		return

	print("Saved foundation screenshot to %s" % ProjectSettings.globalize_path(OUTPUT_PATH))
	quit(0)
