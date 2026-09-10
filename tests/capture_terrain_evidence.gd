extends SceneTree

## Graphical desktop evidence for the terrain field (#52). Three parts, all against the production
## generator and the production session:
##
## 1. A seeds 0..19 ledger: the terrain fingerprint, the terrain seed, amplitude statistics over the
##    fingerprint grid of each play area (min, max, mean, RMS height and the steepest gradient) and
##    the road's own height range and climb, beside the road, object and height fingerprints those
##    seeds already carry. Every fingerprint is generated twice and must repeat; the three older
##    fingerprints must equal the checked-in height-channel ledger byte for byte, so this capture
##    proves the terrain moved none of them.
## 2. Stills on seeds 0, 4 and 9: the car on the road's highest terrain sample (a hill), on its
##    steepest light-facing sample (a slope-shaded stretch of road), and before the ramp whose crest
##    stands on the most shaped ground (a ramp sitting on terrain), overlay off.
## 3. A scripted lap on each of those seeds through the production session -- the pure-pursuit
##    driver from tests/vehicle_terrain_test.gd -- recording climb and descent speeds, every flight
##    and where it landed, resets and slow streaks, with a still at the first flight's apex and at
##    its landing. Then a seed restart, checked to replace the track and the terrain without
##    retaining a node.
##
## Physics runs at the production step throughout: the drives step the server five times faster in
## real time (300 ticks a second at time scale 5, so each step is still 1 / 60 s), and the step is
## pinned by a level-ground coast against the integrator's own model before any lap is scored.
## Run windowed, not headless:
##   godot --path . --script res://tests/capture_terrain_evidence.gd

const MAIN_SCENE_PATH := "res://session/main.tscn"
const OUTPUT_DIRECTORY := "res://docs/evidence/terrain"
const LEDGER_PATH := OUTPUT_DIRECTORY + "/terrain-ledger-seeds-0-19.txt"
const DRIVE_TRACE_PATH := OUTPUT_DIRECTORY + "/drive-trace-seeds-0-4-9.txt"
## The height-channel ledger #37 checked in, whose road, object and height fingerprints this
## capture must reproduce.
const PRIOR_LEDGER_PATH := "res://docs/evidence/height-channel/desktop-trace-seeds-0-4-9.txt"
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const LEDGER_SEEDS := 20
const CAPTURE_SEEDS := [0, 4, 9]
const RESTART_SEED := 5
const WARMUP_FRAMES := 30
## A seed's play area must show real relief for the ledger to mean anything: two fifths of the
## catalog's total amplitude, 21 px, peak to trough.
const RELIEF_FLOOR_FRACTION := 0.4
## Distance before the ramp's foot the car is parked for the ramp still, so the whole ramp and
## the ground it sits on are in frame with the car on the approach.
const RAMP_STILL_APPROACH := 200.0
const TICK := 1.0 / 60.0
const PHYSICS_TICKS_PER_SECOND := 300
const TIME_SCALE := 5.0
const LAP_TICK_BUDGET := 12000
const STEP_PIN_TICKS := 90
const STEP_PIN_SPEED := 500.0
## Grounded ticks with the ground rising this steeply along the heading count as a climb; falling,
## as a descent. A twelfth of the catalog's slope bound, the threshold tests/vehicle_terrain_test.gd uses.
const SLOPE_THRESHOLD := 0.01
## A flight that starts on bare terrain -- not on a ramp or its flank -- is a launch the epic says
## cannot happen at any speed the car reaches; the drive counts them and requires zero.
const STUCK_TICKS := 60

var _failures: Array[String] = []
var _checks := 0
var _tuning: VehicleTuning


