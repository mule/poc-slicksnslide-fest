extends SceneTree

## Task #61, part B: what a field of reactive rivals costs the game, at 0, 1, 5, 10 and 20 rivals.
##
## The production session from `session/main.tscn` in the game's own window, on SEED, its rivals the
## ReactiveDrivers it spawns, the player idle at pole. Physics at the production 60 ticks a second in
## real time, vsync off and the frame rate uncapped, so a frame takes as long as its work and no
## longer. Each count is measured over the first MEASURE_TICKS of its race, launch included, after
## WARMUP_TICKS.
##
## ## What is measured
##
## - **Sensing across the field** and **driver decisions**, per physics tick: MainSession._drive_field
##   timed in a subclass whose body is the production body with clock reads between its loops -- the
##   sense loop, then the perceive, drive and checkpoint loop.
## - **Physics tick span**: wall time from the tree's physics_frame signal to the process_frame that
##   follows it, on frames holding exactly one physics tick. That spans every _physics_process -- the
##   field's drive included -- and the physics server's step. It does not hold the cars'
##   _integrate_forces, where each car's own surface and height queries run: the query pass measures
##   those alone at more than the span leaves beyond the field's drive. The frame figure holds them.
## - **Frame**: wall time between consecutive process_frame signals, on frames holding one physics
##   tick, and on frames holding none; with the renderer's own CPU and GPU times for the root viewport.
##   For both, the 99th percentile and how many frames took longer than BUDGET_MS.
## - **Height and surface queries across the field**: a second, sped-up pass with every query the cars
##   and the sensing pass make routed through timing wrappers, reported per tick and per query. The
##   wrapper's own cost per call is measured and reported beside them, not subtracted.
##
## Every figure is wall-clock on one machine and moves with load; the machine's load average is
## recorded at the start and end. Nothing else may run while this does.
##
## ## What is asserted
##
## Only that the measurement measures the production field: the timed session and the query-wrapped
## session each leave all twenty rivals and the player at bit-identical poses after WRAP_CHECK_TICKS,
## against the production session; every count's session spawned that many rivals and was measured
## over MEASURE_TICKS of physics. The budget is reported, not asserted.
##
## Run windowed:
##   godot --path . --script res://tests/capture_field_cost.gd

const MAIN_SCENE_PATH := "res://session/main.tscn"
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const OUTPUT_PATH := "res://docs/evidence/ai-opponents/field-cost.txt"
const COUNTS := [0, 1, 5, 10, 20]
const SEED := 0
const WARMUP_TICKS := 60
const MEASURE_TICKS := 3600
const QUERY_TICKS := 1200
const WRAP_CHECK_TICKS := 1200
const BUDGET_MS := 16.6
const QUERY_PASS_TICKS_PER_SECOND := 600
const QUERY_PASS_TIME_SCALE := 10.0


## MainSession._drive_field, line for line, with clock reads between its loops.
class TimedSession extends MainSession:
	var timing := false
	var sense_usec := PackedInt64Array()
	var decide_usec := PackedInt64Array()

	func _drive_field(delta: float) -> void:
		if _rivals.is_empty():
			return
		var start := Time.get_ticks_usec()
		var field := _field_cars()
		var driving: Array[Dictionary] = []
		for rival in _rivals:
			var car := field[int(rival["index"])]
			if car == null:
				continue
			if car.consume_auto_reset_notice():
				(rival["detector"] as CheckpointCrossingDetector).reset(car.get_safe_reset_pose().origin)
				continue
			driving.append(rival)
		var senses: Array[DriverSenses] = []
		for rival in driving:
			senses.append(_sensing.sense(field, int(rival["index"]), (rival["driver"] as AiDriver).sensing_horizon()))
		var sensed := Time.get_ticks_usec()
		for slot in range(driving.size()):
			var rival := driving[slot]
			var car := field[int(rival["index"])]
			var driver := rival["driver"] as AiDriver
			driver.perceive(senses[slot])
			car.set_input_state(driver.drive(delta))
			var crossing: Dictionary = (rival["detector"] as CheckpointCrossingDetector).sample(car.global_position)
			if not crossing.is_empty():
				(rival["progress"] as LapProgressTracker).cross_checkpoint(
					int(crossing.get("checkpoint", -1)),
					float(crossing.get("forward_dot", 0.0)),
				)
		if timing:
			sense_usec.append(sensed - start)
			decide_usec.append(Time.get_ticks_usec() - sensed)


