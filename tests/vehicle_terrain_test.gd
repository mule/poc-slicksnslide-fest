extends SceneTree

## A whole lap is driveable on terrain. #49 bounded the field's curvature on paper and #47 summed
## it under the ramps; this suite measures what the car actually does on it. The steepest climb any
## seed produces does not stall a full-throttle car; a released descent is held by drag, with the
## speed clamp proven separately on a synthetic slope steep enough to need it; bare terrain never
## lifts the car off at max_safe_speed in the real integrator; and the ground-only rules -- safe
## pose capture and automatic reset -- work on sloped ground. The pre-terrain gate refused a pose
## wherever the ground was above zero, which on a terrain field is between a quarter and all of a
## lap depending on the seed; the capture RATE is asserted against an eligibility trace built from
## the car's public state, so a gate that captures once a lap cannot pass. Mutations:
##   -- --break-terrain-lift-off  quadruples the terrain amplitude under the lift-off drive, so
##                                bare terrain launches the car at max_safe_speed
##   -- --break-speed-clamp       raises max_safe_speed to 2000 under the clamp drive, so the
##                                synthetic descent runs past the shipped clamp

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const TERRAIN_CATALOG_PATH := "res://data/default_terrain_catalog.tres"
const TICK := 1.0 / 60.0
## Headless physics is paced by the wall clock at 60 ticks a second, and the drives below need
## tens of thousands of ticks. Ten times the tick rate at ten times the time scale steps the
## server with (1 / 600) * 10 = 1 / 60 s, the production step, ten times faster in real time;
## `_verify_physics_step_matches_the_model` pins that the step really is the production one.
const PHYSICS_TICKS_PER_SECOND := 600
const TIME_SCALE := 10.0
const SURVEY_SEED_COUNT := 20
const LAP_SEEDS := [0, 4, 9]
const LIFT_OFF_SEEDS := [0, 7, 13]
const LIFT_OFF_HEADINGS := 8
const LIFT_OFF_MIN_TICKS := 20000
const LIFT_OFF_LINE_TICKS := 3000
const BROKEN_AMPLITUDE_FACTOR := 4.0
const BROKEN_CLAMP := 2000.0
## A 27 degree descent, six times the catalog's per-axis slope bound. On it engine plus gravity beat
## drag at the clamp, so only the clamp can hold the speed; nothing the catalog produces comes close.
const CLAMP_PROOF_SLOPE := 0.5
const CLAMP_PROOF_TICKS := 240
const CLIMB_TICKS := 180
const COAST_TICKS := 240
## Above low_speed_stabilization's 25 px/s threshold, so the release is a roll and not a parked car.
const COAST_RELEASE_SPEED := 30.0
const DESCENT_SEAT_SPEED := 550.0
const DESCENT_TICKS := 90
const PARKED_TICKS := 120
## The steepest climb the catalog allows may cost at most this fraction of flat top speed, so a
## climb reads as a cost rather than a wall.
const CLIMB_SPEED_COST_BOUND := 0.10
const LAP_TICK_BUDGET := 12000
## A terrain lap may take at most this much longer than the same driver's flat lap.
const LAP_TIME_RATIO_BOUND := 1.10
const CAPTURE_RATE_FLOOR := 0.9
const POSITIVE_HEIGHT_CAPTURE_FLOOR := 0.2
const STUCK_TICKS := 60
const RIDE_GAP_TOLERANCE := 0.5
## The scripted hump the landing query count is measured over, and the ticks allowed for the
## car to reach it, fly and land at max_safe_speed.
const QUERY_HUMP_CREST_X := 600.0
const QUERY_HUMP_HALF_LENGTH := 150.0
const QUERY_HUMP_CREST_HEIGHT := 18.0
const LANDING_QUERY_TICKS := 240
const DRIVE_AWAY_DISTANCE := 40.0

var _failures: Array[String] = []
var _checks := 0
var _sections := 0
var _break_lift_off := false
var _break_clamp := false
var _catalog: TerrainCatalog
var _tuning: VehicleTuning
var _generator: TrackGenerator
var _definitions: Dictionary = {}
var _steepest_climb: Dictionary = {}
var _steepest_descent: Dictionary = {}


## Unbounded plane, for the clamp proof: curvature zero everywhere, so nothing but the clamp acts.
class PlaneHeight:
	extends HeightQuery

	var gradient := Vector2.ZERO


	func sample_at(world_position: Vector2) -> HeightSample:
		return HeightSample.new(gradient.dot(world_position), gradient)


## Pure-pursuit steering on the centreline with a speed governor that brakes for the tightest
## corner inside its braking distance. Full throttle everywhere the governor allows.
class LapDriver:
	extends RefCounted

	const LOOKAHEAD_SECONDS := 0.45
	const LOOKAHEAD_MIN := 120.0
	const LOOKAHEAD_MAX := 420.0
	const STEER_GAIN := 2.2
	## Under lateral_grip_acceleration (300) times the dirt grip (0.92), with room to slide.
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
	Engine.physics_ticks_per_second = PHYSICS_TICKS_PER_SECOND
	Engine.time_scale = TIME_SCALE
	_break_lift_off = OS.get_cmdline_user_args().has("--break-terrain-lift-off")
	_break_clamp = OS.get_cmdline_user_args().has("--break-speed-clamp")
	call_deferred("_run")


func _run() -> void:
	_catalog = load(TERRAIN_CATALOG_PATH) as TerrainCatalog
	_tuning = load(TUNING_PATH) as VehicleTuning
	_generator = TrackGenerator.new()
	_section(await _verify_physics_step_matches_the_model(), "the physics step verification ran to completion")
	_section(_verify_slope_bounds_against_the_tuning(), "the slope bounds verification ran to completion")
	_section(await _verify_full_throttle_climb_does_not_stall(), "the climb verification ran to completion")
	_section(await _verify_released_descent_is_drag_limited(), "the descent verification ran to completion")
	_section(await _verify_the_clamp_holds_a_steep_descent(), "the clamp verification ran to completion")
	_section(await _verify_no_lift_off_on_bare_terrain_at_max_safe_speed(), "the lift-off verification ran to completion")
	_section(_verify_height_samples_report_the_feature_height(), "the feature height verification ran to completion")
	_section(await _verify_landing_issues_no_extra_query(), "the landing query verification ran to completion")
	for seed in LAP_SEEDS:
		_section(await _verify_lap_and_safe_pose_capture(seed), "the seed %d lap verification ran to completion" % seed)
	_section(await _verify_reset_on_a_slope(), "the reset on a slope verification ran to completion")
	_finish()