## Pure-pursuit steering on the centreline with a speed governor that brakes for the tightest
## corner inside its braking distance. Full throttle everywhere the governor allows. A copy of the
## driver tests/vehicle_terrain_test.gd laps with, so the lap here is the lap that suite measures.
class LapDriver:
	extends RefCounted

	const LOOKAHEAD_SECONDS := 0.45
	const LOOKAHEAD_MIN := 120.0
	const LOOKAHEAD_MAX := 420.0
	const STEER_GAIN := 2.2
	const LATERAL_BUDGET := 170.0
	const GOVERNOR_WINDOW := 1400.0
	const SPEED_DEADBAND := 12.0
	const SEARCH_WINDOW := 40

	var _points := PackedVector2Array()
	var _curvatures := PackedFloat64Array()
	var _spacing := 1.0
	var _count := 0
	var _index := 0
	var _brake_acceleration := 1.0


	func _init(definition: TrackDefinition, brake_acceleration: float) -> void:
		_count = definition.centerline.size() - 1
		_points = definition.centerline.slice(0, _count)
		_spacing = definition.lap_length / float(_count)
		_brake_acceleration = brake_acceleration
		for index in range(_count):
			var incoming := _points[index] - _points[(index - 1 + _count) % _count]
			var outgoing := _points[(index + 1) % _count] - _points[index]
			var distance := (incoming.length() + outgoing.length()) * 0.5
			_curvatures.append(absf(incoming.angle_to(outgoing)) / distance if distance > 0.0 else 0.0)


	func controls(position: Vector2, forward: Vector2, speed: float) -> Dictionary:
		var best := _index
		var best_distance := position.distance_squared_to(_points[_index])
		for step in range(1, SEARCH_WINDOW):
			var candidate := (_index + step) % _count
			var distance := position.distance_squared_to(_points[candidate])
			if distance < best_distance:
				best_distance = distance
				best = candidate
		_index = best
		var lookahead := clampf(speed * LOOKAHEAD_SECONDS, LOOKAHEAD_MIN, LOOKAHEAD_MAX)
		var target := _points[(_index + int(lookahead / _spacing)) % _count]
		var steer := clampf(forward.angle_to(target - position) * STEER_GAIN, -1.0, 1.0)
		var allowed := INF
		for step in range(int(GOVERNOR_WINDOW / _spacing)):
			var curvature := _curvatures[(_index + step) % _count]
			if curvature <= 1e-6:
				continue
			var corner_speed := sqrt(LATERAL_BUDGET / curvature)
			var distance := maxf(float(step - 1) * _spacing, 0.0)
			allowed = minf(allowed, sqrt(corner_speed * corner_speed + 2.0 * _brake_acceleration * distance))
		return {
			"steer": steer,
			"throttle": 1.0 if speed < allowed - SPEED_DEADBAND else 0.0,
			"brake": 1.0 if speed > allowed + SPEED_DEADBAND else 0.0,
		}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_tuning = load(TUNING_PATH) as VehicleTuning
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	_check(directory_error == OK, "evidence output directory exists")
	var main_scene := load(MAIN_SCENE_PATH) as PackedScene
	_check(main_scene != null, "the production main scene loads")
	var ledger: Array[String] = []
	_check(_record_ledger(ledger), "the ledger ran to completion")
	_write(LEDGER_PATH, ledger)
	var drive: Array[String] = []
	drive.append("# Terrain drive trace")
	drive.append("# renderer=graphical SubViewport=1280x720 overlay=off driver=pure-pursuit physics_ticks_per_second=%d time_scale=%.1f step_s=%.5f" % [PHYSICS_TICKS_PER_SECOND, TIME_SCALE, TIME_SCALE / float(PHYSICS_TICKS_PER_SECOND)])
	drive.append("# a climb is a grounded tick with the ground rising more than %.3f along the heading; a descent, falling more than that" % SLOPE_THRESHOLD)
	_check(await _pin_physics_step(), "the sped-up physics steps at the production step")
	for seed in CAPTURE_SEEDS:
		_check(await _capture_seed(main_scene, seed, drive), "seed %d stills and drive ran to completion" % seed)
	_check(await _verify_seed_restart(main_scene), "the seed restart verification ran to completion")
	_write(DRIVE_TRACE_PATH, drive)
	_finish()


