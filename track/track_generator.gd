class_name TrackGenerator
extends RefCounted

const TrackDefinitionScript := preload("res://track/track_definition.gd")

const DEFAULT_MAX_ATTEMPTS := 6
const SAMPLE_SPACING := 25.0
const CHECKPOINT_COUNT := 8
const MIN_WIDTH := 125.0
const MAX_WIDTH := 175.0
const MIN_LAP_LENGTH := 25000.0
const MAX_LAP_LENGTH := 37500.0
const MAX_CURVATURE := 0.005
const MIN_START_STRAIGHT := 1875.0

const CONTROL_POINT_COUNT := 14
const RADIUS_JITTER_MIN := 0.72
const RADIUS_JITTER_MAX := 1.0
const SPLINE_SAMPLES_PER_SPAN := 24
const STRAIGHT_CURVATURE := 0.0005

const FALLBACK_HALF_STRAIGHT := 3728.0
const FALLBACK_RADIUS := 2600.0
const FALLBACK_WIDTH := 150.0


func generate(requested_seed: int, limit_overrides: Dictionary = {}):
	var started_usec := Time.get_ticks_usec()
	var maximum_attempts := clampi(int(limit_overrides.get("max_attempts", DEFAULT_MAX_ATTEMPTS)), 1, DEFAULT_MAX_ATTEMPTS)
	var rng := RandomNumberGenerator.new()
	rng.seed = requested_seed
	var last_reason := "candidate_not_generated"
	for attempt in range(1, maximum_attempts + 1):
		var target_lap_length := rng.randf_range(MIN_LAP_LENGTH, MAX_LAP_LENGTH)
		var width := float(rng.randi_range(25, 35) * 5)
		var centerline := _sample_loop(rng, target_lap_length)
		var candidate = _build_definition(requested_seed, centerline, width)
		candidate.generation_attempts = attempt
		last_reason = _validation_reason(candidate, limit_overrides)
		if last_reason.is_empty():
			candidate.diagnostic_reason = "accepted"
			candidate.generation_usec = Time.get_ticks_usec() - started_usec
			return candidate

	var fallback = _build_definition(requested_seed, _sample_stadium(FALLBACK_HALF_STRAIGHT, FALLBACK_RADIUS), FALLBACK_WIDTH)
	fallback.generation_attempts = maximum_attempts
	fallback.used_fallback = true
	fallback.diagnostic_reason = "retry_exhausted:%s; fallback=known_valid_stadium" % last_reason
	fallback.generation_usec = Time.get_ticks_usec() - started_usec
	return fallback


func _build_definition(requested_seed: int, centerline: PackedVector2Array, width: float):
	var definition = TrackDefinitionScript.new()
	definition.seed = requested_seed
	definition.track_width = width
	definition.centerline = centerline
	var boundaries := _derive_boundaries(definition.centerline, width)
	definition.left_boundary = boundaries.left
	definition.right_boundary = boundaries.right
	definition.lap_length = _polyline_length(definition.centerline)
	definition.max_curvature = _measure_max_curvature(definition.centerline)
	definition.start_straight_length = _straight_run_length(definition.centerline, 0)
	definition.forward_direction = (definition.centerline[1] - definition.centerline[0]).normalized()
	definition.spawn_transform = Transform2D(definition.forward_direction.angle() + PI * 0.5, definition.centerline[0])
	definition.checkpoints = _build_checkpoints(definition.centerline)
	definition.bounds = _combined_bounds(definition.left_boundary, definition.right_boundary)
	definition.geometry_fingerprint = _fingerprint(definition)
	return definition


func _sample_loop(rng: RandomNumberGenerator, target_lap_length: float) -> PackedVector2Array:
	var base_radius := target_lap_length / TAU
	var radii := []
	for index in range(CONTROL_POINT_COUNT):
		radii.append(base_radius * rng.randf_range(RADIUS_JITTER_MIN, RADIUS_JITTER_MAX))
	# Pin three consecutive control points to the nominal radius so at least one
	# gentle span exists. Without this the start-straight constraint would be a
	# gamble on the jitter, and most seeds would fall back to the stadium.
	radii[0] = base_radius
	radii[1] = base_radius
	radii[CONTROL_POINT_COUNT - 1] = base_radius

	var controls := PackedVector2Array()
	for index in range(CONTROL_POINT_COUNT):
		var angle := TAU * float(index) / float(CONTROL_POINT_COUNT)
		controls.append(Vector2(cos(angle), sin(angle)) * radii[index])

	var loop := _catmull_rom_closed(controls)
	# Scale before resampling, not after. The spec lists resample-then-scale,
	# but scaling a uniformly-spaced polyline multiplies its spacing too, which
	# would leave samples SAMPLE_SPACING * factor apart instead of
	# SAMPLE_SPACING. Scaling first makes the spacing correct at final size.
	loop = _scale_to_lap_length(loop, target_lap_length)
	loop = _resample_uniform(loop, SAMPLE_SPACING)
	return _rotate_to_start_straight(loop)