## Every derived bound below is compared against a car driven by the real integrator, so the
## integrator's longitudinal model and the suite's copy of it must agree, and the sped-up physics
## must still step at 1 / 60 s. A level-ground run from near top speed pins both at once.
func _verify_physics_step_matches_the_model() -> bool:
	var context := _make_car(HeightQuery.new(), Issue4TestSurfaceProvider.new(), _pose(Vector2.ZERO, Vector2.RIGHT), null, Vector2(DESCENT_SEAT_SPEED, 0.0))
	var car: TopDownCar = context.car
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	for tick in range(DESCENT_TICKS):
		await physics_frame
	var modelled := _model_speed(DESCENT_TICKS, 0.0, 1.0, DESCENT_SEAT_SPEED)
	var travelled := car.global_position.x
	print("physics_step ticks=%d real=%.4f model=%.4f travelled=%.1f ticks_per_second=%d time_scale=%.1f" % [DESCENT_TICKS, car.get_speed(), modelled, travelled, Engine.physics_ticks_per_second, Engine.time_scale])
	_check(absf(car.get_speed() - modelled) < 0.05, "on level ground the real car matches the suite's model of the integrator to 0.05 px/s (%.4f against %.4f), so the step is the production 1 / 60 s and the model is faithful" % [car.get_speed(), modelled])
	_check(travelled > 0.9 * DESCENT_SEAT_SPEED * DESCENT_TICKS * TICK, "the car travelled the distance %d production ticks imply (%.1f px)" % [DESCENT_TICKS, travelled])
	context.world.queue_free()
	await process_frame
	return true


## The relationship is gravity times gradient against engine force over mass. The car stalls on a
## slope only when the slope term exceeds the engine's acceleration from rest, where drag is zero:
## s_stall = (engine_force / mass) / g. Everything below is derived from the tuning and the catalog,
## and the survey over twenty seeds' roads says what the field actually produces against its bound.
func _verify_slope_bounds_against_the_tuning() -> bool:
	var per_axis_bound := _catalog.slope_bound()
	# Each gradient component is bounded per axis, so the directional slope along any heading is
	# bounded by the diagonal, sqrt 2 times the per-axis bound. Every derivation uses the diagonal.
	var slope_bound := sqrt(2.0) * per_axis_bound
	var climb := {"seed": -1, "gradient": 0.0, "position": Vector2.ZERO, "forward": Vector2.RIGHT}
	var descent := {"seed": -1, "gradient": 0.0, "position": Vector2.ZERO, "forward": Vector2.RIGHT}
	var road_max := 0.0
	var positive_fraction_min := 1.0
	var positive_fraction_max := 0.0
	for seed in range(SURVEY_SEED_COUNT):
		var definition := _definition(seed)
		var field := TerrainField.new(definition.terrain_seed, _catalog)
		var count := definition.centerline.size() - 1
		var positive := 0
		for index in range(count):
			var position: Vector2 = definition.centerline[index]
			var forward: Vector2 = (definition.centerline[index + 1] - position).normalized()
			var sample := field.sample_at(position)
			road_max = maxf(road_max, sample.gradient.length())
			if sample.ground_height > 0.0:
				positive += 1
			var along := sample.gradient.dot(forward)
			if along > float(climb.gradient):
				climb = {"seed": seed, "gradient": along, "position": position, "forward": forward}
			if along < float(descent.gradient):
				descent = {"seed": seed, "gradient": along, "position": position, "forward": forward}
		var fraction := float(positive) / float(count)
		positive_fraction_min = minf(positive_fraction_min, fraction)
		positive_fraction_max = maxf(positive_fraction_max, fraction)
	_steepest_climb = climb
	_steepest_descent = descent
	print("survey seeds=%d road_max_gradient=%.4f per_axis_bound=%.4f diagonal_bound=%.4f steepest_climb=%.4f seed=%d at=(%.0f,%.0f) steepest_descent=%.4f seed=%d at=(%.0f,%.0f) road_above_zero=%.1f%%..%.1f%%" % [
		SURVEY_SEED_COUNT, road_max, per_axis_bound, slope_bound, climb.gradient, climb.seed, climb.position.x, climb.position.y, descent.gradient, descent.seed, descent.position.x, descent.position.y, 100.0 * positive_fraction_min, 100.0 * positive_fraction_max,
	])
	_check(road_max <= slope_bound, "no road gradient over twenty seeds exceeds the catalog's diagonal slope bound (%.4f of %.4f)" % [road_max, slope_bound])
	_check(road_max > 0.25 * per_axis_bound, "the roads carry real slope, at least a quarter of the per-axis bound (%.4f), so the survey is not measuring a flat field" % road_max)
	_check(positive_fraction_max > 0.9, "some seed's road is above zero for over 90%% of its length (%.1f%%), which is where the pre-terrain gate would capture nothing" % (100.0 * positive_fraction_max))

	var engine_acceleration := _tuning.engine_force / _tuning.mass_kg
	var stall_slope := engine_acceleration / _tuning.gravity
	var flat := _terminal_speed(engine_acceleration)
	var uphill := _terminal_speed(engine_acceleration - _tuning.gravity * slope_bound)
	var downhill := _terminal_speed(engine_acceleration + _tuning.gravity * slope_bound)
	var coast := _terminal_speed(_tuning.gravity * slope_bound)
	print("uphill engine/mass=%.3f g=%.3f stall_slope=%.3f margin_over_bound=%.1fx terminal flat=%.1f uphill=%.1f (%.3f of flat) downhill_full_throttle=%.1f coast=%.1f clamp=%.1f" % [
		engine_acceleration, _tuning.gravity, stall_slope, stall_slope / slope_bound, flat, uphill, uphill / flat, downhill, coast, _tuning.max_safe_speed,
	])
	_check(_tuning.gravity * slope_bound < engine_acceleration, "gravity times the slope bound (%.2f px/s^2) stays under engine force over mass (%.2f), so no terrain slope can stall the car from rest" % [_tuning.gravity * slope_bound, engine_acceleration])
	_check(stall_slope > 1.0, "the stall slope (%.3f) is beyond 45 degrees, far outside anything the catalog can produce" % stall_slope)
	_check(uphill >= (1.0 - CLIMB_SPEED_COST_BOUND) * flat, "the steepest climb the catalog allows costs at most %.0f%% of flat top speed (%.1f of %.1f px/s)" % [100.0 * CLIMB_SPEED_COST_BOUND, uphill, flat])
	_check(downhill < _tuning.max_safe_speed, "drag alone holds a full-throttle descent at the slope bound under the clamp (%.1f of %.1f px/s), so on shipped terrain the clamp is a backstop" % [downhill, _tuning.max_safe_speed])
	_check(flat < _tuning.max_safe_speed, "the flat terminal speed (%.1f) sits under the clamp, so the clamp is not what sets top speed on level ground either" % flat)
	_check(_tuning.low_speed_stabilization > _tuning.gravity * slope_bound, "low speed stabilization (%.1f px/s^2) beats gravity on the steepest slope (%.2f), so a parked or reset car never rolls away" % [_tuning.low_speed_stabilization, _tuning.gravity * slope_bound])
	_check(coast < 0.25 * _tuning.max_safe_speed, "a coasting descent at the slope bound (%.1f px/s) stays under a quarter of the clamp" % coast)
	return true


