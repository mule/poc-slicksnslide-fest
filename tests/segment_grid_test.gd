extends SceneTree

const SEGMENT_GRID_PATH := "res://world/segment_grid.gd"

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