## Time spent in queries, by who asked and what.
class QueryClock extends RefCounted:
	var usec := {}
	var calls := {}

	func add(key: String, spent: int) -> void:
		usec[key] = usec.get(key, 0) + spent
		calls[key] = calls.get(key, 0) + 1


class TimedSurface extends SurfaceQuery:
	var inner: SurfaceQuery
	var clock: QueryClock
	var who: String

	func _init(wrapped: SurfaceQuery, shared: QueryClock, caller: String) -> void:
		inner = wrapped
		clock = shared
		who = caller

	func sample_at(world_position: Vector2) -> SurfaceSample:
		var start := Time.get_ticks_usec()
		var result := inner.sample_at(world_position)
		clock.add(who + " surface.sample_at", Time.get_ticks_usec() - start)
		return result

	func distance_to_centerline(world_position: Vector2, search_radius: float) -> float:
		var start := Time.get_ticks_usec()
		var result := inner.distance_to_centerline(world_position, search_radius)
		clock.add(who + " surface.distance_to_centerline", Time.get_ticks_usec() - start)
		return result

	func road_frame_at(world_position: Vector2, search_radius: float) -> RoadFrame:
		var start := Time.get_ticks_usec()
		var result := inner.road_frame_at(world_position, search_radius)
		clock.add(who + " surface.road_frame_at", Time.get_ticks_usec() - start)
		return result


class TimedHeight extends HeightQuery:
	var inner: HeightQuery
	var clock: QueryClock
	var who: String

	func _init(wrapped: HeightQuery, shared: QueryClock, caller: String) -> void:
		inner = wrapped
		clock = shared
		who = caller

	func sample_at(world_position: Vector2) -> HeightSample:
		var start := Time.get_ticks_usec()
		var result := inner.sample_at(world_position)
		clock.add(who + " height.sample_at", Time.get_ticks_usec() - start)
		return result


var _failures: Array[String] = []
var _checks := 0
var _tuning: VehicleTuning
var _main_scene: PackedScene
var _lines: Array[String] = []
## Per physics tick and per frame, filled by the two signal handlers while a count is measured.
var _measuring := false
var _physics_start := 0
var _physics_this_frame := 0
var _last_frame := 0
var _physics_usec := PackedInt64Array()
var _frame_with_tick_usec := PackedInt64Array()
var _frame_without_tick_usec := PackedInt64Array()
var _render_cpu_ms := PackedFloat64Array()
var _render_gpu_ms := PackedFloat64Array()
var _ticks_seen := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_tuning = load(TUNING_PATH) as VehicleTuning
	_main_scene = load(MAIN_SCENE_PATH) as PackedScene
	_check(DisplayServer.get_name() != "headless", "the cost capture runs in a window, where frames are drawn (display server %s)" % DisplayServer.get_name())
	_lines.append("# Field cost, task #61 part B. Seed %d, the production session in the game window, player idle at pole." % SEED)
	_lines.append("# %s; renderer %s; load average at start %s" % [OS.get_processor_name(), RenderingServer.get_video_adapter_name(), _load_average()])
	_check(await _verify_the_instruments_change_nothing(), "the instrument check ran to completion")
	Engine.physics_ticks_per_second = 60
	Engine.time_scale = 1.0
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_lines.append("# physics %d ticks/s at time scale %.1f; vsync %d (0 = off); max_fps %d" % [Engine.physics_ticks_per_second, Engine.time_scale, DisplayServer.window_get_vsync_mode(), Engine.max_fps])
	physics_frame.connect(_on_physics_frame)
	process_frame.connect(_on_process_frame)
	var results := {}
	for count: int in COUNTS:
		results[count] = await _measure_count(count)
	physics_frame.disconnect(_on_physics_frame)
	process_frame.disconnect(_on_process_frame)
	_report_frames(results)
	Engine.physics_ticks_per_second = QUERY_PASS_TICKS_PER_SECOND
	Engine.time_scale = QUERY_PASS_TIME_SCALE
	_check(await _measure_queries(), "the query pass ran to completion")
	_lines.append("# load average at end %s" % _load_average())
	var file := FileAccess.open(ProjectSettings.globalize_path(OUTPUT_PATH), FileAccess.WRITE)
	_check(file != null, "%s opens for writing" % OUTPUT_PATH)
	if file != null:
		file.store_string("\n".join(_lines) + "\n")
		file.close()
	for line in _lines:
		print(line)
	_finish()