## Full throttle from rest on the steepest climb any seed's road produces, on bare terrain. The
## speed must never fall and the car must gain ground on every tick; after three seconds it must
## be at least as fast as the slope bound allows, and slower than the same run on level ground.
func _verify_full_throttle_climb_does_not_stall() -> bool:
	var climb := _steepest_climb
	var definition := _definition(int(climb.seed))
	var map := _bare_terrain_map(definition)
	var forward: Vector2 = climb.forward
	var origin: Vector2 = climb.position
	var context := _make_car(map, Issue4TestSurfaceProvider.new(), _pose(origin, forward))
	var car: TopDownCar = context.car
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var start_ground := map.sample_at(car.global_position).ground_height
	var ground_after_second := start_ground
	var previous_speed := 0.0
	var previous_progress := 0.0
	var monotone_speed := true
	var monotone_progress := true
	var steepest_under_car := 0.0
	var airborne := false
	for tick in range(CLIMB_TICKS):
		await physics_frame
		var speed := car.get_speed()
		var progress := (car.global_position - origin).dot(forward)
		if speed < previous_speed - 1e-3:
			monotone_speed = false
		if progress < previous_progress - 1e-3:
			monotone_progress = false
		previous_speed = speed
		previous_progress = progress
		var sample := map.sample_at(car.global_position)
		steepest_under_car = maxf(steepest_under_car, sample.gradient.dot(forward))
		if tick == 59:
			ground_after_second = sample.ground_height
		airborne = airborne or car.is_airborne()
	var slope_bound := sqrt(2.0) * _catalog.slope_bound()
	var floor_speed := _model_speed(CLIMB_TICKS, slope_bound, 1.0, 0.0)
	var flat_speed := _model_speed(CLIMB_TICKS, 0.0, 1.0, 0.0)
	print("climb seed=%d gradient=%.4f speed_after=%.1f floor_at_bound=%.1f flat_model=%.1f progress=%.1f rise_first_second=%.2f steepest_under_car=%.4f" % [
		climb.seed, climb.gradient, previous_speed, floor_speed, flat_speed, previous_progress, ground_after_second - start_ground, steepest_under_car,
	])
	_check(monotone_speed, "seed %d climb: speed never falls under full throttle on the steepest climb (%.1f px/s after %.1f s)" % [climb.seed, previous_speed, CLIMB_TICKS * TICK])
	_check(monotone_progress, "seed %d climb: the car gains ground on every tick (%.1f px)" % [climb.seed, previous_progress])
	_check(previous_speed >= floor_speed, "seed %d climb: the car reaches at least the speed the slope bound allows (%.1f >= %.1f px/s)" % [climb.seed, previous_speed, floor_speed])
	_check(previous_speed < flat_speed - 1.0, "seed %d climb: the climb costs speed against the level-ground model (%.1f < %.1f px/s)" % [climb.seed, previous_speed, flat_speed])
	_check(ground_after_second - start_ground >= 2.0, "seed %d climb: the ground under the car rose %.2f px in the first second, so the drive is a climb" % [climb.seed, ground_after_second - start_ground])
	_check(not airborne, "seed %d climb: the car stays on the ground" % climb.seed)
	context.world.queue_free()
	await process_frame
	return true


## Three drives on the steepest descent any seed's road produces. Released at a roll, the car
## gains speed and never passes the coast terminal speed at the slope bound. Parked, it stays put.
## Under full throttle from near flat top speed it never passes the clamp, and its peak stays
## under the drag balance at the slope bound: drag, not the clamp, is what holds it.
func _verify_released_descent_is_drag_limited() -> bool:
	var descent := _steepest_descent
	var definition := _definition(int(descent.seed))
	var map := _bare_terrain_map(definition)
	var forward: Vector2 = descent.forward
	var origin: Vector2 = descent.position
	var slope_bound := sqrt(2.0) * _catalog.slope_bound()
	var engine_acceleration := _tuning.engine_force / _tuning.mass_kg
	var coast_bound := _terminal_speed(_tuning.gravity * slope_bound)
	var full_throttle_bound := _terminal_speed(engine_acceleration + _tuning.gravity * slope_bound)

	var context := _make_car(map, Issue4TestSurfaceProvider.new(), _pose(origin, forward), null, forward * COAST_RELEASE_SPEED)
	var car: TopDownCar = context.car
	var start_ground := map.sample_at(car.global_position).ground_height
	var ground_at_two_seconds := start_ground
	var speed_at_two_seconds := 0.0
	var peak := 0.0
	var airborne := false
	for tick in range(COAST_TICKS):
		await physics_frame
		peak = maxf(peak, car.get_speed())
		airborne = airborne or car.is_airborne()
		if tick == 119:
			speed_at_two_seconds = car.get_speed()
			ground_at_two_seconds = map.sample_at(car.global_position).ground_height
	print("coast seed=%d gradient=%.4f release=%.1f speed_at_2s=%.1f peak=%.1f coast_bound=%.1f drop_in_2s=%.2f" % [
		descent.seed, descent.gradient, COAST_RELEASE_SPEED, speed_at_two_seconds, peak, coast_bound, start_ground - ground_at_two_seconds,
	])
	_check(speed_at_two_seconds >= COAST_RELEASE_SPEED + 3.0, "seed %d descent: a released car gains speed rolling down (%.1f from %.1f px/s in two seconds)" % [descent.seed, speed_at_two_seconds, COAST_RELEASE_SPEED])
	_check(peak <= coast_bound, "seed %d descent: a released car never exceeds the coast terminal speed at the slope bound (%.1f <= %.1f px/s, %.0f%% of the clamp)" % [descent.seed, peak, coast_bound, 100.0 * peak / _tuning.max_safe_speed])
	_check(start_ground - ground_at_two_seconds >= 1.5, "seed %d descent: the ground under the car fell %.2f px in two seconds, so the drive is a descent" % [descent.seed, start_ground - ground_at_two_seconds])
	_check(not airborne, "seed %d descent: the coasting car stays on the ground" % descent.seed)
	context.world.queue_free()
	await process_frame

	context = _make_car(map, Issue4TestSurfaceProvider.new(), _pose(origin, forward))
	car = context.car
	var parked_peak := 0.0
	for tick in range(PARKED_TICKS):
		await physics_frame
		parked_peak = maxf(parked_peak, car.get_speed())
	var parked_drift := car.global_position.distance_to(origin)
	_check(parked_peak < 1.0 and parked_drift < 1.0, "seed %d descent: a car parked on the steepest descent stays put for two seconds (peak %.3f px/s, drift %.3f px)" % [descent.seed, parked_peak, parked_drift])
	context.world.queue_free()
	await process_frame

	context = _make_car(map, Issue4TestSurfaceProvider.new(), _pose(origin, forward), null, forward * DESCENT_SEAT_SPEED)
	car = context.car
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var over_clamp := false
	var full_peak := 0.0
	for tick in range(DESCENT_TICKS):
		await physics_frame
		var speed := car.get_speed()
		full_peak = maxf(full_peak, speed)
		over_clamp = over_clamp or speed > _tuning.max_safe_speed + 1e-3
	var final_speed := car.get_speed()
	var flat_model := _model_speed(DESCENT_TICKS, 0.0, 1.0, DESCENT_SEAT_SPEED)
	print("full_throttle_descent seed=%d seat=%.1f final=%.1f peak=%.1f flat_model=%.1f drag_balance_at_bound=%.1f clamp=%.1f" % [
		descent.seed, DESCENT_SEAT_SPEED, final_speed, full_peak, flat_model, full_throttle_bound, _tuning.max_safe_speed,
	])
	_check(not over_clamp, "seed %d descent: a full-throttle descent never exceeds max_safe_speed (peak %.1f of %.1f px/s)" % [descent.seed, full_peak, _tuning.max_safe_speed])
	_check(full_peak <= full_throttle_bound + 0.5, "seed %d descent: the peak stays under the drag balance at the slope bound (%.1f <= %.1f px/s), so drag and not the clamp is what holds it" % [descent.seed, full_peak, full_throttle_bound])
	_check(final_speed > flat_model + 1.0, "seed %d descent: the descent returns speed against the level-ground model (%.1f > %.1f px/s)" % [descent.seed, final_speed, flat_model])
	context.world.queue_free()
	await process_frame
	return true


