# tests/jump_ramp_placement_test.gd
extends SceneTree

## Ramps are deterministic per seed, live on straight runs with their clearances, respect the spawn,
## gate, and spacing exclusions, and never touch the road or object fingerprints. Mutations:
##   -- --break-height-seed   bumps the catalog version on the second run, so repeat checks fail
##   -- --break-clearance     zeroes the checkpoint exclusion, so the gate oracle fails

const CATALOG_PATH := "res://data/default_height_channel_catalog.tres"
const BASELINE_PATH := "res://tests/offtrack_object_placement_test.gd"
const SEED_COUNT := 20
const PLACEMENT_P95_BUDGET_USEC := 5000
const QUERY_COUNT := 10000
const QUERY_BUDGET_USEC := 20000

var _failures: Array[String] = []
var _checks := 0
var _break_seed := false
var _break_clearance := false
var _geometry_changed_seeds := 0


func _initialize() -> void:
	_break_seed = OS.get_cmdline_user_args().has("--break-height-seed")
	_break_clearance = OS.get_cmdline_user_args().has("--break-clearance")
	call_deferred("_run")


func _run() -> void:
	_check(_verify_density(), "the ramp density verification ran to completion")
	_check(_verify_sweep(), "the seed sweep verification ran to completion")
	_check(_verify_geometry_isolation(), "the geometry isolation verification ran to completion")
	_check(_verify_retry_stream_isolation(), "the retry stream isolation verification ran to completion")
	_check(_verify_height_map_profile(), "the height map profile verification ran to completion")
	_check(_verify_height_map_skips_invalid_records(), "the invalid record verification ran to completion")
	_check(_verify_flat_sample_resets(), "the flat sample reset verification ran to completion")
	_check(_verify_fallback(), "the fallback verification ran to completion")
	_finish()


func _verify_density() -> bool:
	var generator := TrackGenerator.new()
	var placer := JumpRampPlacer.new()
	var catalog := load(CATALOG_PATH) as HeightChannelCatalog
	var counts: Array[int] = []
	var nonempty_seeds := 0
	var total_ramps := 0
	for seed in range(SEED_COUNT):
		var definition: TrackDefinition = generator.generate(seed)
		var result: JumpRampPlacementResult = placer.place(definition, catalog)
		var count: int = result.placements.size()
		counts.append(count)
		total_ramps += count
		if count > 0:
			nonempty_seeds += 1
		_check(count <= catalog.ramps_per_lap_max, "density seed %d does not exceed the catalog maximum" % seed)
		print("density_seed=%d ramps=%d" % [seed, count])
	var mean := float(total_ramps) / float(SEED_COUNT)
	print("density_counts=%s nonempty=%d mean=%.3f" % [str(counts), nonempty_seeds, mean])
	_check(counts[0] >= 1, "seed 0 places at least one ramp")
	_check(nonempty_seeds >= 17, "at least 17 of seeds 0-19 place a ramp (%d do)" % nonempty_seeds)
	_check(mean >= 2.0, "mean ramp count across seeds 0-19 is at least 2.0 (%.3f)" % mean)
	return true


func _verify_sweep() -> bool:
	var generator := TrackGenerator.new()
	var placer := JumpRampPlacer.new()
	var catalog := load(CATALOG_PATH) as HeightChannelCatalog
	var baseline: Dictionary = (load(BASELINE_PATH) as GDScript).ROAD_FINGERPRINTS
	var times: Array[int] = []
	for seed in range(SEED_COUNT):
		_check(_verify_seed(seed, generator, placer, catalog, baseline, times), "seed %d verification completed" % seed)
	times.sort()
	var p95: int = times[int(floor(0.95 * float(times.size() - 1)))]
	print("placement_usec_p95=%d" % p95)
	_check(p95 <= PLACEMENT_P95_BUDGET_USEC, "ramp placement p95 (%d us) is within the 5 ms budget" % p95)
	return true


