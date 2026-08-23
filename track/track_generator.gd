class_name TrackGenerator
extends RefCounted

const TrackDefinitionScript := preload("res://track/track_definition.gd")

const DEFAULT_MAX_ATTEMPTS := 6
const SAMPLE_SPACING := 10.0
const CHECKPOINT_COUNT := 8
const MIN_WIDTH := 40.0
const MAX_WIDTH := 56.0
const MIN_LAP_LENGTH := 1100.0
const MAX_LAP_LENGTH := 1900.0
const MAX_CURVATURE := 0.02
const MIN_START_STRAIGHT := 160.0

const FALLBACK_HALF_STRAIGHT := 210.0
const FALLBACK_RADIUS := 115.0
const FALLBACK_WIDTH := 48.0


func generate(requested_seed: int, limit_overrides: Dictionary = {}):
	var started_usec := Time.get_ticks_usec()
	var maximum_attempts := clampi(int(limit_overrides.get("max_attempts", DEFAULT_MAX_ATTEMPTS)), 1, DEFAULT_MAX_ATTEMPTS)
	var rng := RandomNumberGenerator.new()
	rng.seed = requested_seed
	var last_reason := "candidate_not_generated"
	for attempt in range(1, maximum_attempts + 1):
		var half_straight := float(rng.randi_range(180, 240))
		var radius := float(rng.randi_range(100, 135))
		var width := float(rng.randi_range(20, 28) * 2)
		var candidate = _build_definition(requested_seed, half_straight, radius, width)
		candidate.generation_attempts = attempt
		last_reason = _validation_reason(candidate, limit_overrides)
		if last_reason.is_empty():
			candidate.diagnostic_reason = "accepted"
			candidate.generation_usec = Time.get_ticks_usec() - started_usec
			return candidate

	var fallback = _build_definition(requested_seed, FALLBACK_HALF_STRAIGHT, FALLBACK_RADIUS, FALLBACK_WIDTH)
	fallback.generation_attempts = maximum_attempts
	fallback.used_fallback = true
	fallback.diagnostic_reason = "retry_exhausted:%s; fallback=known_valid_stadium" % last_reason
	fallback.generation_usec = Time.get_ticks_usec() - started_usec
	return fallback


func _build_definition(requested_seed: int, half_straight: float, radius: float, width: float):
	var definition = TrackDefinitionScript.new()
	definition.seed = requested_seed
	definition.track_width = width
	definition.centerline = _sample_stadium(half_straight, radius)
	var boundaries := _derive_boundaries(definition.centerline, width)
	definition.left_boundary = boundaries.left
	definition.right_boundary = boundaries.right
	definition.lap_length = _polyline_length(definition.centerline)
	definition.max_curvature = _measure_max_curvature(definition.centerline)
	definition.start_straight_length = half_straight * 2.0
	definition.forward_direction = (definition.centerline[1] - definition.centerline[0]).normalized()
	definition.spawn_transform = Transform2D(definition.forward_direction.angle() + PI * 0.5, definition.centerline[0])
	definition.checkpoints = _build_checkpoints(definition.centerline)
	definition.bounds = _combined_bounds(definition.left_boundary, definition.right_boundary)
	definition.geometry_fingerprint = _fingerprint(definition)
	return definition


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
	var unique_count := points.size() - 1
	for index in range(unique_count):
		var incoming := points[index] - points[(index - 1 + unique_count) % unique_count]
		var outgoing := points[(index + 1) % unique_count] - points[index]
		var distance := (incoming.length() + outgoing.length()) * 0.5
		if distance > 0.0:
			maximum = maxf(maximum, absf(incoming.angle_to(outgoing)) / distance)
	return maximum


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
