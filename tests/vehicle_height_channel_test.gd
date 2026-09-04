extends SceneTree

## The car crests a scripted hump, flies the analytic arc, lands with the documented cost, and
## keeps its ground-only rules (safe pose, auto reset) out of the air. Mutations:
##   -- --break-gravity   zeroes gravity, so the car never lands and the flight loop times out
##   -- --break-landing   zeroes the speed loss and recovery grip effect, so landing costs nothing

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const START := Vector2(-2200.0, 0.0)
const CREST_X := 0.0
const HALF_LENGTH := 150.0
const CREST_HEIGHT := 18.0
const HEADING_PLUS_X := PI * 0.5
const MAX_FLIGHT_TICKS := 300
const TICK := 1.0 / 60.0

var _failures: Array[String] = []
var _checks := 0
var _break_gravity := false
var _break_landing := false


func _initialize() -> void:
	_break_gravity = OS.get_cmdline_user_args().has("--break-gravity")
	_break_landing = OS.get_cmdline_user_args().has("--break-landing")
	call_deferred("_run")


func _run() -> void:
	_check(await _verify_flight_matches_the_analytic_arc(), "the analytic arc verification ran to completion")
	_check(await _verify_landing_recovery_reduces_grip(), "the landing recovery verification ran to completion")
	_check(await _verify_slow_car_stays_on_the_downslope(), "the downslope verification ran to completion")
	_check(await _verify_plateau_edge_launches(), "the plateau edge verification ran to completion")
	_check(await _verify_a_wall_does_not_lift_the_car(), "the wall verification ran to completion")
	_check(await _verify_ground_only_rules(), "the ground-only rules verification ran to completion")
	_check(await _verify_reset_zeroes_height(), "the reset verification ran to completion")
	_finish()


## One flight, many assertions: lift-off vertical speed, flight time, landing distance, speed loss,
## throttle and steering having no effect in the air.
func _verify_flight_matches_the_analytic_arc() -> bool:
	var context := _make_car()
	var car: TopDownCar = context.car
	var tuning: VehicleTuning = car.tuning
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	# Full steer is applied by _fly on the lift-off tick, not before: steering on the approach
	# would turn the car away from the ramp.
	var flight := await _fly(car, controls)
	_check(flight.launched, "the car leaves the ground at the crest")
	if not flight.launched:
		context.world.queue_free()
		return true
	var slope := CREST_HEIGHT / HALF_LENGTH
	var expected_vz: float = float(flight.launch_speed) * slope
	_check(absf(float(flight.launch_vz) - expected_vz) <= expected_vz * 0.05, "lift-off vertical speed (%.1f) is within 5%% of speed times slope (%.1f)" % [flight.launch_vz, expected_vz])
	_check(float(flight.launch_x) >= CREST_X - HALF_LENGTH and float(flight.launch_x) <= CREST_X + 30.0, "lift-off happens on the rising face or at the crest (x=%.1f)" % flight.launch_x)
	_check(flight.landed, "the car lands within %d ticks" % MAX_FLIGHT_TICKS)
	if not flight.landed:
		context.world.queue_free()
		return true
	var g: float = tuning.gravity
	var h0: float = flight.launch_height
	var vz: float = flight.launch_vz
	var expected_time := (vz + sqrt(vz * vz + 2.0 * g * h0)) / g
	var measured_time := float(flight.air_ticks) * TICK
	_check(float(flight.landing_x) > CREST_X + HALF_LENGTH, "the landing is on flat ground past the ramp, so the flat-ground formula applies")
	_check(absf(measured_time - expected_time) <= 2.0 * TICK, "flight time (%.3f s) matches the analytic %.3f s within two ticks" % [measured_time, expected_time])
	var k: float = tuning.aerodynamic_drag
	var v0: float = flight.launch_speed
	var expected_distance := log(1.0 + k * v0 * expected_time) / k
	var measured_distance: float = float(flight.landing_x) - float(flight.launch_x)
	_check(absf(measured_distance - expected_distance) <= expected_distance * 0.05, "landing distance (%.1f) matches the drag integral (%.1f) within 5%%" % [measured_distance, expected_distance])
	var impact_mps := WorldScale.to_metres(maxf(-float(flight.last_vz) + g * TICK, 0.0))
	var expected_ratio := clampf(1.0 - tuning.landing_speed_loss * impact_mps, 0.3, 1.0)
	var measured_ratio: float = float(flight.speed_after) / float(flight.speed_before)
	_check(absf(measured_ratio - expected_ratio) <= 0.03, "landing keeps %.3f of speed, expected %.3f" % [measured_ratio, expected_ratio])
	_check(expected_ratio < 0.97, "the landing is hard enough that the loss assertion is live")
	_check(flight.speed_never_rose, "throttle adds no speed in the air")
	_check(absf(float(flight.rotation_change)) < 0.01, "full steer does not rotate the car in the air at zero authority")
	_check(flight.recovery_after_landing > 0.0, "landing opens a recovery window")
	_check(car.consume_air_time_notice() > tuning.air_time_notice_seconds, "a long flight leaves an air time notice")
	_check(car.consume_air_time_notice() == 0.0, "the notice is consumed once")
	context.world.queue_free()
	await process_frame
	return true


