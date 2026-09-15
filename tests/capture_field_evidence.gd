extends SceneTree

## Task #61, part B: evidence that a full field of twenty finishes, and races the same way twice, on
## several seeds; and that the game as launched races its ten.
##
## Everything runs the production session from `session/main.tscn`, each race in a SubViewport of its
## own. The rivals are the session's own ReactiveDrivers sensed by its own SensingPass; the player's
## car sits at pole with no input, as it does in any unattended run, and the field has to get past it.
## This file only watches: each physics frame it reads every rival before the session drives it.
##
## ## What is asserted, per seed
##
## Four races of twenty rivals. Race A is a new session's restart from an idle frame. Race B is a new
## session that first races the next seed's track for OTHER_TRACK_TICKS, then restarts onto the seed
## from a call deferred out of a physics frame -- the second history tests/field_race_test.gd uses.
## A and B have mistakes off; C and D repeat them with mistakes on.
##
## - **Every rival completes the lap** within RACE_TICK_BUDGET.
## - **No rival meets the stuck rule** at any tick from its first sensed tick to its finish: slower
##   than the car's own auto_reset_stuck_speed for auto_reset_stuck_seconds. That is stricter than
##   "ends the race stuck", which a finished car cannot be.
## - **No rival leaves the play area** or strays beyond the car's own lost distance from the road.
## - **Final standings are identical** across A and B: the finishing order, every rival's finishing
##   tick, and every rival's whole control stream at 64 bits.
## - **The mistake log is identical** across C and D, rival by rival -- every entry's plan number,
##   kind, tick, amount, seconds and end -- guarded by the logs holding mistakes of at least two kinds.
##   The finishing order and streams are compared too.
## - The mistake switch is what each pair says it is: off, no rival has mistakes on or logs one.
##
## ## The game as launched
##
## `main.tscn` with nothing overridden: its shipped settings resource, which races ten rivals with
## mistakes on, on the shipped seed. Every rival laps, none meets the stuck rule, none strays, and
## mistakes are logged.
##
## ## Output
##
## A ledger of every race to docs/evidence/ai-opponents/ -- one line each, with SHA-256 digests of the
## control streams and mistake logs -- so two runs of this capture can be compared with diff. Windowed,
## it also saves stills: the launched game's grid and its field under way, and a car going round
## another on seed 41. Headless, the stills are skipped and said to be.
##
## Run windowed:
##   godot --path . --script res://tests/capture_field_evidence.gd
## Options:
##   -- --seeds=a,b,c   race these seeds instead of TUNED_SEEDS + HELD_OUT_SEEDS
##   -- --sweep         one race per seed (race A only, mistakes off) over SWEEP_SEEDS or --seeds, to
##                      its own ledger; no repeat, no launched game, no stills
##   -- --no-launched   skip the launched game

const MAIN_SCENE_PATH := "res://session/main.tscn"
const SHIPPED_SETTINGS_PATH := "res://data/default_session_settings.tres"
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const OUTPUT_DIRECTORY := "res://docs/evidence/ai-opponents"
const LEDGER_NAME := "field-ledger.txt"
const SWEEP_LEDGER_NAME := "field-sweep-ledger.txt"
## The production 1 / 60 s step, ten times faster in real time, as the driver suites run it.
const PHYSICS_TICKS_PER_SECOND := 600
const TIME_SCALE := 10.0
const TICK := 1.0 / 60.0
const FULL_FIELD := 20
const SHIPPED_FIELD := 10
## The seeds the stuck fix was tuned on -- 0, the suites' seed, and 41, where the field was first
## found stuck -- and seeds it was not: first raced at ba10ad0, re-raced on the final driver (e1aa53e).
const TUNED_SEEDS := [0, 41]
const HELD_OUT_SEEDS := [4, 58]
const SWEEP_SEEDS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 41, 58]
const OTHER_TRACK_TICKS := 600
## Four minutes of race. Before the stuck fix, seed 41's field took 148 s.
const RACE_TICK_BUDGET := 14400
## Stills: how far into the launched race, and how long to look for a pass on seed 41.
const LAUNCH_STILL_TICKS := 150
const RACE_STILL_TICKS := 1200
const PASS_STILL_SEED := 41
const PASS_SEARCH_TICKS := 4000

