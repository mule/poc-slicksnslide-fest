class_name MainSession
extends Node

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")

@export var session_settings: Resource
@export var vehicle_tuning: Resource

var _controller_input: ControllerInput
var _trial: TimeTrialState
var _checkpoint_detector: CheckpointCrossingDetector
var _track_definition: TrackDefinition
var _vehicle: TopDownCar
var _current_seed := 0
var _status_hide_at_msec := 0

@onready var _diagnostics_overlay: CanvasLayer = %DiagnosticsOverlay
@onready var _seed_label: Label = %SeedLabel
@onready var _lap_label: Label = %LapLabel
@onready var _time_label: Label = %TimeLabel
@onready var _status_panel: Control = %StatusPanel
@onready var _status_label: Label = %StatusLabel
@onready var _pause_overlay: Control = %PauseOverlay
@onready var _resume_button: Button = %ResumeButton
@onready var _restart_button: Button = %RestartButton
@onready var _next_seed_button: Button = %NextSeedButton
@onready var _application_lifecycle: Node = %ApplicationLifecycle


func _ready() -> void:
	if session_settings == null:
		push_error("MainSession requires a SessionSettings resource")
		return
	if vehicle_tuning == null:
		push_error("MainSession requires a VehicleTuning resource")
		return
	_controller_input = ControllerInput.new(
		float(session_settings.get("stick_deadzone")),
		float(session_settings.get("trigger_deadzone")),
	)
	_resume_button.pressed.connect(_on_resume_pressed)
	_restart_button.pressed.connect(_on_restart_pressed)
	_next_seed_button.pressed.connect(_on_next_seed_pressed)
	_application_lifecycle.suspension_requested.connect(_on_application_suspension_requested)
	_application_lifecycle.resume_observed.connect(_on_application_resume_observed)
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	_diagnostics_overlay.visible = bool(session_settings.get("diagnostics_visible_in_debug"))
	_diagnostics_overlay.call("set_release_mode", OS.has_feature("release"))
	_pause_overlay.visible = false
	restart_with_seed(int(session_settings.get("seed")))
	_show_input_status()


func _process(_delta: float) -> void:
	_refresh_hud()
	_refresh_diagnostics()
	if _status_hide_at_msec > 0 and Time.get_ticks_msec() >= _status_hide_at_msec:
		_status_panel.visible = false
		_status_hide_at_msec = 0


func _physics_process(delta: float) -> void:
	if _trial == null or _trial.paused or not is_instance_valid(_vehicle):
		return
	_trial.advance_time(delta)
	_controller_input.poll_actions()
	if Input.is_action_just_pressed("reset_car"):
		_vehicle.request_safe_reset()
		_checkpoint_detector.reset(_vehicle.global_position)
		_show_status("Car reset to the last safe pose")
	var crossing := _checkpoint_detector.sample(_vehicle.global_position)
	if not crossing.is_empty():
		var completed := _trial.cross_checkpoint(
			int(crossing.get("checkpoint", -1)),
			float(crossing.get("forward_dot", 0.0)),
		)
		if completed:
			_show_status("Lap %d  ·  %s" % [_trial.lap_count, _format_time(_trial.last_lap_time)], 4.0)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause_back") and not _event_is_echo(event):
		set_session_paused(not _trial.paused)
		get_viewport().set_input_as_handled()
		return
	if _trial != null and _trial.paused and event.is_action_pressed("confirm") and not _event_is_echo(event):
		var focused := get_viewport().gui_get_focus_owner() as Button
		if focused != null:
			focused.pressed.emit()
			get_viewport().set_input_as_handled()


func install_track(track_scene: Node2D) -> void:
	_install_scene(%TrackMount, track_scene)


func install_vehicle(vehicle_scene: Node2D) -> void:
	_install_scene(%VehicleMount, vehicle_scene)


func restart_with_seed(seed: int) -> void:
	if get_tree().paused:
		set_session_paused(false)
	_current_seed = seed
	_track_definition = TrackGenerator.new().generate(seed)
	var runtime := TrackRuntime.new(_track_definition)
	runtime.name = "GeneratedTrack"
	install_track(runtime)

	_vehicle = VEHICLE_SCENE.instantiate() as TopDownCar
	_vehicle.name = "PlayerCar"
	_vehicle.tuning = vehicle_tuning
	_vehicle.global_transform = _track_definition.spawn_transform
	install_vehicle(_vehicle)
	_vehicle.set_surface_query(TrackSurfaceMap.new(_track_definition))
	_vehicle.set_input_state(_controller_input.apply_raw_values(0.0, 0.0, 0.0, false))
	_vehicle.set_safe_reset_pose(_track_definition.spawn_transform)

	_trial = TimeTrialState.new(_track_definition.checkpoints.size())
	_checkpoint_detector = CheckpointCrossingDetector.new(_track_definition)
	_checkpoint_detector.reset(_vehicle.global_position)
	_controller_input.suppress_until_controls_released()
	_refresh_hud()
	_show_status("Seed %d ready" % _current_seed)