## Seeds 0..19, each generated twice. The terrain statistics are taken over the fingerprint grid
## of the play area -- the same samples the fingerprint hashes -- and along the road's centreline.
func _record_ledger(lines: Array[String]) -> bool:
	var generator := TrackGenerator.new()
	var catalog: TerrainCatalog = TrackGenerator.DEFAULT_TERRAIN_CATALOG
	var prior := _prior_ledger()
	_check(prior.size() == LEDGER_SEEDS, "the checked-in height-channel ledger lists %d seeds to compare against (%d)" % [LEDGER_SEEDS, prior.size()])
	lines.append("# Terrain ledger, seeds 0..%d" % (LEDGER_SEEDS - 1))
	lines.append("# catalog v%d amplitude=%.1f base_wavelength=%.0f octaves=%d persistence=%.3f lacunarity=%.2f total_amplitude=%.2f slope_bound=%.5f curvature_bound=%.10f" % [
		catalog.version, catalog.amplitude, catalog.base_wavelength, catalog.octaves, catalog.persistence, catalog.lacunarity,
		catalog.total_amplitude(), catalog.slope_bound(), catalog.curvature_bound(),
	])
	lines.append("# terrain statistics over the fingerprint grid (one sample every %.0f px of the play area); road statistics along the centreline" % TerrainField.FINGERPRINT_SPACING)
	var seen: Dictionary = {}
	var relief_floor := RELIEF_FLOOR_FRACTION * catalog.total_amplitude()
	var hex := RegEx.new()
	hex.compile("^[0-9a-f]{64}$")
	var prior_matches := 0
	var repeats := 0
	var well_formed := 0
	var distinct := 0
	var within_amplitude := 0
	var within_slope := 0
	var relief := 0
	var min_relief := INF
	var max_height_overall := -INF
	var min_height_overall := INF
	for seed in range(LEDGER_SEEDS):
		var definition: TrackDefinition = generator.generate(seed)
		var again: TrackDefinition = generator.generate(seed)
		var field := TerrainField.for_track(seed, catalog)
		var area: Rect2 = definition.play_area
		var columns := TerrainField.fingerprint_columns(area)
		var rows := TerrainField.fingerprint_rows(area)
		var lowest := INF
		var highest := -INF
		var total := 0.0
		var total_squared := 0.0
		var steepest := 0.0
		var count := 0
		for row in rows:
			for column in columns:
				var position := Vector2(area.position.x + column * TerrainField.FINGERPRINT_SPACING, area.position.y + row * TerrainField.FINGERPRINT_SPACING)
				var sample := field.sample_at(position)
				lowest = minf(lowest, sample.ground_height)
				highest = maxf(highest, sample.ground_height)
				total += sample.ground_height
				total_squared += sample.ground_height * sample.ground_height
				steepest = maxf(steepest, maxf(absf(sample.gradient.x), absf(sample.gradient.y)))
				count += 1
		var road_lowest := INF
		var road_highest := -INF
		var climb := 0.0
		var previous := field.height_at(definition.centerline[0])
		for point in definition.centerline:
			var height := field.height_at(point)
			road_lowest = minf(road_lowest, height)
			road_highest = maxf(road_highest, height)
			climb += maxf(height - previous, 0.0)
			previous = height
		lines.append("ledger seed=%d terrain_seed=%d terrain=%s samples=%d min_px=%.2f max_px=%.2f mean_px=%.2f rms_px=%.2f steepest_gradient=%.5f road_min_px=%.2f road_max_px=%.2f road_climb_px=%.1f ramps=%d terrain_usec=%d height=%s road=%s objects=%s" % [
			seed, definition.terrain_seed, definition.terrain_fingerprint, count, lowest, highest, total / count, sqrt(total_squared / count), steepest,
			road_lowest, road_highest, climb, definition.jump_ramps.size(), definition.terrain_generation_usec,
			definition.height_fingerprint, definition.geometry_fingerprint, definition.offtrack_object_fingerprint,
		])
		if hex.search(definition.terrain_fingerprint) != null:
			well_formed += 1
		if again.terrain_fingerprint == definition.terrain_fingerprint and again.terrain_seed == definition.terrain_seed:
			repeats += 1
		if not seen.has(definition.terrain_fingerprint):
			distinct += 1
		seen[definition.terrain_fingerprint] = true
		if lowest >= -catalog.total_amplitude() and highest <= catalog.total_amplitude():
			within_amplitude += 1
		if steepest <= catalog.slope_bound():
			within_slope += 1
		if highest - lowest >= relief_floor:
			relief += 1
		min_relief = minf(min_relief, highest - lowest)
		max_height_overall = maxf(max_height_overall, highest)
		min_height_overall = minf(min_height_overall, lowest)
		var record: Dictionary = prior.get(seed, {})
		if record.get("height", "") == definition.height_fingerprint and record.get("road", "") == definition.geometry_fingerprint and record.get("objects", "") == definition.offtrack_object_fingerprint:
			prior_matches += 1
	lines.append("ledger seeds=%d distinct_terrain_fingerprints=%d min_relief_px=%.2f height_range_px=%.2f..%.2f prior_fingerprints_matched=%d" % [LEDGER_SEEDS, distinct, min_relief, min_height_overall, max_height_overall, prior_matches])
	_check(well_formed == LEDGER_SEEDS, "every terrain fingerprint is 64 lowercase hex digits (%d of %d)" % [well_formed, LEDGER_SEEDS])
	_check(repeats == LEDGER_SEEDS, "every seed's terrain fingerprint and terrain seed repeat on a second generation (%d of %d)" % [repeats, LEDGER_SEEDS])
	_check(distinct == LEDGER_SEEDS, "every seed's terrain fingerprint is distinct (%d of %d)" % [distinct, LEDGER_SEEDS])
	_check(within_amplitude == LEDGER_SEEDS, "every seed's sampled heights stay within the catalog's total amplitude of %.1f px (%d of %d)" % [catalog.total_amplitude(), within_amplitude, LEDGER_SEEDS])
	_check(within_slope == LEDGER_SEEDS, "every seed's steepest sampled gradient stays under the catalog's slope bound %.5f (%d of %d)" % [catalog.slope_bound(), within_slope, LEDGER_SEEDS])
	_check(relief == LEDGER_SEEDS, "every seed's play area spans at least %.1f px of relief (least %.1f), so the ledger describes real hills" % [relief_floor, min_relief])
	_check(prior_matches == LEDGER_SEEDS, "the road, object and height fingerprints of every seed equal the checked-in height-channel ledger (%d of %d): terrain moved none of them" % [prior_matches, LEDGER_SEEDS])
	return true


## The `ledger seed=N ... height=H road=R objects=O` lines of the #37 trace, by seed.
func _prior_ledger() -> Dictionary:
	var records: Dictionary = {}
	var file := FileAccess.open(PRIOR_LEDGER_PATH, FileAccess.READ)
	if file == null:
		return records
	while not file.eof_reached():
		var line := file.get_line()
		if not line.begins_with("ledger seed="):
			continue
		var record: Dictionary = {}
		for token in line.split(" "):
			var parts := token.split("=", true, 1)
			if parts.size() == 2:
				record[parts[0]] = parts[1]
		if record.has("height") and record.has("road") and record.has("objects"):
			records[int(record["seed"])] = record
	file.close()
	return records


