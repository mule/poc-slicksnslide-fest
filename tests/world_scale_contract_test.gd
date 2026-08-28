extends SceneTree

const WORLD_SCALE_PATH := "res://world/world_scale.gd"
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Each verification reports whether it ran to completion. A GDScript runtime error aborts only
	# the function it occurs in and returns false to here, so without this the script would exit 0
	# with assertions silently skipped. See tests/harness_contract_test.gd.
	_check(_verify_scale_helpers(), "the scale-helper verification ran to completion")
	_check(_verify_rescaled_tuning(), "the rescaled-tuning verification ran to completion")
	_finish()


func _verify_scale_helpers() -> bool:
	var script := load(WORLD_SCALE_PATH) as GDScript
	_check(script != null, "world scale script loads")
	if script == null:
		return false
	_check(is_equal_approx(WorldScale.PIXELS_PER_METRE, 12.5), "the world declares 12.5 px per metre")
	_check(is_equal_approx(WorldScale.metres(4.4), 55.0), "a 4.4 m car body measures 55 px")
	_check(is_equal_approx(WorldScale.to_metres(55.0), 4.4), "pixels-to-metres inverts metres-to-pixels")
	_check(is_equal_approx(WorldScale.to_kph(600.0), 172.8), "600 px/s reads as 172.8 km/h")
	_check(is_equal_approx(WorldScale.to_kph(0.0), 0.0), "a stopped car reads as zero")
	return true


func _verify_rescaled_tuning() -> bool:
	var tuning := load(TUNING_PATH) as VehicleTuning
	_check(tuning != null, "default vehicle tuning loads")
	if tuning == null:
		return false

	# Values must survive their @export_range declarations. aerodynamic_drag is
	# the dangerous one: a step of 0.001 would round 0.00043 down to zero.
	_check(is_equal_approx(tuning.engine_force, 212500.0), "engine force is rescaled to pixel space")
	_check(is_equal_approx(tuning.brake_force, 212500.0), "brake force is rescaled to pixel space")
	_check(is_equal_approx(tuning.reverse_force, 81250.0), "reverse force is rescaled to pixel space")
	_check(is_equal_approx(tuning.rolling_drag, 0.064), "rolling drag is rebalanced")
	_check(tuning.aerodynamic_drag > 0.0004 and tuning.aerodynamic_drag < 0.00046, "aerodynamic drag survives its export step (got %.6f)" % tuning.aerodynamic_drag)
	_check(is_equal_approx(tuning.max_safe_speed, 640.0), "the safety limiter is rescaled")
	_check(is_equal_approx(tuning.steering_full_speed, 225.0), "steering authority speed is rescaled")
	_check(is_equal_approx(tuning.lateral_grip_acceleration, 300.0), "lateral grip acceleration is rescaled")
	_check(is_equal_approx(tuning.low_speed_stabilization, 50.0), "low speed stabilization is rescaled")
	_check(is_equal_approx(tuning.camera_max_lead, 250.0), "camera lead stays a screen-space budget")
	_check(is_equal_approx(tuning.camera_zoom, 0.8), "camera zoom frames 1600 px of world")

	# Rates, angles, and ratios are dimensionless or per-second: they must NOT scale.
	_check(is_equal_approx(tuning.lateral_grip, 5.5), "lateral grip is a rate and does not scale")
	_check(is_equal_approx(tuning.steering_response, 3.4), "steering response is a rate and does not scale")
	_check(is_equal_approx(tuning.max_angular_speed, 2.6), "angular speed is in rad/s and does not scale")
	_check(is_equal_approx(tuning.slip_onset, 0.16), "slip onset is a ratio and does not scale")

	# The design's headline number, derived rather than asserted by hand:
	# terminal speed solves engine_accel = rolling*v + aero*v^2.
	var terminal := _solve_terminal_speed(tuning)
	_check(terminal >= 595.0 and terminal <= 605.0, "analytic terminal speed is the designed 600 px/s (got %.1f)" % terminal)
	_check(terminal < tuning.max_safe_speed, "the limiter sits above terminal speed, so it is a real safety net")
	return true


func _solve_terminal_speed(tuning: VehicleTuning) -> float:
	var engine_acceleration: float = tuning.engine_force / tuning.mass_kg
	var a: float = tuning.aerodynamic_drag
	var b: float = tuning.rolling_drag
	var c: float = -engine_acceleration
	return (-b + sqrt(b * b - 4.0 * a * c)) / (2.0 * a)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("World scale contract checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("World scale contract check failed: %s" % failure)
	quit(1)
