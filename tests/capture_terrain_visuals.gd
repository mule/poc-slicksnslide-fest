extends SceneTree

## Graphical desktop evidence for the terrain visuals: stills of the production session, with the
## diagnostics overlay off, where the elevation cues are strongest on the chosen seed. The road's
## steepest sample shows the directional cue (one face lit, the other in shade); its highest and
## lowest samples show the height tint; the highest- and lowest-standing trees show the shadow
## lengthening. Every position is found by asking the runtime's own height query, and every value
## printed beside a still is the value that still was drawn from. Run windowed, not headless:
##   godot --path . --script res://tests/capture_terrain_visuals.gd

const MAIN_SCENE_PATH := "res://session/main.tscn"
const OUTPUT_DIRECTORY := "res://docs/evidence/terrain"
const TRACE_PATH := OUTPUT_DIRECTORY + "/terrain-visuals-trace.txt"
const CAPTURE_SEED := 0
const WARMUP_FRAMES := 30

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	_check(directory_error == OK, "evidence output directory exists")
	var main_scene := load(MAIN_SCENE_PATH) as PackedScene
	_check(main_scene != null, "the production main scene loads")
	var lines: Array[String] = []
	lines.append("# Terrain visuals desktop trace")
	lines.append("# renderer=graphical SubViewport=1280x720 seed=%d overlay=off" % CAPTURE_SEED)
	lines.append("# light from the screen's top-left; brightness = 1 + %.2f * height/%.1f + %.2f * light_term" % [
		TerrainShading.HEIGHT_CONTRAST, TrackHeightMap.DEFAULT_TERRAIN_CATALOG.total_amplitude(), TerrainShading.SLOPE_CONTRAST,
	])
	_check(await _capture_stills(main_scene, lines), "the still capture ran to completion")
	var file := FileAccess.open(ProjectSettings.globalize_path(TRACE_PATH), FileAccess.WRITE)
	_check(file != null, "the trace file opens")
	if file != null:
		file.store_string("\n".join(lines) + "\n")
		file.close()
	_finish()


func _capture_stills(main_scene: PackedScene, lines: Array[String]) -> bool:
	var context := await _open_session(main_scene, CAPTURE_SEED)
	var viewport: SubViewport = context["viewport"]
	var camera: Camera2D = context["camera"]
	var car: TopDownCar = context["car"]
	var runtime: TrackRuntime = context["runtime"]
	var definition: TrackDefinition = runtime.definition
	var query := runtime.height_query()
	var shading := runtime.get_node("TerrainShading") as TerrainShading
	# The road's steepest, highest and lowest samples, by the runtime's own query.
	var steepest := -1
	var highest := -1
	var lowest := -1
	var steepest_slope := -INF
	var highest_height := -INF
	var lowest_height := INF
	for index in range(definition.centerline.size()):
		var sample := query.sample_at(definition.centerline[index])
		if sample.on_feature:
			continue
		var slope := absf(sample.gradient.dot(TerrainShading.LIGHT_DIRECTION))
		if slope > steepest_slope:
			steepest_slope = slope
			steepest = index
		if sample.ground_height > highest_height:
			highest_height = sample.ground_height
			highest = index
		if sample.ground_height < lowest_height:
			lowest_height = sample.ground_height
			lowest = index
	_check(steepest >= 0 and highest >= 0 and lowest >= 0, "the road has terrain-only samples to frame")
	_check(highest_height - lowest_height > 20.0, "the lap spans %.1f px of height, enough for a tint to read" % (highest_height - lowest_height))
	var shots := {
		"slope": steepest,
		"crest": highest,
		"hollow": lowest,
	}
	for shot_name in shots.keys():
		var index: int = shots[shot_name]
		var position := definition.centerline[index]
		var heading := (definition.centerline[(index + 1) % definition.centerline.size()] - position).normalized()
		_check(await _seat_car(car, position, heading), "the car is seated for the %s still" % shot_name)
		var sample := query.sample_at(car.global_position)
		var tint := shading.shade(TrackRuntime.DIRT_COLOR, sample)
		lines.append("still=%s file=seed-%d-%s.png position=(%.1f, %.1f) height=%.2f gradient=(%.4f, %.4f) height_term=%.3f light_term=%.3f dirt_brightness=%.3f car_height=%.2f" % [
			shot_name, CAPTURE_SEED, shot_name, car.global_position.x, car.global_position.y, sample.ground_height, sample.gradient.x, sample.gradient.y,
			shading.height_term(sample.ground_height), shading.light_term(sample.gradient), tint.r / TrackRuntime.DIRT_COLOR.r, car.get_height(),
		])
		_check(absf(car.get_height() - sample.ground_height) < 1e-6, "the %s still's car rides at the height its tint was drawn from" % shot_name)
		_check(await _save(viewport, camera, car.global_position, "seed-%d-%s.png" % [CAPTURE_SEED, shot_name]), "the %s still is saved" % shot_name)
	# The highest- and lowest-standing trees: same archetype, different ground, different shadows.
	var high_tree: OfftrackObjectPlacement = null
	var low_tree: OfftrackObjectPlacement = null
	var high_tree_height := -INF
	var low_tree_height := INF
	for placement in definition.offtrack_objects:
		if placement == null or placement.archetype_id != &"tree":
			continue
		var height := query.sample_at(placement.transform.origin).ground_height
		if height > high_tree_height:
			high_tree_height = height
			high_tree = placement
		if height < low_tree_height:
			low_tree_height = height
			low_tree = placement
	_check(high_tree != null and low_tree != null and high_tree != low_tree, "the seed places trees on different ground")
	if high_tree != null and low_tree != null:
		for pair in [["tree-high", high_tree, high_tree_height], ["tree-low", low_tree, low_tree_height]]:
			var shot_name: String = pair[0]
			var tree: OfftrackObjectPlacement = pair[1]
			var height: float = pair[2]
			var visual := runtime.get_node("OfftrackObjects/Visuals/SolidObjects/%s" % tree.stable_id.replace(":", "_"))
			var shadow := visual.get_child(0) as Polygon2D
			lines.append("still=%s file=seed-%d-%s.png tree=%s position=(%.1f, %.1f) height=%.2f shadow_factor=%.3f shadow_offset_px=%.2f" % [
				shot_name, CAPTURE_SEED, shot_name, tree.stable_id, tree.transform.origin.x, tree.transform.origin.y, height,
				TerrainShading.shadow_length_factor(height), shadow.position.length() * tree.scale_factor,
			])
			_check(await _save(viewport, camera, tree.transform.origin, "seed-%d-%s.png" % [CAPTURE_SEED, shot_name]), "the %s still is saved" % shot_name)
		_check(high_tree_height - low_tree_height > 20.0, "the two trees stand %.1f px apart in height" % (high_tree_height - low_tree_height))
	_close_session(context)
	await process_frame
	return true


