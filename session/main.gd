class_name MainSession
extends Node

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")

## Grid geometry, in metres through the scale contract. Rows run backwards from the start line
## along the centreline; the two columns sit at a quarter of the track's width either side of it,
## so every slot stays on the road by construction however narrow the generated track is.
const GRID_ROW_SPACING_M := 8.8
const GRID_COLUMN_FRACTION := 0.25
## A rival's spawn rotation is a multiple of 1 / SPAWN_ANGLE_LATTICE radians (2^-16, exact in float32
## across the whole circle) that a physics step leaves unchanged, and never more than
## SPAWN_ANGLE_MAX_STEPS lattice steps from the grid's own rotation. The bound is proved, not sampled:
## tests/field_race_test.gd checks every one of the lattice's 411,775 angles in the engine. See
## _physics_fixed_pose.
const SPAWN_ANGLE_LATTICE := 65536.0
const SPAWN_ANGLE_MAX_STEPS := 6
const SPAWN_REFUSED_STATUS := "Race not started: no rival spawn pose within the proved bound"

@export var session_settings: Resource
@export var vehicle_tuning: Resource

var _controller_input: ControllerInput
var _trial: TimeTrialState
var _checkpoint_detector: CheckpointCrossingDetector
var _track_definition: TrackDefinition
var _vehicle: TopDownCar
var _track_runtime: TrackRuntime
var _current_seed := 0
var _opponent_count := 0
var _status_hide_at_msec := 0
## The field beside the player's car, in car-index order. Each entry: index (1..opponent_count),
## car, driver, detector, progress. The player's own progress stays in _trial, whose TimeTrialState
## owns a LapProgressTracker exactly like each rival's entry does.
var _rivals: Array[Dictionary] = []
var _field_surface_map: TrackSurfaceMap
## The field's one sensing pass (#57): the session owns the field, so it senses for every driver.
var _sensing: SensingPass
## Why the last restart refused to build its race, or empty when it built one. See _refuse_the_race.
var _spawn_failure := ""

@onready var _diagnostics_overlay: CanvasLayer = %DiagnosticsOverlay
@onready var _seed_label: Label = %SeedLabel
@onready var _lap_label: Label = %LapLabel
@onready var _position_label: Label = %PosLabel
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
	# The rivals drive before the player's reset handling, so a player's reset -- which returns early
	# below -- never costs the field a tick.
	_drive_field(delta)
	var reset_this_tick := false
	if Input.is_action_just_pressed("reset_car"):
		_vehicle.request_safe_reset()
		_checkpoint_detector.reset(_vehicle.get_safe_reset_pose().origin)
		_show_status("Car reset to the last safe pose")
		reset_this_tick = true
	if _vehicle.consume_auto_reset_notice():
		_checkpoint_detector.reset(_vehicle.get_safe_reset_pose().origin)
		_show_status("Returned to the track")
		reset_this_tick = true
	# Polled ahead of the reset early-return below: the notice is an unbounded latch that only a
	# consumer clears, so a tick that returns early without draining it would let a stale flight
	# raise its status line at an arbitrary later moment. Draining and reporting are separated for
	# that reason: a reset clears the car's air time but not this latch, so a flight that ends in
	# an off-track reset would otherwise overwrite "Returned to the track" with its own air time in
	# the same tick. The latch still drains on every simulated tick; only the message is suppressed.
	var air_time := _vehicle.consume_air_time_notice()
	if air_time > 0.0 and not reset_this_tick:
		_show_status("Air time  ·  %.2f s" % air_time)
	if reset_this_tick:
		# A reset only sets a flag the vehicle honours on the *next* physics tick, so
		# `_vehicle.global_position` still holds the pre-teleport pose right now. Sampling against
		# it here would immediately overwrite the detector's just-seeded previous position with
		# that stale value, recreating the exact phantom-crossing bug the reset above closes.
		# Resume sampling next tick, once the vehicle has actually landed at the safe pose.
		return
	var crossing := _checkpoint_detector.sample(_vehicle.global_position)
	if not crossing.is_empty():
		var completed := _trial.cross_checkpoint(
			int(crossing.get("checkpoint", -1)),
			float(crossing.get("forward_dot", 0.0)),
		)
		if completed:
			_show_status("Lap %d  ·  %s" % [_trial.lap_count, _format_time(_trial.last_lap_time)], 4.0)
		_track_runtime.set_next_checkpoint(_trial.next_checkpoint)