func _capture_seed(main_scene: PackedScene, seed: int, lines: Array[String]) -> bool:
	var context := await _open_session(main_scene, seed)
	var viewport: SubViewport = context["viewport"]
	var camera: Camera2D = context["camera"]
	var car: TopDownCar = context["car"]
	var session: MainSession = context["session"]
	var runtime: TrackRuntime = context["runtime"]
	var definition: TrackDefinition = runtime.definition
	var query := runtime.height_query()
	var shading := runtime.get_node("TerrainShading") as TerrainShading
	# The lap first, from the spawn the session seated the car at, so no teleport for a still can
	# register as a checkpoint crossing; then the stills at the ordinary rate.
	Engine.physics_ticks_per_second = PHYSICS_TICKS_PER_SECOND
	Engine.time_scale = TIME_SCALE
	_check(await _drive_lap(context, lines), "seed %d: the lap drive ran to completion" % seed)
	Engine.physics_ticks_per_second = 60
	Engine.time_scale = 1.0
	# The road's highest terrain-only sample and its steepest light-facing one.
	var highest := -1
	var steepest := -1
	var highest_height := -INF
	var steepest_light := -INF
	for index in range(definition.centerline.size()):
		var sample := query.sample_at(definition.centerline[index])
		if sample.on_feature:
			continue
		if sample.ground_height > highest_height:
			highest_height = sample.ground_height
			highest = index
		var light := absf(shading.light_term(sample.gradient))
		if light > steepest_light:
			steepest_light = light
			steepest = index
	_check(highest >= 0 and steepest >= 0, "seed %d has terrain-only road samples to frame" % seed)
	for shot in [["hill", highest], ["slope", steepest]]:
		var shot_name: String = shot[0]
		var index: int = shot[1]
		var position := definition.centerline[index]
		var heading := (definition.centerline[(index + 1) % definition.centerline.size()] - position).normalized()
		_check(await _seat_car(car, position, heading), "seed %d: the car is seated for the %s still" % [seed, shot_name])
		var sample := query.sample_at(car.global_position)
		lines.append("still=%s seed=%d file=seed-%d-%s.png position=(%.1f, %.1f) height=%.2f gradient=(%.4f, %.4f) height_term=%.3f light_term=%.3f car_height=%.2f" % [
			shot_name, seed, seed, shot_name, car.global_position.x, car.global_position.y, sample.ground_height, sample.gradient.x, sample.gradient.y,
			shading.height_term(sample.ground_height), shading.light_term(sample.gradient), car.get_height(),
		])
		_check(absf(car.get_height() - sample.ground_height) < 1e-6, "seed %d: the %s still's car rides at the height its tint was drawn from" % [seed, shot_name])
		_check(await _save(session, viewport, camera, car.global_position, "seed-%d-%s.png" % [seed, shot_name]), "seed %d: the %s still is saved" % [seed, shot_name])
	# The ramp whose crest stands on the most shaped ground: terrain under the crest furthest
	# from zero. The car is parked on the approach so the still shows the ramp, its terrain and the
	# car about to take it.
	var ramp: JumpRampPlacement = null
	var ramp_terrain := 0.0
	var bare := TerrainField.for_track(seed, TrackGenerator.DEFAULT_TERRAIN_CATALOG)
	for candidate in definition.jump_ramps:
		var terrain := bare.height_at(candidate.transform.origin)
		if ramp == null or absf(terrain) > absf(ramp_terrain):
			ramp = candidate
			ramp_terrain = terrain
	_check(ramp != null, "seed %d places a ramp for the ramp-on-terrain still" % seed)
	if ramp != null:
		var axis := ramp.transform.x.normalized()
		var foot := ramp.transform.origin - axis * ramp.half_length
		var landing := ramp.transform.origin + axis * ramp.half_length
		var summed := query.sample_at(ramp.transform.origin).ground_height
		_check(await _seat_car(car, foot - axis * RAMP_STILL_APPROACH, axis), "seed %d: the car is parked on the approach to ramp %s" % [seed, ramp.stable_id])
		lines.append("still=ramp-on-terrain seed=%d file=seed-%d-ramp-on-terrain.png ramp=%s crest=(%.1f, %.1f) terrain_at_foot_px=%.2f terrain_at_crest_px=%.2f terrain_at_landing_px=%.2f crest_px=%.2f summed_crest_px=%.2f car_ground_px=%.2f" % [
			seed, seed, ramp.stable_id, ramp.transform.origin.x, ramp.transform.origin.y, bare.height_at(foot), ramp_terrain, bare.height_at(landing), ramp.crest_height, summed, car.get_height(),
		])
		_check(absf(summed - (ramp_terrain + ramp.crest_height)) < 1e-3, "seed %d: the production map's crest height is terrain plus the wedge (%.2f = %.2f + %.2f)" % [seed, summed, ramp_terrain, ramp.crest_height])
		_check(absf(ramp_terrain) > 1.0 or absf(bare.height_at(foot) - bare.height_at(landing)) > 1.0, "seed %d: the framed ramp stands on shaped ground (crest terrain %.2f px, foot %.2f, landing %.2f)" % [seed, ramp_terrain, bare.height_at(foot), bare.height_at(landing)])
		_check(await _save(session, viewport, camera, ramp.transform.origin, "seed-%d-ramp-on-terrain.png" % seed), "seed %d: the ramp-on-terrain still is saved" % seed)
	_close_session(context)
	await process_frame
	return true