## On shipped terrain drag holds every descent under the clamp, so a terrain drive cannot show the
## clamp working. A synthetic plane six times steeper than the catalog's bound can: engine plus
## gravity beat drag at max_safe_speed, and the car sits exactly on the clamp.
func _verify_the_clamp_holds_a_steep_descent() -> bool:
	var tuning := _tuning.duplicate() as VehicleTuning
	if _break_clamp:
		tuning.max_safe_speed = BROKEN_CLAMP
		print("break_speed_clamp max_safe_speed=%.1f" % tuning.max_safe_speed)
	var engine_acceleration := _tuning.engine_force / _tuning.mass_kg
	var unclamped := _terminal_speed(engine_acceleration + _tuning.gravity * CLAMP_PROOF_SLOPE)
	_check(CLAMP_PROOF_SLOPE > sqrt(2.0) * _catalog.slope_bound(), "the synthetic slope (%.2f) is outside anything the catalog can produce, so this is the clamp's proof and not terrain's" % CLAMP_PROOF_SLOPE)
	_check(unclamped > _tuning.max_safe_speed, "on the synthetic descent the drag balance (%.1f px/s) is above the clamp (%.1f), so only the clamp can hold the speed" % [unclamped, _tuning.max_safe_speed])
	var plane := PlaneHeight.new()
	plane.gradient = Vector2(-CLAMP_PROOF_SLOPE, 0.0)
	var context := _make_car(plane, Issue4TestSurfaceProvider.new(), _pose(Vector2.ZERO, Vector2.RIGHT), tuning, Vector2(DESCENT_SEAT_SPEED, 0.0))
	var car: TopDownCar = context.car
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var over_clamp := false
	var pinned := true
	var peak := 0.0
	for tick in range(CLAMP_PROOF_TICKS):
		await physics_frame
		var speed := car.get_speed()
		peak = maxf(peak, speed)
		over_clamp = over_clamp or speed > _tuning.max_safe_speed + 1e-3
		if tick >= CLAMP_PROOF_TICKS - 60:
			pinned = pinned and speed >= _tuning.max_safe_speed - 0.01
	print("clamp_proof slope=%.2f seat=%.1f peak=%.3f clamp=%.1f unclamped_balance=%.1f" % [CLAMP_PROOF_SLOPE, DESCENT_SEAT_SPEED, peak, _tuning.max_safe_speed, unclamped])
	_check(not over_clamp, "on the synthetic descent the car never exceeds the shipped max_safe_speed (peak %.3f of %.1f px/s)" % [peak, _tuning.max_safe_speed])
	_check(pinned, "on the synthetic descent the car sits on the clamp for the whole last second")
	context.world.queue_free()
	await process_frame
	return true


## #49 asserts the curvature bound in the field's own arithmetic. This drives the production car
## across bare terrain at max_safe_speed, in the real integrator, on straight lines through three
## seeds' play areas at eight headings, and asserts it never leaves the ground. Ramps are stripped:
## a ramp launches the car by design, and #47 sanctioned the hop a fast flank crossing produces.
func _verify_no_lift_off_on_bare_terrain_at_max_safe_speed() -> bool:
	var lift_off_curvature := _tuning.gravity / (_tuning.max_safe_speed * _tuning.max_safe_speed)
	var total_ticks := 0
	var airborne_ticks := 0
	var lines := 0
	var max_curvature := 0.0
	var max_gradient := 0.0
	var worst_gap := 0.0
	var min_speed := INF
	for seed in LIFT_OFF_SEEDS:
		var definition := _definition(seed)
		var field := TerrainField.new(definition.terrain_seed, _catalog)
		var query: HeightQuery = _bare_terrain_map(definition)
		if _break_lift_off:
			var steep := _catalog.duplicate(true) as TerrainCatalog
			steep.amplitude *= BROKEN_AMPLITUDE_FACTOR
			print("break_terrain_lift_off amplitude=%.1f" % steep.amplitude)
			field = TerrainField.new(definition.terrain_seed, steep)
			query = field
		var area: Rect2 = definition.play_area
		for heading_index in range(LIFT_OFF_HEADINGS):
			var angle := PI * float(heading_index) / float(LIFT_OFF_HEADINGS)
			var heading := Vector2(cos(angle), sin(angle))
			var pin := heading * _tuning.max_safe_speed
			var context := _make_car(query, Issue4TestSurfaceProvider.new(), _pose(_entry_point(area, heading), heading), null, pin)
			var car: TopDownCar = context.car
			var controls := VehicleInputState.new()
			controls.throttle = 1.0
			car.set_input_state(controls)
			lines += 1
			for tick in range(LIFT_OFF_LINE_TICKS):
				await physics_frame
				total_ticks += 1
				if car.is_airborne():
					airborne_ticks += 1
				var position := car.global_position
				# The car's ride height is the one it computed for the ground one step ahead, so
				# it is compared with the ground where the velocity it chose will put it.
				var next_position := position + car.linear_velocity * TICK
				# The minimum, not the peak: the car is seeded at the clamp, so a peak would be
				# satisfied by the first tick even if the pin below silently stopped working.
				min_speed = minf(min_speed, car.get_speed())
				max_curvature = maxf(max_curvature, field.curvature_at(position))
				max_gradient = maxf(max_gradient, field.sample_at(position).gradient.length())
				worst_gap = maxf(worst_gap, absf(car.get_height() - query.sample_at(next_position).ground_height))
				# Drag would let the car fall a few px/s under the clamp each tick; pin it back.
				car.linear_velocity = pin
				if not area.has_point(position):
					break
			context.world.queue_free()
			await process_frame
	print("lift_off lines=%d ticks=%d airborne=%d min_speed=%.1f max_curvature=%.10f bound=%.10f lift_off_curvature=%.10f max_gradient=%.4f worst_ride_gap=%.4f" % [
		lines, total_ticks, airborne_ticks, min_speed, max_curvature, _catalog.curvature_bound(), lift_off_curvature, max_gradient, worst_gap,
	])
	_check(airborne_ticks == 0, "bare terrain never lifts the car off at max_safe_speed in the real integrator (%d airborne of %d ticks over %d lines)" % [airborne_ticks, total_ticks, lines])
	_check(total_ticks >= LIFT_OFF_MIN_TICKS, "the lift-off drive covers at least %d ticks (%d)" % [LIFT_OFF_MIN_TICKS, total_ticks])
	_check(min_speed >= 0.99 * _tuning.max_safe_speed, "the lift-off drive never drops under 99%% of max_safe_speed on any tick (minimum %.1f of %.1f)" % [min_speed, _tuning.max_safe_speed])
	_check(max_curvature >= 0.25 * _catalog.curvature_bound(), "the lines crossed real curvature, at least a quarter of the bound (%.10f of %.10f; lift-off at %.10f)" % [max_curvature, _catalog.curvature_bound(), lift_off_curvature])
	_check(max_gradient >= 0.25 * _catalog.slope_bound(), "the lines crossed real slope, at least a quarter of the per-axis bound (%.4f)" % max_gradient)
	_check(worst_gap <= RIDE_GAP_TOLERANCE, "the car rode the terrain within %.2f px on every tick (worst %.4f), so it was on the ground rather than floating" % [RIDE_GAP_TOLERANCE, worst_gap])
	return true