## One tick of the field. Every rival senses, in car-index order, before any rival drives; then each
## drives and samples its own checkpoints. Nothing a driver decides moves a car before the physics
## step, so all twenty senses describe the same world. The order is the field's own list, never one
## a physics query or a dictionary decides.
func _drive_field(delta: float) -> void:
	if _rivals.is_empty():
		return
	var field := _field_cars()
	var driving: Array[Dictionary] = []
	for rival in _rivals:
		var car := field[int(rival["index"])]
		if car == null:
			continue
		# A rival's own reset reseeds its detector at the safe destination and skips its
		# pending-teleport tick -- senses, controls and sampling -- before a stale pose reaches any.
		if car.consume_auto_reset_notice():
			(rival["detector"] as CheckpointCrossingDetector).reset(car.get_safe_reset_pose().origin)
			continue
		driving.append(rival)
	var senses: Array[DriverSenses] = []
	for rival in driving:
		senses.append(_sensing.sense(field, int(rival["index"]), (rival["driver"] as AiDriver).sensing_horizon()))
	for slot in range(driving.size()):
		var rival := driving[slot]
		var car := field[int(rival["index"])]
		var driver := rival["driver"] as AiDriver
		driver.perceive(senses[slot])
		car.set_input_state(driver.drive(delta))
		var crossing: Dictionary = (rival["detector"] as CheckpointCrossingDetector).sample(car.global_position)
		if not crossing.is_empty():
			(rival["progress"] as LapProgressTracker).cross_checkpoint(
				int(crossing.get("checkpoint", -1)),
				float(crossing.get("forward_dot", 0.0)),
			)


## Every car in the field, indexed by car index: the player at 0, rival n at n. A rival whose car has
## been freed is a null the sensing pass skips, so no other car's index moves.
func _field_cars() -> Array[TopDownCar]:
	var field: Array[TopDownCar] = [_vehicle if is_instance_valid(_vehicle) else null]
	for rival in _rivals:
		field.append(rival["car"] as TopDownCar if is_instance_valid(rival["car"]) else null)
	return field


func _unhandled_input(event: InputEvent) -> void:
	if _trial == null:
		return
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
	_opponent_count = int(session_settings.get("opponent_count"))
	_rivals.clear()
	_field_surface_map = null
	_sensing = null
	_spawn_failure = ""
	_host_race_in_a_fresh_world()
	_track_definition = TrackGenerator.new().generate(seed)
	# Every rival's pose is found before anything of the race is built, so a pose past the proved bound
	# refuses the whole race rather than placing one car unsnapped.
	var rival_poses: Array[Transform2D] = []
	for index in range(1, _opponent_count + 1):
		rival_poses.append(_physics_fixed_pose(_grid_slot_transform(index)))
	if not _spawn_failure.is_empty():
		_refuse_the_race()
		return
	var runtime := TrackRuntime.new(_track_definition)
	runtime.name = "GeneratedTrack"
	install_track(runtime)
	_track_runtime = runtime

	_vehicle = VEHICLE_SCENE.instantiate() as TopDownCar
	_vehicle.name = "PlayerCar"
	_vehicle.camera_enabled = true
	_vehicle.tuning = vehicle_tuning
	_vehicle.global_transform = _track_definition.spawn_transform
	install_vehicle(_vehicle)
	_field_surface_map = TrackSurfaceMap.new(_track_definition)
	_vehicle.set_surface_query(_field_surface_map)
	# The runtime's own map, so the car drives the field the ground is drawn from and the lattice
	# is built once rather than twice.
	_vehicle.set_height_query(runtime.height_query())
	_vehicle.set_input_state(_controller_input.apply_raw_values(0.0, 0.0, 0.0, false))
	_vehicle.set_safe_reset_pose(_track_definition.spawn_transform)
	_vehicle.set_auto_reset_enabled(bool(session_settings.get("auto_reset_enabled")))

	_trial = TimeTrialState.new(_track_definition.checkpoints.size())
	_checkpoint_detector = CheckpointCrossingDetector.new(_track_definition)
	_checkpoint_detector.reset(_vehicle.global_position)
	_track_runtime.set_next_checkpoint(_trial.next_checkpoint)
	if _opponent_count > 0:
		_sensing = SensingPass.new(_field_surface_map, runtime.height_query())
		for index in range(1, _opponent_count + 1):
			_spawn_rival(index, rival_poses[index - 1])
	_controller_input.suppress_until_controls_released()
	_refresh_hud()
	_show_status("Seed %d ready" % _current_seed)