# ---------------------------------------------------------------------------------------------
# Signals


func _on_physics_frame() -> void:
	_physics_start = Time.get_ticks_usec()
	_physics_this_frame += 1
	_ticks_seen += 1


func _on_process_frame() -> void:
	var now := Time.get_ticks_usec()
	if _measuring and _last_frame > 0:
		if _physics_this_frame == 1:
			_physics_usec.append(now - _physics_start)
			_frame_with_tick_usec.append(now - _last_frame)
			var viewport := root.get_viewport_rid()
			_render_cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(viewport))
			_render_gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(viewport))
		elif _physics_this_frame == 0:
			_frame_without_tick_usec.append(now - _last_frame)
	_last_frame = now
	_physics_this_frame = 0


# ---------------------------------------------------------------------------------------------
# Frames


func _measure_count(count: int) -> Dictionary:
	var session := _timed_session(count)
	root.add_child(session)
	_hold_focus(session)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	for tick in range(WARMUP_TICKS):
		await physics_frame
	session.restart_with_seed(SEED)
	_physics_usec.clear()
	_frame_with_tick_usec.clear()
	_frame_without_tick_usec.clear()
	_render_cpu_ms.clear()
	_render_gpu_ms.clear()
	_last_frame = 0
	_ticks_seen = 0
	session.timing = true
	_measuring = true
	while _ticks_seen < MEASURE_TICKS:
		await process_frame
	_measuring = false
	session.timing = false
	var result := {
		"count": count,
		"rivals": (session.get("_rivals") as Array).size(),
		"ticks": _ticks_seen,
		"sense": _stats(session.sense_usec),
		"decide": _stats(session.decide_usec),
		"physics": _stats(_physics_usec),
		"frame_tick": _stats(_frame_with_tick_usec),
		"frame_idle": _stats(_frame_without_tick_usec),
		"render_cpu": _stats_ms(_render_cpu_ms),
		"render_gpu": _stats_ms(_render_gpu_ms),
		"paused": paused,
	}
	_check(result.rivals == count and result.ticks >= MEASURE_TICKS and not result.paused, "%d rivals: the session spawned %d and was measured unpaused over %d physics ticks (%d frames with one tick)" % [count, result.rivals, result.ticks, _physics_usec.size()])
	_check(count == 0 or session.sense_usec.size() >= MEASURE_TICKS - 2, "%d rivals: the field's drive was timed on every measured tick (%d)" % [count, session.sense_usec.size()])
	session.free()
	await process_frame
	return result