## The safe-pose gate needs to know whether the ground under the car is part of a placed feature
## rather than merely above zero. The sample carries that as on_feature: true inside a ramp and its
## flank, false on bare terrain and from every flat provider, with the wedge still summed into the
## height.
func _verify_height_samples_report_the_feature_height() -> bool:
	var definition := _definition(0)
	var field := TerrainField.new(definition.terrain_seed, _catalog)
	_check(not field.sample_at(Vector2(100.0, 200.0)).on_feature, "bare terrain reports no feature")
	var map := TrackHeightMap.new(definition)
	_check(map.ramp_count() > 0, "seed 0 places a ramp to sample")
	if map.ramp_count() == 0:
		return false
	var ramp: JumpRampPlacement = definition.jump_ramps[0]
	var crest := ramp.transform.origin
	var axis := ramp.transform.x.normalized()
	var lateral := ramp.transform.y.normalized()
	var at_crest := map.sample_at(crest)
	_check(at_crest.on_feature, "a crest is on a feature")
	_check(absf(at_crest.ground_height - (field.height_at(crest) + ramp.crest_height)) < 1e-6, "at a crest the ground height is terrain plus the crest (%.3f = %.3f + %.3f)" % [at_crest.ground_height, field.height_at(crest), ramp.crest_height])
	# The wedge is read as the map's height minus the field's, so the check does not depend on
	# the map reporting it. Positions are float32, so a seat 75 px along a crest at thousands of
	# px is a few 1e-5 px off.
	var mid_face := crest + axis * (ramp.half_length * 0.5)
	var at_mid_face := map.sample_at(mid_face)
	var mid_face_wedge := at_mid_face.ground_height - field.height_at(mid_face)
	_check(at_mid_face.on_feature and absf(mid_face_wedge - 0.5 * ramp.crest_height) < 1e-3, "halfway down a face the sample is on a feature and the wedge is half the crest (%.4f px)" % mid_face_wedge)
	var mid_flank := crest + lateral * (ramp.width * 0.5 + ramp.flank_width * 0.5)
	var at_mid_flank := map.sample_at(mid_flank)
	var mid_flank_wedge := at_mid_flank.ground_height - field.height_at(mid_flank)
	_check(at_mid_flank.on_feature and absf(mid_flank_wedge - 0.5 * ramp.crest_height) < 1e-3, "halfway across the flank the sample is on a feature and the wedge is half the crest (%.3f px), so a flank counts as ramp" % mid_flank_wedge)
	var beyond := crest + lateral * (ramp.width * 0.5 + ramp.flank_width + 1.0)
	_check(not map.sample_at(beyond).on_feature, "a pixel beyond the flank is not on a feature")
	_check(not map.sample_at(crest + axis * (ramp.half_length + 1.0)).on_feature, "a pixel past the foot is not on a feature")
	var far := Vector2(1.0e6, 1.0e6)
	var poisoned := map.sample_at(far)
	poisoned.on_feature = true
	var next := map.sample_at(far + Vector2(500.0, 0.0))
	_check(next == poisoned, "the miss path returns the shared sample, so the discipline below is exercised")
	_check(not next.on_feature, "the shared miss sample's feature flag is cleared on the next miss")
	var provider := HeightChannelTestHeightProvider.new()
	_check(provider.sample_at(Vector2.ZERO).on_feature, "the scripted hump reports itself as a feature, so the vehicle suite's on-a-ramp assertions keep their meaning")
	_check(not provider.sample_at(Vector2(1000.0, 0.0)).on_feature, "off the hump the scripted ground reports no feature")
	provider.mode = HeightChannelTestHeightProvider.Mode.PLATEAU
	provider.plateau_height = 40.0
	_check(provider.sample_at(Vector2(-10.0, 0.0)).on_feature, "a scripted plateau is a feature")
	provider.mode = HeightChannelTestHeightProvider.Mode.WALL
	_check(provider.sample_at(Vector2(10.0, 0.0)).on_feature, "the scripted wall's face is a feature")
	return true


