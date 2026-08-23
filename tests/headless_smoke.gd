extends SceneTree

var _failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene_path := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	_check(main_scene_path == "res://session/main.tscn", "main scene is configured")

	var main_scene := load(main_scene_path) as PackedScene if not main_scene_path.is_empty() else null
	_check(main_scene != null, "main scene resource loads")
	if main_scene != null:
		_verify_main_scene(main_scene)

	_verify_contracts()
	_verify_default_resources()

	if _failures.is_empty():
		print("Foundation smoke check passed")
		quit(0)
		return

	for failure in _failures:
		push_error("Foundation smoke check failed: %s" % failure)
	quit(1)


func _verify_main_scene(main_scene: PackedScene) -> void:
	var root := main_scene.instantiate()
	_check(root != null, "main scene instantiates")
	if root == null:
		return

	_check(root.has_method("install_track"), "session exposes the track mount contract")
	_check(root.has_method("install_vehicle"), "session exposes the vehicle mount contract")
	var track_mount := root.get_node_or_null("%TrackMount")
	var vehicle_mount := root.get_node_or_null("%VehicleMount")
	_check(track_mount != null, "main scene contains a unique track mount")
	_check(vehicle_mount != null, "main scene contains a unique vehicle mount")

	if root.has_method("install_track") and track_mount != null:
		var test_track := Node2D.new()
		root.call("install_track", test_track)
		_check(test_track.get_parent() == track_mount, "track scenes install without internal node paths")

	if root.has_method("install_vehicle") and vehicle_mount != null:
		var test_vehicle := Node2D.new()
		root.call("install_vehicle", test_vehicle)
		_check(test_vehicle.get_parent() == vehicle_mount, "vehicle scenes install without internal node paths")

	var overlay := root.get_node_or_null("%DiagnosticsOverlay")
	_check(overlay != null, "development diagnostics overlay exists")
	if overlay != null:
		_check(overlay.has_method("set_metrics"), "diagnostics accept session metrics")
		_check(overlay.has_method("set_release_mode"), "diagnostics expose build visibility behavior")
		_check(overlay.has_method("toggle_visibility"), "diagnostics expose a development toggle")
		overlay.call("set_release_mode", false)
		overlay.visible = true
		if overlay.has_method("toggle_visibility"):
			overlay.call("toggle_visibility")
			_check(not overlay.visible, "development diagnostics can be toggled")
		overlay.call("set_release_mode", true)
		_check(not overlay.visible, "diagnostics are hidden in release mode")
		if overlay.has_method("toggle_visibility"):
			overlay.call("toggle_visibility")
			_check(not overlay.visible, "release diagnostics cannot be toggled back on")

	root.free()


func _verify_contracts() -> void:
	var track_script := load("res://track/track_definition.gd") as GDScript
	_check(track_script != null, "track definition contract loads")
	if track_script != null:
		var definition = track_script.new()
		definition.seed = 42
		definition.centerline = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT])
		_check(definition.seed == 42 and definition.centerline.size() == 2, "track definition stores generated data")

	var surface_script := load("res://track/surface_query.gd") as GDScript
	_check(surface_script != null, "surface query contract loads")

	var input_script := load("res://input/vehicle_input_state.gd") as GDScript
	_check(input_script != null, "normalized vehicle input contract loads")
	if input_script != null:
		var input_state = input_script.new()
		input_state.set_controls(2.0, -1.0, 0.4, 3.0)
		_check(input_state.steer == 1.0, "steering is normalized to minus one through one")
		_check(input_state.throttle == 0.0, "throttle is normalized to zero through one")
		_check(input_state.brake == 0.4 and input_state.handbrake == 1.0, "brake inputs preserve analog magnitude within bounds")


func _verify_default_resources() -> void:
	var session_settings := load("res://data/default_session_settings.tres")
	_check(session_settings != null, "default session settings load")
	if session_settings != null:
		_check(session_settings.get("seed") == 0, "default seed has an explicit resource home")

	var vehicle_tuning := load("res://data/default_vehicle_tuning.tres")
	_check(vehicle_tuning != null, "default vehicle tuning loads")
	if vehicle_tuning != null:
		_check(float(vehicle_tuning.get("mass_kg")) > 0.0, "vehicle physics tuning has an explicit resource home")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