## A level-ground full-throttle run from a known speed must match the integrator's longitudinal
## model tick for tick at the sped-up rate, as tests/vehicle_terrain_test.gd pins with the same
## model; otherwise the laps below would be scored on a different step from the one a player
## drives. A standalone car on flat ground and a dirt surface, outside any session.
func _pin_physics_step() -> bool:
	Engine.physics_ticks_per_second = PHYSICS_TICKS_PER_SECOND
	Engine.time_scale = TIME_SCALE
	var world := Node2D.new()
	root.add_child(world)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = _tuning
	var pose := Transform2D(atan2(1.0, 0.0), Vector2.ZERO)
	car.global_transform = Transform2D(pose.get_rotation(), Vector2(STEP_PIN_SPEED * TICK, 0.0))
	car.set_surface_query(Issue4TestSurfaceProvider.new())
	car.set_height_query(HeightQuery.new())
	car.global_transform = pose
	world.add_child(car)
	car.linear_velocity = Vector2(STEP_PIN_SPEED, 0.0)
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	for tick in range(STEP_PIN_TICKS):
		await physics_frame
	var speed := STEP_PIN_SPEED
	for tick in range(STEP_PIN_TICKS):
		speed += (_tuning.engine_force / _tuning.mass_kg) * TICK
		var drag := (_tuning.rolling_drag * absf(speed) + _tuning.aerodynamic_drag * speed * speed) * TICK
		speed = move_toward(speed, 0.0, drag)
		speed = minf(speed, _tuning.max_safe_speed)
	print("physics_step ticks=%d real=%.4f model=%.4f travelled=%.1f ticks_per_second=%d time_scale=%.1f" % [STEP_PIN_TICKS, car.get_speed(), speed, car.global_position.x, Engine.physics_ticks_per_second, Engine.time_scale])
	_check(absf(car.get_speed() - speed) < 0.05, "on level ground the real car matches the integrator's model to 0.05 px/s (%.4f against %.4f) at %d ticks a second and time scale %.1f, so each step is the production 1 / 60 s" % [car.get_speed(), speed, PHYSICS_TICKS_PER_SECOND, TIME_SCALE])
	_check(car.global_position.x > 0.9 * STEP_PIN_SPEED * STEP_PIN_TICKS * TICK, "the car travelled the distance %d production ticks imply (%.1f px)" % [STEP_PIN_TICKS, car.global_position.x])
	Engine.physics_ticks_per_second = 60
	Engine.time_scale = 1.0
	world.queue_free()
	await process_frame
	return true