## One lap on terrain and one on the flat base with the same driver, same track, same ramps. The
## terrain lap must complete, never strand the car, and stay close to the flat lap time. Safe
## poses must be captured at the rate the eligibility trace predicts -- on ground above zero,
## which the pre-terrain gate could never record -- and a reset must land the car on the road at
## the terrain's height, from where it drives away.
func _verify_lap_and_safe_pose_capture(seed: int) -> bool:
	var definition := _definition(seed)
	var flat_definition := TrackDefinition.new()
	flat_definition.jump_ramps = definition.jump_ramps
	# The flat lap runs first and its world is freed before the terrain lap starts: a lap's car
	# is left parked past the finish line, and a second car spawning on the same track would hit
	# it, which the trace would then see as contact ticks.
	var flat := await _drive_lap(definition, TrackHeightMap.new(flat_definition), "seed %d flat" % seed)
	flat.context.world.queue_free()
	await process_frame
	var terrain := await _drive_lap(definition, TrackHeightMap.new(definition), "seed %d terrain" % seed)
	_check(terrain.map.has_terrain() and not flat.map.has_terrain(), "seed %d: the terrain lap ran on terrain and the flat lap on a flat base" % seed)
	_check(flat.completed, "seed %d flat: the driver completes a lap (%d ticks)" % [seed, flat.ticks])
	_check(terrain.completed, "seed %d terrain: the driver completes a lap (%d ticks)" % [seed, terrain.ticks])
	_check(terrain.contact_ticks == 0 and flat.contact_ticks == 0, "seed %d: neither lap touched another body (%d, %d ticks), so the gate's contact condition never entered the trace" % [seed, terrain.contact_ticks, flat.contact_ticks])
	if not (flat.completed and terrain.completed):
		terrain.context.world.queue_free()
		await process_frame
		return true
	_check(terrain.ticks <= LAP_TIME_RATIO_BOUND * flat.ticks, "seed %d: the terrain lap (%.1f s) takes at most %.0f%% longer than the flat lap (%.1f s)" % [seed, terrain.ticks * TICK, 100.0 * (LAP_TIME_RATIO_BOUND - 1.0), flat.ticks * TICK])
	_check(terrain.resets == 0 and flat.resets == 0, "seed %d: no automatic reset fired on either lap (%d, %d)" % [seed, terrain.resets, flat.resets])
	_check(terrain.longest_slow_streak < STUCK_TICKS and flat.longest_slow_streak < STUCK_TICKS, "seed %d: the car never sat below the stuck speed for a second on either lap (longest %d and %d ticks)" % [seed, terrain.longest_slow_streak, flat.longest_slow_streak])
	_check(terrain.eligible_ticks >= 0.6 * terrain.ticks, "seed %d terrain: most of the lap is eligible for capture (%.0f%%), so the rate below is measured on a real drive" % [seed, 100.0 * terrain.eligible_ticks / terrain.ticks])
	_check(terrain.captures >= CAPTURE_RATE_FLOOR * terrain.expected_captures, "seed %d terrain: safe poses are captured at the rate the eligibility trace predicts (%d of %d expected, %.2f per second over %.1f s)" % [seed, terrain.captures, terrain.expected_captures, terrain.captures / (terrain.ticks * TICK), terrain.ticks * TICK])
	_check(terrain.captures <= terrain.expected_captures + terrain.streaks + 2, "seed %d terrain: no more poses than the interval allows (%d of %d expected plus %d streaks)" % [seed, terrain.captures, terrain.expected_captures, terrain.streaks])
	_check(terrain.captures_at_positive_height >= POSITIVE_HEIGHT_CAPTURE_FLOOR * terrain.captures, "seed %d terrain: %d of %d captured poses sit on ground above zero, which the pre-terrain gate could never record" % [seed, terrain.captures_at_positive_height, terrain.captures])
	_check(terrain.captures_on_ramp == 0, "seed %d terrain: no pose was captured on a ramp or its flank (%d)" % [seed, terrain.captures_on_ramp])
	_check(terrain.captures_off_dirt == 0, "seed %d terrain: no pose was captured off dirt (%d)" % [seed, terrain.captures_off_dirt])
	_check(terrain.captures_in_air == 0, "seed %d terrain: no pose was captured in the air or during landing recovery (%d)" % [seed, terrain.captures_in_air])
	_check(flat.captures >= CAPTURE_RATE_FLOOR * flat.expected_captures, "seed %d flat: the same rate holds on the flat base (%d of %d expected)" % [seed, flat.captures, flat.expected_captures])
	# The flat lap's captures are all at zero height by construction of the flat map, so that is
	# not asserted; it is what makes the terrain count above terrain's doing.

	var car: TopDownCar = terrain.context.car
	var map: TrackHeightMap = terrain.map
	var surface: TrackSurfaceMap = terrain.surface
	var pose: Transform2D = car.get_safe_reset_pose()
	var pose_ground := map.sample_at(pose.origin).ground_height
	_check(car.global_position.distance_to(pose.origin) > 1.0, "seed %d reset: the car is away from its last safe pose, so the destination assertion is live" % seed)
	# Release the driver's controls first: a throttle left applied would move the reset car.
	car.set_input_state(VehicleInputState.new())
	car.request_safe_reset()
	await physics_frame
	await physics_frame
	_check(car.global_position.distance_to(pose.origin) < 1.0, "seed %d reset: a reset returns the car to the last safe pose" % seed)
	_check(not car.is_airborne() and car.get_vertical_velocity() == 0.0, "seed %d reset: the reset car is on the ground" % seed)
	_check(pose_ground != 0.0 and absf(car.get_height() - pose_ground) < 1e-3, "seed %d reset: the reset seats the car on the terrain under the pose (%.3f px), not at zero" % [seed, pose_ground])
	_check(surface.sample_at(pose.origin).surface_type == SurfaceQuery.SurfaceType.DIRT, "seed %d reset: the pose is on the road" % seed)
	_check(not _on_ramp(definition, pose.origin), "seed %d reset: the pose is not on a ramp" % seed)
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	for tick in range(60):
		await physics_frame
	var driven := car.global_position.distance_to(pose.origin)
	_check(driven >= DRIVE_AWAY_DISTANCE, "seed %d reset: the car drives away from the reset pose under throttle (%.1f px in a second)" % [seed, driven])
	terrain.context.world.queue_free()
	await process_frame
	return true