## Slot 0 is the player's and is the definition's spawn transform itself, so the player's pose
## never moves with the opponent count and every lap time this repo has recorded stays
## comparable. Rivals take slots 1..opponent_count in rows behind the start line: slot s sits in
## row (s + 1) / 2, odd slots on one side of the centreline, even slots on the other. The layout
## is a pure function of the definition and the slot number, so the same seed and count always
## place the same cars in the same slots, and no slot depends on the count.
func _grid_slot_transform(slot: int) -> Transform2D:
	if slot <= 0:
		return _track_definition.spawn_transform
	var row := (slot + 1) / 2
	var side := -1.0 if slot % 2 == 1 else 1.0
	var pose := _centerline_pose_behind(row * WorldScale.metres(GRID_ROW_SPACING_M))
	# pose's rotation is the local direction of travel, so its y basis is already the lateral
	# normal to lay the columns along.
	var lateral := pose.y * (side * _track_definition.track_width * GRID_COLUMN_FRACTION)
	return Transform2D(pose.get_rotation() + PI * 0.5, pose.origin + lateral)


## The centreline pose (origin plus direction of travel) a given arc length behind the start,
## walking the generated polyline backwards around the loop.
func _centerline_pose_behind(arc_length: float) -> Transform2D:
	var points := _track_definition.centerline
	var unique := points.size() - 1
	var index := 0
	var remaining := arc_length
	while remaining > 0.0 and unique > 0:
		var previous := points[(index - 1 + unique) % unique]
		var segment := points[index].distance_to(previous)
		if segment >= remaining:
			var origin := points[index].lerp(previous, remaining / maxf(segment, 0.000001))
			return Transform2D((points[index] - previous).angle(), origin)
		remaining -= segment
		index = (index - 1 + unique) % unique
	var forward := (_track_definition.centerline[1] - _track_definition.centerline[0]).normalized()
	return Transform2D(forward.angle(), points[0])


## The pose a physics step would leave a body at rest in. Integrating a body rebuilds its transform
## from its angle in 32-bit real_t, which re-rounds a basis built any other way -- the grid's is built
## from a centreline direction plus a quarter turn -- in its last digit. Whether a step ran between
## spawning and the first sense then decided which race twenty drivers drove: the #59 review measured
## it (the spawn contexts differed only in some cars' global_rotation, by one ulp). A car spawned at a
## pose the rebuild leaves unchanged senses one world whichever phase it was spawned in.
##
## The review found that pose by rebuilding until nothing changed. That iteration has no usable bound:
## seed 41's rivals 13 and 14 take 14,670 rounds, and an exhaustive sweep of every float32 angle (task
## #61 fix round 1, against this machine's libm, whose cosf/sinf/atan2f matched the engine bit for bit on
## a million angles) found runs of about 3.7 million consecutive angles a step would move. So the
## rotation is instead moved onto a lattice of 2^-16 rad and the nearest lattice angle the rebuild leaves
## unchanged is taken, nearest first and the higher angle first at equal distance. Every lattice angle is
## exactly representable in float32, so the candidates are the same on every run. Of the 411,775 a spawn
## can round to, 24,478 are moved by a step, and none is more than SPAWN_ANGLE_MAX_STEPS = 6 steps from
## a fixed one -- at most 9.9e-5 rad of rotation. That bound is exhaustive over the lattice and
## tests/field_race_test.gd re-proves it in the engine, so it holds for the math library the suite runs
## on. Past it -- another libm could put it there -- there is no pose to return: this records the failure
## in _spawn_failure, logs it with push_error in every build, and returns the raw pose, which
## restart_with_seed never places, because it refuses the race (_refuse_the_race).
func _physics_fixed_pose(pose: Transform2D) -> Transform2D:
	var max_steps := _spawn_angle_max_steps()
	var nearest := roundi(pose.get_rotation() * SPAWN_ANGLE_LATTICE)
	for distance in range(max_steps + 1):
		for index in [nearest + distance, nearest - distance]:
			var candidate := Transform2D(index / SPAWN_ANGLE_LATTICE, pose.origin)
			if Transform2D(candidate.get_rotation(), candidate.origin) == candidate:
				return candidate
	var message := "MainSession: no physics fixed spawn rotation within %d lattice steps of %s" % [max_steps, pose]
	push_error(message)
	if _spawn_failure.is_empty():
		_spawn_failure = message
	return pose