## Two identical landings, one with the recovery multiplier and one without: the recovering car
## must slide more under the same steering input.
func _verify_landing_recovery_reduces_grip() -> bool:
	var recovering := await _peak_slip_after_landing(true)
	var control := await _peak_slip_after_landing(false)
	print("peak_slip recovering=%.3f control=%.3f" % [recovering, control])
	_check(recovering > control + 0.02, "reduced grip after landing produces more slip (%.3f) than full grip (%.3f)" % [recovering, control])
	return true


func _peak_slip_after_landing(apply_recovery: bool) -> float:
	var context := _make_car()
	var car: TopDownCar = context.car
	if not apply_recovery:
		var tuning := (car.tuning as VehicleTuning).duplicate() as VehicleTuning
		tuning.landing_recovery_grip_multiplier = 1.0
		car.tuning = tuning
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var flight := await _fly(car, controls)
	var peak := 0.0
	if flight.landed:
		controls.steer = 1.0
		controls.throttle = 0.0
		car.set_input_state(controls)
		var window := int(ceil((car.tuning as VehicleTuning).landing_recovery_seconds / TICK))
		for tick in range(window):
			await physics_frame
			peak = maxf(peak, car.get_slip_ratio())
	context.world.queue_free()
	await process_frame
	return peak


func _verify_slow_car_stays_on_the_downslope() -> bool:
	var context := _make_car()
	var car: TopDownCar = context.car
	car.global_transform = Transform2D(HEADING_PLUS_X, Vector2(CREST_X + 10.0, 0.0))
	car.linear_velocity = Vector2(30.0, 0.0)
	# Re-seat the car after the teleport: it has been moved onto the face, not driven onto it.
	car.set_height_query(context.height)
	var left_ground := false
	for tick in range(60):
		await physics_frame
		if car.is_airborne():
			left_ground = true
	_check(not left_ground, "a slow car rolling down the far face stays on the ground")
	_check(car.get_height() >= 0.0 and car.get_height() <= CREST_HEIGHT, "the grounded car's height follows the face")
	context.world.queue_free()
	await process_frame
	return true