func _drive_lap(definition: TrackDefinition, map: TrackHeightMap, label: String) -> Dictionary:
	var surface := TrackSurfaceMap.new(definition)
	var context := _make_car(map, surface, definition.spawn_transform)
	var car: TopDownCar = context.car
	car.set_auto_reset_enabled(true)
	var driver := LapDriver.new(definition, _tuning.brake_force / _tuning.mass_kg)
	var detector := CheckpointCrossingDetector.new(definition)
	detector.reset(car.global_position)
	var tracker := LapProgressTracker.new(definition.checkpoints.size())
	var controls := VehicleInputState.new()
	# The gate accumulates one physics step per eligible tick and captures once the interval is
	# reached; at 60 Hz that is the 30th consecutive eligible tick.
	var capture_ticks := roundi(_tuning.safe_pose_interval / TICK)
	var result := {
		"label": label, "context": context, "map": map, "surface": surface,
		"completed": false, "ticks": 0, "resets": 0, "airborne_ticks": 0, "longest_slow_streak": 0,
		"top_speed": 0.0, "top_speed_uphill": 0.0, "top_speed_downhill": 0.0, "min_speed": INF, "top_slip": 0.0,
		"eligible_ticks": 0, "expected_captures": 0, "streaks": 0, "contact_ticks": 0,
		"captures": 0, "captures_at_positive_height": 0, "captures_on_ramp": 0, "captures_off_dirt": 0, "captures_in_air": 0,
	}
	var previous_pose := car.get_safe_reset_pose().origin
	var eligible_run := 0
	var slow_streak := 0
	var was_eligible := false
	for tick in range(LAP_TICK_BUDGET):
		var forward := -car.global_transform.y.normalized()
		var command := driver.controls(car.global_position, forward, car.get_speed())
		controls.steer = command.steer
		controls.throttle = command.throttle
		controls.brake = command.brake
		car.set_input_state(controls)
		await physics_frame
		result.ticks += 1
		var position := car.global_position
		var speed := car.get_speed()
		var airborne := car.is_airborne()
		var recovering := car.get_landing_recovery_remaining() > 0.0
		var crossing := detector.sample(position)
		if not crossing.is_empty() and tracker.cross_checkpoint(int(crossing.checkpoint), float(crossing.forward_dot)):
			result.completed = true
		forward = -car.global_transform.y.normalized()
		var along := map.sample_at(position).gradient.dot(forward)
		if not airborne:
			result.top_speed = maxf(result.top_speed, speed)
			if along > 0.01:
				result.top_speed_uphill = maxf(result.top_speed_uphill, speed)
			elif along < -0.01:
				result.top_speed_downhill = maxf(result.top_speed_downhill, speed)
		if tick >= 60:
			result.min_speed = minf(result.min_speed, speed)
		result.top_slip = maxf(result.top_slip, car.get_slip_ratio())
		if speed < _tuning.auto_reset_stuck_speed:
			slow_streak += 1
			result.longest_slow_streak = maxi(result.longest_slow_streak, slow_streak)
		else:
			slow_streak = 0
		if car.consume_auto_reset_notice():
			result.resets += 1
		if airborne:
			result.airborne_ticks += 1
		# The gate's inputs, read through the public getters after the tick. _integrate_forces
		# runs at the start of the iteration on the transform the previous step produced, which
		# is the position read here, so the ground the gate sampled is the ground under it. The
		# gate's contact condition is read from the body's contact monitor; this world holds no
		# other body, so it never bites, but the trace predicts the whole rule.
		var touching := not car.get_colliding_bodies().is_empty()
		if touching:
			result.contact_ticks += 1
		var eligible := not airborne and not recovering and car.get_surface_type() == SurfaceQuery.SurfaceType.DIRT and car.get_slip_ratio() <= _tuning.safe_pose_max_slip and not _on_ramp(definition, position) and not touching
		if eligible:
			eligible_run += 1
			result.eligible_ticks += 1
			if eligible_run >= capture_ticks:
				eligible_run = 0
				result.expected_captures += 1
		else:
			if was_eligible:
				result.streaks += 1
			eligible_run = 0
		was_eligible = eligible
		var pose := car.get_safe_reset_pose().origin
		if pose != previous_pose:
			result.captures += 1
			if map.sample_at(pose).ground_height > 0.0:
				result.captures_at_positive_height += 1
			if _on_ramp(definition, pose):
				result.captures_on_ramp += 1
			if surface.sample_at(pose).surface_type != SurfaceQuery.SurfaceType.DIRT:
				result.captures_off_dirt += 1
			if airborne or recovering:
				result.captures_in_air += 1
			previous_pose = pose
		if result.completed:
			break
	print("lap %s: completed=%s ticks=%d (%.1f s) top=%.1f uphill=%.1f downhill=%.1f min=%.1f top_slip=%.2f airborne=%d resets=%d slow_streak=%d eligible=%d contact_ticks=%d expected=%d captures=%d positive=%d on_ramp=%d off_dirt=%d in_air=%d streaks=%d" % [
		label, result.completed, result.ticks, result.ticks * TICK, result.top_speed, result.top_speed_uphill, result.top_speed_downhill, result.min_speed, result.top_slip, result.airborne_ticks, result.resets, result.longest_slow_streak,
		result.eligible_ticks, result.contact_ticks, result.expected_captures, result.captures, result.captures_at_positive_height, result.captures_on_ramp, result.captures_off_dirt, result.captures_in_air, result.streaks,
	])
	return result


## Stuck off-track beside the steepest climb, the automatic reset must land the car on the road
## at the terrain's own height, still, and able to drive away.
func _verify_reset_on_a_slope() -> bool:
	var climb := _steepest_climb
	var definition := _definition(int(climb.seed))
	var map := TrackHeightMap.new(definition)
	var surface := TrackSurfaceMap.new(definition)
	var forward: Vector2 = climb.forward
	var origin: Vector2 = climb.position
	var pose := _pose(origin, forward)
	var lateral := Vector2(-forward.y, forward.x)
	var stranded := origin + lateral * (definition.track_width * 0.5 + 400.0)
	_check(not _on_ramp(definition, origin), "the steepest climb is not on a ramp, so the pose below is a plain terrain pose")
	_check(surface.sample_at(stranded).surface_type == SurfaceQuery.SurfaceType.OFF_TRACK, "the stranded position is off-track")
	var context := _make_car(map, surface, Transform2D(0.0, stranded))
	var car: TopDownCar = context.car
	_check(car.set_safe_reset_pose(pose), "the climb pose is accepted as a safe pose")
	car.set_auto_reset_enabled(true)
	var ticks := int((_tuning.auto_reset_stuck_seconds + 0.5) * 60.0)
	for tick in range(ticks):
		await physics_frame
	var pose_ground := map.sample_at(origin).ground_height
	print("reset_on_slope seed=%d gradient=%.4f pose_ground=%.3f car_height=%.3f distance=%.3f" % [climb.seed, climb.gradient, pose_ground, car.get_height(), car.global_position.distance_to(origin)])
	_check(car.consume_auto_reset_notice(), "sitting still off-track beside a slope fires the automatic reset")
	_check(car.global_position.distance_to(origin) < 1.0, "the reset lands the car on the climb pose")
	_check(not car.is_airborne() and car.get_vertical_velocity() == 0.0, "the reset car is on the ground and still")
	_check(pose_ground != 0.0 and absf(car.get_height() - pose_ground) < 1e-3, "the reset seats the car at the terrain height under the pose (%.3f px)" % pose_ground)
	var parked_peak := 0.0
	for tick in range(PARKED_TICKS):
		await physics_frame
		parked_peak = maxf(parked_peak, car.get_speed())
	_check(parked_peak < 1.0, "the reset car does not roll on the slope (peak %.3f px/s in two seconds)" % parked_peak)
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	for tick in range(60):
		await physics_frame
	var driven := (car.global_position - origin).dot(forward)
	_check(driven >= DRIVE_AWAY_DISTANCE, "the reset car climbs away under throttle (%.1f px in a second)" % driven)
	context.world.queue_free()
	await process_frame
	return true


