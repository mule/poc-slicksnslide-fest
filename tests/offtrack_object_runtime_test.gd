extends SceneTree

const MAIN_SCENE_PATH := "res://session/main.tscn"

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load(MAIN_SCENE_PATH) as PackedScene
	_check(main_scene != null, "main session scene loads for off-track seed restart coverage")
	_check(_verify_generated_runtime(), "generated off-track runtime verification completed")
	if main_scene != null:
		_check(await _verify_seed_restart(main_scene), "seed restart off-track runtime verification completed")
	_finish()


func _verify_generated_runtime() -> bool:
	var generator := TrackGenerator.new()
	var definition: TrackDefinition = generator.generate(0)
	_check(not definition.offtrack_objects.is_empty(), "seed 0 carries generated off-track objects")
	_check(definition.offtrack_object_fingerprint.length() == 64, "seed 0 carries an object fingerprint")
	_check(
		is_finite(float(definition.offtrack_object_generation_usec)) and definition.offtrack_object_generation_usec > 0,
		"seed 0 carries finite positive object generation timing"
	)
	_check(
		_verify_object_diagnostics(definition.offtrack_object_diagnostics, definition.offtrack_objects),
		"seed 0 carries placement diagnostics consistent with generated objects"
	)
	var repeated: TrackDefinition = generator.generate(0)
	_check(repeated.geometry_fingerprint == definition.geometry_fingerprint, "off-track placement leaves the road fingerprint unchanged")
	_check(repeated.offtrack_object_fingerprint == definition.offtrack_object_fingerprint, "same seed repeats the exact object fingerprint")
	var runtime := TrackRuntime.new(definition)
	root.add_child(runtime)
	var objects := runtime.get_node_or_null("OfftrackObjects")
	_check(objects != null, "track runtime mounts off-track objects")
	if objects == null:
		runtime.free()
		return false
	_check(objects.has_method("get_metrics"), "off-track runtime exposes runtime metrics")
	if not objects.has_method("get_metrics"):
		runtime.free()
		return false
	var metrics: Dictionary = objects.call("get_metrics")
	_check(int(metrics.get("visuals", -1)) == definition.offtrack_objects.size(), "every placement is visualized")
	_check(int(metrics.get("colliders", -1)) == _solid_count(definition.offtrack_objects), "every solid placement has one collider")
	var catalog := load("res://data/default_offtrack_object_catalog.tres") as OfftrackObjectCatalog
	_check(catalog != null, "default catalog loads for runtime transform verification")
	if catalog != null:
		_check(_verify_solid_transforms(objects, definition.offtrack_objects, catalog), "solid visual/collider transform verification completed")
	runtime.free()
	return true


func _verify_seed_restart(main_scene: PackedScene) -> bool:
	var session := main_scene.instantiate() as MainSession
	_check(session != null, "main scene instantiates a main session")
	if session == null:
		return false
	root.add_child(session)
	await process_frame
	var first_runtime := session.get_node_or_null("World/TrackMount/GeneratedTrack") as TrackRuntime
	_check(first_runtime != null, "session mounts the initial generated track runtime")
	_check(_verify_single_runtime_mount(session, first_runtime, "initial seed"), "initial seed mount integrity verification completed")
	var first_snapshot: Dictionary = session.get_session_snapshot()
	var first_fingerprint: String = str(first_snapshot.get("offtrack_object_fingerprint", ""))
	_check(first_fingerprint.length() == 64, "session snapshot exposes the initial object fingerprint")
	session.restart_with_seed(0)
	var repeated_runtime := session.get_node_or_null("World/TrackMount/GeneratedTrack") as TrackRuntime
	_check(not is_instance_valid(first_runtime), "same-seed restart frees the initial runtime immediately")
	_check(repeated_runtime != first_runtime, "same-seed restart mounts a distinct runtime")
	_check(_verify_single_runtime_mount(session, repeated_runtime, "same-seed restart"), "same-seed mount integrity verification completed")
	var repeated_fingerprint: String = str(session.get_session_snapshot().get("offtrack_object_fingerprint", ""))
	_check(repeated_fingerprint == first_fingerprint, "same-seed session restart repeats the object fingerprint")
	session.restart_with_seed(1)
	var second_runtime := session.get_node_or_null("World/TrackMount/GeneratedTrack") as TrackRuntime
	_check(second_runtime != null, "seed restart mounts a replacement generated track runtime")
	_check(not is_instance_valid(repeated_runtime), "different-seed restart frees the immediately preceding same-seed runtime")
	_check(second_runtime != repeated_runtime, "different-seed restart mounts a distinct runtime")
	_check(_verify_single_runtime_mount(session, second_runtime, "different-seed restart"), "different-seed mount integrity verification completed")
	var second_snapshot: Dictionary = session.get_session_snapshot()
	var second_fingerprint: String = str(second_snapshot.get("offtrack_object_fingerprint", ""))
	_check(second_fingerprint.length() == 64 and second_fingerprint != first_fingerprint, "different seeds produce different object fingerprints")
	if second_runtime != null:
		var objects := second_runtime.get_node_or_null("OfftrackObjects")
		_check(objects != null, "replacement runtime mounts exactly one off-track coordinator")
		if objects != null and objects.has_method("get_metrics"):
			var metrics: Dictionary = objects.call("get_metrics")
			_check(int(metrics.get("visuals", -1)) > 0, "replacement runtime has no stale empty visual batch")
			_check(int(metrics.get("colliders", -1)) == _solid_count(second_runtime.definition.offtrack_objects), "replacement runtime has no stale collision bodies")
	session.free()
	return true


