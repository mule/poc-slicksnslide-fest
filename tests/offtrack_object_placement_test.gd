extends SceneTree

const ROAD_FINGERPRINTS := {
	0: "c473c35414d6ee31c9abada0c4d5fe4856997f137ca8d7dd6223a45da29bf55f",
	1: "b4b5a88a8be258e58c43567bb2e1ffc9364f21c98bae38ee92e0a087de9fa90e",
	2: "d1e5d0df9651e041374342582d1cccf79193fe8ecb95796baac1eb19217bd7ea",
	3: "a1e4ab9b4425050a266ac40d2bb958b99d303303192c241c02b0822912ed078d",
	4: "4600dc93fe343e17e999276b333051a9538f51c50d02992863af9b4970779155",
	5: "8d530ec157495015293c77e77d2b3f9dfb458db272c3176b1f11bc9e495716b5",
	6: "7fad0c2e88fccb083da767eba455a3b50ed248e8fea025fb43500d14e3ab04d9",
	7: "ed6a92a5ee67e6e67f147fe6382bb266afe356d1de03cdc2322fdeb1d28c2af8",
	8: "d0ff3f39294c44e16a182eabc0283b23842801ce6617c1f79a66001d93929aef",
	9: "3fbe38ff1f6a222c0050cc004bddf93225b5da99176639d4b22f5934ece85670",
	10: "56c585fc00729f4416cd459c57e7b6821b101a83374f9bb2e7443f6633546c42",
	11: "f0237efe220f89c01733e293d377a299f1c39b88843c992b5006bc0512ba51b0",
	12: "5331af0ca10b06d73cb47223caf72bebfa0c87c53df04951a395c24e2646976f",
	13: "a3b44cf2ccee2206c308f0bdc1af8324e32767e59152061a174b887ad3db97a2",
	14: "72af4a69dc7a4a8c5924348879c45258c9fd047fdcf325774a44ba025b781633",
	15: "3c2386bfa626521b3ba4996c2191cefb6902728d9c1ec80c9bd18b8a7c30fa34",
	16: "97458ea8106f57c08f45cc2f6d35611be28bd03e40dcc57431022e129a2d1bb9",
	17: "497f951e560567f3ed51b523ded8761dbad88e94fa347124e56ece7911b60cf4",
	18: "4018845b4baf9e1d3da8b49fc42d02b832771c952fb0616de956b13a150a4597",
	19: "1ccbbd249025dfc5f5d8a05f60fa43933f023bd34cfa38d66d42d66bc066bbda",
}

const PLACEMENT_TIME_BUDGET_USEC := 50000
const EPSILON := 0.01

var _failures: Array[String] = []
var _checks := 0
var _break_seed := false
var _break_clearance := false


func _initialize() -> void:
	_break_seed = OS.get_cmdline_user_args().has("--break-seed")
	_break_clearance = OS.get_cmdline_user_args().has("--break-clearance")
	call_deferred("_run")


func _run() -> void:
	_check(_verify_placement_sweep(), "the twenty-seed placement sweep ran to completion")
	_finish()


func _verify_placement_sweep() -> bool:
	var catalog := load("res://data/default_offtrack_object_catalog.tres") as OfftrackObjectCatalog
	_check(catalog != null, "default off-track object catalog loads")
	if catalog == null:
		return false
	var placer := OfftrackObjectPlacer.new()
	var generator := TrackGenerator.new()
	var generation_times: Array[int] = []
	for seed in range(20):
		_check(_verify_seed(seed, generator, placer, catalog, generation_times), "seed %d placement verification ran to completion" % seed)
	_check(_verify_performance_budget(generation_times), "placement p95 stays within the 50 ms budget")
	_check(_verify_fallback(generator, placer, catalog), "fallback placement verification ran to completion")
	return true