var _failures: Array[String] = []
var _checks := 0
var _tuning: VehicleTuning
var _main_scene: PackedScene
var _seeds: Array[int] = []
var _sweep := false
var _launched := true
var _windowed := false


func _initialize() -> void:
	Engine.physics_ticks_per_second = PHYSICS_TICKS_PER_SECOND
	Engine.time_scale = TIME_SCALE
	# Windowed, a frame waits for the display; with vsync on and the default cap of 8 physics steps a
	# frame, the drawing -- not the simulation -- set the pace. Every step is still 1 / 60 s.
	Engine.max_physics_steps_per_frame = 64
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--seeds="):
			for text in argument.trim_prefix("--seeds=").split(","):
				_seeds.append(int(text))
		_sweep = _sweep or argument == "--sweep"
		_launched = _launched and argument != "--no-launched"
	call_deferred("_run")


func _run() -> void:
	_tuning = load(TUNING_PATH) as VehicleTuning
	_main_scene = load(MAIN_SCENE_PATH) as PackedScene
	_windowed = DisplayServer.get_name() != "headless"
	_check(DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY)) == OK, "the evidence directory exists")
	var ledger: Array[String] = []
	ledger.append("# Field evidence, task #61 part B. One line per race; streams and logs are the first 16 hex digits of a SHA-256.")
	ledger.append("# physics_ticks_per_second=%d time_scale=%.1f step_s=%.6f field=%d player=idle at pole stuck_rule=%d ticks under %.1f px/s" % [PHYSICS_TICKS_PER_SECOND, TIME_SCALE, TICK, FULL_FIELD, _stuck_ticks(), _tuning.auto_reset_stuck_speed])
	if _seeds.is_empty():
		for seed: int in (SWEEP_SEEDS if _sweep else TUNED_SEEDS + HELD_OUT_SEEDS):
			_seeds.append(seed)
	for seed in _seeds:
		if _sweep:
			_check(await _sweep_seed(seed, ledger), "seed %d sweep race ran to completion" % seed)
		else:
			_check(await _verify_seed(seed, ledger), "seed %d races ran to completion" % seed)
	if not _sweep and _launched:
		_check(await _verify_the_game_as_launched(ledger), "the launched game ran to completion")
	if not _sweep:
		if _windowed:
			_check(await _capture_stills(), "the stills ran to completion")
		else:
			print("NOTE: headless, so no stills were saved; run windowed for them.")
	_write("%s/%s" % [OUTPUT_DIRECTORY, SWEEP_LEDGER_NAME if _sweep else LEDGER_NAME], ledger)
	_finish()


# ---------------------------------------------------------------------------------------------
# Seeds


func _set_of(seed: int) -> String:
	return "tuned" if TUNED_SEEDS.has(seed) else "held-out"


