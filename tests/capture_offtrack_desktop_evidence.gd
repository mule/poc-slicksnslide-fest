extends SceneTree

## Graphical, deterministic desktop evidence.  This intentionally measures the real MainSession
## in a 1280x720 SubViewport and drives its production car into a generated solid placement.
## It is not a synthetic CharacterBody collision probe.

const MAIN_SCENE_PATH := "res://session/main.tscn"
const OUTPUT_DIRECTORY := "res://docs/evidence/offtrack-objects"
const TRACE_PATH := OUTPUT_DIRECTORY + "/desktop-trace-seeds-0-4-9.txt"
const TRACE_SEEDS := [0, 4, 9]
const WARMUP_FRAMES := 120
const SAMPLE_FRAMES := 240

var _failures: Array[String] = []
var _checks := 0
var _impact_bodies: Array[Node] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	_check(directory_error == OK, "desktop evidence output directory exists")
	var main_scene := load(MAIN_SCENE_PATH) as PackedScene
	_check(main_scene != null, "desktop evidence main session loads")
	var trace_lines: Array[String] = []
	trace_lines.append("# Off-track objects warmed desktop trace")
	trace_lines.append("# renderer=graphical SubViewport=1280x720 warmup_frames=%d sample_frames=%d" % [WARMUP_FRAMES, SAMPLE_FRAMES])
	if main_scene != null and directory_error == OK:
		for seed in TRACE_SEEDS:
			_check(await _record_seed(main_scene, seed, trace_lines), "seed %d warmed desktop trace completed" % seed)
		_check(await _capture_generated_solid_impact(main_scene, trace_lines), "production car generated-solid impact capture completed")
	var trace_file := FileAccess.open(ProjectSettings.globalize_path(TRACE_PATH), FileAccess.WRITE)
	_check(trace_file != null, "desktop trace file opens")
	if trace_file != null:
		trace_file.store_string("\n".join(trace_lines) + "\n")
		trace_file.close()
	_finish()


func _record_seed(main_scene: PackedScene, seed: int, trace_lines: Array[String]) -> bool:
	var viewport := _new_viewport()
	root.add_child(viewport)
	var session := main_scene.instantiate() as MainSession
	_check(session != null, "seed %d instantiates production session" % seed)
	if session == null:
		viewport.free()
		return false
	viewport.add_child(session)
	await process_frame
	session.restart_with_seed(seed)
	for _frame in range(WARMUP_FRAMES):
		await process_frame
	var frame_usec: Array[int] = []
	var memory_bytes: Array[int] = []
	var previous_usec := Time.get_ticks_usec()
	for _frame in range(SAMPLE_FRAMES):
		await process_frame
		var now_usec := Time.get_ticks_usec()
		frame_usec.append(now_usec - previous_usec)
		previous_usec = now_usec
		memory_bytes.append(int(Performance.get_monitor(Performance.MEMORY_STATIC)))
	var runtime := session.get_node_or_null("World/TrackMount/GeneratedTrack") as TrackRuntime
	var objects := runtime.get_node_or_null("OfftrackObjects") as OfftrackObjectRuntime if runtime != null else null
	var metrics := objects.get_metrics() if objects != null else {}
	var snapshot := session.get_session_snapshot()
	_check(runtime != null and objects != null, "seed %d production generated runtime is mounted" % seed)
	_check(int(metrics.get("visuals", -1)) > 0 and int(metrics.get("colliders", -1)) > 0, "seed %d trace observes generated visuals and colliders" % seed)
	trace_lines.append("seed=%d nodes=%d visuals=%d batches=%d solid_visuals=%d colliders=%d collision_chunks=%d frame_usec_min=%d frame_usec_p50=%d frame_usec_p95=%d frame_usec_p99=%d frame_usec_max=%d memory_bytes_min=%d memory_bytes_max=%d memory_mib_min=%.3f memory_mib_max=%.3f road=%s objects=%s" % [
		seed,
		_count_nodes(root),
		int(metrics.get("visuals", -1)),
		int(metrics.get("decorative_batches", -1)),
		int(metrics.get("solid_visuals", -1)),
		int(metrics.get("colliders", -1)),
		int(metrics.get("collision_chunks", -1)),
		_minimum(frame_usec),
		_percentile(frame_usec, 0.50),
		_percentile(frame_usec, 0.95),
		_percentile(frame_usec, 0.99),
		_maximum(frame_usec),
		_minimum(memory_bytes),
		_maximum(memory_bytes),
		float(_minimum(memory_bytes)) / (1024.0 * 1024.0),
		float(_maximum(memory_bytes)) / (1024.0 * 1024.0),
		str(snapshot.get("geometry_fingerprint", "")),
		str(snapshot.get("offtrack_object_fingerprint", "")),
	])
	var completed := runtime != null and objects != null and not frame_usec.is_empty()
	viewport.free()
	await process_frame
	return completed


