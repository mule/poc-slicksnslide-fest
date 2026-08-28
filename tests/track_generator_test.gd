extends SceneTree

const TRACK_GENERATOR_PATH := "res://track/track_generator.gd"
const SURFACE_MAP_PATH := "res://track/track_surface_map.gd"
const LAP_TRACKER_PATH := "res://track/lap_progress_tracker.gd"
const TRACK_RUNTIME_PATH := "res://track/track_runtime.gd"
const TrackGeneratorScript := preload("res://track/track_generator.gd")

const EXPECTED_MIN_WIDTH := 200.0
const EXPECTED_MAX_WIDTH := 280.0
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
	# Each verification reports whether it ran to completion. A GDScript runtime error aborts
	# only the function it occurs in and returns false to here, so without this the script
	# would exit 0 with assertions silently skipped. See tests/harness_contract_test.gd.
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
		_check(_verify_driveable_definition(definition, seed), "the driveable definition verification ran to completion")
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

	_check(_verify_determinism(generator, definitions), "the determinism verification ran to completion")
	_check(_verify_bounded_fallback(generator), "the bounded fallback verification ran to completion")
	_check(_verify_surface_samples(definitions[0]), "the surface samples verification ran to completion")
	_check(_verify_lap_order(definitions[0]), "the lap order verification ran to completion")
	_check(_verify_runtime_geometry(definitions[0]), "the runtime geometry verification ran to completion")
	_finish(started_usec)


func _verify_driveable_definition(definition, seed: int) -> bool:
	_check(definition != null, "seed %d produces a definition" % seed)
	if definition == null:
		return false
	_check(definition.seed == seed, "seed %d is retained" % seed)
	_check(definition.generation_attempts >= 1 and definition.generation_attempts <= generator_attempt_limit(), "seed %d uses bounded attempts" % seed)
	_check(definition.track_width >= EXPECTED_MIN_WIDTH and definition.track_width <= EXPECTED_MAX_WIDTH, "seed %d width is within the driveable bound" % seed)
	var expected_margin: float = TrackGeneratorScript.PLAY_AREA_MARGIN
	_check(definition.play_area.encloses(definition.bounds), "seed %d play area encloses the track bounds" % seed)
	_check(
		is_equal_approx(definition.play_area.position.x, definition.bounds.position.x - expected_margin)
			and is_equal_approx(definition.play_area.position.y, definition.bounds.position.y - expected_margin),
		"seed %d play area starts one margin outside the bounds" % seed
	)
	_check(
		is_equal_approx(definition.play_area.size.x, definition.bounds.size.x + expected_margin * 2.0)
			and is_equal_approx(definition.play_area.size.y, definition.bounds.size.y + expected_margin * 2.0),
		"seed %d play area adds one margin on every side" % seed
	)
	_check(definition.lap_length >= EXPECTED_MIN_LAP_LENGTH and definition.lap_length <= EXPECTED_MAX_LAP_LENGTH, "seed %d lap length is within bounds" % seed)
	_check(definition.max_curvature <= EXPECTED_MAX_CURVATURE, "seed %d curvature is bounded" % seed)
	_check(definition.start_straight_length >= EXPECTED_MIN_START_STRAIGHT, "seed %d has an adequate start straight" % seed)
	_check(_verify_world_exceeds_one_screen(definition, seed), "the world exceeds one screen verification ran to completion")
	_check(definition.geometry_fingerprint.length() == 64, "seed %d has a SHA-256 geometry fingerprint" % seed)
	_check(definition.centerline.size() >= 64, "seed %d is sampled densely" % seed)
	_check(definition.left_boundary.size() == definition.centerline.size(), "seed %d left boundary matches centerline sampling" % seed)
	_check(definition.right_boundary.size() == definition.centerline.size(), "seed %d right boundary matches centerline sampling" % seed)
	_check(definition.centerline[0].is_equal_approx(definition.centerline[-1]), "seed %d centerline is closed" % seed)
	_check(definition.left_boundary[0].is_equal_approx(definition.left_boundary[-1]), "seed %d left boundary is continuous at closure" % seed)
	_check(definition.right_boundary[0].is_equal_approx(definition.right_boundary[-1]), "seed %d right boundary is continuous at closure" % seed)
	_check(_maximum_gap(definition.centerline) <= EXPECTED_MAX_SAMPLE_GAP, "seed %d centerline sampling has no escape-sized gaps" % seed)
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
	return true


func _verify_world_exceeds_one_screen(definition, seed: int) -> bool:
	_check(definition.bounds.size.x >= 5000.0, "seed %d spans several screens horizontally (%.0f px)" % [seed, definition.bounds.size.x])
	_check(definition.bounds.size.y >= 5000.0, "seed %d spans several screens vertically (%.0f px)" % [seed, definition.bounds.size.y])
	return true