func _verify_seed(seed: int, ledger: Array[String]) -> bool:
	var label := "seed %d (%s)" % [seed, _set_of(seed)]
	var a := await _race(seed, FULL_FIELD, false, false)
	var b := await _race(seed, FULL_FIELD, false, true)
	var c := await _race(seed, FULL_FIELD, true, false)
	var d := await _race(seed, FULL_FIELD, true, true)
	for record: Dictionary in [a, b, c, d]:
		_check(_check_race(label, record, FULL_FIELD), "%s %s: the race checks ran to completion" % [label, record.label])
		ledger.append(_ledger_line(seed, record))

	_check(a.order.size() == FULL_FIELD and a.order == b.order, "STANDINGS: %s: mistakes off, both races finish all twenty in the same order (%s against %s)" % [label, a.order, b.order])
	_check(_same_count(a.finish, b.finish) == FULL_FIELD, "STANDINGS: %s: mistakes off, every rival finishes on the same tick in both races (%d of %d)" % [label, _same_count(a.finish, b.finish), FULL_FIELD])
	_check(_same_streams(a, b) == FULL_FIELD, "STANDINGS: %s: mistakes off, every rival's control stream is non-empty and identical at 64 bits (%d of %d)" % [label, _same_streams(a, b), FULL_FIELD])

	var kinds := {}
	for log: Array in c.logs:
		for entry: Dictionary in log:
			kinds[int(entry["kind"])] = true
	var same_logs := 0
	for slot in range(FULL_FIELD):
		same_logs += int(var_to_str(c.logs[slot]) == var_to_str(d.logs[slot]))
	_check(c.logged > 0 and kinds.size() >= 2, "MISTAKE LOG: %s: with mistakes on the field logs mistakes of at least two kinds (%d logged, %d kinds)" % [label, c.logged, kinds.size()])
	_check(c.logged > 0 and same_logs == FULL_FIELD, "MISTAKE LOG: %s: with mistakes on, every rival's mistake log is identical across both races, entry for entry (%d of %d; %d and %d logged)" % [label, same_logs, FULL_FIELD, c.logged, d.logged])
	_check(c.order.size() == FULL_FIELD and c.order == d.order and _same_streams(c, d) == FULL_FIELD, "MISTAKE LOG: %s: and those races finish in the same order with identical streams (%d of %d streams)" % [label, _same_streams(c, d), FULL_FIELD])
	return true


## One race, mistakes off, for the widening sweep: the same per-race assertions, no repeat.
func _sweep_seed(seed: int, ledger: Array[String]) -> bool:
	var record := await _race(seed, FULL_FIELD, false, false)
	_check(_check_race("seed %d (%s)" % [seed, _set_of(seed)], record, FULL_FIELD), "seed %d: the race checks ran to completion" % seed)
	ledger.append(_ledger_line(seed, record))
	return true


func _check_race(label: String, record: Dictionary, field: int) -> bool:
	var race := "%s %s" % [label, record.label]
	var watched: int = record.watched
	_check(record.finished == field, "LAP: %s: every one of the %d rivals completes the lap (%d, in %d ticks)" % [race, field, record.finished, record.ticks])
	_check(watched == field and record.worst_slow < _stuck_ticks(), "STUCK: %s: all %d rivals were watched driving and none meets the stuck rule (%d watched, longest slow streak %d of %d ticks, by rival %d)" % [race, field, watched, record.worst_slow, _stuck_ticks(), record.worst_slow_rival])
	_check(watched == field and record.strayed == 0, "PLAY AREA: %s: all %d rivals were watched driving and none leaves the play area or gets lost (%d watched, %d strayed)" % [race, field, watched, record.strayed])
	if record.mistakes:
		_check(record.switched_on == field, "SWITCH: %s: every rival has mistakes on (%d)" % [race, record.switched_on])
	else:
		_check(record.switched_on == 0 and record.logged == 0, "SWITCH: %s: no rival has mistakes on or logs one (%d on, %d logged)" % [race, record.switched_on, record.logged])
	_check(not record.paused and is_equal_approx(record.step_delta, TICK), "%s: the tree ran unpaused at the production step (%.6f s)" % [race, record.step_delta])
	print("%s: finished %d in %d ticks, worst slow %d (rival %d), contact ticks %d, passes %d, reversals %d, logged %d, order %s" % [race, record.finished, record.ticks, record.worst_slow, record.worst_slow_rival, record.contact_ticks, record.passes, record.reversals, record.logged, record.order])
	return true


func _ledger_line(seed: int, record: Dictionary) -> String:
	return "seed=%d set=%s race=%s finished=%d ticks=%d worst_slow=%d strayed=%d contact_ticks=%d passes=%d reversals=%d logged=%d order=%s finish=%s streams=%s logs=%s" % [
		seed, _set_of(seed), record.label, record.finished, record.ticks, record.worst_slow, record.strayed,
		record.contact_ticks, record.passes, record.reversals, record.logged, record.order, record.finish,
		_digest_streams(record.streams), var_to_str(record.logs).sha256_text().substr(0, 16),
	]