func _verify_object_diagnostics(diagnostics: Dictionary, placements: Array[OfftrackObjectPlacement]) -> bool:
	_check(not diagnostics.is_empty(), "object diagnostics are non-empty")
	_check(int(diagnostics.get("total_cells", 0)) > 0, "object diagnostics report a non-empty placement domain")
	var zones: Dictionary = diagnostics.get("zones", {})
	var accepted_total := 0
	for zone_name in ["near_shoulder", "hazard"]:
		var zone: Dictionary = zones.get(zone_name, {})
		for counter in ["valid_cells", "occupied_draws", "accepted", "road_or_recovery", "containment", "spawn_checkpoint", "solid_overlap"]:
			_check(zone.has(counter) and int(zone.get(counter, -1)) >= 0, "%s diagnostics include non-negative %s" % [zone_name, counter])
		accepted_total += int(zone.get("accepted", 0))
	_check(accepted_total == placements.size(), "object diagnostic accepted counts equal generated placements")
	return true


func _verify_single_runtime_mount(session: MainSession, runtime: TrackRuntime, label: String) -> bool:
	var mount := session.get_node_or_null("World/TrackMount")
	_check(mount != null, "%s exposes the track mount" % label)
	if mount == null or runtime == null:
		return false
	_check(mount.get_child_count() == 1, "%s track mount has exactly one child" % label)
	var generated_count := 0
	for child in mount.get_children():
		if child.name == "GeneratedTrack":
			generated_count += 1
	_check(generated_count == 1 and mount.get_child(0) == runtime, "%s track mount has exactly one generated runtime" % label)
	var object_count := 0
	for child in runtime.get_children():
		if child.name == "OfftrackObjects":
			object_count += 1
	_check(object_count == 1, "%s generated runtime has exactly one off-track coordinator" % label)
	return true


func _solid_count(placements: Array[OfftrackObjectPlacement]) -> int:
	var count := 0
	for placement in placements:
		if placement != null and placement.solid:
			count += 1
	return count


func _verify_solid_transforms(objects: Node, placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> bool:
	var visuals := objects.get_node_or_null("Visuals/SolidObjects")
	var collisions := objects.get_node_or_null("Collisions")
	_check(visuals != null and collisions != null, "coordinator owns visual and collision consumers")
	if visuals == null or collisions == null:
		return false
	for placement in placements:
		if placement == null or not placement.solid:
			continue
		var stable_name := placement.stable_id.replace(":", "_")
		var visual := visuals.get_node_or_null(stable_name) as Node2D
		var collider := _find_collision_shape(collisions, stable_name)
		var archetype := catalog.archetype_by_id(placement.archetype_id)
		_check(visual != null, "%s solid visual is addressable by stable ID" % placement.stable_id)
		_check(collider != null, "%s solid collider is addressable by stable ID" % placement.stable_id)
		if visual == null or collider == null or archetype == null:
			return false
		_check(visual.position.is_equal_approx(placement.transform.origin), "%s visual position copies placement origin" % placement.stable_id)
		_check(is_equal_approx(visual.rotation, placement.transform.get_rotation()), "%s visual rotation copies placement rotation" % placement.stable_id)
		_check(collider.position.is_equal_approx(placement.transform.origin), "%s collider position copies placement origin" % placement.stable_id)
		_check(is_equal_approx(collider.rotation, placement.transform.get_rotation()), "%s collider rotation copies placement rotation" % placement.stable_id)
		var circle := collider.shape as CircleShape2D
		_check(circle != null and is_equal_approx(circle.radius, archetype.collision_radius * placement.scale_factor), "%s collider radius follows catalog and scale" % placement.stable_id)
	return true


func _find_collision_shape(node: Node, stable_name: String) -> CollisionShape2D:
	for child in node.get_children():
		if child is CollisionShape2D and child.name == stable_name:
			return child
		var found := _find_collision_shape(child, stable_name)
		if found != null:
			return found
	return null


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("offtrack_runtime checks=%d" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Off-track runtime check failed: %s" % failure)
	print("offtrack_runtime checks=%d failures=%d" % [_checks, _failures.size()])
	quit(1)