func _verify_seed(seed: int, generator: TrackGenerator, placer: JumpRampPlacer, catalog: HeightChannelCatalog, baseline: Dictionary, times: Array[int]) -> bool:
	var definition: TrackDefinition = generator.generate(seed)
	var road_fingerprint := definition.geometry_fingerprint
	var object_fingerprint := definition.offtrack_object_fingerprint
	var first := placer.place(definition, catalog)
	times.append(first.generation_usec)
	var second_catalog := catalog.duplicate(true) as HeightChannelCatalog
	if _break_seed:
		second_catalog.version += 1
	if _break_clearance:
		second_catalog.checkpoint_exclusion = 0.0
	var second := placer.place(definition, second_catalog)
	var checked := second.placements if _break_clearance else first.placements
	print("seed=%d ramps=%d requested=%d eligible_runs=%d usec=%d" % [seed, first.placements.size(), int(first.diagnostics.get("requested", -1)), int(first.diagnostics.get("eligible_runs", -1)), first.generation_usec])

	_check(first.fingerprint.length() == 64, "seed %d produces a SHA-256 height fingerprint" % seed)
	_check(first.fingerprint == second.fingerprint, "seed %d height fingerprint repeats" % seed)
	_check(_placements_equal(first.placements, second.placements), "seed %d placements repeat exactly" % seed)
	_check(_verify_crest_geometry(seed, first.placements, second.placements), "seed %d crest geometry verification completed" % seed)
	_check(definition.geometry_fingerprint == road_fingerprint, "seed %d road fingerprint is unchanged by placement" % seed)
	_check(definition.geometry_fingerprint == baseline[seed], "seed %d road fingerprint matches the pre-B baseline" % seed)
	_check(definition.offtrack_object_fingerprint == object_fingerprint, "seed %d object fingerprint is unchanged by placement" % seed)
	_check(_verify_rules(definition, checked, catalog, seed), "seed %d rule verification completed" % seed)
	_check(_verify_diagnostics(first, catalog, seed), "seed %d diagnostics verification completed" % seed)
	return true


func _verify_rules(definition: TrackDefinition, placements: Array[JumpRampPlacement], catalog: HeightChannelCatalog, seed: int) -> bool:
	var unique_count := definition.centerline.size() - 1
	var generator_script := load("res://track/track_generator.gd") as GDScript
	var straight_curvature: float = generator_script.STRAIGHT_CURVATURE
	var crest_positions: Array[Vector2] = []
	var stable_ids := {}
	for ramp in placements:
		_check(ramp.is_valid(), "seed %d ramp %s is valid" % [seed, ramp.stable_id])
		_check(not stable_ids.has(ramp.stable_id), "seed %d ramp id %s is unique" % [seed, ramp.stable_id])
		stable_ids[ramp.stable_id] = true
		_check(ramp.stable_id.begins_with("h%d:%d:" % [catalog.version, seed]), "seed %d ramp id carries version and seed" % seed)
		var stable_id_fields := ramp.stable_id.split(":")
		var stable_id_has_shape := stable_id_fields.size() == 4 and stable_id_fields[3].is_valid_int()
		_check(stable_id_has_shape, "seed %d ramp id has four fields and an integer attempt ordinal" % seed)
		_check(is_equal_approx(ramp.half_length, catalog.half_length), "seed %d ramp uses the catalog half length" % seed)
		_check(is_equal_approx(ramp.crest_height, catalog.crest_height()), "seed %d ramp uses the catalog crest height" % seed)
		_check(is_equal_approx(ramp.width, definition.track_width), "seed %d ramp spans the road width" % seed)
		# The crest sits on a centerline sample, and every sample under the approach, both faces,
		# and the landing zone is gentle.
		var crest_index := _nearest_sample(definition.centerline, ramp.transform.origin)
		_check(definition.centerline[crest_index].distance_to(ramp.transform.origin) < 0.01, "seed %d crest sits on a centerline sample" % seed)
		var spacing := definition.lap_length / float(unique_count)
		var before := int(ceil((catalog.approach_clearance + catalog.half_length) / spacing))
		var after := int(ceil((catalog.landing_clearance + catalog.half_length) / spacing))
		var all_gentle := true
		for offset in range(-before, after + 1):
			var index := (crest_index + offset + unique_count) % unique_count
			if _curvature_at(definition.centerline, index) > straight_curvature:
				all_gentle = false
		_check(all_gentle, "seed %d ramp %s has a gentle approach and landing zone" % [seed, ramp.stable_id])
		var axis := ramp.transform.x.normalized()
		var tangent := (definition.centerline[(crest_index + 1) % unique_count] - definition.centerline[crest_index]).normalized()
		_check(absf(axis.dot(tangent)) > 0.999, "seed %d ramp axis follows the centerline" % seed)
		var spawn_distance := ramp.transform.origin.distance_to(definition.spawn_transform.origin)
		_check(spawn_distance >= catalog.spawn_exclusion + catalog.half_length, "seed %d ramp keeps clear of the spawn" % seed)
		for checkpoint in definition.checkpoints:
			var gate_distance := ramp.transform.origin.distance_to(checkpoint.origin)
			_check(gate_distance >= catalog.checkpoint_exclusion + catalog.half_length, "seed %d ramp keeps clear of a gate (%.1f px)" % [seed, gate_distance])
		for other in crest_positions:
			_check(other.distance_to(ramp.transform.origin) >= catalog.minimum_spacing, "seed %d crests respect minimum spacing" % seed)
		crest_positions.append(ramp.transform.origin)
	return true


