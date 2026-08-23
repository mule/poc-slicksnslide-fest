extends SceneTree

const GAMEPLAY_OUTPUT := "res://docs/screenshots/issue-5-gameplay-1280x720.png"
const PAUSE_OUTPUT := "res://docs/screenshots/issue-5-pause-1280x800.png"


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var main_scene := load("res://session/main.tscn") as PackedScene
	if main_scene == null:
		push_error("Cannot capture issue #5: main scene did not load")
		quit(1)
		return

	var capture_viewport := SubViewport.new()
	capture_viewport.size = Vector2i(1280, 720)
	capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(capture_viewport)
	var session = main_scene.instantiate()
	capture_viewport.add_child(session)
	await _settle_frames()
	if not await _save_viewport(capture_viewport, GAMEPLAY_OUTPUT):
		return

	capture_viewport.size = Vector2i(1280, 800)
	session.call("set_session_paused", true)
	await _settle_frames()
	if not await _save_viewport(capture_viewport, PAUSE_OUTPUT):
		return

	paused = false
	print("Saved issue #5 gameplay and pause captures")
	quit(0)


func _settle_frames() -> void:
	for _frame in range(3):
		await process_frame
	await RenderingServer.frame_post_draw


func _save_viewport(viewport: SubViewport, output_path: String) -> bool:
	var image := viewport.get_texture().get_image()
	var save_error := image.save_png(output_path)
	if save_error == OK:
		return true
	push_error("Cannot save %s: error %d" % [output_path, save_error])
	quit(1)
	return false
