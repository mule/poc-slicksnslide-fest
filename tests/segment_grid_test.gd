extends SceneTree

const SEGMENT_GRID_PATH := "res://world/segment_grid.gd"
const SURFACE_MAP_PATH := "res://track/track_surface_map.gd"
const TRACK_GENERATOR_PATH := "res://track/track_generator.gd"

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var script := load(SEGMENT_GRID_PATH) as GDScript
	_check(script != null, "segment grid script loads")
	if script != null:
		_verify_proximity_matches_brute_force()
		_verify_pairs_cover_every_real_intersection()
		_verify_overlapping_matches_brute_force()
		_verify_degenerate_inputs_are_safe()
		_verify_surface_map_agrees_with_brute_force()
		_verify_segments_near_actually_narrows_candidates()
		_verify_distance_agrees_with_surface_classification()
		_verify_base_surface_query_never_reports_lost()
	_finish()


func _verify_proximity_matches_brute_force() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260824
	for trial in range(8):
		var points := _random_polyline(rng, 240, 4000.0)
		var radius := 150.0
		var grid := SegmentGrid.new(points, radius)
		var misses := 0
		for probe in range(60):
			var query := Vector2(rng.randf_range(-4200.0, 4200.0), rng.randf_range(-4200.0, 4200.0))
			var expected := _brute_force_near(points, query, radius)
			var actual := {}
			for index in grid.segments_near(query, radius):
				actual[index] = true
			for index in expected:
				if not actual.has(index):
					misses += 1
		_check(misses == 0, "trial %d: grid proximity returns every segment brute force finds (%d misses)" % [trial, misses])


func _verify_pairs_cover_every_real_intersection() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99001
	for trial in range(6):
		var points := _random_polyline(rng, 120, 2000.0)
		var grid := SegmentGrid.new(points, 200.0)
		var offered := {}
		for pair in grid.candidate_pairs():
			offered[Vector2i(mini(pair.x, pair.y), maxi(pair.x, pair.y))] = true
		var misses := 0
		var segment_count := points.size() - 1
		for first in range(segment_count):
			for second in range(first + 2, segment_count):
				if Geometry2D.segment_intersects_segment(points[first], points[first + 1], points[second], points[second + 1]) == null:
					continue
				if not offered.has(Vector2i(first, second)):
					misses += 1
		_check(misses == 0, "trial %d: candidate pairs cover every real intersection (%d misses)" % [trial, misses])


func _verify_overlapping_matches_brute_force() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 771144
	for trial in range(6):
		var points := _random_polyline(rng, 160, 3000.0)
		var grid := SegmentGrid.new(points, 180.0)
		var misses := 0
		var crossings := 0
		for probe in range(40):
			var from := Vector2(rng.randf_range(-1500.0, 1500.0), rng.randf_range(-1500.0, 1500.0))
			var to := from + Vector2(rng.randf_range(-900.0, 900.0), rng.randf_range(-900.0, 900.0))
			var offered := {}
			for index in grid.segments_overlapping(from, to):
				offered[index] = true
			for index in range(points.size() - 1):
				if Geometry2D.segment_intersects_segment(points[index], points[index + 1], from, to) == null:
					continue
				crossings += 1
				if not offered.has(index):
					misses += 1
		_check(crossings > 0, "trial %d: probe segments actually crossed the polyline (%d crossings)" % [trial, crossings])
		_check(misses == 0, "trial %d: segments_overlapping returns every real crossing (%d misses)" % [trial, misses])


func _verify_degenerate_inputs_are_safe() -> void:
	var empty := SegmentGrid.new(PackedVector2Array(), 50.0)
	_check(empty.segments_near(Vector2.ZERO, 100.0).is_empty(), "an empty polyline yields no candidates")
	_check(empty.candidate_pairs().is_empty(), "an empty polyline yields no pairs")
	var single := SegmentGrid.new(PackedVector2Array([Vector2.ZERO]), 50.0)
	_check(single.segments_near(Vector2.ZERO, 100.0).is_empty(), "a one-point polyline has no segments")
	var zero_cell := SegmentGrid.new(PackedVector2Array([Vector2.ZERO, Vector2(10.0, 0.0)]), 0.0)
	_check(zero_cell.segments_near(Vector2(5.0, 0.0), 10.0).size() == 1, "a zero cell size is clamped rather than dividing by zero")