func _verify_diagnostics(result: JumpRampPlacementResult, catalog: HeightChannelCatalog, seed: int) -> bool:
	var diagnostics := result.diagnostics
	for key in ["eligible_runs", "requested", "placed", "rejected_spawn_candidates", "rejected_checkpoint_candidates", "rejected_spacing_candidates", "underfilled"]:
		_check(diagnostics.has(key), "seed %d diagnostics report %s" % [seed, key])
	for key in ["rejected_spawn_candidates", "rejected_checkpoint_candidates", "rejected_spacing_candidates"]:
		_check(int(diagnostics.get(key, -1)) >= 0, "seed %d diagnostics report a non-negative candidate count for %s" % [seed, key])
	var requested := int(diagnostics.get("requested", -1))
	var placed := int(diagnostics.get("placed", -1))
	_check(requested >= catalog.ramps_per_lap_min and requested <= catalog.ramps_per_lap_max, "seed %d requested count is inside the catalog range" % seed)
	_check(placed == result.placements.size(), "seed %d placed count matches the placement array" % seed)
	_check(bool(diagnostics.get("underfilled")) == (placed < requested), "seed %d underfill flag is honest" % seed)
	return true


## A version bump must move crests through the domain seed, not merely rewrite stable ids and the
## fingerprint, so this repeat check compares geometry only. Under --break-height-seed a changed
## domain seed usually but not always moves a given seed's crests: seeds whose origins legitimately
## coincide across versions still pass the repeat check, which is why _verify_geometry_isolation
## additionally asserts at sweep scope that at least one seed's crest geometry changed.
func _verify_crest_geometry(seed: int, first: Array[JumpRampPlacement], second: Array[JumpRampPlacement]) -> bool:
	var first_origins := _sorted_origins(first)
	var second_origins := _sorted_origins(second)
	var matches := _origins_match(first_origins, second_origins)
	if _break_seed:
		if not matches:
			_geometry_changed_seeds += 1
		_check(matches, "seed %d crest origins repeat across the version bump" % seed)
		return true
	if _break_clearance:
		return true
	_check(matches, "seed %d crest origins repeat without the stable ids" % seed)
	return true


func _verify_geometry_isolation() -> bool:
	if _break_seed:
		_check(_geometry_changed_seeds > 0, "a version bump moves at least one seed's crest origins (%d of 20 changed)" % _geometry_changed_seeds)
	return true


## Seed 4 has several separated eligible runs. With a deliberately high request ceiling it visits
## all of them; adding a gate on one run's attempt-zero crest forces that first candidate to reject
## without changing the chosen crest or attempt ordinal in a later, distant run.
func _verify_retry_stream_isolation() -> bool:
	var definition: TrackDefinition = TrackGenerator.new().generate(4)
	var catalog := (load(CATALOG_PATH) as HeightChannelCatalog).duplicate(true) as HeightChannelCatalog
	catalog.ramps_per_lap_min = 16
	catalog.ramps_per_lap_max = 16
	var placer := JumpRampPlacer.new()
	var first := placer.place(definition, catalog)
	var repeated := placer.place(definition, catalog)
	_check(_placements_equal(first.placements, repeated.placements), "retry placement repeats exactly with the same catalog")
	var rejected_candidate: JumpRampPlacement = null
	var isolated_candidate: JumpRampPlacement = null
	for candidate in first.placements:
		if candidate.stable_id.get_slice(":", 3) != "0":
			continue
		var candidate_run := int(candidate.stable_id.get_slice(":", 2))
		for placement in first.placements:
			var placement_run := int(placement.stable_id.get_slice(":", 2))
			if placement_run == candidate_run:
				continue
			var separation := placement.transform.origin.distance_to(candidate.transform.origin)
			var safely_distant := separation > catalog.minimum_spacing + catalog.checkpoint_exclusion + catalog.half_length
			if placement_run > candidate_run and safely_distant:
				rejected_candidate = candidate
				isolated_candidate = placement
				break
		if rejected_candidate != null:
			break
	_check(rejected_candidate != null, "the isolation fixture accepts a later run's attempt-zero candidate to reject")
	if rejected_candidate == null:
		return false
	_check(isolated_candidate != null, "the isolation fixture has a distant candidate in another run")
	if isolated_candidate == null:
		return false
	var rejected_run := int(rejected_candidate.stable_id.get_slice(":", 2))
	var isolated_run := int(isolated_candidate.stable_id.get_slice(":", 2))
	print("retry_isolation rejected_run=%d isolated_run=%d" % [rejected_run, isolated_run])
	_check(isolated_run > rejected_run, "the retry-isolation oracle observes a later run")
	definition.checkpoints.append(Transform2D(0.0, rejected_candidate.transform.origin))
	var with_rejection := placer.place(definition, catalog)
	_check(_placement_by_id(with_rejection.placements, rejected_candidate.stable_id) == null, "adding a gate on a run's first candidate rejects it")
	var isolated_after := _placement_by_id(with_rejection.placements, isolated_candidate.stable_id)
	_check(isolated_after != null, "rejecting one run's first candidate preserves another run's chosen candidate")
	if isolated_after != null:
		_check(isolated_after.transform.is_equal_approx(isolated_candidate.transform), "rejecting one run's first candidate does not move another run's crest")
	return true