func _drive_lap(context: Dictionary, lines: Array[String]) -> bool:
	var viewport: SubViewport = context["viewport"]
	var camera: Camera2D = context["camera"]
	var car: TopDownCar = context["car"]
	var session: MainSession = context["session"]
	var runtime: TrackRuntime = context["runtime"]
	var definition: TrackDefinition = runtime.definition
	var seed: int = definition.seed
	var map := TrackHeightMap.new(definition)
	var surface := TrackSurfaceMap.new(definition)
	car.set_auto_reset_enabled(true)
	# The restart's "Seed N ready" banner is session UI, not the world; the air-time notice the
	# session raises on landing is left alone, as the #37 landing stills left it.
	(session.get_node("%StatusPanel") as Control).visible = false
	_check(car.global_position.distance_to(definition.spawn_transform.origin) < 1.0 and not car.is_airborne(), "seed %d: the lap starts from the spawn the session seated the car at" % seed)
	var driver := LapDriver.new(definition, _tuning.brake_force / _tuning.mass_kg)
	var controls := VehicleInputState.new()
	var laps_before := int(session.get_session_snapshot().get("lap_count", 0))
	var result := {
		"ticks": 0, "completed": false, "top": 0.0, "min_after_start": INF,
		"climb_ticks": 0, "climb_min": INF, "climb_max": 0.0, "climb_speed_sum": 0.0,
		"descent_ticks": 0, "descent_max": 0.0, "descent_speed_sum": 0.0, "level_speed_sum": 0.0, "level_ticks": 0,
		"flights": 0, "flights_from_ramp": 0, "flights_from_terrain": 0, "airborne_ticks": 0, "landings_on_dirt": 0, "landings_off_dirt": 0,
		"longest_air_s": 0.0, "highest_apex_over_ground": 0.0, "resets": 0, "slow_streak": 0, "contacts": 0,
		"steepest_climb": 0.0, "steepest_descent": 0.0,
	}
	var slow_streak := 0
	var was_airborne := false
	var flight_apex := 0.0
	var apex_saved := false
	var landing_saved := false
	var apex_image: Image = null
	var wall_start := Time.get_ticks_msec()
	for tick in range(LAP_TICK_BUDGET):
		var forward := -car.global_transform.y.normalized()
		var command := driver.controls(car.global_position, forward, car.get_speed())
		controls.steer = command.steer
		controls.throttle = command.throttle
		controls.brake = command.brake
		car.set_input_state(controls)
		await physics_frame
		result.ticks += 1
		var speed := car.get_speed()
		var airborne := car.is_airborne()
		var position := car.global_position
		forward = -car.global_transform.y.normalized()
		var sample := map.sample_at(position)
		var along := sample.gradient.dot(forward)
		if not airborne:
			result.top = maxf(result.top, speed)
			if along > SLOPE_THRESHOLD:
				result.climb_ticks += 1
				result.climb_min = minf(result.climb_min, speed)
				result.climb_max = maxf(result.climb_max, speed)
				result.climb_speed_sum += speed
				result.steepest_climb = maxf(result.steepest_climb, along)
			elif along < -SLOPE_THRESHOLD:
				result.descent_ticks += 1
				result.descent_max = maxf(result.descent_max, speed)
				result.descent_speed_sum += speed
				result.steepest_descent = maxf(result.steepest_descent, -along)
			else:
				result.level_ticks += 1
				result.level_speed_sum += speed
		if tick >= 60:
			result.min_after_start = minf(result.min_after_start, speed)
		if speed < _tuning.auto_reset_stuck_speed:
			slow_streak += 1
			result.slow_streak = maxi(result.slow_streak, slow_streak)
		else:
			slow_streak = 0
		if not car.get_colliding_bodies().is_empty():
			result.contacts += 1
		if airborne:
			result.airborne_ticks += 1
			var over_ground := car.get_height() - sample.ground_height
			result.highest_apex_over_ground = maxf(result.highest_apex_over_ground, over_ground)
			result.longest_air_s = maxf(result.longest_air_s, car.get_air_time())
			if not was_airborne:
				result.flights += 1
				flight_apex = 0.0
				if sample.on_feature or _on_ramp(definition, position):
					result.flights_from_ramp += 1
				else:
					result.flights_from_terrain += 1
					lines.append("launch seed=%d tick=%d position=(%.1f, %.1f) speed=%.1f ground=%.2f on_bare_terrain" % [seed, tick, position.x, position.y, speed, sample.ground_height])
			if over_ground > flight_apex and not apex_saved:
				flight_apex = over_ground
				camera.global_position = position
				await RenderingServer.frame_post_draw
				apex_image = viewport.get_texture().get_image()
		elif was_airborne:
			var on_dirt := surface.sample_at(position).surface_type == SurfaceQuery.SurfaceType.DIRT
			if on_dirt:
				result.landings_on_dirt += 1
			else:
				result.landings_off_dirt += 1
			lines.append("landing seed=%d tick=%d position=(%.1f, %.1f) speed=%.1f ground=%.2f on_dirt=%s apex_over_ground=%.2f" % [seed, tick, position.x, position.y, speed, sample.ground_height, on_dirt, flight_apex])
			if not apex_saved and apex_image != null:
				apex_saved = apex_image.save_png(ProjectSettings.globalize_path("%s/seed-%d-drive-apex.png" % [OUTPUT_DIRECTORY, seed])) == OK
			if not landing_saved:
				landing_saved = await _save(session, viewport, camera, position, "seed-%d-drive-landing.png" % seed)
		was_airborne = airborne
		if car.consume_auto_reset_notice():
			result.resets += 1
		if int(session.get_session_snapshot().get("lap_count", 0)) > laps_before:
			result.completed = true
			break
	# The session's own clock, which counts every simulated tick, including those that passed
	# while a still was waiting on a draw.
	var lap_time := float(session.get_session_snapshot().get("last_lap_time", 0.0)) if result.completed else float(session.get_session_snapshot().get("current_lap_time", 0.0))
	var climb_mean: float = result.climb_speed_sum / result.climb_ticks if result.climb_ticks > 0 else 0.0
	var descent_mean: float = result.descent_speed_sum / result.descent_ticks if result.descent_ticks > 0 else 0.0
	var level_mean: float = result.level_speed_sum / result.level_ticks if result.level_ticks > 0 else 0.0
	lines.append("lap seed=%d completed=%s ticks=%d lap_s=%.1f real_s=%.1f top_kph=%.1f min_after_start_kph=%.1f level_mean_kph=%.1f climb_ticks=%d climb_mean_kph=%.1f climb_min_kph=%.1f steepest_climb=%.4f descent_ticks=%d descent_mean_kph=%.1f descent_max_kph=%.1f steepest_descent=%.4f flights=%d from_ramp=%d from_bare_terrain=%d airborne_ticks=%d longest_air_s=%.2f highest_apex_over_ground_px=%.2f landings_on_dirt=%d landings_off_dirt=%d resets=%d longest_slow_streak_ticks=%d contact_ticks=%d" % [
		seed, result.completed, result.ticks, lap_time, (Time.get_ticks_msec() - wall_start) / 1000.0, WorldScale.to_kph(result.top), WorldScale.to_kph(result.min_after_start), WorldScale.to_kph(level_mean),
		result.climb_ticks, WorldScale.to_kph(climb_mean), WorldScale.to_kph(result.climb_min), result.steepest_climb,
		result.descent_ticks, WorldScale.to_kph(descent_mean), WorldScale.to_kph(result.descent_max), result.steepest_descent,
		result.flights, result.flights_from_ramp, result.flights_from_terrain, result.airborne_ticks, result.longest_air_s, result.highest_apex_over_ground,
		result.landings_on_dirt, result.landings_off_dirt, result.resets, result.slow_streak, result.contacts,
	])
	_check(result.completed, "seed %d: the scripted lap completes through the production session in %.1f s" % [seed, lap_time])
	_check(result.resets == 0, "seed %d: no automatic reset fired on the lap (%d)" % [seed, result.resets])
	_check(result.slow_streak < STUCK_TICKS, "seed %d: the car never sat below the stuck speed for a second (longest %d ticks)" % [seed, result.slow_streak])
	_check(result.climb_ticks > 0 and result.descent_ticks > 0, "seed %d: the lap has both climbs (%d ticks) and descents (%d ticks), so the speeds below are measured on real slopes" % [seed, result.climb_ticks, result.descent_ticks])
	_check(result.flights > 0, "seed %d: the lap includes at least one flight (%d), so the landing checks are live" % [seed, result.flights])
	_check(result.flights_from_terrain == 0, "seed %d: every flight left from a ramp or its flank, none from bare terrain (%d of %d)" % [seed, result.flights_from_ramp, result.flights])
	_check(result.landings_off_dirt == 0, "seed %d: every landing came down on the road (%d on, %d off)" % [seed, result.landings_on_dirt, result.landings_off_dirt])
	_check(result.descent_max <= _tuning.max_safe_speed + 1e-3, "seed %d: no descent exceeded max_safe_speed (%.1f of %.1f px/s)" % [seed, result.descent_max, _tuning.max_safe_speed])
	_check(apex_saved and landing_saved, "seed %d: the first flight's apex and landing stills are saved" % seed)
	return true


