extends SceneTree

## Graphical desktop evidence for the objects on the terrain (#51): stills of the production
## session, overlay off, at seed 0's highest- and lowest-standing tree and highest rock, and the
## car parked beside the highest tree so the two lifts can be compared on one hill. Every position
## is found by asking the runtime's own height query, and every value printed beside a still is
## the value that still was drawn from. Run windowed, not headless:
##   godot --path . --script res://tests/capture_offtrack_object_terrain.gd

const MAIN_SCENE_PATH := "res://session/main.tscn"
const OUTPUT_DIRECTORY := "res://docs/evidence/terrain"
const TRACE_PATH := OUTPUT_DIRECTORY + "/object-terrain-trace.txt"
const CAPTURE_SEED := 0
const WARMUP_FRAMES := 30
## The car is parked this far from the tree, along the screen's x axis, so both stand on nearly
## the same ground and neither covers the other.
const CAR_BESIDE_OFFSET := Vector2(-70.0, 0.0)

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
	lines.append("# Off-track objects on terrain desktop trace")
	lines.append("# renderer=graphical SubViewport=1280x720 seed=%d overlay=off lift_px_per_px=%.2f contrast_floor=%.2f" % [CAPTURE_SEED, TerrainShading.LIFT_PIXELS_PER_PIXEL, TerrainShading.BODY_CONTRAST_FLOOR])
	_check(await _capture_stills(main_scene, lines), "the still capture ran to completion")
	var file := FileAccess.open(ProjectSettings.globalize_path(TRACE_PATH), FileAccess.WRITE)
	_check(file != null, "the trace file opens")
	if file != null:
		file.store_string("\n".join(lines) + "\n")
		file.close()
	_finish()


func _extreme(placements: Array[OfftrackObjectPlacement], query: HeightQuery, archetype_id: StringName, highest: bool) -> OfftrackObjectPlacement:
	var best: OfftrackObjectPlacement = null
	var best_height := -INF if highest else INF
	for placement in placements:
		if placement == null or placement.archetype_id != archetype_id:
			continue
		var height := query.sample_at(placement.transform.origin).ground_height
		if (highest and height > best_height) or (not highest and height < best_height):
			best_height = height
			best = placement
	return best


