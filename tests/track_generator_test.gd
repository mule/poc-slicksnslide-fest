extends SceneTree

const TRACK_GENERATOR_PATH := "res://track/track_generator.gd"
const SURFACE_MAP_PATH := "res://track/track_surface_map.gd"
const LAP_TRACKER_PATH := "res://track/lap_progress_tracker.gd"
const TRACK_RUNTIME_PATH := "res://track/track_runtime.gd"

const EXPECTED_MIN_WIDTH := 125.0
const EXPECTED_MAX_WIDTH := 175.0
const EXPECTED_MIN_LAP_LENGTH := 25000.0
const EXPECTED_MAX_LAP_LENGTH := 37500.0
const EXPECTED_MAX_CURVATURE := 0.005
const EXPECTED_MIN_START_STRAIGHT := 1875.0
const EXPECTED_MAX_SAMPLE_GAP := 30.0

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var started_usec := Time.get_ticks_usec()
	var generator_script := load(TRACK_GENERATOR_PATH) as GDScript
	_check(generator_script != null, "runtime generator script loads")
	if generator_script == null:
		_finish(started_usec)
		return

	var generator = generator_script.new()
	var definitions: Array = []
	var fingerprints: Dictionary = {}
	var accepted_count := 0
	var fallback_count := 0
	for seed in range(20):
		var definition = generator.generate(seed)
		definitions.append(definition)
		_verify_driveable_definition(definition, seed)
		if definition != null:
			if definition.used_fallback:
				fallback_count += 1
			else:
				fingerprints[definition.geometry_fingerprint] = true
				accepted_count += 1
			print("seed=%d fingerprint=%s generation_usec=%d attempts=%d fallback=%s" % [
				seed,
				definition.geometry_fingerprint,
				definition.generation_usec,
				definition.generation_attempts,
				definition.used_fallback,
			])
	_check(fallback_count <= 2, "at most 2 of 20 seeds fall back to the stadium (got %d)" % fallback_count)
	_check(fingerprints.size() == accepted_count, "accepted (non-fallback) seeds produce distinct geometry")

	_verify_determinism(generator, definitions)
	_verify_bounded_fallback(generator)
	_verify_surface_samples(definitions[0])
	_verify_lap_order(definitions[0])
	_verify_runtime_geometry(definitions[0])
	_finish(started_usec)