## Inside a ramp's footprint or its flank, in the ramp's own frame.
func _on_ramp(definition: TrackDefinition, position: Vector2) -> bool:
	for ramp in definition.jump_ramps:
		var local := ramp.transform.affine_inverse() * position
		if absf(local.x) <= ramp.half_length and absf(local.y) <= ramp.width * 0.5 + ramp.flank_width:
			return true
	return false


## A seed restart must replace the track, its terrain shading and its objects, retaining no node
## of the previous seed, and the new shading must be the new seed's. Task #60 runs the same
## teardown against a full field: twenty-one cars must all go with the restart.
func _verify_seed_restart(main_scene: PackedScene) -> bool:
	var context := await _open_session(main_scene, CAPTURE_SEEDS[0])
	var session: MainSession = context["session"]
	var default_runtime := session.get_node("World/TrackMount/GeneratedTrack")
	var default_shading := default_runtime.get_node("TerrainShading")
	var default_ground := default_shading.get_node("Ground")
	var default_objects := default_runtime.get_node("OfftrackObjects")
	var default_car := session.get_node("World/VehicleMount/PlayerCar")
	_check(session.get_field_size() == 1, "default restart fixture starts with the shipped single-car field")
	session.restart_with_seed(RESTART_SEED)
	_check(not is_instance_valid(default_car) and not is_instance_valid(default_runtime) and not is_instance_valid(default_shading) and not is_instance_valid(default_ground) and not is_instance_valid(default_objects), "default count-zero restart frees car, track, shading, ground and objects")
	_check(session.get_node("World/VehicleMount").get_child_count() == 1, "default restart mounts one fresh player")
	var field_settings := SessionSettings.new()
	field_settings.opponent_count = 20
	session.session_settings = field_settings
	session.restart_with_seed(CAPTURE_SEEDS[0])
	for frame in range(WARMUP_FRAMES):
		await process_frame
	var first_runtime: TrackRuntime = session.get_node("World/TrackMount/GeneratedTrack")
	var first_shading := first_runtime.get_node("TerrainShading") as TerrainShading
	var first_ground := first_shading.get_node("Ground")
	var first_objects := first_runtime.get_node("OfftrackObjects")
	var first_cars: Array = []
	for child in session.get_node("World/VehicleMount").get_children():
		first_cars.append(child)
	_check(first_cars.size() == 21, "the twenty-opponent field restart mounts twenty-one cars (%d)" % first_cars.size())
	var mount := session.get_node("World/TrackMount")
	var first_fingerprint: String = first_runtime.definition.terrain_fingerprint
	session.restart_with_seed(RESTART_SEED)
	for frame in range(WARMUP_FRAMES):
		await process_frame
	var second_runtime := session.get_node("World/TrackMount/GeneratedTrack") as TrackRuntime
	var second_shading := second_runtime.get_node("TerrainShading") as TerrainShading
	var freed_cars := 0
	for first_car in first_cars:
		freed_cars += int(not is_instance_valid(first_car))
	_check(mount.get_child_count() == 1, "after a seed restart the track mount holds exactly one track (%d)" % mount.get_child_count())
	_check(session.get_node("World/VehicleMount").get_child_count() == 21, "after a seed restart the vehicle mount holds the fresh field of twenty-one cars")
	_check(freed_cars == first_cars.size(), "every one of the previous field's twenty-one cars is freed (%d of %d)" % [freed_cars, first_cars.size()])
	_check(not is_instance_valid(first_runtime) and not is_instance_valid(first_shading) and not is_instance_valid(first_ground) and not is_instance_valid(first_objects), "the previous seed's track, terrain shading, ground grid and objects are all freed")
	_check(second_runtime != first_runtime and second_runtime.definition.seed == RESTART_SEED, "the new track is seed %d's" % RESTART_SEED)
	_check(second_runtime.definition.terrain_fingerprint != first_fingerprint, "the new track carries seed %d's own terrain fingerprint" % RESTART_SEED)
	_check(second_shading.ground_sample_count() == TerrainShading.ground_columns(second_runtime.definition.play_area) * TerrainShading.ground_rows(second_runtime.definition.play_area), "the new ground grid covers the new play area (%d vertices)" % second_shading.ground_sample_count())
	var car := session.get_node("World/VehicleMount/PlayerCar") as TopDownCar
	var ground := TrackHeightMap.new(second_runtime.definition).sample_at(car.global_position).ground_height
	_check(absf(car.get_height() - ground) < 1e-6 and absf(ground) > 0.5, "the restarted car is seated on seed %d's terrain at its spawn (%.2f px), not at zero" % [RESTART_SEED, ground])
	_close_session(context)
	await process_frame
	return true