func _capture_generated_solid_impact(main_scene: PackedScene, trace_lines: Array[String]) -> bool:
	const seed := 0
	var viewport := _new_viewport()
	root.add_child(viewport)
	var session := main_scene.instantiate() as MainSession
	_check(session != null, "impact capture instantiates production session")
	if session == null:
		viewport.free()
		return false
	viewport.add_child(session)
	await process_frame
	session.restart_with_seed(seed)
	for _frame in range(6):
		await process_frame
		await physics_frame
	var runtime := session.get_node_or_null("World/TrackMount/GeneratedTrack") as TrackRuntime
	var definition: TrackDefinition = runtime.definition if runtime != null else null
	var collisions := runtime.get_node_or_null("OfftrackObjects/Collisions") as OfftrackObjectCollisions if runtime != null else null
	var car := session.get_node_or_null("World/VehicleMount/PlayerCar") as TopDownCar
	var target_data := _find_generated_impact_target(definition, collisions, car)
	var target := target_data.get("placement") as OfftrackObjectPlacement
	var target_shape := target_data.get("shape") as CollisionShape2D
	var target_body := target_data.get("body") as StaticBody2D
	var start: Vector2 = target_data.get("start", Vector2.ZERO)
	var direction: Vector2 = target_data.get("direction", Vector2.RIGHT)
	var preimpact_shape_index: int = int(target_data.get("ray_shape_index", -1))
	_check(target != null and target_shape != null and target_body != null, "impact target is a generated solid with a runtime collision shape")
	_check(car != null, "impact capture uses the production TopDownCar")
	if target == null or target_shape == null or target_body == null or car == null:
		viewport.free()
		return false
	car.global_transform = Transform2D(direction.angle() + PI * 0.5, start)
	car.linear_velocity = direction * car.tuning.max_safe_speed
	car.angular_velocity = 0.0
	car.sleeping = false
	_impact_bodies.clear()
	car.body_entered.connect(_record_impact_body)
	var collision_before := car.get_collision_count()
	for _tick in range(180):
		await physics_frame
		if car.get_collision_count() > collision_before:
			break
	var impact_body: Node = _impact_bodies.back() if not _impact_bodies.is_empty() else null
	var target_shape_index := target_shape.get_index()
	_check(car.get_collision_count() > collision_before, "production car recorded a physics contact")
	_check(impact_body == target_body, "impact event body is the generated solid chunk")
	_check(preimpact_shape_index == target_shape_index, "pre-impact ray identifies generated placement %s" % target.stable_id)
	_check(car.global_position.distance_to(target.transform.origin) < start.distance_to(target.transform.origin), "production car moved toward the generated solid")
	var camera := Camera2D.new()
	camera.name = "GeneratedSolidImpactCamera"
	camera.top_level = true
	camera.zoom = Vector2.ONE * car.tuning.camera_zoom
	session.add_child(camera)
	camera.global_position = car.global_position.lerp(target.transform.origin, 0.5)
	camera.make_current()
	camera.force_update_scroll()
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	var output_path := "%s/seed-%d-generated-solid-impact.png" % [OUTPUT_DIRECTORY, seed]
	var save_error := image.save_png(ProjectSettings.globalize_path(output_path))
	_check(save_error == OK, "production car generated-solid impact PNG saves")
	trace_lines.append("impact seed=%d stable_id=%s archetype=%s target_shape_index=%d collision_before=%d collision_after=%d preimpact_ray_shape_index=%d contact_body=%s car_x=%.3f target_x=%.3f speed=%.3f image=%s dimensions=%dx%d" % [
		seed,
		target.stable_id,
		target.archetype_id,
		target_shape_index,
		collision_before,
		car.get_collision_count(),
		preimpact_shape_index,
		impact_body.name if impact_body != null else "",
		car.global_position.x,
		target.transform.origin.x,
		car.get_speed(),
		output_path,
		image.get_width(),
		image.get_height(),
	])
	var completed := save_error == OK and car.get_collision_count() > collision_before and impact_body == target_body and preimpact_shape_index == target_shape_index
	viewport.free()
	await process_frame
	return completed