func _random_polyline(rng: RandomNumberGenerator, count: int, extent: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var cursor := Vector2.ZERO
	for index in range(count):
		points.append(cursor)
		cursor += Vector2(rng.randf_range(-extent / count, extent / count), rng.randf_range(-extent / count, extent / count)) * 8.0
	points.append(points[0])
	return points


func _brute_force_near(points: PackedVector2Array, query: Vector2, radius: float) -> Array:
	var found := []
	for index in range(points.size() - 1):
		var closest := Geometry2D.get_closest_point_to_segment(query, points[index], points[index + 1])
		if query.distance_to(closest) <= radius:
			found.append(index)
	return found


func _verify_surface_map_agrees_with_brute_force() -> void:
	var generator_script := load(TRACK_GENERATOR_PATH) as GDScript
	var surface_script := load(SURFACE_MAP_PATH) as GDScript
	_check(generator_script != null and surface_script != null, "generator and surface map scripts load")
	if generator_script == null or surface_script == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var generator = generator_script.new()
	var disagreements := 0
	var on_track_hits := 0
	for seed in range(3):
		var definition = generator.generate(seed)
		var surface_map = surface_script.new(definition)
		var half_width: float = definition.track_width * 0.5
		for probe in range(400):
			# Probe near the centerline so both on-track and off-track cases occur.
			var anchor: Vector2 = definition.centerline[rng.randi_range(0, definition.centerline.size() - 2)]
			var query := anchor + Vector2(rng.randf_range(-half_width * 3.0, half_width * 3.0), rng.randf_range(-half_width * 3.0, half_width * 3.0))
			var expected_on_track := _brute_force_distance(definition.centerline, query) <= half_width
			var actual_on_track: bool = surface_map.sample_at(query).surface_type == SurfaceQuery.SurfaceType.DIRT
			if expected_on_track:
				on_track_hits += 1
			if expected_on_track != actual_on_track:
				disagreements += 1
	_check(on_track_hits > 0, "the probe actually covered on-track positions (%d hits)" % on_track_hits)
	_check(disagreements == 0, "indexed surface lookup agrees with brute force everywhere (%d disagreements)" % disagreements)


func _verify_segments_near_actually_narrows_candidates() -> void:
	## The superset checks above would all still pass if `segments_near()` degenerately
	## returned every segment for every query. This guards the one property the spatial
	## index actually exists for: that it narrows the candidate set. Mirrors the real
	## production usage in `track/track_surface_map.gd` (cell size = track width, query
	## radius = half the track width) on a real generated circuit.
	const MAX_CANDIDATE_FRACTION := 0.10
	var generator_script := load(TRACK_GENERATOR_PATH) as GDScript
	_check(generator_script != null, "generator script loads for the narrowing check")
	if generator_script == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 555222
	var generator = generator_script.new()
	var definition = generator.generate(0)
	var segment_count: int = definition.centerline.size() - 1
	var half_width: float = definition.track_width * 0.5
	var grid := SegmentGrid.new(definition.centerline, maxf(definition.track_width, 1.0))
	var total_candidates := 0
	var probes := 200
	for probe in range(probes):
		var anchor: Vector2 = definition.centerline[rng.randi_range(0, segment_count - 1)]
		var query := anchor + Vector2(rng.randf_range(-half_width, half_width), rng.randf_range(-half_width, half_width))
		total_candidates += grid.segments_near(query, half_width).size()
	var average_candidates := float(total_candidates) / float(probes)
	var average_fraction := average_candidates / float(segment_count)
	_check(average_fraction < MAX_CANDIDATE_FRACTION, "segments_near narrows candidates well below every segment (avg %.1f of %d segments = %.1f%%, threshold %.0f%%)" % [average_candidates, segment_count, average_fraction * 100.0, MAX_CANDIDATE_FRACTION * 100.0])


func _verify_distance_agrees_with_surface_classification() -> void:
	var generator_script := load(TRACK_GENERATOR_PATH) as GDScript
	var surface_map_script := load(SURFACE_MAP_PATH) as GDScript
	var definition = generator_script.new().generate(0)
	var surface_map = surface_map_script.new(definition)
	var half_width: float = definition.track_width * 0.5

	var centre: Vector2 = definition.centerline[10]
	_check(
		surface_map.distance_to_centerline(centre, half_width) < 1.0,
		"a point on the centerline reports a near-zero distance"
	)

	var lateral: Vector2 = (definition.centerline[11] - definition.centerline[10]).normalized().orthogonal()
	var just_inside: Vector2 = centre + lateral * (half_width - 5.0)
	var just_outside: Vector2 = centre + lateral * (half_width + 5.0)
	_check(
		surface_map.sample_at(just_inside).surface_type == SurfaceQuery.SurfaceType.DIRT
			and surface_map.distance_to_centerline(just_inside, half_width) <= half_width,
		"a point inside the track is DIRT and within half a width of the line"
	)
	var far_distance: float = surface_map.distance_to_centerline(just_outside, half_width * 8.0)
	_check(
		surface_map.sample_at(just_outside).surface_type == SurfaceQuery.SurfaceType.OFF_TRACK
			and far_distance > half_width and far_distance < half_width * 2.0,
		"a point just outside the track is OFF_TRACK and reports a real distance, not INF"
	)
	_check(
		is_inf(surface_map.distance_to_centerline(centre + lateral * (half_width * 20.0), half_width)),
		"a point beyond the search radius saturates to INF rather than lying about the distance"
	)


func _verify_base_surface_query_never_reports_lost() -> void:
	var base := SurfaceQuery.new()
	_check(
		is_zero_approx(base.distance_to_centerline(Vector2(9999.0, 9999.0), 1000.0)),
		"the base SurfaceQuery reports zero distance so providers without a centerline never read as lost"
	)


func _brute_force_distance(points: PackedVector2Array, query: Vector2) -> float:
	var nearest := INF
	for index in range(points.size() - 1):
		var closest := Geometry2D.get_closest_point_to_segment(query, points[index], points[index + 1])
		nearest = minf(nearest, query.distance_to(closest))
	return nearest


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Segment grid checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Segment grid check failed: %s" % failure)
	quit(1)