func _verify_seed(seed: int, generator: TrackGenerator, placer: OfftrackObjectPlacer, catalog: OfftrackObjectCatalog, generation_times: Array[int]) -> bool:
	var definition = generator.generate(seed)
	_check(definition != null, "seed %d produces a track definition" % seed)
	if definition == null:
		return false
	var road_fingerprint = definition.geometry_fingerprint
	var first := placer.place(definition, catalog)
	generation_times.append(first.generation_usec)
	print("seed=%d placement_usec=%d cells=%d placements=%d" % [seed, first.generation_usec, first.diagnostics.get("total_cells", -1), first.placements.size()])
	var second_catalog := catalog.duplicate(true) as OfftrackObjectCatalog
	if _break_seed:
		second_catalog.version += 1
	if _break_clearance:
		second_catalog.solid_clearance = 0.0
	var second := placer.place(definition, second_catalog)

	_check(first.fingerprint.length() == 64, "seed %d produces a SHA-256 object fingerprint" % seed)
	_check(first.fingerprint == second.fingerprint, "seed %d placement fingerprint repeats" % seed)
	_check(_placements_equal(first.placements, second.placements), "seed %d placements repeat exactly" % seed)
	_check(is_equal_approx(second_catalog.solid_clearance, WorldScale.metres(20.0)), "seed %d run retains the approved 20 m solid clearance" % seed)
	_check(definition.geometry_fingerprint == road_fingerprint, "seed %d road fingerprint is unchanged" % seed)
	_check(definition.geometry_fingerprint == ROAD_FINGERPRINTS[seed], "seed %d road fingerprint matches the pre-B baseline" % seed)
	_check(_verify_zones(definition, first.placements, catalog, seed), "seed %d zone verification completed" % seed)
	_check(_verify_solid_overlap(first.placements, catalog, seed), "seed %d overlap verification completed" % seed)
	_check(_verify_diagnostics(first, catalog, seed), "seed %d diagnostics verification completed" % seed)
	if _break_clearance:
		_check(_verify_zones(definition, second.placements, catalog, seed), "seed %d recovery corridor remains clear after placement" % seed)
	return true


func _verify_zones(definition: TrackDefinition, placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog, seed: int) -> bool:
	var surface := TrackSurfaceMap.new(definition)
	for placement in placements:
		var archetype := catalog.archetype_by_id(placement.archetype_id)
		_check(archetype != null, "seed %d placement uses a known archetype" % seed)
		if archetype == null:
			continue
		var position := placement.transform.origin
		var scale_factor := placement.scale_factor
		var footprint := archetype.footprint_radius * scale_factor
		var edge_distance := surface.distance_to_centerline(position, catalog.hazard_max_distance + definition.track_width) - definition.track_width * 0.5
		var contracted_play_area := definition.play_area.grow(-(catalog.containment_buffer + footprint))
		_check(is_finite(position.x) and is_finite(position.y) and is_finite(placement.transform.get_rotation()), "seed %d placement transform is finite" % seed)
		_check(is_finite(scale_factor) and scale_factor > 0.0, "seed %d placement scale is positive" % seed)
		_check(is_finite(edge_distance) and edge_distance - footprint >= -EPSILON, "seed %d object footprint stays off the road" % seed)
		_check(edge_distance + footprint <= catalog.hazard_max_distance + EPSILON, "seed %d object footprint stays in the hazard bound" % seed)
		_check(contracted_play_area.has_point(position), "seed %d object footprint stays inside containment" % seed)
		if edge_distance <= catalog.near_max_distance + EPSILON:
			_check(archetype.near_weight > 0.0, "seed %d near-shoulder object is allowed by catalog" % seed)
		else:
			_check(archetype.hazard_weight > 0.0, "seed %d hazard object is allowed by catalog" % seed)
		if placement.solid:
			_check(archetype.solid, "seed %d solid placement matches archetype" % seed)
			_check(edge_distance - footprint >= catalog.solid_clearance - EPSILON, "seed %d solid placement leaves the recovery corridor" % seed)
			_check(position.distance_to(definition.spawn_transform.origin) >= catalog.spawn_checkpoint_exclusion + footprint - EPSILON, "seed %d solid placement leaves spawn exclusion" % seed)
			for checkpoint in definition.checkpoints:
				_check(position.distance_to(checkpoint.origin) >= catalog.spawn_checkpoint_exclusion + footprint - EPSILON, "seed %d solid placement leaves checkpoint exclusion" % seed)
		else:
			_check(not archetype.solid, "seed %d decorative placement is non-solid" % seed)
	return true