func _open_session(main_scene: PackedScene, seed: int) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var session := main_scene.instantiate() as MainSession
	viewport.add_child(session)
	await process_frame
	session.restart_with_seed(seed)
	for frame in range(WARMUP_FRAMES):
		await process_frame
	var runtime := session.get_node("World/TrackMount/GeneratedTrack") as TrackRuntime
	var car := session.get_node("World/VehicleMount/PlayerCar") as TopDownCar
	car.set_auto_reset_enabled(false)
	# The diagnostics overlay is what the acceptance criterion says the hill must read without.
	var overlay := session.get_node("%DiagnosticsOverlay") as DiagnosticsOverlay
	overlay.set_release_mode(true)
	# The session pauses the SceneTree when the window loses focus; on a desktop where this window
	# never holds focus a paused tree would leave the car unseated. See
	# capture_height_channel_evidence.gd for the full account.
	var lifecycle := session.get_node("ApplicationLifecycle")
	var suspension := Callable(session, "_on_application_suspension_requested")
	if lifecycle.suspension_requested.is_connected(suspension):
		lifecycle.suspension_requested.disconnect(suspension)
	session.set_session_paused(false)
	_check(not paused, "the scene tree is running for this capture session")
	var camera := Camera2D.new()
	camera.name = "TerrainCaptureCamera"
	camera.top_level = true
	camera.zoom = Vector2.ONE * car.tuning.camera_zoom
	session.add_child(camera)
	camera.make_current()
	return {"viewport": viewport, "session": session, "runtime": runtime, "car": car, "camera": camera}


func _close_session(context: Dictionary) -> void:
	var viewport: SubViewport = context["viewport"]
	viewport.free()


## Parks the car at the position through its own safe-reset path, so its ride height is the one
## the session's height query gives there.
func _seat_car(car: TopDownCar, position: Vector2, heading: Vector2) -> bool:
	var pose := Transform2D(heading.angle() + PI * 0.5, position)
	if not car.set_safe_reset_pose(pose):
		return false
	car.request_safe_reset()
	await physics_frame
	await physics_frame
	return not car.is_airborne()


func _save(viewport: SubViewport, camera: Camera2D, focus: Vector2, file_name: String) -> bool:
	camera.global_position = focus
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	return image.save_png(ProjectSettings.globalize_path("%s/%s" % [OUTPUT_DIRECTORY, file_name])) == OK


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Terrain visuals capture passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Terrain visuals capture failed: %s" % failure)
	quit(1)