func _new_viewport() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	return viewport


func _first_generated_solid(definition: TrackDefinition) -> OfftrackObjectPlacement:
	if definition == null:
		return null
	for placement in definition.offtrack_objects:
		if placement != null and placement.solid:
			return placement
	return null


func _find_generated_impact_target(definition: TrackDefinition, collisions: OfftrackObjectCollisions, car: TopDownCar) -> Dictionary:
	if definition == null or collisions == null or car == null:
		return {}
	var directions := [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]
	for placement in definition.offtrack_objects:
		if placement == null or not placement.solid:
			continue
		var shape := _find_collision_shape(collisions, placement.stable_id.replace(":", "_"))
		var body := shape.get_parent() as StaticBody2D if shape != null else null
		if shape == null or body == null:
			continue
		for direction in directions:
			var start: Vector2 = placement.transform.origin - direction * WorldScale.metres(20.0)
			var query := PhysicsRayQueryParameters2D.create(start, placement.transform.origin)
			query.collision_mask = OfftrackObjectCollisions.TALL_LAYER | OfftrackObjectCollisions.LOW_LAYER
			query.exclude = [car.get_rid()]
			var hit := car.get_world_2d().direct_space_state.intersect_ray(query)
			if hit.get("collider") == body and int(hit.get("shape", -1)) == shape.get_index():
				return {
					"placement": placement,
					"shape": shape,
					"body": body,
					"start": start,
					"direction": direction,
					"ray_shape_index": int(hit.get("shape", -1)),
				}
	return {}


func _find_collision_shape(node: Node, stable_name: String) -> CollisionShape2D:
	if node == null:
		return null
	for child in node.get_children():
		if child is CollisionShape2D and child.name == stable_name:
			return child
		var found := _find_collision_shape(child, stable_name)
		if found != null:
			return found
	return null


func _record_impact_body(body: Node) -> void:
	_impact_bodies.append(body)


func _count_nodes(node: Node) -> int:
	var count := 1
	for child in node.get_children():
		count += _count_nodes(child)
	return count


func _percentile(values: Array[int], ratio: float) -> int:
	if values.is_empty():
		return 0
	var ordered := values.duplicate()
	ordered.sort()
	return ordered[clampi(ceili(ratio * ordered.size()) - 1, 0, ordered.size() - 1)]


func _minimum(values: Array[int]) -> int:
	var result := values[0]
	for value in values:
		result = mini(result, value)
	return result


func _maximum(values: Array[int]) -> int:
	var result := values[0]
	for value in values:
		result = maxi(result, value)
	return result


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("offtrack_desktop_evidence checks=%d" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Off-track desktop evidence failed: %s" % failure)
	print("offtrack_desktop_evidence checks=%d failures=%d" % [_checks, _failures.size()])
	quit(1)
