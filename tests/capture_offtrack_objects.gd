extends SceneTree

const MAIN_SCENE_PATH := "res://session/main.tscn"
const OUTPUT_DIRECTORY := "res://docs/evidence/offtrack-objects"
const CAPTURE_SEEDS := [0, 4, 9]

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	_check(directory_error == OK, "off-track capture output directory exists")
	var main_scene := load(MAIN_SCENE_PATH) as PackedScene
	_check(main_scene != null, "main session scene loads for off-track captures")
	if main_scene != null and directory_error == OK:
		for seed in CAPTURE_SEEDS:
			_check(await _capture_seed(main_scene, seed), "seed %d graphical capture completed" % seed)
	_finish()


func _capture_seed(main_scene: PackedScene, seed: int) -> bool:
	var session := main_scene.instantiate() as MainSession
	_check(session != null, "seed %d instantiates a main session" % seed)
	if session == null:
		return false
	var capture_viewport := SubViewport.new()
	capture_viewport.size = Vector2i(1280, 720)
	capture_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(capture_viewport)
	capture_viewport.add_child(session)
	await process_frame
	session.restart_with_seed(seed)
	await process_frame
	await process_frame
	await process_frame
	await physics_frame
	var capture_target := _capture_target(seed)
	var follow_camera := session.get_node_or_null("World/VehicleMount/PlayerCar/FollowCamera") as Camera2D
	_check(follow_camera != null, "seed %d exposes its follow camera for deterministic framing" % seed)
	if follow_camera != null:
		var capture_camera := Camera2D.new()
		capture_camera.name = "OfftrackEvidenceCamera"
		capture_camera.top_level = true
		capture_camera.zoom = follow_camera.zoom
		session.add_child(capture_camera)
		capture_camera.global_position = capture_target
		capture_camera.make_current()
		capture_camera.force_update_scroll()
	await RenderingServer.frame_post_draw
	var image := capture_viewport.get_texture().get_image()
	var path := "%s/seed-%d.png" % [OUTPUT_DIRECTORY, seed]
	var error := image.save_png(ProjectSettings.globalize_path(path))
	_check(error == OK, "seed %d capture saves" % seed)
	var snapshot := session.get_session_snapshot()
	print("capture seed=%d dimensions=%dx%d road=%s objects=%s" % [
		seed,
		image.get_width(),
		image.get_height(),
		snapshot.get("geometry_fingerprint", ""),
		snapshot.get("offtrack_object_fingerprint", ""),
	])
	capture_viewport.free()
	await process_frame
	return error == OK


func _capture_target(seed: int) -> Vector2:
	var definition: TrackDefinition = TrackGenerator.new().generate(seed)
	var target := definition.spawn_transform.origin
	var nearest_distance := INF
	for placement in definition.offtrack_objects:
		if placement == null or not placement.solid:
			continue
		var distance := placement.transform.origin.distance_to(definition.spawn_transform.origin)
		if distance < nearest_distance:
			nearest_distance = distance
			target = definition.spawn_transform.origin.lerp(placement.transform.origin, 0.5)
	print("capture framing seed=%d target=(%.1f, %.1f) nearest_solid_distance=%.1f" % [seed, target.x, target.y, nearest_distance])
	return target


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("offtrack_capture checks=%d" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Off-track capture check failed: %s" % failure)
	print("offtrack_capture checks=%d failures=%d" % [_checks, _failures.size()])
	quit(1)
