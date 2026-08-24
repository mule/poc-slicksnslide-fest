extends SceneTree

const WORLD_SCALE_PATH := "res://world/world_scale.gd"

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_verify_scale_helpers()
	_finish()


func _verify_scale_helpers() -> void:
	var script := load(WORLD_SCALE_PATH) as GDScript
	_check(script != null, "world scale script loads")
	if script == null:
		return
	_check(is_equal_approx(WorldScale.PIXELS_PER_METRE, 12.5), "the world declares 12.5 px per metre")
	_check(is_equal_approx(WorldScale.metres(4.4), 55.0), "a 4.4 m car body measures 55 px")
	_check(is_equal_approx(WorldScale.to_metres(55.0), 4.4), "pixels-to-metres inverts metres-to-pixels")
	_check(is_equal_approx(WorldScale.to_kph(600.0), 172.8), "600 px/s reads as 172.8 km/h")
	_check(is_equal_approx(WorldScale.to_kph(0.0), 0.0), "a stopped car reads as zero")


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
