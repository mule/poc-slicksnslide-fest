extends SceneTree

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_verify_diagnostics_action()

	var main_scene := load("res://session/main.tscn") as PackedScene
	_check(main_scene != null, "main session scene loads for Android checks")
	if main_scene == null:
		_finish()
		return
	var session := main_scene.instantiate()
	root.add_child(session)
	await process_frame
	await physics_frame
	_check(session.get_script() != null and session.has_method("get_session_snapshot"), "main session implementation is active for Android checks")
	if session.get_script() == null or not session.has_method("get_session_snapshot"):
		session.queue_free()
		await process_frame
		_finish()
		return

	_verify_mobile_diagnostics(session)
	_verify_application_lifecycle(session)

	paused = false
	session.queue_free()
	await process_frame
	_finish()


func _verify_diagnostics_action() -> void:
	_check(InputMap.has_action("toggle_diagnostics"), "InputMap exposes an on-device diagnostics toggle")
	if not InputMap.has_action("toggle_diagnostics"):
		return
	_check(_has_key("toggle_diagnostics", KEY_F3), "diagnostics retain the F3 development shortcut")
	_check(_has_joy_button("toggle_diagnostics", JOY_BUTTON_BACK), "diagnostics use the controller Back/View button on Android")


func _verify_mobile_diagnostics(session: Node) -> void:
	var overlay := session.get_node_or_null("%DiagnosticsOverlay") as CanvasLayer
	_check(overlay != null, "Android session includes the in-viewport diagnostics overlay")
	if overlay == null:
		return
	var metrics_method := _find_method(overlay, "set_metrics")
	var supports_mobile_metrics := int(metrics_method.get("args", []).size()) >= 8
	_check(supports_mobile_metrics, "diagnostics accept seed, vehicle, and normalized input telemetry")
	if not supports_mobile_metrics:
		return
	overlay.callv("set_metrics", [23, 61.5, "dirt", 0.35, -0.25, 0.75, 0.10, 1.0])
	overlay.call("_process", 1.0 / 60.0)
	var label := session.get_node_or_null("%MetricsLabel") as Label
	_check(label != null, "diagnostics expose player-visible telemetry text")
	if label == null:
		return
	var text := label.text.to_lower()
	_check(text.contains("memory:") and text.contains("peak:"), "diagnostics report current and peak memory for trend recording")
	_check(text.contains("steer:") and text.contains("throttle:") and text.contains("brake:") and text.contains("handbrake:"), "diagnostics report normalized controller input state")
	_check(text.contains("seed: 23") and text.contains("61.5 km/h"), "diagnostics retain seed and driving telemetry")


func _verify_application_lifecycle(session: Node) -> void:
	var lifecycle := session.get_node_or_null("%ApplicationLifecycle")
	_check(lifecycle != null, "session routes application lifecycle through the platform boundary")
	if lifecycle == null:
		return

	# Release the initial restart suppression, then prove the real car receives input.
	session.call("_physics_process", 1.0 / 60.0)
	Input.action_press("throttle", 1.0)
	session.call("_physics_process", 1.0 / 60.0)
	var car := session.get_node_or_null("%VehicleMount").get_child(0) as TopDownCar
	var before_pause := car.get_diagnostics() if car != null else {}
	_check(float(before_pause.get("throttle", 0.0)) > 0.9, "real vehicle receives throttle before application suspension")

	lifecycle.notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var paused_snapshot: Dictionary = session.call("get_session_snapshot")
	var after_pause := car.get_diagnostics() if car != null else {}
	_check(paused and bool(paused_snapshot.get("paused", false)), "Android application pause suspends the time-trial and physics tree")
	_check(is_zero_approx(float(after_pause.get("throttle", -1.0))), "application pause immediately neutralizes held vehicle input")

	lifecycle.notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	var resumed_snapshot: Dictionary = session.call("get_session_snapshot")
	_check(paused and bool(resumed_snapshot.get("paused", false)), "Android resume stays safely paused until explicit controller confirmation")

	Input.action_release("throttle")
	session.call("set_session_paused", false)
	lifecycle.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(paused, "application focus loss also enters the safe paused state")
	Input.action_release("throttle")


func _find_method(instance: Object, method_name: StringName) -> Dictionary:
	for method in instance.get_method_list():
		if method.get("name", &"") == method_name:
			return method
	return {}


func _has_key(action: StringName, key: Key) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventKey and (event.keycode == key or event.physical_keycode == key):
			return true
	return false


func _has_joy_button(action: StringName, button: JoyButton) -> bool:
	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadButton and event.button_index == button:
			return true
	return false


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Issue #6 Android checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Issue #6 Android check failed: %s" % failure)
	quit(1)