func _verify_height_map_profile() -> bool:
	var definition := TrackDefinition.new()
	definition.track_width = 240.0
	var ramp := JumpRampPlacement.new()
	ramp.stable_id = "h1:0:0"
	ramp.transform = Transform2D(0.0, Vector2(1000.0, 500.0))
	ramp.half_length = 150.0
	ramp.crest_height = 18.0
	ramp.width = 240.0
	definition.jump_ramps.append(ramp)
	var map := TrackHeightMap.new(definition)
	var slope := 18.0 / 150.0
	_check(map.sample_at(Vector2(800.0, 500.0)).ground_height == 0.0, "flat before the ramp")
	_check(is_equal_approx(map.sample_at(Vector2(925.0, 500.0)).ground_height, 9.0), "halfway up the rising face is half the crest")
	_check(map.sample_at(Vector2(925.0, 500.0)).gradient.is_equal_approx(Vector2(slope, 0.0)), "the rising face slopes up along the axis")
	_check(is_equal_approx(map.sample_at(Vector2(1000.0, 500.0)).ground_height, 18.0), "the crest is the crest height")
	_check(is_equal_approx(map.sample_at(Vector2(1075.0, 500.0)).ground_height, 9.0), "halfway down the falling face is half the crest")
	_check(map.sample_at(Vector2(1075.0, 500.0)).gradient.is_equal_approx(Vector2(-slope, 0.0)), "the falling face slopes down along the axis")
	_check(map.sample_at(Vector2(1200.0, 500.0)).ground_height == 0.0, "flat after the ramp")
	_check(map.sample_at(Vector2(1000.0, 500.0 + 121.0)).ground_height == 0.0, "flat beside the road")
	_check(is_equal_approx(map.sample_at(Vector2(1000.0, 500.0 - 119.0)).ground_height, 18.0), "the ramp spans the road width")
	var rotated := ramp.duplicate() as JumpRampPlacement
	rotated.transform = Transform2D(PI * 0.5, Vector2(0.0, 0.0))
	var rotated_definition := TrackDefinition.new()
	rotated_definition.jump_ramps.append(rotated)
	var rotated_map := TrackHeightMap.new(rotated_definition)
	_check(is_equal_approx(rotated_map.sample_at(Vector2(0.0, -75.0)).ground_height, 9.0), "a rotated ramp is sampled in its own frame")
	_check(rotated_map.sample_at(Vector2(0.0, -75.0)).gradient.is_equal_approx(Vector2(0.0, slope)), "a rotated ramp's gradient follows its axis")

	var four := TrackDefinition.new()
	for index in range(4):
		var extra := ramp.duplicate() as JumpRampPlacement
		extra.transform = Transform2D(0.0, Vector2(2000.0 * float(index), 0.0))
		four.jump_ramps.append(extra)
	var four_map := TrackHeightMap.new(four)
	var started := Time.get_ticks_usec()
	var accumulated := 0.0
	for query in range(QUERY_COUNT):
		accumulated += four_map.sample_at(Vector2(float(query % 8000), 0.0)).ground_height
	var elapsed := Time.get_ticks_usec() - started
	print("height_query_usec_per_10k=%d accumulated=%.1f" % [elapsed, accumulated])
	_check(elapsed <= QUERY_BUDGET_USEC, "ten thousand height queries (%d us) stay under 20 ms" % elapsed)
	return true