func _report_frames(results: Dictionary) -> void:
	_lines.append("")
	_lines.append("## Per physics tick and per frame, microseconds: mean / p95 / max")
	_lines.append("| Rivals | Sensing | Decisions | Physics tick | Frame with a tick | Frame without | Render CPU ms | Render GPU ms |")
	_lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
	for count: int in COUNTS:
		var r: Dictionary = results[count]
		_lines.append("| %d | %s | %s | %s | %s | %s | %.3f | %.3f |" % [count, _triple(r.sense), _triple(r.decide), _triple(r.physics), _triple(r.frame_tick), _triple(r.frame_idle), r.render_cpu.mean, r.render_gpu.mean])
	_lines.append("")
	_lines.append("## Frames longer than %.1f ms, and the 99th percentile, microseconds" % BUDGET_MS)
	_lines.append("| Rivals | Frames with a tick over budget | Their p99 | Frames without a tick over budget | Their p99 |")
	_lines.append("| --- | --- | --- | --- | --- |")
	for count: int in COUNTS:
		var r: Dictionary = results[count]
		_lines.append("| %d | %d of %d (%.3f%%) | %.0f | %d of %d (%.3f%%) | %.0f |" % [count, r.frame_tick.over, r.frame_tick.n, 100.0 * r.frame_tick.over / maxf(r.frame_tick.n, 1), r.frame_tick.p99, r.frame_idle.over, r.frame_idle.n, 100.0 * r.frame_idle.over / maxf(r.frame_idle.n, 1), r.frame_idle.p99])
	_lines.append("")
	_lines.append("## Per-car marginal cost of the mean, microseconds per added rival, between consecutive counts")
	_lines.append("| From | To | Sensing | Decisions | Physics tick | Frame with a tick |")
	_lines.append("| --- | --- | --- | --- | --- | --- |")
	for step in range(1, COUNTS.size()):
		var lo: Dictionary = results[COUNTS[step - 1]]
		var hi: Dictionary = results[COUNTS[step]]
		var cars := float(COUNTS[step] - COUNTS[step - 1])
		_lines.append("| %d | %d | %.1f | %.1f | %.1f | %.1f |" % [COUNTS[step - 1], COUNTS[step], (hi.sense.mean - lo.sense.mean) / cars, (hi.decide.mean - lo.decide.mean) / cars, (hi.physics.mean - lo.physics.mean) / cars, (hi.frame_tick.mean - lo.frame_tick.mean) / cars])
	var full: Dictionary = results[COUNTS[COUNTS.size() - 1]]
	_lines.append("")
	_lines.append("## Budget at %d rivals: frame with a tick mean %.2f ms, p95 %.2f ms, max %.2f ms against %.1f ms: headroom at p95 %.2f ms" % [COUNTS[COUNTS.size() - 1], full.frame_tick.mean / 1000.0, full.frame_tick.p95 / 1000.0, full.frame_tick.max / 1000.0, BUDGET_MS, BUDGET_MS - full.frame_tick.p95 / 1000.0])


func _triple(s: Dictionary) -> String:
	return "%.0f / %.0f / %.0f" % [s.mean, s.p95, s.max]


func _stats(values: PackedInt64Array) -> Dictionary:
	if values.is_empty():
		return {"mean": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0, "n": 0, "over": 0}
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0
	for value in sorted:
		total += value
	var over := 0
	for value in sorted:
		over += int(value > BUDGET_MS * 1000.0)
	return {"mean": float(total) / sorted.size(), "p95": float(sorted[mini(sorted.size() - 1, int(sorted.size() * 0.95))]), "p99": float(sorted[mini(sorted.size() - 1, int(sorted.size() * 0.99))]), "max": float(sorted[sorted.size() - 1]), "n": sorted.size(), "over": over}


func _stats_ms(values: PackedFloat64Array) -> Dictionary:
	if values.is_empty():
		return {"mean": 0.0}
	var total := 0.0
	for value in values:
		total += value
	return {"mean": total / values.size()}


# ---------------------------------------------------------------------------------------------
# Queries


func _measure_queries() -> bool:
	_lines.append("")
	_lines.append("## Height and surface queries across the field, sped up (%d ticks/s at time scale %.0f), over %d ticks from the start" % [QUERY_PASS_TICKS_PER_SECOND, QUERY_PASS_TIME_SCALE, QUERY_TICKS])
	var overhead := _wrapper_overhead_usec()
	_lines.append("# a timing wrapper's own cost, measured around the base query's empty sample_at: %.2f us per call, included in every figure below" % overhead)
	_lines.append("| Rivals | Asked by | Query | Calls per tick | us per tick | us per call |")
	_lines.append("| --- | --- | --- | --- | --- | --- |")
	for count: int in COUNTS:
		if count == 0:
			continue
		var session := _new_session(count)
		root.add_child(session)
		_hold_focus(session)
		await process_frame
		session.restart_with_seed(SEED)
		var clock := QueryClock.new()
		_wrap_queries(session, clock)
		for tick in range(QUERY_TICKS):
			await physics_frame
		var keys := clock.usec.keys()
		keys.sort()
		for key: String in keys:
			var parts := key.split(" ")
			_lines.append("| %d | %s | %s | %.1f | %.0f | %.2f |" % [count, parts[0], parts[1], float(clock.calls[key]) / QUERY_TICKS, float(clock.usec[key]) / QUERY_TICKS, float(clock.usec[key]) / clock.calls[key]])
		session.free()
		await process_frame
	return true