## The other way to leave the ground. At a drop-off the height falls with no change of gradient, so
## the rate test is blind to it and only the ballistic-clearance test can see it.
func _verify_plateau_edge_launches() -> bool:
	var context := _make_car()
	var car: TopDownCar = context.car
	var height: HeightChannelTestHeightProvider = context.height
	height.mode = HeightChannelTestHeightProvider.Mode.PLATEAU
	height.plateau_height = CREST_HEIGHT
	height.plateau_end_x = CREST_X
	car.set_height_query(height)
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	await physics_frame
	_check(absf(car.get_height() - CREST_HEIGHT) < 0.5, "the car rides at the plateau height (%.2f) before the edge" % car.get_height())
	var launch_x := INF
	var landing_x := INF
	for tick in range(MAX_FLIGHT_TICKS + 200):
		await physics_frame
		if car.is_airborne():
			if launch_x == INF:
				launch_x = car.global_position.x
		elif launch_x != INF:
			landing_x = car.global_position.x
			break
	_check(launch_x != INF, "the car leaves the ground at the plateau edge")
	_check(launch_x >= CREST_X - 20.0 and launch_x <= CREST_X + 20.0, "lift-off happens at the edge (x=%.1f)" % launch_x)
	_check(landing_x != INF, "the car lands past the edge (x=%.1f)" % landing_x)
	_check(car.consume_landing_event(), "the drop-off landing fires a landing event")
	context.world.queue_free()
	await process_frame
	return true


## A generated height map gives every ramp a vertical wall at its lateral boundary, and the surface
## is open enough to drive into one. The ground behind the wall reads as falling away, but it is
## above the car, so the car must neither lift off nor be carried up onto it.
func _verify_a_wall_does_not_lift_the_car() -> bool:
	var context := _make_car()
	var car: TopDownCar = context.car
	var height: HeightChannelTestHeightProvider = context.height
	height.mode = HeightChannelTestHeightProvider.Mode.WALL
	car.set_height_query(height)
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var launched := false
	var peak_height := 0.0
	var passed_the_wall := false
	for tick in range(MAX_FLIGHT_TICKS + 200):
		await physics_frame
		launched = launched or car.is_airborne()
		peak_height = maxf(peak_height, car.get_height())
		if car.global_position.x > CREST_X + 40.0:
			passed_the_wall = true
			break
	_check(passed_the_wall, "the wall scenario reaches and crosses the wall")
	_check(not launched, "driving into a vertical wall does not lift the car off the ground")
	_check(peak_height < 1.0, "the car is not carried up onto the wall (peak height %.2f of a %.1f wall)" % [peak_height, CREST_HEIGHT])
	_check(not car.consume_landing_event(), "a wall fires no landing event")
	_check(car.get_landing_recovery_remaining() == 0.0, "a wall opens no grip recovery window")
	context.world.queue_free()
	await process_frame
	return true


func _verify_ground_only_rules() -> bool:
	var context := _make_car()
	var car: TopDownCar = context.car
	var provider: Issue4TestSurfaceProvider = context.surface
	var tuning: VehicleTuning = car.tuning
	car.set_auto_reset_enabled(true)
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var noticed_in_air := false
	var pose_moved_in_air_or_on_ramp := false
	var launched := false
	for tick in range(MAX_FLIGHT_TICKS + 200):
		await physics_frame
		if car.is_airborne() and not launched:
			launched = true
			# Become "lost" exactly while airborne. Nothing may fire until the wheels are down.
			provider.force_off_track = true
			provider.distance_from_line = tuning.auto_reset_lost_distance + 100.0
		if car.is_airborne():
			if car.consume_auto_reset_notice():
				noticed_in_air = true
			var pose_x := car.get_safe_reset_pose().origin.x
			if pose_x > CREST_X - HALF_LENGTH:
				pose_moved_in_air_or_on_ramp = true
		elif launched:
			break
	_check(launched, "the ground-only scenario reaches the air")
	_check(not noticed_in_air, "auto reset does not fire while airborne")
	_check(not pose_moved_in_air_or_on_ramp, "no safe pose is captured in the air or on a ramp face")
	for tick in range(10):
		await physics_frame
	_check(car.consume_auto_reset_notice(), "the same lost condition fires once the car has landed")
	context.world.queue_free()
	await process_frame
	return true