func _verify_driveable_definition(definition, seed: int) -> void:
	_check(definition != null, "seed %d produces a definition" % seed)
	if definition == null:
		return
	_check(definition.seed == seed, "seed %d is retained" % seed)
	_check(definition.generation_attempts >= 1 and definition.generation_attempts <= generator_attempt_limit(), "seed %d uses bounded attempts" % seed)
	_check(definition.track_width >= EXPECTED_MIN_WIDTH and definition.track_width <= EXPECTED_MAX_WIDTH, "seed %d width is within the driveable bound" % seed)
	_check(definition.lap_length >= EXPECTED_MIN_LAP_LENGTH and definition.lap_length <= EXPECTED_MAX_LAP_LENGTH, "seed %d lap length is within bounds" % seed)
	_check(definition.max_curvature <= EXPECTED_MAX_CURVATURE, "seed %d curvature is bounded" % seed)
	_check(definition.start_straight_length >= EXPECTED_MIN_START_STRAIGHT, "seed %d has an adequate start straight" % seed)
	_verify_world_exceeds_one_screen(definition, seed)
	_check(definition.geometry_fingerprint.length() == 64, "seed %d has a SHA-256 geometry fingerprint" % seed)
	_check(definition.centerline.size() >= 64, "seed %d is sampled densely" % seed)
	_check(definition.left_boundary.size() == definition.centerline.size(), "seed %d left boundary matches centerline sampling" % seed)
	_check(definition.right_boundary.size() == definition.centerline.size(), "seed %d right boundary matches centerline sampling" % seed)
	_check(definition.centerline[0].is_equal_approx(definition.centerline[-1]), "seed %d centerline is closed" % seed)
	_check(definition.left_boundary[0].is_equal_approx(definition.left_boundary[-1]), "seed %d left boundary is continuous at closure" % seed)
	_check(definition.right_boundary[0].is_equal_approx(definition.right_boundary[-1]), "seed %d right boundary is continuous at closure" % seed)
	_check(_maximum_gap(definition.centerline) <= EXPECTED_MAX_SAMPLE_GAP, "seed %d centerline sampling has no escape-sized gaps" % seed)
	_check(_maximum_gap(definition.left_boundary) <= EXPECTED_MAX_SAMPLE_GAP * 1.1, "seed %d left edge collision sampling is continuous" % seed)
	_check(_maximum_gap(definition.right_boundary) <= EXPECTED_MAX_SAMPLE_GAP * 1.1, "seed %d right edge collision sampling is continuous" % seed)
	_check(not _has_self_intersection(definition.centerline), "seed %d centerline does not self-intersect" % seed)
	_check(not _has_self_intersection(definition.left_boundary), "seed %d left boundary does not self-intersect" % seed)
	_check(not _has_self_intersection(definition.right_boundary), "seed %d right boundary does not self-intersect" % seed)
	_check(not _boundaries_intersect(definition.left_boundary, definition.right_boundary), "seed %d boundaries do not overlap" % seed)
	_check(definition.spawn_transform.origin.is_equal_approx(definition.centerline[0]), "seed %d spawn is on the start line" % seed)
	_check((-definition.spawn_transform.y).normalized().dot(definition.forward_direction.normalized()) > 0.999, "seed %d vehicle-local forward axis faces the first segment" % seed)
	_check(definition.checkpoints.size() == 8, "seed %d supplies eight ordered checkpoints" % seed)
	for checkpoint_index in range(definition.checkpoints.size()):
		var expected_sample := int(round(float(checkpoint_index) * float(definition.centerline.size() - 1) / float(definition.checkpoints.size())))
		_check(definition.checkpoints[checkpoint_index].origin.distance_to(definition.centerline[expected_sample]) < EXPECTED_MAX_SAMPLE_GAP, "seed %d checkpoint %d follows centerline order" % [seed, checkpoint_index])


func _verify_world_exceeds_one_screen(definition, seed: int) -> void:
	_check(definition.bounds.size.x >= 5000.0, "seed %d spans several screens horizontally (%.0f px)" % [seed, definition.bounds.size.x])
	_check(definition.bounds.size.y >= 5000.0, "seed %d spans several screens vertically (%.0f px)" % [seed, definition.bounds.size.y])


func _verify_determinism(generator, originals: Array) -> void:
	for seed in range(10):
		var regenerated = generator.generate(seed)
		var original = originals[seed]
		_check(regenerated.geometry_fingerprint == original.geometry_fingerprint, "seed %d fingerprint is repeatable" % seed)
		_check(regenerated.centerline == original.centerline, "seed %d sampled geometry is repeatable" % seed)
		_check(regenerated.spawn_transform == original.spawn_transform, "seed %d spawn transform is repeatable" % seed)
		_check(regenerated.checkpoints == original.checkpoints, "seed %d checkpoint order is repeatable" % seed)


func _verify_bounded_fallback(generator) -> void:
	var impossible_limits := {
		"max_attempts": 2,
		"min_lap_length": 100000.0,
	}
	var fallback = generator.generate(314159, impossible_limits)
	_check(fallback != null, "invalid candidates return a fallback")
	if fallback == null:
		return
	_check(fallback.used_fallback, "retry exhaustion is reported")
	_check(fallback.generation_attempts == 2, "retry exhaustion stops at the configured bound")
	_check(fallback.diagnostic_reason.begins_with("retry_exhausted:"), "fallback includes the validation reason")
	_check(fallback.seed == 314159, "fallback retains the requested seed for diagnostics")
	_check(fallback.lap_length >= EXPECTED_MIN_LAP_LENGTH and fallback.lap_length <= EXPECTED_MAX_LAP_LENGTH, "fallback layout is known-valid")
	_check(not _has_self_intersection(fallback.centerline), "fallback centerline is valid")