## SPAWN_ANGLE_MAX_STEPS, behind a method so tests/field_race_test.gd can force the bound low and watch
## the race be refused. Nothing in the game overrides it.
func _spawn_angle_max_steps() -> int:
	return SPAWN_ANGLE_MAX_STEPS


## A rival pose past the proved bound: the restart has already freed the previous race and swapped in a
## fresh world, and it builds nothing of this one -- no track, no player's car, no rival, no sensing
## pass. With no trial the session's physics tick, HUD and pause input do nothing, the snapshot and
## standings are empty, and the status line says why and stays up (_show_status writes nothing over it). get_spawn_failure() names the pose.
## A new restart (another seed, or this one on a math library the bound holds for) builds normally.
func _refuse_the_race() -> void:
	_trial = null
	_vehicle = null
	_checkpoint_detector = null
	_track_runtime = null
	_pause_overlay.visible = false
	_status_label.text = SPAWN_REFUSED_STATUS
	_status_panel.visible = true
	_status_hide_at_msec = 0


## Why the last restart refused to build its race, or empty when it built one.
func get_spawn_failure() -> String:
	return _spawn_failure


## `pose` is the slot's physics fixed pose, found by restart_with_seed before anything was built.
func _spawn_rival(index: int, pose: Transform2D) -> void:
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.name = "RivalCar%d" % index
	# _ready() reads the session tuning for mass and captures the grid pose for safe resets.
	# The scene has default tuning, but it must not override a session's custom tuning.
	# The camera stays disabled through the scene default.
	car.tuning = vehicle_tuning
	car.global_transform = pose
	%VehicleMount.add_child(car)
	car.set_surface_query(_field_surface_map)
	car.set_height_query(_track_runtime.height_query())
	# Skill comes from the car's own seed stream (#59); mistakes from the field's one switch.
	var driver := ReactiveDriver.new(_current_seed, index)
	driver.mistakes_enabled = bool(session_settings.get("opponent_mistakes_enabled"))
	car.set_input_state(VehicleInputState.new())
	car.set_auto_reset_enabled(bool(session_settings.get("auto_reset_enabled")))
	var detector := CheckpointCrossingDetector.new(_track_definition)
	detector.reset(car.global_position)
	var progress := LapProgressTracker.new(_track_definition.checkpoints.size())
	_rivals.append({
		"index": index,
		"car": car,
		"driver": driver,
		"detector": detector,
		"progress": progress,
	})


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
		"opponent_count": _opponent_count,
		"field_size": get_field_size(),
		"player_position": get_player_position(),
		"lap_count": _trial.lap_count,
		"next_checkpoint": _trial.next_checkpoint,
		"current_lap_time": _trial.current_lap_time,
		"session_time": _trial.session_time,
		"last_lap_time": _trial.last_lap_time,
		"best_lap_time": _trial.best_lap_time,
		"paused": _trial.paused,
		"geometry_fingerprint": _track_definition.geometry_fingerprint,
		"offtrack_object_fingerprint": _track_definition.offtrack_object_fingerprint,
		"height_fingerprint": _track_definition.height_fingerprint,
	}


func get_field_size() -> int:
	return get_race_entries().size()