func set_session_paused(is_paused: bool) -> void:
	if _trial == null or _trial.paused == is_paused:
		return
	_trial.set_paused(is_paused)
	_controller_input.suppress_until_controls_released()
	_pause_overlay.visible = is_paused
	get_tree().paused = is_paused
	if is_paused:
		_resume_button.grab_focus()
	else:
		_resume_button.release_focus()


func get_session_snapshot() -> Dictionary:
	if _trial == null:
		return {}
	return {
		"seed": _current_seed,
		"lap_count": _trial.lap_count,
		"next_checkpoint": _trial.next_checkpoint,
		"current_lap_time": _trial.current_lap_time,
		"session_time": _trial.session_time,
		"last_lap_time": _trial.last_lap_time,
		"best_lap_time": _trial.best_lap_time,
		"paused": _trial.paused,
		"geometry_fingerprint": _track_definition.geometry_fingerprint,
	}


func _install_scene(mount: Node2D, scene_root: Node2D) -> void:
	for child in mount.get_children():
		child.free()
	mount.add_child(scene_root)


func _refresh_hud() -> void:
	if _trial == null:
		return
	_seed_label.text = "SEED  %d" % _current_seed
	_lap_label.text = "LAP  %d" % (_trial.lap_count + 1)
	_time_label.text = "TIME  %s" % _format_time(_trial.current_lap_time)


func _refresh_diagnostics() -> void:
	if not is_instance_valid(_vehicle):
		return
	var metrics := _vehicle.get_diagnostics()
	_diagnostics_overlay.call(
		"set_metrics",
		_current_seed,
		float(metrics.get("speed_kph", 0.0)),
		str(metrics.get("surface", "unknown")),
		float(metrics.get("slip", 0.0)),
		float(metrics.get("steering", 0.0)),
		float(metrics.get("throttle", 0.0)),
		float(metrics.get("brake", 0.0)),
		float(metrics.get("handbrake", 0.0)),
	)


func _show_input_status() -> void:
	var connected := Input.get_connected_joypads()
	if connected.is_empty():
		_show_status("Keyboard controls active  ·  controller hot-plug ready")
		return
	var device_id: int = connected[0]
	var device_name := Input.get_joy_name(device_id)
	_show_status("Controller connected%s" % ("  ·  %s" % device_name if not device_name.is_empty() else ""))


func _show_status(message: String, seconds := 3.0) -> void:
	_status_label.text = message
	_status_panel.visible = true
	_status_hide_at_msec = Time.get_ticks_msec() + roundi(seconds * 1000.0)


func _on_joy_connection_changed(device: int, connected: bool) -> void:
	_controller_input.suppress_until_controls_released()
	if connected:
		var device_name := Input.get_joy_name(device)
		_show_status("Controller connected%s" % ("  ·  %s" % device_name if not device_name.is_empty() else ""), 4.0)
	else:
		_show_status("Controller disconnected  ·  keyboard remains active", 4.0)


func _on_application_suspension_requested(reason: String) -> void:
	set_session_paused(true)
	_show_status("%s  ·  controls neutralized" % reason.capitalize(), 4.0)


func _on_application_resume_observed() -> void:
	if _trial != null and _trial.paused:
		_show_status("Application resumed  ·  confirm Resume when ready", 4.0)


func _on_resume_pressed() -> void:
	set_session_paused(false)


func _on_restart_pressed() -> void:
	restart_with_seed(_current_seed)


func _on_next_seed_pressed() -> void:
	restart_with_seed(_current_seed + 1)


func _format_time(seconds: float) -> String:
	var total_msec := maxi(roundi(seconds * 1000.0), 0)
	var minutes := total_msec / 60000
	var remaining_seconds := (total_msec / 1000) % 60
	var milliseconds := total_msec % 1000
	return "%02d:%02d.%03d" % [minutes, remaining_seconds, milliseconds]


func _event_is_echo(event: InputEvent) -> bool:
	return event is InputEventKey and event.echo
