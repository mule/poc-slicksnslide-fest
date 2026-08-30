extends SceneTree

const PLACEMENT_P95_BUDGET_USEC := 80_000
const RUNTIME_P95_BUDGET_USEC := 100_000

var _failures: Array[String] = []
var _checks := 0
var _break_runtime_integrity := false


func _initialize() -> void:
	_break_runtime_integrity = OS.get_cmdline_user_args().has("--break-runtime-integrity")
	call_deferred("_run")


func _run() -> void:
	var catalog := load("res://data/default_offtrack_object_catalog.tres") as OfftrackObjectCatalog
	_check(catalog != null, "default off-track object catalog loads for performance verification")
	if catalog != null:
		_check(_verify_budgets(catalog), "the off-track object performance verification ran to completion")
	_finish()


func _verify_budgets(catalog: OfftrackObjectCatalog) -> bool:
	var placement_times: Array[int] = []
	var runtime_times: Array[int] = []
	for seed in range(20):
		var definition: TrackDefinition = TrackGenerator.new().generate(seed)
		placement_times.append(definition.offtrack_object_generation_usec)
		var runtime_placements: Array[OfftrackObjectPlacement] = definition.offtrack_objects
		if _break_runtime_integrity:
			runtime_placements = []
		var started := Time.get_ticks_usec()
		var runtime := OfftrackObjectRuntime.new(runtime_placements, catalog)
		root.add_child(runtime)
		var construction_usec := Time.get_ticks_usec() - started
		runtime_times.append(construction_usec)
		var metrics := runtime.get_metrics()
		var expected_solid_count := _solid_count(definition.offtrack_objects)
		_check(not definition.offtrack_objects.is_empty(), "seed %d produces non-empty object placements for performance verification" % seed)
		_check(int(metrics.get("visuals", -1)) == definition.offtrack_objects.size(), "seed %d runtime visual count matches generated placements" % seed)
		_check(int(metrics.get("solid_visuals", -1)) == expected_solid_count, "seed %d runtime solid visual count matches generated solid placements" % seed)
		_check(int(metrics.get("colliders", -1)) == expected_solid_count, "seed %d runtime collider count matches generated solid placements" % seed)
		_check(int(metrics.get("colliders", -1)) == int(metrics.get("solid_visuals", -1)), "seed %d runtime collider count matches solid visual count" % seed)
		_check(int(metrics.get("decorative_batches", -1)) > 0, "seed %d runtime produces decorative batches" % seed)
		_check(int(metrics.get("collision_chunks", -1)) > 0, "seed %d runtime produces solid collision chunks" % seed)
		print("offtrack_perf seed=%d placement_usec=%d runtime_usec=%d placements=%d batches=%d solid_visuals=%d colliders=%d collision_chunks=%d" % [
			seed,
			definition.offtrack_object_generation_usec,
			construction_usec,
			definition.offtrack_objects.size(),
			int(metrics.get("decorative_batches", 0)),
			int(metrics.get("solid_visuals", 0)),
			int(metrics.get("colliders", 0)),
			int(metrics.get("collision_chunks", 0)),
		])
		runtime.free()
	var placement_p50 := _percentile(placement_times, 0.50)
	var placement_p95 := _percentile(placement_times, 0.95)
	var runtime_p50 := _percentile(runtime_times, 0.50)
	var runtime_p95 := _percentile(runtime_times, 0.95)
	_check(placement_p95 <= PLACEMENT_P95_BUDGET_USEC, "one-time placement-generation p95 is <= 80 ms (got %.2f ms)" % (placement_p95 / 1000.0))
	_check(runtime_p95 <= RUNTIME_P95_BUDGET_USEC, "runtime p95 is <= 100 ms (got %.2f ms)" % (runtime_p95 / 1000.0))
	print("offtrack_perf placement_p50_usec=%d placement_p95_usec=%d runtime_p50_usec=%d runtime_p95_usec=%d" % [placement_p50, placement_p95, runtime_p50, runtime_p95])
	return true


func _solid_count(placements: Array[OfftrackObjectPlacement]) -> int:
	var count := 0
	for placement in placements:
		if placement != null and placement.solid:
			count += 1
	return count


func _percentile(values: Array[int], ratio: float) -> int:
	var ordered := values.duplicate()
	ordered.sort()
	var index := clampi(ceili(ratio * ordered.size()) - 1, 0, ordered.size() - 1)
	return ordered[index]


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("offtrack_performance checks=%d" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Off-track performance check failed: %s" % failure)
	print("offtrack_performance checks=%d failures=%d" % [_checks, _failures.size()])
	quit(1)