# ---------------------------------------------------------------------------------------------
# The launched game


func _verify_the_game_as_launched(ledger: Array[String]) -> bool:
	var record := await _race(-1, SHIPPED_FIELD, true, false, true)
	var label := "the game as launched"
	_check(record.settings_path == SHIPPED_SETTINGS_PATH, "LAUNCHED: the session runs on the shipped settings resource (%s)" % record.settings_path)
	_check(record.count == SHIPPED_FIELD and record.mounted == SHIPPED_FIELD + 1, "LAUNCHED: the shipped settings race %d rivals, and the session mounts the player and all of them (count %d, %d mounted)" % [SHIPPED_FIELD, record.count, record.mounted])
	_check(_check_race(label, record, SHIPPED_FIELD), "the launched game's race checks ran to completion")
	_check(record.logged > 0, "LAUNCHED: the shipped field makes deliberate mistakes (%d logged)" % record.logged)
	ledger.append("launched seed=%d count=%d mistakes=on finished=%d ticks=%d worst_slow=%d strayed=%d contact_ticks=%d passes=%d reversals=%d logged=%d order=%s finish=%s streams=%s logs=%s" % [
		record.seed, record.count, record.finished, record.ticks, record.worst_slow, record.strayed, record.contact_ticks,
		record.passes, record.reversals, record.logged, record.order, record.finish, _digest_streams(record.streams),
		var_to_str(record.logs).sha256_text().substr(0, 16),
	])
	return true


# ---------------------------------------------------------------------------------------------
# A race