func _verify_reset_zeroes_height() -> bool:
	var context := _make_car()
	var car: TopDownCar = context.car
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	for tick in range(MAX_FLIGHT_TICKS + 200):
		await physics_frame
		if car.is_airborne():
			break
	_check(car.is_airborne(), "the reset scenario reaches the air")
	# Read the pose before resetting: the approach from START is long enough for the checkpoint to
	# have moved several times, so the destination is the latest safe pose, not START.
	var expected_pose := car.get_safe_reset_pose().origin
	_check(car.global_position.distance_to(expected_pose) > 1.0, "the car is away from the pose it will reset to, so the destination assertion is live")
	car.request_safe_reset()
	await physics_frame
	await physics_frame
	_check(not car.is_airborne(), "a reset lands the car")
	_check(car.get_height() == 0.0 and car.get_vertical_velocity() == 0.0, "a reset zeroes height and vertical speed")
	_check(car.global_position.distance_to(expected_pose) < 1.0, "a reset returns to the safe pose")
	context.world.queue_free()
	await process_frame
	return true


## Drives from START until the car has launched and landed (or the tick budget runs out), and
## records everything the assertions need. Full steer is held from lift-off to landing so the
## steering-authority assertion is exercised without disturbing the approach.
func _fly(car: TopDownCar, controls: VehicleInputState) -> Dictionary:
	var flight := {
		"launched": false, "landed": false, "launch_speed": 0.0, "launch_vz": 0.0, "launch_x": 0.0,
		"launch_height": 0.0, "launch_rotation": 0.0, "air_ticks": 0, "landing_x": 0.0,
		"speed_before": 0.0, "speed_after": 0.0, "last_vz": 0.0, "speed_never_rose": true,
		"rotation_change": 0.0, "recovery_after_landing": 0.0,
	}
	var previous_speed := 0.0
	for tick in range(MAX_FLIGHT_TICKS + 600):
		await physics_frame
		var airborne := car.is_airborne()
		if airborne and not flight.launched:
			flight.launched = true
			flight.launch_speed = car.get_speed()
			flight.launch_vz = car.get_vertical_velocity()
			flight.launch_x = car.global_position.x
			flight.launch_height = car.get_height()
			flight.launch_rotation = car.rotation
			previous_speed = car.get_speed()
			controls.steer = 1.0
			car.set_input_state(controls)
		if airborne:
			flight.air_ticks += 1
			if car.get_speed() > previous_speed + 0.01:
				flight.speed_never_rose = false
			previous_speed = car.get_speed()
			flight.speed_before = car.get_speed()
			flight.last_vz = car.get_vertical_velocity()
			if flight.air_ticks > MAX_FLIGHT_TICKS:
				break
		elif flight.launched:
			flight.landed = true
			flight.landing_x = car.global_position.x
			flight.speed_after = car.get_speed()
			flight.rotation_change = car.rotation - flight.launch_rotation
			flight.recovery_after_landing = car.get_landing_recovery_remaining()
			controls.steer = 0.0
			car.set_input_state(controls)
			break
	return flight


func _make_car() -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	var tuning := (load(TUNING_PATH) as VehicleTuning).duplicate() as VehicleTuning
	if _break_gravity:
		tuning.gravity = 0.0
	if _break_landing:
		tuning.landing_speed_loss = 0.0
		tuning.landing_recovery_grip_multiplier = 1.0
	car.tuning = tuning
	car.global_transform = Transform2D(HEADING_PLUS_X, START)
	var surface := Issue4TestSurfaceProvider.new()
	car.set_surface_query(surface)
	var height := HeightChannelTestHeightProvider.new()
	height.mode = HeightChannelTestHeightProvider.Mode.HUMP
	height.crest_x = CREST_X
	height.half_length = HALF_LENGTH
	height.crest_height = CREST_HEIGHT
	car.set_height_query(height)
	world.add_child(car)
	car.set_safe_reset_pose(Transform2D(HEADING_PLUS_X, START))
	return {"world": world, "car": car, "surface": surface, "height": height}


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Vehicle height channel checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Vehicle height channel check failed: %s" % failure)
	quit(1)