func _verify_determinism(generator, originals: Array) -> bool:
	for seed in range(10):
		var regenerated = generator.generate(seed)
		var original = originals[seed]
		_check(regenerated.geometry_fingerprint == original.geometry_fingerprint, "seed %d fingerprint is repeatable" % seed)
		_check(regenerated.centerline == original.centerline, "seed %d sampled geometry is repeatable" % seed)
		_check(regenerated.spawn_transform == original.spawn_transform, "seed %d spawn transform is repeatable" % seed)
		_check(regenerated.checkpoints == original.checkpoints, "seed %d checkpoint order is repeatable" % seed)
	return true


func _verify_bounded_fallback(generator) -> bool:
	var impossible_limits := {
		"max_attempts": 2,
		"min_lap_length": 100000.0,
	}
	var fallback = generator.generate(314159, impossible_limits)
	_check(fallback != null, "invalid candidates return a fallback")
	if fallback == null:
		return false
	_check(fallback.used_fallback, "retry exhaustion is reported")
	_check(fallback.generation_attempts == 2, "retry exhaustion stops at the configured bound")
	_check(fallback.diagnostic_reason.begins_with("retry_exhausted:"), "fallback includes the validation reason")
	_check(fallback.seed == 314159, "fallback retains the requested seed for diagnostics")
	_check(fallback.lap_length >= EXPECTED_MIN_LAP_LENGTH and fallback.lap_length <= EXPECTED_MAX_LAP_LENGTH, "fallback layout is known-valid")
	_check(not _has_self_intersection(fallback.centerline), "fallback centerline is valid")
	return true


func _verify_surface_samples(definition) -> bool:
	var surface_script := load(SURFACE_MAP_PATH) as GDScript
	_check(surface_script != null, "track surface provider loads")
	if surface_script == null:
		return false
	var surface_map = surface_script.new(definition)
	var dirt = surface_map.sample_at(definition.centerline[0])
	var grass = surface_map.sample_at(definition.bounds.end + Vector2(500.0, 500.0))
	_check(dirt.surface_type != grass.surface_type, "road and off-track positions report distinct surfaces")
	_check(dirt.grip_multiplier > grass.grip_multiplier, "dirt has more grip than off-track grass")
	_check(dirt.drag_multiplier < grass.drag_multiplier, "off-track grass has more drag than dirt")
	return true


func _verify_lap_order(definition) -> bool:
	var tracker_script := load(LAP_TRACKER_PATH) as GDScript
	_check(tracker_script != null, "lap progress tracker loads")
	if tracker_script == null:
		return false
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
	return true


func _verify_runtime_geometry(definition) -> bool:
	var runtime_script := load(TRACK_RUNTIME_PATH) as GDScript
	_check(runtime_script != null, "prototype runtime renderer loads")
	if runtime_script == null:
		return false
	var runtime = runtime_script.new(definition)
	root.add_child(runtime)
	var dirt_line := runtime.get_node_or_null("Dirt") as Line2D
	var grass_shoulder := runtime.get_node_or_null("GrassShoulder") as Line2D
	var collision_body := runtime.get_node_or_null("PlayAreaBounds") as StaticBody2D
	_check(dirt_line != null and dirt_line.points.size() == definition.centerline.size(), "prototype dirt rendering follows the generated circuit")
	_check(grass_shoulder != null and grass_shoulder.width > dirt_line.width, "prototype grass shoulder distinguishes off-track")
	_check(collision_body != null and collision_body.get_child_count() == 4, "prototype track builds a four-segment containment boundary")
	_check(_verify_checkpoint_markers(runtime, definition), "the checkpoint markers verification ran to completion")
	runtime.free()


## Every checkpoint gets a visible gate, the start/finish reads differently from the rest, and the
## gate the driver needs next is the bright one. Ordered gates are unforgiving -- passing them out
## of sequence silently voids the lap -- so which one is next has to be visible from the car.
	return true


func _verify_checkpoint_markers(runtime, definition) -> bool:
	var markers := []
	var missing := 0
	for index in range(definition.checkpoints.size()):
		var marker := runtime.get_node_or_null("Checkpoint%d" % index) as Line2D
		if marker == null:
			missing += 1
		markers.append(marker)
	_check(missing == 0, "every checkpoint is drawn as its own marker (%d of %d missing)" % [missing, markers.size()])
	if missing > 0:
		return false
	var half_width: float = definition.track_width * 0.5
	_check(
		is_equal_approx(markers[0].points[0].distance_to(markers[0].points[1]), half_width * 2.0),
		"a checkpoint marker spans the full track width"
	)
	_check(markers[0].width > markers[1].width, "the start/finish marker is distinguishable from the other gates")

	_check(runtime.has_method("set_next_checkpoint"), "the runtime can be told which gate comes next")
	if not runtime.has_method("set_next_checkpoint"):
		return false
	runtime.set_next_checkpoint(2)
	_check(
		markers[2].default_color.a > markers[3].default_color.a,
		"the next gate is brighter than the gates beyond it"
	)
	_check(
		markers[2].default_color.a > markers[1].default_color.a,
		"the next gate is brighter than the gates already passed"
	)
	runtime.set_next_checkpoint(0)
	_check(
		markers[0].default_color.a > markers[2].default_color.a,
		"the start/finish highlights when it is the gate needed to complete the lap"
	)
	return true


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