## A race of `count` rivals on `seed`, watched until every rival laps or the budget runs out.
##
## `history` false: a new session restarted onto the seed from an idle frame. True: a new session that
## races the next seed's track first, then restarts onto the seed from a call deferred out of a
## physics frame. `as_launched`: the scene's own settings resource and the race its _ready builds.
func _race(seed: int, count: int, mistakes: bool, history: bool, as_launched := false) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var session := _main_scene.instantiate() as MainSession
	if not as_launched:
		var settings := SessionSettings.new()
		settings.seed = seed + 1 if history else seed
		settings.opponent_count = count
		settings.opponent_mistakes_enabled = mistakes
		session.session_settings = settings
	viewport.add_child(session)
	_hold_focus(session)
	if as_launched:
		# The race is the one _ready just built, watched from before its first physics frame.
		seed = int(session.session_settings.get("seed"))
	elif history:
		await process_frame
		for tick in range(OTHER_TRACK_TICKS):
			await physics_frame
		# Deferred out of a physics frame: it runs after the session's _physics_process and before the
		# step. The next physics_frame is before the new field's first sense.
		await physics_frame
		session.restart_with_seed.call_deferred(seed)
		await physics_frame
	else:
		await process_frame
		session.restart_with_seed(seed)
	var label := "launched" if as_launched else "%s(mistakes %s, %s)" % ["CD"[int(history)] if mistakes else "AB"[int(history)], "on" if mistakes else "off", "in-session restart after seed %d from a physics frame" % (seed + 1) if history else "new session, idle frame"]
	var rivals: Array = session.get("_rivals")
	var definition: TrackDefinition = session.get("_track_definition")
	var surface := TrackSurfaceMap.new(definition)
	var record := {
		"label": label, "seed": seed, "mistakes": mistakes, "count": rivals.size(),
		"mounted": session.get_node("World/VehicleMount").get_child_count(),
		"settings_path": (session.session_settings as Resource).resource_path,
		"order": [], "finished": 0, "ticks": 0, "worst_slow": 0, "worst_slow_rival": 0, "strayed": 0,
		"watched": 0, "contact_ticks": 0, "switched_on": 0, "logged": 0, "passes": 0, "reversals": 0,
		"step_delta": 0.0, "paused": false,
	}
	var finish: Array[int] = []
	var streams: Array[PackedFloat64Array] = []
	var slow: Array[int] = []
	var strayed: Array[bool] = []
	for slot in range(rivals.size()):
		finish.append(-1)
		streams.append(PackedFloat64Array())
		slow.append(0)
		strayed.append(false)
	for frame in range(RACE_TICK_BUDGET + 2):
		# Observed before the session's _physics_process for this frame: the decision the last tick made
		# and the pose the last step left.
		for slot in range(rivals.size()):
			var car := rivals[slot]["car"] as TopDownCar
			var tick := _driver_int(rivals[slot]["driver"], "_tick")
			if tick == 0 or finish[slot] >= 0:
				continue
			if streams[slot].size() / 4 < tick:
				var controls: VehicleInputState = car.get("_input_state")
				streams[slot].append_array(PackedFloat64Array([controls.steer, controls.throttle, controls.brake, controls.handbrake]))
			slow[slot] = slow[slot] + 1 if car.get_speed() < _tuning.auto_reset_stuck_speed else 0
			if slow[slot] > record.worst_slow:
				record.worst_slow = slow[slot]
				record.worst_slow_rival = slot + 1
			if not definition.play_area.has_point(car.global_position) or surface.distance_to_centerline(car.global_position, _tuning.auto_reset_lost_distance * 2.0) > _tuning.auto_reset_lost_distance:
				strayed[slot] = true
			for body in car.get_colliding_bodies():
				if body is TopDownCar:
					record.contact_ticks += 1
					break
			if (rivals[slot]["progress"] as LapProgressTracker).lap_count >= 1:
				finish[slot] = tick
				record.order.append(slot + 1)
				record.ticks = maxi(record.ticks, tick)
		if record.order.size() == rivals.size():
			break
		record.paused = record.paused or paused
		await physics_frame
	record.step_delta = session.get_physics_process_delta_time()
	record.finish = finish
	record.streams = streams
	var logs: Array = []
	for slot in range(rivals.size()):
		var driver: AiDriver = rivals[slot]["driver"]
		record.finished += int(finish[slot] >= 0)
		record.strayed += int(strayed[slot])
		record.watched += int(streams[slot].size() > 0)
		record.switched_on += int(driver.get("mistakes_enabled") == true)
		record.passes += _driver_int(driver, "passes")
		record.reversals += _driver_int(driver, "reversals")
		var log: Array = driver.call("mistake_log") if driver.has_method("mistake_log") else []
		record.logged += log.size()
		logs.append(log)
	record.logs = logs
	viewport.free()
	await process_frame
	return record


# ---------------------------------------------------------------------------------------------
# Stills


## Separate sessions from the races above, so that waiting for a frame to be drawn never costs a race
## an observed tick.
func _capture_stills() -> bool:
	var launched := await _open_still_session(true, 0)
	await _run_ticks(LAUNCH_STILL_TICKS)
	var player: TopDownCar = launched.session.get("_vehicle")
	_check(await _save(launched, "launched-seed-0-grid.png", player.global_position), "STILL: the launched game's field leaving the grid past the idle player")
	await _run_ticks(RACE_STILL_TICKS - LAUNCH_STILL_TICKS)
	var leader := _leading_rival(launched.session)
	_check(await _save(launched, "launched-seed-0-under-way.png", leader.global_position), "STILL: the launched game's leading rival under way (rival %s)" % leader.name)
	launched.viewport.free()
	await process_frame

	var field := await _open_still_session(false, PASS_STILL_SEED)
	var found: TopDownCar = null
	for tick in range(PASS_SEARCH_TICKS):
		for rival: Dictionary in field.session.get("_rivals"):
			if (rival["driver"] as AiDriver).get("passing") == true and (rival["car"] as TopDownCar).get_speed() > WorldScale.metres(3.0):
				found = rival["car"]
		if found != null:
			break
		await physics_frame
	_check(found != null, "STILL: a rival on seed %d goes round a stopped car within %d ticks (%s)" % [PASS_STILL_SEED, PASS_SEARCH_TICKS, found.name if found != null else "none"])
	if found != null:
		_check(await _save(field, "seed-41-going-round.png", found.global_position), "STILL: seed %d, the first tick a rival is going round a stopped car, centred on it (%s)" % [PASS_STILL_SEED, found.name])
	field.viewport.free()
	await process_frame
	return true