func _verify_surface_samples(definition) -> void:
	var surface_script := load(SURFACE_MAP_PATH) as GDScript
	_check(surface_script != null, "track surface provider loads")
	if surface_script == null:
		return
	var surface_map = surface_script.new(definition)
	var dirt = surface_map.sample_at(definition.centerline[0])
	var grass = surface_map.sample_at(definition.bounds.end + Vector2(500.0, 500.0))
	_check(dirt.surface_type != grass.surface_type, "road and off-track positions report distinct surfaces")
	_check(dirt.grip_multiplier > grass.grip_multiplier, "dirt has more grip than off-track grass")
	_check(dirt.drag_multiplier < grass.drag_multiplier, "off-track grass has more drag than dirt")


func _verify_lap_order(definition) -> void:
	var tracker_script := load(LAP_TRACKER_PATH) as GDScript
	_check(tracker_script != null, "lap progress tracker loads")
	if tracker_script == null:
		return
	var tracker = tracker_script.new(definition.checkpoints.size())
	for ignored_crossing in range(6):
		tracker.cross_checkpoint(0, 1.0)
	_check(tracker.lap_count == 0, "finish-line oscillation cannot count a lap")
	tracker.cross_checkpoint(1, -1.0)
	_check(tracker.next_checkpoint == 1, "reverse checkpoint crossings are ignored")
	for checkpoint_index in range(1, definition.checkpoints.size()):
		tracker.cross_checkpoint(checkpoint_index, 1.0)
	_check(tracker.lap_count == 0, "a lap waits for the final forward finish crossing")
	tracker.cross_checkpoint(0, 1.0)
	_check(tracker.lap_count == 1, "one forward ordered circuit counts exactly one lap")
	tracker.cross_checkpoint(0, 1.0)
	tracker.cross_checkpoint(0, -1.0)
	_check(tracker.lap_count == 1, "repeated and reverse finish crossings do not add laps")


func _verify_runtime_geometry(definition) -> void:
	var runtime_script := load(TRACK_RUNTIME_PATH) as GDScript
	_check(runtime_script != null, "prototype runtime renderer loads")
	if runtime_script == null:
		return
	var runtime = runtime_script.new(definition)
	root.add_child(runtime)
	var dirt_line := runtime.get_node_or_null("Dirt") as Line2D
	var grass_shoulder := runtime.get_node_or_null("GrassShoulder") as Line2D
	var collision_body := runtime.get_node_or_null("TrackEdges") as StaticBody2D
	_check(dirt_line != null and dirt_line.points.size() == definition.centerline.size(), "prototype dirt rendering follows the generated circuit")
	_check(grass_shoulder != null and grass_shoulder.width > dirt_line.width, "prototype grass shoulder distinguishes off-track")
	_check(collision_body != null, "generated track owns static edge collision")
	if collision_body != null:
		_check(collision_body.get_child_count() == 2 * (definition.centerline.size() - 1), "both continuous boundaries receive static segment collision")
	runtime.free()


func generator_attempt_limit() -> int:
	return 30


func _maximum_gap(points: PackedVector2Array) -> float:
	var maximum := 0.0
	for index in range(points.size() - 1):
		maximum = maxf(maximum, points[index].distance_to(points[index + 1]))
	return maximum


func _has_self_intersection(points: PackedVector2Array) -> bool:
	var segment_count := points.size() - 1
	for first in range(segment_count):
		for second in range(first + 1, segment_count):
			if abs(first - second) <= 1:
				continue
			if first == 0 and second == segment_count - 1:
				continue
			if Geometry2D.segment_intersects_segment(points[first], points[first + 1], points[second], points[second + 1]) != null:
				return true
	return false


func _boundaries_intersect(left: PackedVector2Array, right: PackedVector2Array) -> bool:
	for left_index in range(left.size() - 1):
		for right_index in range(right.size() - 1):
			if Geometry2D.segment_intersects_segment(left[left_index], left[left_index + 1], right[right_index], right[right_index + 1]) != null:
				return true
	return false


func _finish(started_usec: int) -> void:
	var elapsed_usec := Time.get_ticks_usec() - started_usec
	print("generator_test checks=%d elapsed_usec=%d" % [_checks, elapsed_usec])
	if _failures.is_empty():
		print("Procedural track generator checks passed")
		quit(0)
		return
	for failure in _failures:
		push_error("Procedural track generator check failed: %s" % failure)
	quit(1)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