func _definition(seed: int) -> TrackDefinition:
	if not _definitions.has(seed):
		_definitions[seed] = _generator.generate(seed)
	return _definitions[seed]


## The terrain of a definition with no ramps on it: the map's answer is the field alone.
func _bare_terrain_map(definition: TrackDefinition) -> TrackHeightMap:
	var bare := TrackDefinition.new()
	bare.terrain_seed = definition.terrain_seed
	return TrackHeightMap.new(bare)


func _on_ramp(definition: TrackDefinition, position: Vector2) -> bool:
	for ramp: JumpRampPlacement in definition.jump_ramps:
		var local := ramp.transform.affine_inverse() * position
		if absf(local.x) <= ramp.half_length and absf(local.y) <= ramp.width * 0.5 + ramp.flank_width:
			return true
	return false


## A transform whose forward axis (the car's -y) points along `forward`.
func _pose(position: Vector2, forward: Vector2) -> Transform2D:
	return Transform2D(atan2(forward.x, -forward.y), position)


## Where a line through the area's centre along `heading` enters the area, a little inside it.
func _entry_point(area: Rect2, heading: Vector2) -> Vector2:
	var centre := area.get_center()
	var distance := INF
	if heading.x > 1e-6:
		distance = minf(distance, (centre.x - area.position.x) / heading.x)
	elif heading.x < -1e-6:
		distance = minf(distance, (area.end.x - centre.x) / -heading.x)
	if heading.y > 1e-6:
		distance = minf(distance, (centre.y - area.position.y) / heading.y)
	elif heading.y < -1e-6:
		distance = minf(distance, (area.end.y - centre.y) / -heading.y)
	return centre - heading * (distance - 30.0)


## Speed at which rolling plus aerodynamic drag balance a constant acceleration.
func _terminal_speed(acceleration: float) -> float:
	if acceleration <= 0.0:
		return 0.0
	var rolling := _tuning.rolling_drag
	var aero := _tuning.aerodynamic_drag
	return (-rolling + sqrt(rolling * rolling + 4.0 * aero * acceleration)) / (2.0 * aero)


## The integrator's longitudinal model on a constant slope, step for step: engine and slope, then
## drag toward zero, then the clamp.
func _model_speed(ticks: int, slope: float, throttle: float, initial_speed: float) -> float:
	var speed := initial_speed
	for tick in range(ticks):
		speed += (_tuning.engine_force * throttle / _tuning.mass_kg - _tuning.gravity * slope) * TICK
		var drag := (_tuning.rolling_drag * absf(speed) + _tuning.aerodynamic_drag * speed * speed) * TICK
		speed = move_toward(speed, 0.0, drag)
		speed = minf(speed, _tuning.max_safe_speed)
	return speed


## A car seeded with a velocity is seated on the ground one step along it: the physics server
## moves a body by one step of its velocity before the first _integrate_forces sees it, so a car
## seated where it was placed reads its first tick against a stale height and, on a descent
## steeper than the lift-off tolerance per tick of travel, leaves the ground for no reason.
## The car reads its lookahead sample within the tick that queried it. TrackHeightMap's miss path
## hands back one shared sample that the next query rewrites, so that read is safe only while
## nothing between the query and the last read samples again; the landing call is where the sample
## used to cross a call boundary. Pinned by count rather than by inspection: on a scripted hump,
## every physics tick after the first issues exactly the two height queries a grounded tick does,
## the ground under the car and the lookahead, and the landing tick issues no more than that.
## Adding one query inside _land fails the landing check (performed live in the fix report).
func _verify_landing_issues_no_extra_query() -> bool:
	var provider := HeightChannelTestHeightProvider.new()
	provider.mode = HeightChannelTestHeightProvider.Mode.HUMP
	provider.crest_x = QUERY_HUMP_CREST_X
	provider.half_length = QUERY_HUMP_HALF_LENGTH
	provider.crest_height = QUERY_HUMP_CREST_HEIGHT
	var context := _make_car(provider, Issue4TestSurfaceProvider.new(), _pose(Vector2.ZERO, Vector2.RIGHT), null, Vector2(_tuning.max_safe_speed, 0.0))
	var car: TopDownCar = context.car
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var counted_from := provider.sample_count
	var was_airborne := false
	var launched := false
	var landings := 0
	var landing_queries := -1
	var grounded_counts: Dictionary = {}
	var airborne_counts: Dictionary = {}
	var ticks := 0
	for tick in range(LANDING_QUERY_TICKS):
		await physics_frame
		ticks += 1
		var queries := provider.sample_count - counted_from
		counted_from = provider.sample_count
		var airborne := car.is_airborne()
		# The first await may or may not straddle a physics step; every later one is exactly one.
		if tick == 0:
			was_airborne = airborne
			continue
		if airborne and not was_airborne:
			launched = true
		if was_airborne and not airborne:
			landings += 1
			landing_queries = queries
		elif airborne:
			airborne_counts[queries] = int(airborne_counts.get(queries, 0)) + 1
		else:
			grounded_counts[queries] = int(grounded_counts.get(queries, 0)) + 1
		was_airborne = airborne
		if landings > 0:
			break
	print("landing_queries ticks=%d launched=%s landings=%d landing_tick_queries=%d grounded=%s airborne=%s" % [ticks, launched, landings, landing_queries, grounded_counts, airborne_counts])
	_check(launched and landings == 1, "the hump launches the car and it lands within %d ticks (%d landings)" % [LANDING_QUERY_TICKS, landings])
	_check(grounded_counts.keys() == [2] and airborne_counts.keys() == [2], "every grounded and every airborne tick issues exactly two height queries, the ground under the car and the lookahead (grounded %s, airborne %s)" % [grounded_counts, airborne_counts])
	_check(landing_queries == 2, "the landing tick issues the same two queries, so _land samples nothing through the held lookahead (%d)" % landing_queries)
	context.world.queue_free()
	await process_frame
	return true


func _make_car(height_query: HeightQuery, surface_query: SurfaceQuery, transform: Transform2D, tuning: VehicleTuning = null, velocity: Vector2 = Vector2.ZERO) -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = tuning if tuning != null else _tuning
	car.global_transform = Transform2D(transform.get_rotation(), transform.origin + velocity * TICK)
	car.set_surface_query(surface_query)
	car.set_height_query(height_query)
	car.global_transform = transform
	world.add_child(car)
	car.set_safe_reset_pose(transform)
	car.linear_velocity = velocity
	return {"world": world, "car": car}


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


## A section's completion is a guard, not an assertion: it fails only when the section bailed out
## early, and it is not counted toward the check total the final line reports.
func _section(ran: bool, message: String) -> void:
	_sections += 1
	if ran:
		print("DONE: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Vehicle terrain checks passed: %d checks across %d sections" % [_checks, _sections])
		quit(0)
		return
	for failure in _failures:
		push_error("Vehicle terrain check failed: %s" % failure)
	quit(1)
