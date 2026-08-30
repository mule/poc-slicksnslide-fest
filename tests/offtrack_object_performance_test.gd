extends SceneTree

const PLACEMENT_P95_BUDGET_USEC := 80_000
const RUNTIME_P95_BUDGET_USEC := 100_000

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
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
		var started := Time.get_ticks_usec()
		var runtime := OfftrackObjectRuntime.new(definition.offtrack_objects, catalog)
		root.add_child(runtime)
		var construction_usec := Time.get_ticks_usec() - started
		runtime_times.append(construction_usec)
		var metrics := runtime.get_metrics()
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