func _open_session(main_scene: PackedScene, seed: int) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var session := main_scene.instantiate() as MainSession
	viewport.add_child(session)
	await process_frame
	session.restart_with_seed(seed)
	for frame in range(WARMUP_FRAMES):
		await process_frame
	var runtime := session.get_node("World/TrackMount/GeneratedTrack") as TrackRuntime
	var car := session.get_node("World/VehicleMount/PlayerCar") as TopDownCar
	car.set_auto_reset_enabled(false)
	var overlay := session.get_node("%DiagnosticsOverlay") as DiagnosticsOverlay
	overlay.set_release_mode(true)
	# The session pauses the SceneTree when the window loses focus; see
	# capture_height_channel_evidence.gd for the full account.
	var lifecycle := session.get_node("ApplicationLifecycle")
	var suspension := Callable(session, "_on_application_suspension_requested")
	if lifecycle.suspension_requested.is_connected(suspension):
		lifecycle.suspension_requested.disconnect(suspension)
	session.set_session_paused(false)
	_check(not paused, "the scene tree is running for this capture session")
	var camera := Camera2D.new()
	camera.name = "TerrainEvidenceCamera"
	camera.top_level = true
	camera.zoom = Vector2.ONE * car.tuning.camera_zoom
	session.add_child(camera)
	camera.make_current()
	return {"viewport": viewport, "session": session, "runtime": runtime, "car": car, "camera": camera}


func _close_session(context: Dictionary) -> void:
	var viewport: SubViewport = context["viewport"]
	viewport.free()


## Parks the car at the position through its own safe-reset path, so its ride height is the one
## the session's height query gives there.
func _seat_car(car: TopDownCar, position: Vector2, heading: Vector2) -> bool:
	var pose := Transform2D(heading.angle() + PI * 0.5, position)
	car.set_input_state(VehicleInputState.new())
	if not car.set_safe_reset_pose(pose):
		return false
	car.request_safe_reset()
	await physics_frame
	await physics_frame
	return not car.is_airborne()


## Frames the camera, hides the session's status banner so the still shows the world alone, waits
## for the frame to be drawn, and writes it out.
func _save(session: MainSession, viewport: SubViewport, camera: Camera2D, focus: Vector2, file_name: String) -> bool:
	camera.global_position = focus
	(session.get_node("%StatusPanel") as Control).visible = false
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	return image.save_png(ProjectSettings.globalize_path("%s/%s" % [OUTPUT_DIRECTORY, file_name])) == OK


func _write(path: String, lines: Array[String]) -> void:
	var file := FileAccess.open(ProjectSettings.globalize_path(path), FileAccess.WRITE)
	_check(file != null, "%s opens for writing" % path)
	if file != null:
		file.store_string("\n".join(lines) + "\n")
		file.close()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Terrain evidence capture passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Terrain evidence capture failed: %s" % failure)
	quit(1)
