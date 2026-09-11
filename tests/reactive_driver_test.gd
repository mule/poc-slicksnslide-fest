extends SceneTree

## Reactive driving (#58): a car driven by ReactiveDriver, from nothing but its senses, gets round.
##
## Laps run against the production world -- TrackRuntime with its real trees, rocks and play-area
## boundary in the physics space, the production TrackSurfaceMap and height map, a production
## SensingPass -- with the car's own automatic reset OFF, so nothing but the driver gets it home.
##
## ## What is asserted, and the thresholds, fixed before anything was measured against them
##
## - **A lap**, on every seed in TUNED_SEEDS and HELD_OUT_SEEDS, inside LAP_TICK_BUDGET.
## - **Never outside the play area**, and never further from the centreline than the car's own
##   automatic reset calls lost (`auto_reset_lost_distance`).
## - **Never stuck.** Stuck is the car's own definition, the one its automatic reset fires on:
##   slower than `auto_reset_stuck_speed` (2 m/s) for `auto_reset_stuck_seconds` (2 s) without a
##   break. The reset only applies that rule off the road; this suite applies it everywhere, which
##   is stricter. With the reset switched off, a car that meets it is a car the game would have had
##   to rescue.
## - **On the road.** The car's centre is off the dirt for at most MAX_OFF_ROAD_FRACTION of the lap.
##   The issue does not ask for this; it is here because a driver that gets round by running wide at
##   every corner and recovering is being rescued by its recovery, not driving, and the lap test
##   should be able to tell the two apart. Fixed before either mutation below was first run.
## - **Lift.** Every flight leaves the ground with the throttle released.
## - **Recovery**, from three placed starts on RECOVERY_SEEDS: facing the wrong way, off the road
##   facing away from it, and pinned nose-first against a rock off the road. Each must get back to
##   racing -- two consecutive checkpoints crossed forward -- without meeting the stuck rule, and each
##   carries a guard that the start really was what it claims to be.
## - **Determinism.** Two cars started from the same pose on the same seed produce identical control
##   streams, compared tick for tick over a whole lap. A third start 1 px to the side must produce a
##   different stream, which is what shows the comparison can see a difference at all.
## - **Stopping from speed.** A rival parked on the start straight: the car closes on it at racing
##   speed and comes to rest behind it without touching it. ADDED AFTER the lap test was found not to
##   fail under --break-brake-distance (see the report and _verify_it_stops_for_a_parked_rival).
## - **Senses only.** Structurally: every field the driver declares is plain data, and the only
##   object any of its methods accepts is the DriverSenses handed to perceive().
##
## ## Mutations
##
##   -- --break-steer-heading   drops the heading term from steering (BrokenHeadingDriver)
##   -- --break-brake-distance  makes the braking distance a constant (BrokenBrakingDriver): the
##                              production distance from half of max_safe_speed to rest, whatever
##                              the actual speed. Chosen as the middle of the car's range before the
##                              mutation was first run, and not adjusted since.
##
## Either one replaces the driver in every section of this file, so the unit checks fail with it as
## well as the laps.
##
## Exploration switches, for tuning and for the report, none of which a normal run uses:
##   --seeds=a,b,c           laps and recovery on these seeds only
##   --laps-only             skip the unit checks, recovery and determinism
##   --recovery-only         skip the laps
##   --blind-to-road-ahead   drive with the road-ahead sense blanked (see BlindToTheRoadAheadDriver)
##   --trace                 write a per-tick CSV of every drive to user://

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const OBJECT_CATALOG_PATH := "res://data/default_offtrack_object_catalog.tres"
const TICK := 1.0 / 60.0
## Ten times the tick rate at ten times the time scale is still a 1 / 60 s step, ten times faster in
## real time; tests/vehicle_terrain_test.gd pins that the step really is the production one, and
## _verify_the_physics_step below re-pins it for this file.
const PHYSICS_TICKS_PER_SECOND := 600
const TIME_SCALE := 10.0
## Five minutes. The driver's slowest lap on any seed is well under two.
const LAP_TICK_BUDGET := 18000
## The seeds the driver's gains were tuned against, and the seeds it was only ever tested on.
const TUNED_SEEDS := [0, 1, 2, 3, 4]
const HELD_OUT_SEEDS := [5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
const RECOVERY_SEEDS := [0, 1, 2, 5, 6, 7]
const DETERMINISM_SEED := 3
## The index a rival's driver is built with. 0 is the player's identity.
const DRIVER_INDEX := 1
const MAX_OFF_ROAD_FRACTION := 0.05
## The recovery scenarios start at this fraction of the way round the lap.
const SCENARIO_LAP_FRACTION := 0.3
## Forty seconds to get back to racing and cross two checkpoints.
const SCENARIO_TICK_BUDGET := 2400
## How far past the road's edge the off-road start stands.
const OFF_ROAD_START_BEYOND_EDGE_M := 10.0
## Gap between the car's nose and the rock it is pinned against, and the angle from the road's normal
## that its nose points in at: 45 degrees, so its heading error is 45 degrees and nowhere near the
## wrong-way threshold. See _pinned_against_a_rock.
const PINNED_GAP_PX := 2.0
const PINNED_APPROACH_ANGLE := PI * 0.25
## The car's collision capsule: half its length along the nose, and its radius.
const CAR_HALF_LENGTH_PX := 26.0
const CAR_RADIUS_PX := 15.0
## The stopping check: how far down the start straight the rival is parked, how many seeds it runs
## on, and the speed the car must have reached for the stop to be a stop from racing speed.
const PARKED_RIVAL_DISTANCE := 1500.0
const PARKED_RIVAL_SEED_COUNT := 3
const PARKED_RIVAL_SCAN_STEP := 10
const PARKED_RIVAL_MAX_CURVATURE := 0.002
const PARKED_RIVAL_TICK_BUDGET := 1200
const RACING_SPEED_M := 28.0
const STEP_PIN_TICKS := 90
const STEP_PIN_SPEED := 500.0

var _failures: Array[String] = []
var _checks := 0
var _tuning: VehicleTuning
var _catalog: OfftrackObjectCatalog
var _generator := TrackGenerator.new()
var _break_heading := false
var _break_braking := false
var _only_seeds: Array[int] = []
## Seeds whose lap met every lap assertion, filled in by _verify_a_lap.
var _clean_laps: Array[int] = []
var _laps_only := false
var _recovery_only := false
var _trace := false


## --break-steer-heading. Steering keeps the offset term and the road's turn and loses the damping.
class BrokenHeadingDriver:
	extends ReactiveDriver

	func _heading_term(_heading_error: float) -> float:
		return 0.0


## --break-brake-distance. Every "can I stop in time" is answered with the same distance: the
## production answer from half of max_safe_speed to rest, whatever speed the car is actually doing.
class BrokenBrakingDriver:
	extends ReactiveDriver

	var _constant: float

	func _init(track_seed: int = 0, index: int = 0, version: int = 1) -> void:
		super(track_seed, index, version)
		var tuning := load(TUNING_PATH) as VehicleTuning
		_constant = super._braking_distance(tuning.max_safe_speed * 0.5, 0.0)

	func _braking_distance(_from_speed: float, _to_speed: float) -> float:
		return _constant


## Evidence, not a mutation the issue names: the driver with #58's one added sense blanked, so the
## report can say what the road-ahead sense buys. Only run through --blind-to-road-ahead.
class BlindToTheRoadAheadDriver:
	extends ReactiveDriver

	func perceive(senses: DriverSenses) -> void:
		senses.road_ahead_found = false
		senses.road_ahead_lateral_offset = 0.0
		senses.road_ahead_heading_error = 0.0
		super(senses)


var _blind := false


func _initialize() -> void:
	Engine.physics_ticks_per_second = PHYSICS_TICKS_PER_SECOND
	Engine.time_scale = TIME_SCALE
	var arguments := OS.get_cmdline_user_args()
	_break_heading = arguments.has("--break-steer-heading")
	_break_braking = arguments.has("--break-brake-distance")
	_blind = arguments.has("--blind-to-road-ahead")
	_laps_only = arguments.has("--laps-only")
	_recovery_only = arguments.has("--recovery-only")
	_trace = arguments.has("--trace")
	for argument in arguments:
		if argument.begins_with("--seeds="):
			for text in argument.trim_prefix("--seeds=").split(","):
				_only_seeds.append(int(text))
	call_deferred("_run")


func _run() -> void:
	_tuning = load(TUNING_PATH) as VehicleTuning
	_catalog = load(OBJECT_CATALOG_PATH) as OfftrackObjectCatalog
	if _break_heading:
		print("NOTE: --break-steer-heading is on; every driver in this run steers without its heading term.")
	if _break_braking:
		print("NOTE: --break-brake-distance is on; every driver in this run brakes at one constant distance.")
	if not _laps_only:
		_check(await _verify_the_physics_step(), "the physics step verification ran to completion")
		_check(_verify_the_driver_reads_only_its_senses(), "the senses-only verification ran to completion")
		_check(_verify_it_is_neutral_until_it_has_senses(), "the neutral-start verification ran to completion")
		_check(_verify_steering_has_two_terms(), "the steering verification ran to completion")
		_check(_verify_braking_distance_grows_with_speed(), "the braking distance verification ran to completion")
		_check(_verify_it_slows_for_what_it_senses(), "the slow-down verification ran to completion")
		_check(_verify_it_lifts_for_a_falling_crest(), "the lift verification ran to completion")
		_check(_verify_the_recovery_rules(), "the recovery rule verification ran to completion")
	var lap_seeds: Array[int] = []
	if _only_seeds.is_empty():
		lap_seeds.append_array(TUNED_SEEDS)
		lap_seeds.append_array(HELD_OUT_SEEDS)
	else:
		lap_seeds = _only_seeds
	if _recovery_only:
		lap_seeds = []
	for seed in lap_seeds:
		_check(await _verify_a_lap(seed), "the seed %d lap verification ran to completion" % seed)
	print("laps: %d of %d seeds completed a clean lap: %s" % [_clean_laps.size(), lap_seeds.size(), _clean_laps])
	if not lap_seeds.is_empty():
		_check(_clean_laps.size() >= 5, "a full lap on at least five different track seeds (%d: %s)" % [_clean_laps.size(), _clean_laps])
	if not _laps_only:
		var recovery_seeds: Array = RECOVERY_SEEDS if _only_seeds.is_empty() else _only_seeds
		for seed: int in recovery_seeds:
			_check(await _verify_recovery(seed), "the seed %d recovery verification ran to completion" % seed)
		_check(await _verify_control_streams_repeat(), "the determinism verification ran to completion")
		_check(await _verify_it_stops_for_a_parked_rival(), "the parked-rival verification ran to completion")
	_finish()


func _make_driver(seed: int, index: int = DRIVER_INDEX) -> ReactiveDriver:
	if _break_heading:
		return BrokenHeadingDriver.new(seed, index)
	if _break_braking:
		return BrokenBrakingDriver.new(seed, index)
	if _blind:
		return BlindToTheRoadAheadDriver.new(seed, index)
	return ReactiveDriver.new(seed, index)


# ---------------------------------------------------------------------------------------------
# The step


## Lap times below are counted in ticks, so each tick must really be the production 1 / 60 s at the
## sped-up rate. A level-ground full-throttle run from a known speed is compared with the
## integrator's longitudinal model, the check tests/vehicle_terrain_test.gd makes.
func _verify_the_physics_step() -> bool:
	var world := Node2D.new()
	root.add_child(world)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = _tuning
	var pose := Transform2D(atan2(1.0, 0.0), Vector2.ZERO)
	car.global_transform = pose
	car.set_surface_query(Issue4TestSurfaceProvider.new())
	car.set_height_query(HeightQuery.new())
	world.add_child(car)
	car.linear_velocity = Vector2(STEP_PIN_SPEED, 0.0)
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	await physics_frame
	var speed := car.get_speed()
	for tick in range(STEP_PIN_TICKS):
		await physics_frame
		speed += (_tuning.engine_force / _tuning.mass_kg) * TICK
		var drag := (_tuning.rolling_drag * absf(speed) + _tuning.aerodynamic_drag * speed * speed) * TICK
		speed = minf(move_toward(speed, 0.0, drag), _tuning.max_safe_speed)
	print("physics_step real=%.4f model=%.4f ticks_per_second=%d time_scale=%.1f" % [car.get_speed(), speed, Engine.physics_ticks_per_second, Engine.time_scale])
	_check(absf(car.get_speed() - speed) < 0.05, "at %d ticks a second and time scale %.1f the car matches the integrator's model to 0.05 px/s (%.4f against %.4f), so each tick is the production 1 / 60 s" % [PHYSICS_TICKS_PER_SECOND, TIME_SCALE, car.get_speed(), speed])
	world.queue_free()
	await process_frame
	return true


# ---------------------------------------------------------------------------------------------
# Structure


## The issue asks for "the driver reads only its senses" to be established structurally where the
## language allows. Two walks, both over what the script declares rather than what it happens to do:
##
## - every property ReactiveDriver declares is plain data -- the seam rule from
##   tests/ai_driver_contract_test.gd, applied to this class -- so it can hold no car, no track, no
##   field and no DriverSenses between ticks;
## - every method it declares, its own and inherited, takes only plain values, with one exception:
##   perceive(), whose one argument is typed DriverSenses. That is the only door an object comes in
##   by, and it is the senses.
##
## What neither walk can see is a global: an autoload or a static reached by name. The driver
## script names no autoload and no static but WorldScale's pure conversions; that half is by
## inspection, stated in the report.
func _verify_the_driver_reads_only_its_senses() -> bool:
	var driver := _make_driver(0)
	var declared := 0
	for property in driver.get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		declared += 1
		if int(property["type"]) in [TYPE_NIL, TYPE_OBJECT, TYPE_NODE_PATH, TYPE_RID, TYPE_CALLABLE, TYPE_SIGNAL]:
			_check(false, "ReactiveDriver.%s is plain data (type %d)" % [property["name"], property["type"]])
	_check(declared >= 30, "the property walk saw the driver's own state as well as its identity (%d declared)" % declared)
	var object_arguments: Array[String] = []
	var methods := 0
	var script: Script = driver.get_script()
	while script != null:
		for method in script.get_script_method_list():
			methods += 1
			for argument in method["args"]:
				if int(argument["type"]) in [TYPE_NIL, TYPE_OBJECT, TYPE_NODE_PATH, TYPE_RID, TYPE_CALLABLE, TYPE_SIGNAL]:
					object_arguments.append("%s(%s: %s)" % [method["name"], argument["name"], argument.get("class_name", "")])
		script = script.get_base_script()
	print("senses only: %d declared properties, %d declared methods, object arguments %s" % [declared, methods, object_arguments])
	_check(methods >= 10, "the method walk saw the driver's methods (%d)" % methods)
	var only_senses := not object_arguments.is_empty()
	for entry in object_arguments:
		only_senses = only_senses and entry.begins_with("perceive(") and entry.ends_with(": DriverSenses)")
	_check(only_senses, "the only object any driver method accepts is perceive()'s DriverSenses (%s)" % [object_arguments])
	return true


# ---------------------------------------------------------------------------------------------
# Single ticks against synthetic senses. No physics: these are the terms, one at a time.


## A DriverSenses for a car on a straight road, on the centreline, aligned, at `speed` px/s along its
## nose, nothing around it. Each check below changes what it is about.
func _straight_road_senses(speed: float) -> DriverSenses:
	var senses := DriverSenses.new()
	senses.look_ahead = WorldScale.metres(ReactiveDriver.LOOK_AHEAD_M)
	senses.road_found = true
	senses.distance_to_left_edge = 120.0
	senses.distance_to_right_edge = 120.0
	senses.road_ahead_found = true
	senses.surface_type = SurfaceQuery.SurfaceType.DIRT
	senses.local_velocity = Vector2(0.0, -speed)
	return senses


func _one_tick(senses: DriverSenses, driver: ReactiveDriver = null) -> VehicleInputState:
	var subject := driver if driver != null else _make_driver(0)
	subject.perceive(senses)
	return subject.drive(TICK)


func _verify_it_is_neutral_until_it_has_senses() -> bool:
	var controls := _make_driver(0).drive(TICK)
	_check(controls.steer == 0.0 and controls.throttle == 0.0 and controls.brake == 0.0 and controls.handbrake == 0.0, "a driver that has been handed no senses yet returns neutral controls")
	var moving := _one_tick(_straight_road_senses(0.0))
	_check(moving.throttle > 0.0, "handed the senses of an empty straight road at rest, it drives off (throttle %.2f)" % moving.throttle)
	return true


## Heading and offset, each alone. The heading case has the car ON the centreline, so the offset
## term reads zero and anything the steering does comes from the heading term; the offset case has
## the car aligned, so the reverse holds. The road ahead mirrors the road here in both, so the road's
## own turn reads zero too. Signs are the car's: positive steer turns the nose right.
func _verify_steering_has_two_terms() -> bool:
	var speed := WorldScale.metres(24.0)
	for heading: float in [0.2, -0.2]:
		var senses := _straight_road_senses(speed)
		senses.heading_error = heading
		senses.road_ahead_heading_error = heading
		senses.road_ahead_lateral_offset = senses.look_ahead * sin(heading)
		# Travelling where the nose points, so the course and the nose agree.
		senses.local_velocity = Vector2(0.0, -speed)
		var controls := _one_tick(senses)
		_check(signf(controls.steer) == -signf(heading) and absf(controls.steer) > 0.1, "on the centreline with the nose %+.1f rad off the road, it steers back (steer %+.3f)" % [heading, controls.steer])
	for offset: float in [40.0, -40.0]:
		var senses := _straight_road_senses(speed)
		senses.lateral_offset = offset
		senses.road_ahead_lateral_offset = offset
		senses.distance_to_right_edge = 120.0 - offset
		senses.distance_to_left_edge = 120.0 + offset
		var controls := _one_tick(senses)
		_check(signf(controls.steer) == -signf(offset) and absf(controls.steer) > 0.05, "aligned but %+.0f px off the centreline, it steers back (steer %+.3f)" % [offset, controls.steer])
	# A slide: the nose points down the road while the car travels wide of it. Only the direction of
	# travel says so, and the heading term is what reads it.
	var sliding := _straight_road_senses(speed)
	sliding.local_velocity = Vector2(-0.25, -1.0).normalized() * speed
	var slide := _one_tick(sliding)
	_check(slide.steer > 0.1, "nose aligned but sliding to the left, it steers right into the slide's direction of travel (steer %+.3f)" % slide.steer)
	return true


## The same obstacle at the same distance, at two speeds. The expectation is the driver's own
## belief worked by hand: stopping from 150 px/s at 12 m/s^2 (150 px/s^2) takes 150^2 / 300 +
## 150 * 0.15 = 97.5 px, well inside the 250 px it has once 50 px of clearance is kept; from 400 px/s
## it takes 533.3 + 60 = 593.3 px, more than twice what it has.
##
## 400 px/s and not faster on purpose. Above about 437 px/s the car's own limit of vision brakes it
## with nothing in the way (the tightest corner it expects may start just past its 600 px horizon), so
## a faster "fast" case would pass with the obstacle rule deleted. The straight-road case at the same
## speed is what shows the obstacle, and nothing else, is the reason.
func _verify_braking_distance_grows_with_speed() -> bool:
	var obstacle_at := 300.0
	var clear_road := _one_tick(_straight_road_senses(400.0))
	_check(clear_road.brake == 0.0 and clear_road.throttle > 0.5, "at 400 px/s on an empty straight it does not brake (throttle %.2f)" % clear_road.throttle)
	var slow := _straight_road_senses(150.0)
	slow.has_obstacle_ahead = true
	slow.obstacle_distance = obstacle_at
	slow.obstacle_offset = Vector2(0.0, -obstacle_at)
	var fast := _straight_road_senses(400.0)
	fast.has_obstacle_ahead = true
	fast.obstacle_distance = obstacle_at
	fast.obstacle_offset = Vector2(0.0, -obstacle_at)
	var slow_controls := _one_tick(slow)
	var fast_controls := _one_tick(fast)
	_check(fast_controls.brake > 0.5 and fast_controls.throttle == 0.0, "at 400 px/s an obstacle 300 px ahead is inside its stopping distance: it brakes (brake %.2f)" % fast_controls.brake)
	_check(slow_controls.brake == 0.0 and slow_controls.throttle > 0.0, "at 150 px/s the same obstacle is not: it keeps driving (throttle %.2f, brake %.2f)" % [slow_controls.throttle, slow_controls.brake])
	# The same pair for a corner. The road turns 1 rad right across the look-ahead, and the look-ahead
	# point sits 0.5 * 600 * sin(1) = 252.4 px outside the car's line. Read as a straight into an arc,
	# the arc is 2 * 252.4 / 1 = 504.8 px long, so it starts 95.2 px out with a radius of 504.8 px and
	# a corner speed of sqrt(170 * 504.8) = 292.9 px/s. From 400 px/s that needs 263 px of braking;
	# from 180 px/s it needs none.
	for speed: float in [180.0, 400.0]:
		var senses := _straight_road_senses(speed)
		senses.road_ahead_heading_error = -1.0
		senses.road_ahead_lateral_offset = -0.5 * senses.look_ahead * sin(1.0)
		var controls := _one_tick(senses)
		if speed < 300.0:
			_check(controls.brake == 0.0, "at %.0f px/s a corner of 505 px radius starting 95 px ahead needs no braking (brake %.2f)" % [speed, controls.brake])
		else:
			_check(controls.brake > 0.5, "at %.0f px/s the same corner does (brake %.2f)" % [speed, controls.brake])
	return true


## A rival in its path that it is catching, one it is not catching, and one beside its path. Rivals
## are never on the obstacle ray (the senses rule), and they are only a reason to brake when being
## caught: a driver that braked for every car ahead would brake for the whole field.
func _verify_it_slows_for_what_it_senses() -> bool:
	var speed := WorldScale.metres(28.0)
	var catching := _straight_road_senses(speed)
	catching.has_rival_ahead = true
	catching.rival_offset = Vector2(0.0, -120.0)
	catching.rival_distance = 120.0
	catching.rival_relative_velocity = Vector2(0.0, 150.0)
	var caught := _one_tick(catching)
	_check(caught.brake > 0.5, "catching a rival 120 px ahead in its path at 150 px/s, it brakes (brake %.2f)" % caught.brake)
	var leaving := _straight_road_senses(speed)
	leaving.has_rival_ahead = true
	leaving.rival_offset = Vector2(0.0, -120.0)
	leaving.rival_distance = 120.0
	leaving.rival_relative_velocity = Vector2(0.0, -50.0)
	var followed := _one_tick(leaving)
	_check(followed.brake == 0.0 and followed.throttle > 0.0, "the same rival pulling away costs nothing (throttle %.2f, brake %.2f)" % [followed.throttle, followed.brake])
	var beside := _straight_road_senses(speed)
	beside.has_rival_ahead = true
	beside.rival_offset = Vector2(-100.0, -60.0)
	beside.rival_distance = beside.rival_offset.length()
	beside.rival_relative_velocity = Vector2(0.0, 150.0)
	var passing := _one_tick(beside)
	_check(passing.brake == 0.0, "a rival being caught but 100 px beside its path is not in the way (brake %.2f)" % passing.brake)
	# The path is the road's, not the nose's. A rival 200 px ahead and 45 px right of the nose line,
	# closing at 200 px/s: on a straight road that is beside the path (45 px against a 37.5 px lane),
	# and on a road turning 0.9 rad right across the look-ahead it is in it -- the road has moved
	# 0.9 / 600 * 200^2 / 2 = 30 px right by then, leaving the rival 15 px off the line. Stopping
	# from 200 px/s takes 163 px of the 125 px left once the following gap is kept. At 200 px/s the
	# bend itself needs no braking (radius 667 px, corner speed 337 px/s), so the rival is the reason.
	for bend: float in [0.0, 0.9]:
		var senses := _straight_road_senses(200.0)
		senses.road_ahead_heading_error = -bend
		senses.road_ahead_lateral_offset = -270.0 if bend > 0.0 else 0.0
		senses.has_rival_ahead = true
		senses.rival_offset = Vector2(45.0, -200.0)
		senses.rival_distance = senses.rival_offset.length()
		senses.rival_relative_velocity = Vector2(0.0, 200.0)
		var controls := _one_tick(senses)
		if bend == 0.0:
			_check(controls.brake == 0.0, "on a straight road a rival 45 px right of the nose line is beside the path (brake %.2f)" % controls.brake)
		else:
			_check(controls.brake > 0.5, "on a road bending right the same rival is in the path, and it brakes (brake %.2f)" % controls.brake)
	# A road edge closing across the nose on a straight road: 0.3 rad toward an edge 40 px away puts
	# the crossing 40 / sin(0.3) = 135 px ahead, too close to be down to a turning speed from 400 px/s.
	var crossing := _straight_road_senses(400.0)
	crossing.lateral_offset = 80.0
	crossing.distance_to_right_edge = 40.0
	crossing.distance_to_left_edge = 200.0
	crossing.heading_error = 0.3
	crossing.road_ahead_heading_error = 0.3
	crossing.road_ahead_lateral_offset = 80.0 + crossing.look_ahead * sin(0.3)
	var edge := _one_tick(crossing)
	_check(edge.brake > 0.5, "with the right edge closing 135 px along its nose at 400 px/s, it brakes (brake %.2f)" % edge.brake)
	return true


## Lift reads how fast the ground ahead falls away as the car moves, so it takes two ticks. At
## 400 px/s a tick covers 6.67 px: a ramp face, whose slope is 0.06, drops the ground ahead 0.4 px
## relative to the car in that tick. A gentle terrain change of 0.1 px in the same tick is a slope
## break of 0.015, which is not a crest. And a steady downhill -- the ground ahead 9 px lower, and
## staying 9 px lower -- is not falling away at all.
func _verify_it_lifts_for_a_falling_crest() -> bool:
	var speed := 400.0
	for case: Array in [["a ramp face", 0.0, -0.4, true], ["a gentle terrain change", 0.0, -0.1, false], ["a steady downhill", -9.0, -9.0, false]]:
		var driver := _make_driver(0)
		var before := _straight_road_senses(speed)
		before.height_change_ahead = case[1]
		_one_tick(before, driver)
		var after := _straight_road_senses(speed)
		after.height_change_ahead = case[2]
		var controls := _one_tick(after, driver)
		if case[3]:
			_check(controls.throttle == 0.0 and controls.brake == 0.0, "with the ground ahead falling away as on %s, it lifts: no throttle and no brake (throttle %.2f, brake %.2f)" % [case[0], controls.throttle, controls.brake])
		else:
			_check(controls.throttle > 0.5, "on %s it stays on the throttle (%.2f)" % [case[0], controls.throttle])
	return true


## Stuck, then out. A car held still with the road straight ahead reverses once the stall has lasted
## STALL_SECONDS, steering so its nose swings back toward the road; after REVERSE_SECONDS it drives
## again. Wrong way round, it commits to one direction of turn and holds it across the +/-PI seam.
func _verify_the_recovery_rules() -> bool:
	var driver := _make_driver(0)
	var stalled := _straight_road_senses(0.0)
	stalled.lateral_offset = 60.0
	stalled.distance_to_right_edge = 60.0
	stalled.distance_to_left_edge = 180.0
	stalled.road_ahead_lateral_offset = 60.0
	var stall_ticks := ceili(ReactiveDriver.STALL_SECONDS / TICK) + 1
	var last := VehicleInputState.new()
	for tick in range(stall_ticks):
		last = _one_tick(stalled, driver)
	_check(driver.reversals == 1 and driver.mode == ReactiveDriver.Mode.REVERSE, "held still for %d ticks it starts one reversal (%d, mode %d)" % [stall_ticks, driver.reversals, driver.mode])
	last = _one_tick(stalled, driver)
	_check(last.brake == 1.0 and last.throttle == 0.0, "reversing is the brake held at a standstill, which TopDownCar turns into reverse")
	# 60 px right of the centreline, the road steering wants the nose to turn left; rolling
	# backwards that takes a right-hand input.
	_check(last.steer > 0.5, "backing out, it steers so the nose swings left toward the road (steer %+.2f)" % last.steer)
	var reverse_ticks := ceili(ReactiveDriver.REVERSE_SECONDS / TICK) + 1
	for tick in range(reverse_ticks):
		last = _one_tick(stalled, driver)
	_check(driver.mode == ReactiveDriver.Mode.RACE and last.throttle > 0.0, "after %d ticks of reversing it drives forward again (mode %d, throttle %.2f)" % [reverse_ticks, driver.mode, last.throttle])

	var turning := _make_driver(0)
	var backwards := _straight_road_senses(WorldScale.metres(4.0))
	backwards.heading_error = PI - 0.05
	backwards.road_ahead_heading_error = PI - 0.05
	var first := _one_tick(backwards, turning)
	backwards.heading_error = -PI + 0.05
	backwards.road_ahead_heading_error = -PI + 0.05
	var second := _one_tick(backwards, turning)
	_check(absf(first.steer) == 1.0 and second.steer == first.steer, "facing the wrong way it turns at full lock and holds the same direction as heading error crosses PI (%+.2f then %+.2f)" % [first.steer, second.steer])
	_check(turning.turn_arounds == 1, "that is counted as one turn-around (%d)" % turning.turn_arounds)
	var lost := _make_driver(0)
	var nowhere := DriverSenses.new()
	nowhere.look_ahead = WorldScale.metres(ReactiveDriver.LOOK_AHEAD_M)
	lost.perceive(nowhere)
	_check(lost.sensing_horizon() > WorldScale.metres(ReactiveDriver.LOOK_AHEAD_M), "a driver that finds no road asks to look further (%.0f px)" % lost.sensing_horizon())
	return true


# ---------------------------------------------------------------------------------------------
# Laps


func _verify_a_lap(seed: int) -> bool:
	var definition: TrackDefinition = _generator.generate(seed)
	var lap := await _drive(definition, _make_driver(seed), definition.spawn_transform, LAP_TICK_BUDGET, "lap")
	var set_name := "tuned" if seed in TUNED_SEEDS else "held-out"
	print("lap seed=%d set=%s completed=%s lap_s=%.2f checkpoints=%d top=%.1f mean=%.1f off_road=%.2f%% max_from_centre=%.1f outside=%d slowest_streak=%d contacts=%d flights=%d lifted=%d landings_off_road=%d recoveries=%d (reversals=%d turn_arounds=%d road_returns=%d)" % [
		seed, set_name, lap.completed, lap.ticks * TICK, lap.checkpoints, lap.top_speed, definition.lap_length / (lap.ticks * TICK),
		100.0 * lap.off_road_ticks / float(lap.ticks), lap.max_from_centre, lap.outside_ticks, lap.longest_slow, lap.contact_ticks,
		lap.flights, lap.flights_lifted, lap.landings_off_road, lap.recoveries, lap.reversals, lap.turn_arounds, lap.road_returns,
	])
	var clean := true
	clean = _check(lap.completed, "seed %d (%s): the reactive driver completes a lap (%.2f s)" % [seed, set_name, lap.ticks * TICK]) and clean
	clean = _check(lap.outside_ticks == 0, "seed %d: it never leaves the play area (%d ticks outside)" % [seed, lap.outside_ticks]) and clean
	clean = _check(lap.max_from_centre <= _tuning.auto_reset_lost_distance, "seed %d: it is never further from the centreline than the car's lost distance (%.1f of %.1f px)" % [seed, lap.max_from_centre, _tuning.auto_reset_lost_distance]) and clean
	clean = _check(lap.longest_slow < _stuck_ticks(), "seed %d: it is never stuck -- never below %.0f px/s for %d ticks (longest %d)" % [seed, _tuning.auto_reset_stuck_speed, _stuck_ticks(), lap.longest_slow]) and clean
	clean = _check(lap.off_road_ticks <= MAX_OFF_ROAD_FRACTION * lap.ticks, "seed %d: it drives the road, off it for %.2f%% of the lap (at most %.0f%%)" % [seed, 100.0 * lap.off_road_ticks / float(lap.ticks), 100.0 * MAX_OFF_ROAD_FRACTION]) and clean
	clean = _check(lap.flights_lifted == lap.flights, "seed %d: every flight left the ground with the throttle released (%d of %d)" % [seed, lap.flights_lifted, lap.flights]) and clean
	_check(lap.landings_off_road == 0, "seed %d: every landing came down on the road (%d off it)" % [seed, lap.landings_off_road])
	if clean:
		_clean_laps.append(seed)
	return true


func _stuck_ticks() -> int:
	return roundi(_tuning.auto_reset_stuck_seconds / TICK)


## Drives one car with one driver from `pose` until the lap completes, or -- for a scenario -- until
## it has crossed two consecutive checkpoints forward, or the budget runs out. Returns the whole
## record, including the control stream, four floats a tick.
func _drive(definition: TrackDefinition, driver: ReactiveDriver, pose: Transform2D, budget: int, goal: String) -> Dictionary:
	var runtime := TrackRuntime.new(definition)
	root.add_child(runtime)
	var surface := TrackSurfaceMap.new(definition)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = _tuning
	car.global_transform = pose
	runtime.add_child(car)
	car.set_surface_query(surface)
	car.set_height_query(runtime.height_query())
	car.set_auto_reset_enabled(false)
	# OfftrackObjectCollisions adds its shapes to bodies already in the tree, and those reach the
	# broadphase only once a step has run. The driver must not sense an empty world on its first tick.
	await physics_frame
	var sensing := SensingPass.new(surface, runtime.height_query())
	var field: Array[TopDownCar] = [car]
	var detector := CheckpointCrossingDetector.new(definition)
	detector.reset(car.global_position)
	var tracker := LapProgressTracker.new(definition.checkpoints.size())
	var record := {
		"completed": false, "ticks": 0, "controls": PackedFloat32Array(), "checkpoints": 0,
		"off_road_ticks": 0, "outside_ticks": 0, "max_from_centre": 0.0, "longest_slow": 0,
		"top_speed": 0.0, "contact_ticks": 0, "flights": 0, "flights_lifted": 0, "landings_off_road": 0,
		"forward_crossings": 0, "last_crossing": -1, "first_obstacle_distance": INF,
	}
	var slow := 0
	var was_airborne := false
	var throttle_before_step := 0.0
	var trace_lines: Array[String] = []
	for tick in range(budget):
		var senses := sensing.sense(field, 0, driver.sensing_horizon())
		if tick == 0 and senses.has_obstacle_ahead:
			record.first_obstacle_distance = senses.obstacle_distance
		driver.perceive(senses)
		var controls := driver.drive(TICK)
		record.controls.append_array(PackedFloat32Array([controls.steer, controls.throttle, controls.brake, controls.handbrake]))
		car.set_input_state(controls)
		throttle_before_step = controls.throttle
		if _trace:
			trace_lines.append("%d,%.1f,%.1f,%.1f,%.1f,%.3f,%.1f,%.3f,%.3f,%.2f,%.2f,%.2f,%d,%s,%.3f,%s,%.4f" % [
				tick, car.global_position.x, car.global_position.y, car.get_speed(), senses.lateral_offset, senses.heading_error,
				senses.road_ahead_lateral_offset, senses.road_ahead_heading_error, senses.height_change_ahead,
				controls.steer, controls.throttle, controls.brake, driver.mode, senses.surface_type == SurfaceQuery.SurfaceType.OFF_TRACK,
				car.get_height(), car.is_airborne(), -senses.gradient_ahead.y,
			])
		await physics_frame
		record.ticks += 1
		var position := car.global_position
		var speed := car.get_speed()
		record.top_speed = maxf(record.top_speed, speed)
		var off_road := surface.sample_at(position).surface_type == SurfaceQuery.SurfaceType.OFF_TRACK
		record.off_road_ticks += int(off_road)
		record.outside_ticks += int(not definition.play_area.has_point(position))
		record.max_from_centre = maxf(record.max_from_centre, surface.distance_to_centerline(position, _tuning.auto_reset_lost_distance * 2.0))
		record.contact_ticks += int(not car.get_colliding_bodies().is_empty())
		var airborne := car.is_airborne()
		if airborne and not was_airborne:
			record.flights += 1
			record.flights_lifted += int(throttle_before_step == 0.0)
		if was_airborne and not airborne and off_road:
			record.landings_off_road += 1
		was_airborne = airborne
		slow = slow + 1 if speed < _tuning.auto_reset_stuck_speed else 0
		record.longest_slow = maxi(record.longest_slow, slow)
		var crossing := detector.sample(position)
		if not crossing.is_empty():
			var gate := int(crossing.checkpoint)
			var count := definition.checkpoints.size()
			if record.last_crossing >= 0 and gate == (record.last_crossing + 1) % count:
				record.forward_crossings += 1
			elif record.last_crossing < 0:
				record.forward_crossings = 1
			record.last_crossing = gate
			var before := tracker.next_checkpoint
			if tracker.cross_checkpoint(gate, float(crossing.forward_dot)):
				record.completed = true
			if tracker.next_checkpoint != before:
				record.checkpoints += 1
		if goal == "lap" and record.completed:
			break
		if goal == "scenario" and record.forward_crossings >= 2:
			record.completed = true
			break
	record["reversals"] = driver.reversals
	record["turn_arounds"] = driver.turn_arounds
	record["road_returns"] = driver.road_returns
	record["recoveries"] = driver.recoveries
	if _trace:
		var file := FileAccess.open("user://reactive_trace_%d_%s.csv" % [definition.seed, goal], FileAccess.WRITE)
		file.store_line("tick,x,y,speed,lat,he,lat_a,he_a,dh,steer,throttle,brake,mode,off,height,air,climb_ahead")
		for line in trace_lines:
			file.store_line(line)
		file.close()
	runtime.queue_free()
	await process_frame
	return record


# ---------------------------------------------------------------------------------------------
# Recovery


## Three starts, each placed to need a different recovery, at the same point SCENARIO_LAP_FRACTION
## of the way round. Each must end with the car racing: two consecutive checkpoints crossed forward.
func _verify_recovery(seed: int) -> bool:
	var definition: TrackDefinition = _generator.generate(seed)
	var unique := definition.centerline.size() - 1
	var index := int(SCENARIO_LAP_FRACTION * unique)
	var here: Vector2 = definition.centerline[index]
	var along: Vector2 = (definition.centerline[(index + 1) % unique] - here).normalized()
	var right := SurfaceQuery.right_normal(along)

	var wrong_way := await _drive(definition, _make_driver(seed), _pose(here, -along), SCENARIO_TICK_BUDGET, "scenario")
	_report_scenario(seed, "wrong way", wrong_way)
	_check(wrong_way.turn_arounds >= 1, "seed %d wrong way: the start really faced back down the road, and the driver turned round (%d)" % [seed, wrong_way.turn_arounds])
	_check_recovered(seed, "wrong way", wrong_way)

	var beyond: float = definition.track_width * 0.5 + WorldScale.metres(OFF_ROAD_START_BEYOND_EDGE_M)
	var off_road := await _drive(definition, _make_driver(seed), _pose(here + right * beyond, right), SCENARIO_TICK_BUDGET, "scenario")
	_report_scenario(seed, "off road", off_road)
	_check(off_road.road_returns >= 1, "seed %d off road: the start really was off the road, and the driver came back to it (%d)" % [seed, off_road.road_returns])
	_check_recovered(seed, "off road", off_road)

	var rock := _pinned_against_a_rock(definition)
	_check(not rock.is_empty(), "seed %d has a rock with room behind it to pin a car against" % seed)
	if not rock.is_empty():
		var pinned := await _drive(definition, _make_driver(seed), rock.pose, SCENARIO_TICK_BUDGET, "scenario")
		_report_scenario(seed, "pinned on %s" % rock.id, pinned)
		# The scenario's own guard: the rock really is right in front of the nose on the first tick,
		# where the placement put it -- half the car's length plus the gap from the ray's origin at the
		# car's centre. Which way the driver then gets out is its business: on most seeds the stall
		# detector reverses it, and on some the obstacle rule's brake, held at a standstill, backs it
		# off first (TopDownCar turns a held brake at rest into reverse). Both are counted and printed.
		var expected_gap := CAR_HALF_LENGTH_PX + PINNED_GAP_PX
		_check(absf(pinned.first_obstacle_distance - expected_gap) < 1.0, "seed %d pinned: the car starts with the rock %.1f px along its nose, where it was placed (expected %.1f)" % [seed, pinned.first_obstacle_distance, expected_gap])
		_check_recovered(seed, "pinned", pinned)
	return true


func _check_recovered(seed: int, scenario: String, record: Dictionary) -> void:
	_check(record.completed, "seed %d %s: it gets back to racing, two checkpoints crossed forward in %.1f s" % [seed, scenario, record.ticks * TICK])
	_check(record.longest_slow < _stuck_ticks(), "seed %d %s: it is never stuck on the way (longest slow streak %d of %d ticks)" % [seed, scenario, record.longest_slow, _stuck_ticks()])
	_check(record.outside_ticks == 0 and record.max_from_centre <= _tuning.auto_reset_lost_distance, "seed %d %s: it stays in the play area and never gets lost (%.1f px from the centreline at most)" % [seed, scenario, record.max_from_centre])


func _report_scenario(seed: int, scenario: String, record: Dictionary) -> void:
	print("recovery seed=%d scenario=%s completed=%s s=%.2f first_obstacle=%.1f slowest_streak=%d contacts=%d max_from_centre=%.1f recoveries=%d (reversals=%d turn_arounds=%d road_returns=%d)" % [
		seed, scenario, record.completed, record.ticks * TICK, record.first_obstacle_distance, record.longest_slow, record.contact_ticks, record.max_from_centre,
		record.recoveries, record.reversals, record.turn_arounds, record.road_returns,
	])


## The rock nearest the road that has room behind it, and a pose on its far side with the car's nose
## PINNED_GAP_PX off the rock. "Room" is checked against every other solid's collider, so the car is
## not also wedged into a tree.
##
## The nose points into the rock at PINNED_APPROACH_ANGLE to the road's direction of travel, turned
## toward the road: the way a car that ran wide ends up, and the right way round. The first version
## pointed straight at the road, 90 degrees off its direction, and on seed 5 that read as wrong-way:
## the driver turned round and drove away from the rock, the scenario's own guard (the driver must
## have backed out) failed, and the start was shown to test nothing about being pinned.
##
## And only a rock on ground no higher than the car's low-obstacle clearance. TopDownCar chooses its
## collision mask from its ABSOLUTE height, so a grounded car on terrain above 12.5 px drops the low
## layer: to it, a rock there is neither solid nor on the ray. That is the mask limitation the terrain
## epic deferred, not something this task may change; it is why seeds 5 and 13 first showed a car
## "pinned" 2 px from a rock whose ray read nothing at all. A rock the car cannot hit cannot pin it.
func _pinned_against_a_rock(definition: TrackDefinition) -> Dictionary:
	var surface := TrackSurfaceMap.new(definition)
	var ground := TrackHeightMap.new(definition)
	var best := {}
	var best_distance := INF
	for placement: OfftrackObjectPlacement in definition.offtrack_objects:
		if not placement.solid or placement.archetype_id != &"rock":
			continue
		var archetype := _catalog.archetype_by_id(placement.archetype_id)
		var radius := archetype.collision_radius * placement.scale_factor
		var rock: Vector2 = placement.transform.origin
		var frame := surface.road_frame_at(rock, _tuning.auto_reset_lost_distance)
		if not frame.found or frame.distance >= best_distance:
			continue
		# Away from the road: the rock sits on the side `lateral_offset` points to.
		var away := SurfaceQuery.right_normal(frame.tangent) * signf(frame.lateral_offset)
		var nose := (-away * cos(PINNED_APPROACH_ANGLE) + frame.tangent * sin(PINNED_APPROACH_ANGLE)).normalized()
		var centre := rock - nose * (radius + PINNED_GAP_PX + CAR_HALF_LENGTH_PX)
		if not _clear_of_other_solids(definition, centre, placement):
			continue
		if ground.sample_at(centre).ground_height > _tuning.low_obstacle_clearance - 1.0:
			continue
		best_distance = frame.distance
		best = {"id": placement.stable_id, "pose": _pose(centre, nose)}
	return best


func _clear_of_other_solids(definition: TrackDefinition, centre: Vector2, except: OfftrackObjectPlacement) -> bool:
	for other: OfftrackObjectPlacement in definition.offtrack_objects:
		if other == except or not other.solid:
			continue
		var archetype := _catalog.archetype_by_id(other.archetype_id)
		var reach := archetype.collision_radius * other.scale_factor + CAR_HALF_LENGTH_PX + CAR_RADIUS_PX + 20.0
		if other.transform.origin.distance_to(centre) < reach:
			return false
	return true


## A car's transform with its nose (-y) along `forward`.
func _pose(position: Vector2, forward: Vector2) -> Transform2D:
	return Transform2D(atan2(forward.x, -forward.y), position)


# ---------------------------------------------------------------------------------------------
# Stopping from speed


## A rival parked on the start straight, PARKED_RIVAL_DISTANCE ahead, and the reactive car starting
## from the grid behind it. It has to reach racing speed and then stop without touching the rival.
##
## **Added after the fact, and said so.** --break-brake-distance still completed every lap: on this
## generator's circuits a corner slides into the horizon and tightens gradually, so the braking the
## corner rule asks for never exceeded ~185 px, and the mutation's constant (389 px) is longer than
## that. The lap test cannot see the difference. This check is the case the issue's own sentence is
## about -- "braking has to begin far enough out that the car can actually stop" -- and it is where a
## stopping distance that does not grow with speed runs out: from 437 px/s the car needs about 495 px
## of real braking, and a constant starts braking 389 + 75 px out.
##
## The rival is frozen, so it is a still car and not a car creeping downhill. The approach must be
## clear of ramps -- a car in the air cannot brake -- and ramps favour the start straight, so the car
## starts from rest at the first centreline vertex (in steps of PARKED_RIVAL_SCAN_STEP) whose next
## PARKED_RIVAL_DISTANCE px are ramp-free and no tighter than PARKED_RIVAL_MAX_CURVATURE: gentle
## enough to reach racing speed, bent enough that a rival on the centreline is not always on the
## nose's line. The seeds are the first PARKED_RIVAL_SEED_COUNT of TUNED_SEEDS + HELD_OUT_SEEDS.
func _verify_it_stops_for_a_parked_rival() -> bool:
	var chosen := 0
	var all_seeds: Array = TUNED_SEEDS + HELD_OUT_SEEDS
	for seed: int in all_seeds:
		if chosen >= PARKED_RIVAL_SEED_COUNT:
			break
		var definition: TrackDefinition = _generator.generate(seed)
		var approach := _clear_approach(definition)
		if approach.is_empty():
			continue
		chosen += 1
		var record := await _approach_a_parked_rival(definition, approach.start, approach.parked)
		print("parked rival seed=%d from vertex %d to %d, sharpest bend on the way %.5f /px, rival %.1f px off the starting nose line: peak=%.1f px/s braking_from=%.1f px/s touched=%d rested_at=%.1f px from it at tick %d" % [
			seed, approach.first, approach.last, approach.curvature, approach.off_line, record.peak, record.braking_from, record.touching, record.rest_gap, record.rest_tick,
		])
		_check(record.braking_from >= WorldScale.metres(RACING_SPEED_M), "seed %d: it closes on the parked rival at racing speed, braking from %.1f px/s (at least %.1f)" % [seed, record.braking_from, WorldScale.metres(RACING_SPEED_M)])
		_check(record.rest_tick >= 0, "seed %d: it comes to rest behind the parked rival (tick %d)" % [seed, record.rest_tick])
		_check(record.touching == 0, "seed %d: without touching it (%d ticks in contact)" % [seed, record.touching])
	_check(chosen == PARKED_RIVAL_SEED_COUNT, "%d seeds had a clear start straight to park a rival on (%d)" % [PARKED_RIVAL_SEED_COUNT, chosen])
	return true


## The first run of PARKED_RIVAL_DISTANCE px of centreline, scanning from the start line, that no ramp
## comes near and that bends no tighter than PARKED_RIVAL_MAX_CURVATURE. Down the centreline by arc
## length: the first version measured down the start's heading instead, and the generator's
## "straight" is anything gentler than a 2000 px radius, so it parked seed 12's rival on the grass.
func _clear_approach(definition: TrackDefinition) -> Dictionary:
	var unique := definition.centerline.size() - 1
	var first := 0
	while first < unique:
		var index := first
		var travelled := 0.0
		var sharpest := 0.0
		var clear := true
		while travelled < PARKED_RIVAL_DISTANCE and clear:
			var a: Vector2 = definition.centerline[index % unique]
			var b: Vector2 = definition.centerline[(index + 1) % unique]
			var c: Vector2 = definition.centerline[(index + 2) % unique]
			var bend := absf((b - a).angle_to(c - b)) / maxf(a.distance_to(b), 1.0)
			sharpest = maxf(sharpest, bend)
			clear = bend <= PARKED_RIVAL_MAX_CURVATURE
			for ramp: JumpRampPlacement in definition.jump_ramps:
				if a.distance_to(ramp.transform.origin) < ramp.half_length + definition.track_width:
					clear = false
			travelled += a.distance_to(b)
			index += 1
		if clear:
			var start_point: Vector2 = definition.centerline[first % unique]
			var start_forward := (definition.centerline[(first + 1) % unique] - start_point).normalized()
			var end_point: Vector2 = definition.centerline[index % unique]
			var end_forward := (definition.centerline[(index + 1) % unique] - end_point).normalized()
			return {
				"first": first, "last": index, "curvature": sharpest,
				"start": _pose(start_point, start_forward), "parked": _pose(end_point, end_forward),
				"off_line": absf((end_point - start_point).dot(SurfaceQuery.right_normal(start_forward))),
			}
		first += PARKED_RIVAL_SCAN_STEP
	return {}


func _approach_a_parked_rival(definition: TrackDefinition, start: Transform2D, parked: Transform2D) -> Dictionary:
	var runtime := TrackRuntime.new(definition)
	root.add_child(runtime)
	var surface := TrackSurfaceMap.new(definition)
	var rival := VEHICLE_SCENE.instantiate() as TopDownCar
	rival.tuning = _tuning
	rival.freeze = true
	rival.global_transform = parked
	runtime.add_child(rival)
	rival.set_surface_query(surface)
	rival.set_height_query(runtime.height_query())
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = _tuning
	car.global_transform = start
	runtime.add_child(car)
	car.set_surface_query(surface)
	car.set_height_query(runtime.height_query())
	car.set_auto_reset_enabled(false)
	await physics_frame
	var driver := _make_driver(definition.seed)
	var sensing := SensingPass.new(surface, runtime.height_query())
	var field: Array[TopDownCar] = [car, rival]
	var record := {"peak": 0.0, "braking_from": 0.0, "touching": 0, "rest_tick": -1, "rest_gap": INF}
	var braking := false
	for tick in range(PARKED_RIVAL_TICK_BUDGET):
		var controls := VehicleInputState.new()
		driver.perceive(sensing.sense(field, 0, driver.sensing_horizon()))
		controls = driver.drive(TICK)
		car.set_input_state(controls)
		if controls.brake > 0.0 and not braking:
			braking = true
			record.braking_from = car.get_speed()
		await physics_frame
		var speed := car.get_speed()
		record.peak = maxf(record.peak, speed)
		record.touching += int(car.get_colliding_bodies().has(rival))
		if braking and speed < WorldScale.metres(ReactiveDriver.STALL_SPEED_M):
			record.rest_tick = tick
			record.rest_gap = car.global_position.distance_to(rival.global_position)
			break
	runtime.queue_free()
	await process_frame
	return record


# ---------------------------------------------------------------------------------------------
# Determinism


## The control streams, not the finishing positions. Two runs of the same car from the same pose on
## the same seed, each in a freshly built world, compared value for value over the whole lap.
##
## The third run is the control: the same start moved 1 px to the side. If it did not produce a
## different stream, "identical" above would be a statement about a comparison that cannot fail.
func _verify_control_streams_repeat() -> bool:
	var definition: TrackDefinition = _generator.generate(DETERMINISM_SEED)
	var pose := definition.spawn_transform
	var first := await _drive(definition, _make_driver(DETERMINISM_SEED), pose, LAP_TICK_BUDGET, "lap")
	var second := await _drive(definition, _make_driver(DETERMINISM_SEED), pose, LAP_TICK_BUDGET, "lap")
	var nudged_pose := Transform2D(pose.get_rotation(), pose.origin + pose.x.normalized())
	var nudged := await _drive(definition, _make_driver(DETERMINISM_SEED), nudged_pose, 600, "partial")
	var first_stream: PackedFloat32Array = first.controls
	var second_stream: PackedFloat32Array = second.controls
	var nudged_stream: PackedFloat32Array = nudged.controls
	var divergence := _first_difference(first_stream, second_stream)
	var nudged_divergence := _first_difference(first_stream.slice(0, nudged_stream.size()), nudged_stream)
	print("determinism seed=%d ticks=%d and %d, first difference at value %d; nudged 1 px: first difference at value %d (tick %d)" % [
		DETERMINISM_SEED, first.ticks, second.ticks, divergence, nudged_divergence, nudged_divergence / 4,
	])
	_check(first.completed and second.completed, "both runs complete the lap (%d and %d ticks)" % [first.ticks, second.ticks])
	_check(first_stream.size() == second_stream.size() and first_stream.size() == 4 * first.ticks, "both control streams hold four values for every one of the lap's %d ticks" % first.ticks)
	_check(divergence == -1, "two cars from the same pose on the same seed produce identical control streams, tick for tick (first difference at value %d)" % divergence)
	_check(nudged_divergence >= 0, "a car started 1 px to the side produces a different stream (from tick %d), so the comparison above can see a difference" % (nudged_divergence / 4))
	return true


func _first_difference(left: PackedFloat32Array, right: PackedFloat32Array) -> int:
	for index in range(mini(left.size(), right.size())):
		if left[index] != right[index]:
			return index
	return -1 if left.size() == right.size() else mini(left.size(), right.size())


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)
	return condition


func _finish() -> void:
	print("Reactive driver: %d checks, %d failures" % [_checks, _failures.size()])
	quit(0 if _failures.is_empty() else 1)