func _verify_height_map_skips_invalid_records() -> bool:
	var definition := TrackDefinition.new()
	var bad := JumpRampPlacement.new()
	bad.transform = Transform2D(0.0, Vector2(0.0, 0.0))
	bad.crest_height = 0.0
	definition.jump_ramps.append(bad)
	definition.jump_ramps.append(null)
	var map := TrackHeightMap.new(definition)
	_check(map.sample_at(Vector2.ZERO).ground_height == 0.0, "an invalid ramp record contributes no height")
	_check(map.ramp_count() == 0, "invalid and null records are not retained")
	return true


## The flat miss path hands back a shared sample; a consumer writing through it must not corrupt
## later off-ramp queries, because every flat return re-zeros the sample first.
func _verify_flat_sample_resets() -> bool:
	var definition := TrackDefinition.new()
	var ramp := JumpRampPlacement.new()
	ramp.stable_id = "h1:0:0"
	ramp.transform = Transform2D(0.0, Vector2(1000.0, 500.0))
	ramp.half_length = 150.0
	ramp.crest_height = 18.0
	ramp.width = 240.0
	definition.jump_ramps.append(ramp)
	var map := TrackHeightMap.new(definition)
	var poisoned := map.sample_at(Vector2(-500.0, -500.0))
	poisoned.ground_height = 123.0
	poisoned.gradient = Vector2(7.0, 9.0)
	var flat := map.sample_at(Vector2(2500.0, 900.0))
	_check(flat.ground_height == 0.0, "an off-ramp query after a consumer writes to the flat sample still reads flat height")
	_check(flat.gradient.is_equal_approx(Vector2.ZERO), "an off-ramp query after a consumer writes to the flat sample still reads a zero gradient")
	return true


func _verify_fallback() -> bool:
	var generator := TrackGenerator.new()
	var definition: TrackDefinition = generator.generate(17, {"max_attempts": 1})
	_check(definition.used_fallback, "seed 17 with one attempt uses the fallback stadium")
	var catalog := load(CATALOG_PATH) as HeightChannelCatalog
	var result := JumpRampPlacer.new().place(definition, catalog)
	_check(result.placements.size() > 0, "the fallback stadium receives ramps on its straights")
	_check(_verify_rules(definition, result.placements, catalog, 17), "fallback rule verification completed")
	return true


func _nearest_sample(centerline: PackedVector2Array, position: Vector2) -> int:
	var best := 0
	var best_distance := INF
	for index in range(centerline.size() - 1):
		var distance := centerline[index].distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best = index
	return best


func _curvature_at(points: PackedVector2Array, index: int) -> float:
	var unique_count := points.size() - 1
	var incoming := points[index] - points[(index - 1 + unique_count) % unique_count]
	var outgoing := points[(index + 1) % unique_count] - points[index]
	var distance := (incoming.length() + outgoing.length()) * 0.5
	if distance <= 0.0:
		return 0.0
	return absf(incoming.angle_to(outgoing)) / distance


func _placements_equal(first: Array[JumpRampPlacement], second: Array[JumpRampPlacement]) -> bool:
	if first.size() != second.size():
		return false
	for index in range(first.size()):
		var a := first[index]
		var b := second[index]
		if a.stable_id != b.stable_id or not a.transform.is_equal_approx(b.transform):
			return false
		if not is_equal_approx(a.half_length, b.half_length) or not is_equal_approx(a.crest_height, b.crest_height) or not is_equal_approx(a.width, b.width):
			return false
	return true


func _placement_by_id(placements: Array[JumpRampPlacement], stable_id: String) -> JumpRampPlacement:
	for placement in placements:
		if placement.stable_id == stable_id:
			return placement
	return null


func _sorted_origins(placements: Array[JumpRampPlacement]) -> Array[Vector2]:
	var origins: Array[Vector2] = []
	for ramp in placements:
		origins.append(ramp.transform.origin)
	origins.sort_custom(_origin_before)
	return origins


func _origin_before(a: Vector2, b: Vector2) -> bool:
	if a.x == b.x:
		return a.y < b.y
	return a.x < b.x


func _origins_match(first: Array[Vector2], second: Array[Vector2]) -> bool:
	if first.size() != second.size():
		return false
	for index in range(first.size()):
		if not first[index].is_equal_approx(second[index]):
			return false
	return true


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Jump ramp placement checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Jump ramp placement check failed: %s" % failure)
	quit(1)