func _wrap_queries(session: MainSession, clock: QueryClock) -> void:
	var surface: SurfaceQuery = session.get("_field_surface_map")
	var runtime: TrackRuntime = session.get("_track_runtime")
	var height := runtime.height_query()
	var car_surface := TimedSurface.new(surface, clock, "car")
	var car_height := TimedHeight.new(height, clock, "car")
	for car in session.call("_field_cars"):
		(car as TopDownCar).set_surface_query(car_surface)
		(car as TopDownCar).set_height_query(car_height)
	if session.get("_sensing") != null:
		session.set("_sensing", SensingPass.new(TimedSurface.new(surface, clock, "sensing"), TimedHeight.new(height, clock, "sensing")))


func _wrapper_overhead_usec() -> float:
	var clock := QueryClock.new()
	var wrapped := TimedHeight.new(HeightQuery.new(), clock, "empty")
	var calls := 100000
	for call in range(calls):
		wrapped.sample_at(Vector2.ZERO)
	return float(clock.usec["empty height.sample_at"]) / calls


# ---------------------------------------------------------------------------------------------
# The instruments change nothing


## The timed session and the query-wrapped session each drive the same race as the production session:
## after WRAP_CHECK_TICKS every car's transform and velocity are bit-identical.
func _verify_the_instruments_change_nothing() -> bool:
	Engine.physics_ticks_per_second = QUERY_PASS_TICKS_PER_SECOND
	Engine.time_scale = QUERY_PASS_TIME_SCALE
	var production := await _poses_after(_new_session(20), false)
	var timed_session := _timed_session(20)
	var timed := await _poses_after(timed_session, false, true)
	var wrapped := await _poses_after(_new_session(20), true)
	_check(production.size() == 21 and production.size() == timed.size() and production.size() == wrapped.size(), "the three sessions each hold the player and twenty rivals (%d, %d, %d)" % [production.size(), timed.size(), wrapped.size()])
	var moved := 0
	for index in range(production.size()):
		moved += int((production[index] as Array)[0] != Transform2D.IDENTITY and (production[index] as Array)[1] != Vector2.ZERO)
	_check(moved >= 20, "the production field is moving after %d ticks, so identical poses mean something (%d of %d cars moving)" % [WRAP_CHECK_TICKS, moved, production.size()])
	_check(var_to_str(production) == var_to_str(timed), "INSTRUMENTS: the timed session leaves every car where the production session does, after %d ticks" % WRAP_CHECK_TICKS)
	_check(var_to_str(production) == var_to_str(wrapped), "INSTRUMENTS: the query-wrapped session leaves every car where the production session does, after %d ticks" % WRAP_CHECK_TICKS)
	return true


func _poses_after(session: MainSession, wrap: bool, timing := false) -> Array:
	root.add_child(session)
	_hold_focus(session)
	await process_frame
	session.restart_with_seed(SEED)
	if wrap:
		_wrap_queries(session, QueryClock.new())
	if timing:
		session.set("timing", true)
	for tick in range(WRAP_CHECK_TICKS):
		await physics_frame
	var poses: Array = []
	for car in session.call("_field_cars"):
		poses.append([(car as TopDownCar).global_transform, (car as TopDownCar).linear_velocity])
	session.free()
	await process_frame
	return poses


# ---------------------------------------------------------------------------------------------
# Helpers


func _new_session(count: int) -> MainSession:
	var session := _main_scene.instantiate() as MainSession
	session.session_settings = _settings(count)
	return session


func _timed_session(count: int) -> TimedSession:
	var session := _main_scene.instantiate()
	session.set_script(TimedSession)
	session.vehicle_tuning = _tuning
	session.session_settings = _settings(count)
	return session as TimedSession


func _settings(count: int) -> SessionSettings:
	var settings := SessionSettings.new()
	settings.seed = SEED
	settings.opponent_count = count
	return settings


func _hold_focus(session: MainSession) -> void:
	var lifecycle := session.get_node("ApplicationLifecycle")
	var suspension := Callable(session, "_on_application_suspension_requested")
	if lifecycle.suspension_requested.is_connected(suspension):
		lifecycle.suspension_requested.disconnect(suspension)


func _load_average() -> String:
	var output: Array = []
	OS.execute("cat", ["/proc/loadavg"], output)
	return (output[0] as String).strip_edges() if not output.is_empty() else "unknown"


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)
	return condition


func _finish() -> void:
	print("Field cost capture: %d checks, %d failures" % [_checks, _failures.size()])
	quit(0 if _failures.is_empty() else 1)
