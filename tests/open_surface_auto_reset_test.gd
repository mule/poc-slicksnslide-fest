extends SceneTree

## Automatic reset fires when the car is stuck off-track or has strayed far from the racing line,
## and stays silent otherwise. Uses a deterministic surface provider rather than a generated track
## so each condition can be driven in isolation.

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const GENERATOR_PATH := "res://track/track_generator.gd"
const START := Vector2(4000.0, 6500.0)

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _verify_stuck_off_track_triggers_reset()
	await _verify_straying_far_triggers_reset()
	await _verify_disabled_never_triggers()
	await _verify_moving_off_track_near_the_line_does_not_trigger()
	_verify_lost_distance_stays_inside_the_play_area()
	_finish()


func _verify_stuck_off_track_triggers_reset() -> void:
	var context := _make_car(true)
	var car: TopDownCar = context.car
	var provider = context.provider
	provider.force_off_track = true
	provider.distance_from_line = 10.0
	var tuning: VehicleTuning = car.tuning
	var ticks := int((tuning.auto_reset_stuck_seconds + 0.5) * 60.0)
	for tick in range(ticks):
		await physics_frame
	_check(car.consume_auto_reset_notice(), "sitting still off-track triggers an automatic reset")
	_check(car.global_position.distance_to(START) < 1.0, "the automatic reset returns the car to its safe pose")
	context.world.queue_free()
	await process_frame


func _verify_straying_far_triggers_reset() -> void:
	var context := _make_car(true)
	var car: TopDownCar = context.car
	var provider = context.provider
	provider.force_off_track = true
	var tuning: VehicleTuning = car.tuning
	provider.distance_from_line = tuning.auto_reset_lost_distance + 100.0
	for tick in range(5):
		await physics_frame
	_check(car.consume_auto_reset_notice(), "straying beyond the lost distance triggers an automatic reset")
	context.world.queue_free()
	await process_frame


func _verify_disabled_never_triggers() -> void:
	var context := _make_car(false)
	var car: TopDownCar = context.car
	var provider = context.provider
	provider.force_off_track = true
	var tuning: VehicleTuning = car.tuning
	provider.distance_from_line = tuning.auto_reset_lost_distance + 100.0
	var ticks := int((tuning.auto_reset_stuck_seconds + 1.0) * 60.0)
	for tick in range(ticks):
		await physics_frame
	_check(not car.consume_auto_reset_notice(), "auto reset stays silent when the setting is disabled")
	context.world.queue_free()
	await process_frame


func _verify_moving_off_track_near_the_line_does_not_trigger() -> void:
	var context := _make_car(true)
	var car: TopDownCar = context.car
	var provider = context.provider
	provider.force_off_track = true
	provider.distance_from_line = 50.0
	var tuning: VehicleTuning = car.tuning
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var ticks := int((tuning.auto_reset_stuck_seconds + 1.0) * 60.0)
	for tick in range(ticks):
		await physics_frame
	_check(
		not car.consume_auto_reset_notice(),
		"a deliberate off-track run at speed near the line is not interrupted"
	)
	context.world.queue_free()
	await process_frame


func _verify_lost_distance_stays_inside_the_play_area() -> void:
	var tuning = load(TUNING_PATH) as VehicleTuning
	var margin: float = (load(GENERATOR_PATH) as GDScript).PLAY_AREA_MARGIN
	_check(
		tuning.auto_reset_lost_distance < margin,
		"the lost distance (%.1f) resolves before the containment boundary (%.1f)" % [tuning.auto_reset_lost_distance, margin]
	)


func _make_car(auto_reset_enabled: bool) -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = load(TUNING_PATH) as VehicleTuning
	car.global_transform = Transform2D(0.0, START)
	var provider := Issue4TestSurfaceProvider.new()
	car.set_surface_query(provider)
	world.add_child(car)
	car.set_safe_reset_pose(Transform2D(0.0, START))
	car.set_auto_reset_enabled(auto_reset_enabled)
	return {"world": world, "car": car, "provider": provider}


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	print("auto_reset checks=%d" % _checks)
	if _failures.is_empty():
		print("Auto reset checks passed")
		quit(0)
		return
	for failure in _failures:
		push_error("Auto reset check failed: %s" % failure)
	quit(1)