## Per-car progress as rankable data: laps completed, the next checkpoint, how many checkpoints
## of the current lap are behind the car, and how far the car stands from its next gate.
func get_race_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	if _trial == null or not is_instance_valid(_vehicle) or _track_definition == null:
		return entries
	var checkpoint_count := _track_definition.checkpoints.size()
	entries.append(_race_entry(0, _trial.lap_count, _trial.next_checkpoint, _vehicle.global_position, checkpoint_count))
	for rival in _rivals:
		if not is_instance_valid(rival["car"]):
			continue
		var car := rival["car"] as TopDownCar
		var progress := rival["progress"] as LapProgressTracker
		entries.append(_race_entry(int(rival["index"]), progress.lap_count, progress.next_checkpoint, car.global_position, checkpoint_count))
	return entries


func _race_entry(index: int, laps: int, next_checkpoint: int, position: Vector2, checkpoint_count: int) -> Dictionary:
	var gate: Transform2D = _track_definition.checkpoints[next_checkpoint]
	return {
		"index": index,
		"laps": laps,
		"next_checkpoint": next_checkpoint,
		"checkpoints_passed": posmod(next_checkpoint - 1, checkpoint_count),
		"next_checkpoint_distance": position.distance_to(gate.origin),
	}


func get_race_order() -> Array[int]:
	return _rank_entries(get_race_entries())


## Rank by laps completed, then checkpoints passed this lap, then progress toward the next gate,
## then car index. The index term is the tie-break: it depends on identity, never on the order
## the entries happen to be listed in, so exact progress ties
## resolve identically on every run.
func _rank_entries(entries: Array[Dictionary]) -> Array[int]:
	var sorted_entries := entries.duplicate()
	sorted_entries.sort_custom(_is_ahead_of)
	var order: Array[int] = []
	for entry in sorted_entries:
		order.append(int(entry["index"]))
	return order


func _is_ahead_of(a: Dictionary, b: Dictionary) -> bool:
	if int(a["laps"]) != int(b["laps"]):
		return int(a["laps"]) > int(b["laps"])
	if int(a["checkpoints_passed"]) != int(b["checkpoints_passed"]):
		return int(a["checkpoints_passed"]) > int(b["checkpoints_passed"])
	if float(a["next_checkpoint_distance"]) != float(b["next_checkpoint_distance"]):
		return float(a["next_checkpoint_distance"]) < float(b["next_checkpoint_distance"])
	return int(a["index"]) < int(b["index"])


func get_player_position() -> int:
	return get_race_order().find(0) + 1


## Every race gets a new physics space. Measured on seed 0 with twenty rivals: a
## restart into the viewport's existing space did not reproduce the race -- racing seed 1 first
## changed 18 of 20 cars, racing seed 0 itself first changed 20, and seeds 1 then 2 first changed
## none -- while the same three histories with a fresh World2D before the restart each drove the
## reference race bit for bit. What inside a reused space carries the history was not measured.
##
## The previous race's track and cars are freed first, so they never enter the new space on their way
## out, and the persistent World nodes re-enter the new world's canvas with it. The swap is the
## viewport's, so anything else living in that viewport comes along too: a StaticBody2D kept in the root
## beside the session was in each new space after every restart, and a rival's ray hit it there. The new
## space is new only of what this restart freed.
func _host_race_in_a_fresh_world() -> void:
	for mount in [%TrackMount, %VehicleMount]:
		for child in mount.get_children():
			child.free()
	get_viewport().world_2d = World2D.new()


func _install_scene(mount: Node2D, scene_root: Node2D) -> void:
	for child in mount.get_children():
		child.free()
	mount.add_child(scene_root)


func _refresh_hud() -> void:
	if _trial == null:
		return
	_seed_label.text = "SEED  %d" % _current_seed
	_lap_label.text = "LAP  %d" % (_trial.lap_count + 1)
	_position_label.text = "POS  %d/%d" % [get_player_position(), get_field_size()]
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
	_diagnostics_overlay.call(
		"set_height_metrics",
		float(metrics.get("height_m", 0.0)),
		float(metrics.get("vertical_speed_mps", 0.0)),
		bool(metrics.get("airborne", false)),
		float(metrics.get("air_time", 0.0)),
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
	# A refused race's status line stays up: nothing else the session reports matters until a restart
	# builds a race.
	if not _spawn_failure.is_empty():
		return
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