func _capture_stills(main_scene: PackedScene, lines: Array[String]) -> bool:
	var context := await _open_session(main_scene, CAPTURE_SEED)
	var viewport: SubViewport = context["viewport"]
	var camera: Camera2D = context["camera"]
	var car: TopDownCar = context["car"]
	var runtime: TrackRuntime = context["runtime"]
	var definition: TrackDefinition = runtime.definition
	var query := runtime.height_query()
	var shading := runtime.get_node("TerrainShading") as TerrainShading
	var shots := [
		["object-high", _extreme(definition.offtrack_objects, query, &"tree", true)],
		["object-low", _extreme(definition.offtrack_objects, query, &"tree", false)],
		["rock-high", _extreme(definition.offtrack_objects, query, &"rock", true)],
	]
	# Park the car out of every frame first, so the object stills show the object alone.
	_check(await _seat_car(car, definition.spawn_transform.origin, definition.forward_direction), "the car is parked at the spawn, out of frame")
	for shot in shots:
		var shot_name: String = shot[0]
		var placement: OfftrackObjectPlacement = shot[1]
		_check(placement != null, "seed %d places a %s for the %s still" % [CAPTURE_SEED, "tree" if shot_name != "rock-high" else "rock", shot_name])
		if placement == null:
			continue
		var sample := query.sample_at(placement.transform.origin)
		var visual := runtime.get_node("OfftrackObjects/Visuals/SolidObjects/%s" % placement.stable_id.replace(":", "_")) as Node2D
		var shadow := visual.get_child(0) as Polygon2D
		var body := visual.get_child(1) as Polygon2D
		var lift := visual.transform.basis_xform(body.position)
		var ground := shading.shade(TerrainShading.GROUND_COLOR, sample)
		# How far the body polygon reaches below its own origin on screen (rotation and scale
		# applied), and so where its base ends up relative to the foot once lifted: positive is
		# above the foot, a gap of tinted ground between base and shadow.
		var body_extent_below := -INF
		for point in body.polygon:
			body_extent_below = maxf(body_extent_below, visual.transform.basis_xform(point).y)
		var base_above_foot := -(lift.y + body_extent_below)
		lines.append("still=%s file=seed-%d-%s.png object=%s position=(%.1f, %.1f) height=%.2f lift_px=%.2f body_extent_below_origin_px=%.2f body_base_above_foot_px=%.2f shadow_factor=%.3f shadow_offset_px=%.2f body_luminance=%.3f ground_luminance=%.3f ratio=%.3f" % [
			shot_name, CAPTURE_SEED, shot_name, placement.stable_id, placement.transform.origin.x, placement.transform.origin.y, sample.ground_height,
			-lift.y, body_extent_below, base_above_foot, TerrainShading.shadow_length_factor(sample.ground_height), shadow.position.length() * placement.scale_factor,
			body.color.get_luminance(), ground.get_luminance(), body.color.get_luminance() / ground.get_luminance(),
		])
		_check(is_equal_approx(lift.y, -sample.ground_height * TerrainShading.LIFT_PIXELS_PER_PIXEL), "the %s still's body is lifted by the ground height its tint was drawn from" % shot_name)
		_check(await _save(viewport, camera, placement.transform.origin, "seed-%d-%s.png" % [CAPTURE_SEED, shot_name]), "the %s still is saved" % shot_name)
	# The car beside the highest tree: two lifts on one hill.
	var high_tree: OfftrackObjectPlacement = shots[0][1]
	if high_tree != null:
		var beside := high_tree.transform.origin + CAR_BESIDE_OFFSET
		_check(await _seat_car(car, beside, Vector2.UP), "the car is parked beside the highest tree")
		# The map's miss path hands back one shared sample rewritten on every query, so each height
		# is read before the next query is made.
		var car_ground := query.sample_at(car.global_position).ground_height
		var tree_ground := query.sample_at(high_tree.transform.origin).ground_height
		lines.append("still=car-beside-high file=seed-%d-car-beside-high.png tree=%s car_position=(%.1f, %.1f) car_height=%.2f tree_height=%.2f car_lift_px=%.2f tree_lift_px=%.2f car_heading=up" % [
			CAPTURE_SEED, high_tree.stable_id, car.global_position.x, car.global_position.y, car.get_height(), tree_ground,
			car.get_height() * car.tuning.lift_pixels_per_pixel, tree_ground * TerrainShading.LIFT_PIXELS_PER_PIXEL,
		])
		_check(absf(car.get_height() - car_ground) < 1e-6, "the parked car rides at the ground height beside the tree (%.2f vs %.2f px)" % [car.get_height(), car_ground])
		_check(absf(car_ground - tree_ground) < 5.0, "the car and the tree stand on nearly the same ground (%.2f vs %.2f px)" % [car_ground, tree_ground])
		_check(await _save(viewport, camera, high_tree.transform.origin + CAR_BESIDE_OFFSET * 0.5, "seed-%d-car-beside-high.png" % CAPTURE_SEED), "the car-beside-high still is saved")
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
	var overlay := session.get_node("%DiagnosticsOverlay") as DiagnosticsOverlay
	overlay.set_release_mode(true)
	# The session pauses the SceneTree when the window loses focus; see
	# capture_height_channel_evidence.gd for the full account.
	var lifecycle := session.get_node("ApplicationLifecycle")
	var suspension := Callable(session, "_on_application_suspension_requested")
	if lifecycle.suspension_requested.is_connected(suspension):
		lifecycle.suspension_requested.disconnect(suspension)
	session.set_session_paused(false)
	_check(not paused, "the scene tree is running for this capture session")
	var camera := Camera2D.new()
	camera.name = "ObjectCaptureCamera"
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
		print("Off-track object terrain capture passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Off-track object terrain capture failed: %s" % failure)
	quit(1)