func _verify_solid_overlap(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog, seed: int) -> bool:
	for first_index in range(placements.size()):
		var first := placements[first_index]
		if not first.solid:
			continue
		var first_archetype := catalog.archetype_by_id(first.archetype_id)
		if first_archetype == null:
			continue
		var first_radius := first_archetype.collision_radius * first.scale_factor
		for second_index in range(first_index + 1, placements.size()):
			var second := placements[second_index]
			if not second.solid:
				continue
			var second_archetype := catalog.archetype_by_id(second.archetype_id)
			if second_archetype == null:
				continue
			var second_radius := second_archetype.collision_radius * second.scale_factor
			_check(first.transform.origin.distance_to(second.transform.origin) >= first_radius + second_radius - EPSILON, "seed %d solid collision circles do not overlap" % seed)
	return true


func _verify_diagnostics(result: OfftrackObjectPlacementResult, catalog: OfftrackObjectCatalog, seed: int) -> bool:
	_check(result.diagnostics.has("total_cells"), "seed %d diagnostics report total cells" % seed)
	_check(result.diagnostics.has("zones"), "seed %d diagnostics report zones" % seed)
	if not result.diagnostics.has("zones"):
		return false
	var total_accepted := 0
	for zone_name in [&"near_shoulder", &"hazard"]:
		var zone: Dictionary = result.diagnostics.zones.get(zone_name, {})
		for field in [&"valid_cells", &"occupied_draws", &"accepted"]:
			_check(zone.has(field) and int(zone.get(field, -1)) >= 0, "seed %d %s diagnostics report %s" % [seed, zone_name, field])
		for rule in [&"road_or_recovery", &"containment", &"spawn_checkpoint", &"solid_overlap"]:
			_check(zone.has(rule) and int(zone.get(rule, -1)) >= 0, "seed %d %s diagnostics report %s rejections" % [seed, zone_name, rule])
		var occupied := int(zone.get("occupied_draws", 0))
		var accepted := int(zone.get("accepted", 0))
		var underfilled := bool(zone.get("underfilled", false))
		_check(accepted <= occupied, "seed %d %s accepted count is bounded by occupied draws" % [seed, zone_name])
		if occupied > 0:
			_check(underfilled == (float(accepted) / float(occupied) < catalog.minimum_fill_ratio), "seed %d %s underfill diagnostic is accurate" % [seed, zone_name])
		total_accepted += accepted
	_check(total_accepted == result.placements.size(), "seed %d diagnostics accepted count matches placements" % seed)
	return true


func _verify_fallback(generator: TrackGenerator, placer: OfftrackObjectPlacer, catalog: OfftrackObjectCatalog) -> bool:
	var fallback = generator.generate(271828, {"max_attempts": 1, "min_lap_length": 100000.0})
	_check(fallback != null and fallback.used_fallback, "impossible road request returns a fallback")
	if fallback == null:
		return false
	var result := placer.place(fallback, catalog)
	_check(_verify_zones(fallback, result.placements, catalog, 271828), "fallback placements obey the same zone rules")
	_check(_verify_solid_overlap(result.placements, catalog, 271828), "fallback placements obey solid overlap rules")
	_check(result.fingerprint.length() == 64, "fallback placements have a SHA-256 fingerprint")
	return true


func _verify_performance_budget(times: Array[int]) -> bool:
	if times.is_empty():
		return false
	var sorted := times.duplicate()
	sorted.sort()
	var p95_index := mini(sorted.size() - 1, maxi(0, ceili(float(sorted.size()) * 0.95) - 1))
	var p95: int = sorted[p95_index]
	print("placement p95_usec=%d max_usec=%d" % [p95, sorted[-1]])
	_check(p95 <= PLACEMENT_TIME_BUDGET_USEC, "placement p95 is at most 50 ms (got %d us)" % p95)
	return true


func _placements_equal(first: Array[OfftrackObjectPlacement], second: Array[OfftrackObjectPlacement]) -> bool:
	if first.size() != second.size():
		return false
	for index in range(first.size()):
		var left := first[index]
		var right := second[index]
		if left.stable_id != right.stable_id or left.archetype_id != right.archetype_id:
			return false
		if not left.transform.is_equal_approx(right.transform):
			return false
		if not is_equal_approx(left.scale_factor, right.scale_factor) or left.visual_variant != right.visual_variant:
			return false
		if left.solid != right.solid or left.collision_profile != right.collision_profile:
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
		print("offtrack_placement checks=%d" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Off-track placement check failed: %s" % failure)
	print("offtrack_placement checks=%d" % _checks)
	quit(1)