func _catmull_rom_closed(controls: PackedVector2Array) -> PackedVector2Array:
	var points := PackedVector2Array()
	var count := controls.size()
	for index in range(count):
		var p0 := controls[(index - 1 + count) % count]
		var p1 := controls[index]
		var p2 := controls[(index + 1) % count]
		var p3 := controls[(index + 2) % count]
		for step in range(SPLINE_SAMPLES_PER_SPAN):
			var t := float(step) / float(SPLINE_SAMPLES_PER_SPAN)
			var t2 := t * t
			var t3 := t2 * t
			points.append(0.5 * (
				2.0 * p1
				+ (-p0 + p2) * t
				+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
				+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
			))
	points.append(points[0])
	return points


func _scale_to_lap_length(points: PackedVector2Array, target_length: float) -> PackedVector2Array:
	var current := _polyline_length(points)
	if current <= 0.0:
		return points
	var factor := target_length / current
	var scaled := PackedVector2Array()
	for point in points:
		scaled.append(point * factor)
	return scaled


func _resample_uniform(points: PackedVector2Array, spacing: float) -> PackedVector2Array:
	var total := _polyline_length(points)
	var target_count := maxi(int(round(total / spacing)), 8)
	var step := total / float(target_count)
	var resampled := PackedVector2Array([points[0]])
	var travelled := 0.0
	var next_mark := step
	var index := 0
	while index < points.size() - 1 and resampled.size() < target_count:
		var segment_length := points[index].distance_to(points[index + 1])
		if segment_length <= 0.0:
			index += 1
			continue
		if travelled + segment_length >= next_mark:
			var ratio := (next_mark - travelled) / segment_length
			resampled.append(points[index].lerp(points[index + 1], ratio))
			next_mark += step
		else:
			travelled += segment_length
			index += 1
	resampled.append(resampled[0])
	return resampled