func _open_still_session(as_launched: bool, seed: int) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var session := _main_scene.instantiate() as MainSession
	if not as_launched:
		var settings := SessionSettings.new()
		settings.seed = seed
		settings.opponent_count = FULL_FIELD
		session.session_settings = settings
	viewport.add_child(session)
	_hold_focus(session)
	(session.get_node("%DiagnosticsOverlay") as DiagnosticsOverlay).set_release_mode(true)
	await process_frame
	return {"viewport": viewport, "session": session}


func _run_ticks(ticks: int) -> void:
	for tick in range(ticks):
		await physics_frame


## A camera of its own at `focus`, with the simulation all but held while the frame is drawn, so what
## is framed is what was chosen. These sessions assert nothing.
func _save(context: Dictionary, file_name: String, focus: Vector2) -> bool:
	var session: MainSession = context.session
	var viewport: SubViewport = context.viewport
	(session.get_node("%StatusPanel") as Control).visible = false
	var camera := Camera2D.new()
	camera.zoom = Vector2.ONE * _tuning.camera_zoom
	session.add_child(camera)
	camera.global_position = focus
	camera.make_current()
	Engine.time_scale = 0.001
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	Engine.time_scale = TIME_SCALE
	camera.free()
	return image != null and image.save_png(ProjectSettings.globalize_path("%s/%s" % [OUTPUT_DIRECTORY, file_name])) == OK


func _leading_rival(session: MainSession) -> TopDownCar:
	var order := session.get_race_order()
	for index in order:
		if index > 0:
			return (session.get("_rivals") as Array)[index - 1]["car"]
	return session.get("_vehicle")


# ---------------------------------------------------------------------------------------------
# Helpers


## The session pauses the SceneTree when the window loses focus, and a paused tree still emits
## physics_frame; see capture_height_channel_evidence.gd. A capture must not depend on focus.
func _hold_focus(session: MainSession) -> void:
	var lifecycle := session.get_node("ApplicationLifecycle")
	var suspension := Callable(session, "_on_application_suspension_requested")
	if lifecycle.suspension_requested.is_connected(suspension):
		lifecycle.suspension_requested.disconnect(suspension)


func _driver_int(driver: AiDriver, property: String) -> int:
	var value = driver.get(property)
	return int(value) if value != null else 0


func _same_count(left: Array[int], right: Array[int]) -> int:
	var same := 0
	for slot in range(mini(left.size(), right.size())):
		same += int(left[slot] >= 0 and left[slot] == right[slot])
	return same


func _same_streams(left: Dictionary, right: Dictionary) -> int:
	var same := 0
	for slot in range(mini(left.streams.size(), right.streams.size())):
		same += int(left.streams[slot].size() > 0 and left.streams[slot] == right.streams[slot])
	return same


func _digest_streams(streams: Array[PackedFloat64Array]) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	for stream in streams:
		context.update(stream.to_byte_array())
	return context.finish().hex_encode().substr(0, 16)


func _stuck_ticks() -> int:
	return roundi(_tuning.auto_reset_stuck_seconds / TICK)


func _write(path: String, lines: Array[String]) -> void:
	var file := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	_check(file != null, "%s opens for writing" % path)
	if file != null:
		file.store_string("\n".join(lines) + "\n")
		file.close()


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)
	return condition


func _finish() -> void:
	print("Field evidence capture: %d checks, %d failures" % [_checks, _failures.size()])
	quit(0 if _failures.is_empty() else 1)