func _sample_stadium(half_straight: float, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var straight_segments := ceili((half_straight * 2.0) / SAMPLE_SPACING)
	for index in range(straight_segments + 1):
		var ratio := float(index) / float(straight_segments)
		points.append(Vector2(lerpf(-half_straight, half_straight, ratio), -radius))

	var arc_segments := ceili(PI * radius / SAMPLE_SPACING)
	for index in range(1, arc_segments + 1):
		var angle := lerpf(-PI * 0.5, PI * 0.5, float(index) / float(arc_segments))
		points.append(Vector2(half_straight + cos(angle) * radius, sin(angle) * radius))

	for index in range(1, straight_segments + 1):
		var ratio := float(index) / float(straight_segments)
		points.append(Vector2(lerpf(half_straight, -half_straight, ratio), radius))

	for index in range(1, arc_segments + 1):
		var angle := lerpf(PI * 0.5, PI * 1.5, float(index) / float(arc_segments))
		points.append(Vector2(-half_straight + cos(angle) * radius, sin(angle) * radius))

	points[-1] = points[0]
	return points


func _derive_boundaries(centerline: PackedVector2Array, width: float) -> Dictionary:
	var left := PackedVector2Array()
	var right := PackedVector2Array()
	var unique_count := centerline.size() - 1
	for index in range(unique_count):
		var previous := centerline[(index - 1 + unique_count) % unique_count]
		var following := centerline[(index + 1) % unique_count]
		var tangent := (following - previous).normalized()
		var normal := Vector2(-tangent.y, tangent.x)
		left.append(centerline[index] + normal * width * 0.5)
		right.append(centerline[index] - normal * width * 0.5)
	left.append(left[0])
	right.append(right[0])
	return {"left": left, "right": right}


func _build_checkpoints(centerline: PackedVector2Array) -> Array[Transform2D]:
	var checkpoints: Array[Transform2D] = []
	var unique_count := centerline.size() - 1
	for checkpoint_index in range(CHECKPOINT_COUNT):
		var sample_index := int(round(float(checkpoint_index) * float(unique_count) / float(CHECKPOINT_COUNT))) % unique_count
		var next_index := (sample_index + 1) % unique_count
		var forward := (centerline[next_index] - centerline[sample_index]).normalized()
		checkpoints.append(Transform2D(forward.angle(), centerline[sample_index]))
	return checkpoints


func _validation_reason(definition, limits: Dictionary) -> String:
	var min_width := float(limits.get("min_width", MIN_WIDTH))
	var max_width := float(limits.get("max_width", MAX_WIDTH))
	var min_lap := float(limits.get("min_lap_length", MIN_LAP_LENGTH))
	var max_lap := float(limits.get("max_lap_length", MAX_LAP_LENGTH))
	var max_curve := float(limits.get("max_curvature", MAX_CURVATURE))
	var min_straight := float(limits.get("min_start_straight", MIN_START_STRAIGHT))
	if definition.track_width < min_width:
		return "width_below_min"
	if definition.track_width > max_width:
		return "width_above_max"
	if definition.lap_length < min_lap:
		return "lap_length_below_min"
	if definition.lap_length > max_lap:
		return "lap_length_above_max"
	if definition.max_curvature > max_curve:
		return "curvature_above_max"
	if definition.start_straight_length < min_straight:
		return "start_straight_below_min"
	if _has_self_intersection(definition.centerline):
		return "centerline_self_intersection"
	if _has_self_intersection(definition.left_boundary) or _has_self_intersection(definition.right_boundary):
		return "boundary_self_intersection"
	if _boundaries_intersect(definition.left_boundary, definition.right_boundary):
		return "boundaries_overlap"
	return ""


func _polyline_length(points: PackedVector2Array) -> float:
	var length := 0.0
	for index in range(points.size() - 1):
		length += points[index].distance_to(points[index + 1])
	return length


func _measure_max_curvature(points: PackedVector2Array) -> float:
	var maximum := 0.0
	for index in range(points.size() - 1):
		maximum = maxf(maximum, _curvature_at(points, index))
	return maximum


func _curvature_at(points: PackedVector2Array, index: int) -> float:
	var unique_count := points.size() - 1
	var incoming := points[index] - points[(index - 1 + unique_count) % unique_count]
	var outgoing := points[(index + 1) % unique_count] - points[index]
	var distance := (incoming.length() + outgoing.length()) * 0.5
	if distance <= 0.0:
		return 0.0
	return absf(incoming.angle_to(outgoing)) / distance


func _straight_run_length(points: PackedVector2Array, start: int) -> float:
	var unique_count := points.size() - 1
	var length := 0.0
	for offset in range(unique_count):
		var index := (start + offset) % unique_count
		if _curvature_at(points, index) > STRAIGHT_CURVATURE:
			break
		length += points[index].distance_to(points[(index + 1) % unique_count])
	return length


func _rotate_to_start_straight(points: PackedVector2Array) -> PackedVector2Array:
	var unique_count := points.size() - 1
	# Precompute curvature once, then find the longest gentle run in a single
	# wrapped pass. Calling _straight_run_length from every index would be
	# O(n^2) over ~1250 samples.
	var gentle := []
	for index in range(unique_count):
		gentle.append(_curvature_at(points, index) <= STRAIGHT_CURVATURE)
	var best_start := 0
	var best_length := -1.0
	var run_start := -1
	var run_length := 0.0
	for offset in range(unique_count * 2):
		var index := offset % unique_count
		if not gentle[index]:
			run_start = -1
			run_length = 0.0
			continue
		if run_start < 0:
			run_start = index
			run_length = 0.0
		run_length += points[index].distance_to(points[(index + 1) % unique_count])
		if run_length > best_length:
			best_length = run_length
			best_start = run_start
	var rotated := PackedVector2Array()
	for offset in range(unique_count):
		rotated.append(points[(best_start + offset) % unique_count])
	rotated.append(rotated[0])
	return rotated


func _combined_bounds(left: PackedVector2Array, right: PackedVector2Array) -> Rect2:
	var bounds := Rect2(left[0], Vector2.ZERO)
	for point in left:
		bounds = bounds.expand(point)
	for point in right:
		bounds = bounds.expand(point)
	return bounds


func _fingerprint(definition) -> String:
	var components := PackedStringArray(["width=%.3f" % definition.track_width])
	for point in definition.centerline:
		components.append("%.3f,%.3f" % [point.x, point.y])
	for point in definition.left_boundary:
		components.append("L%.3f,%.3f" % [point.x, point.y])
	for point in definition.right_boundary:
		components.append("R%.3f,%.3f" % [point.x, point.y])
	return "|".join(components).sha256_text()


func _has_self_intersection(points: PackedVector2Array) -> bool:
	var segment_count := points.size() - 1
	var grid := SegmentGrid.new(points, SAMPLE_SPACING * 4.0)
	for pair in grid.candidate_pairs():
		var first: int = mini(pair.x, pair.y)
		var second: int = maxi(pair.x, pair.y)
		if second - first <= 1:
			continue
		if first == 0 and second == segment_count - 1:
			continue
		if Geometry2D.segment_intersects_segment(points[first], points[first + 1], points[second], points[second + 1]) != null:
			return true
	return false


func _boundaries_intersect(left: PackedVector2Array, right: PackedVector2Array) -> bool:
	var grid := SegmentGrid.new(left, SAMPLE_SPACING * 4.0)
	for right_index in range(right.size() - 1):
		for left_index in grid.segments_overlapping(right[right_index], right[right_index + 1]):
			if Geometry2D.segment_intersects_segment(left[left_index], left[left_index + 1], right[right_index], right[right_index + 1]) != null:
				return true
	return false
