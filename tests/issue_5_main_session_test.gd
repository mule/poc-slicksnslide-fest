extends SceneTree

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var main_scene := load("res://session/main.tscn") as PackedScene
	_check(main_scene != null, "main session scene loads")
	if main_scene == null:
		_finish()
		return
	var session = main_scene.instantiate()
	root.add_child(session)
	await process_frame
	await physics_frame

	_verify_integrated_world(session)
	_verify_single_viewport_ui(session)
	_verify_pause_and_restart(session)

	await process_frame
	await physics_frame
	await _verify_automatic_reset_does_not_leak_checkpoint_progress(session)

	paused = false
	session.queue_free()
	await process_frame
	_finish()


func _verify_integrated_world(session: Node) -> void:
	var track_mount := session.get_node_or_null("%TrackMount")
	var vehicle_mount := session.get_node_or_null("%VehicleMount")
	_check(track_mount != null and track_mount.get_child_count() == 1, "session installs one generated track")
	_check(vehicle_mount != null and vehicle_mount.get_child_count() == 1, "session installs one playable vehicle")
	if track_mount != null and track_mount.get_child_count() == 1:
		var runtime := track_mount.get_child(0)
		_check(runtime is TrackRuntime, "track mount contains runtime generated geometry")
		var start_finish := runtime.get_node_or_null("StartFinishLine") as Line2D
		_check(start_finish != null and start_finish.points.size() == 2, "generated finish checkpoint has a visible track-width marker")
	if vehicle_mount != null and vehicle_mount.get_child_count() == 1:
		_check(vehicle_mount.get_child(0) is TopDownCar, "vehicle mount contains the real top-down car")
	_check(session.has_method("get_session_snapshot"), "session exposes observable time-trial state")
	if session.has_method("get_session_snapshot"):
		var snapshot: Dictionary = session.call("get_session_snapshot")
		_check(snapshot.get("seed", -1) == 0, "session starts from the configured seed")
		_check(snapshot.get("lap_count", -1) == 0 and snapshot.get("next_checkpoint", -1) == 1, "session starts with ordered lap progress")


func _verify_single_viewport_ui(session: Node) -> void:
	_check(_count_descendants_of_type(session, "SubViewport") == 0, "gameplay uses no nested or secondary viewport")
	var hud := session.get_node_or_null("%SessionHud") as Control
	var pause_overlay := session.get_node_or_null("%PauseOverlay") as Control
	_check(hud != null, "minimal seed/lap/time HUD exists in the gameplay viewport")
	_check(pause_overlay != null, "pause menu overlay exists in the gameplay viewport")
	if hud != null:
		_check(hud.get_global_rect().end.y <= 160.0, "HUD overlays the top edge instead of reserving a lower region")
	for button_name in ["ResumeButton", "RestartButton", "NextSeedButton"]:
		var button := session.get_node_or_null("%%%s" % button_name) as Button
		_check(button != null and button.focus_mode == Control.FOCUS_ALL, "%s is controller-focusable" % button_name)


func _verify_pause_and_restart(session: Node) -> void:
	_check(session.has_method("set_session_paused"), "session exposes pause control")
	_check(session.has_method("restart_with_seed"), "session exposes seed restart control")
	if not session.has_method("set_session_paused") or not session.has_method("restart_with_seed"):
		return
	var before_pause: Dictionary = session.call("get_session_snapshot")
	session.call("set_session_paused", true)
	var pause_overlay := session.get_node_or_null("%PauseOverlay") as Control
	var vehicle_mount := session.get_node_or_null("%VehicleMount")
	var car := vehicle_mount.get_child(0) if vehicle_mount != null and vehicle_mount.get_child_count() > 0 else null
	_check(paused, "pause suspends the scene tree and vehicle simulation")
	_check(car != null and not car.can_process(), "paused world prevents the real car from processing physics")
	_check(pause_overlay != null and pause_overlay.visible, "pause displays the focusable menu")
	session.call("_physics_process", 2.0)
	var while_paused: Dictionary = session.call("get_session_snapshot")
	_check(is_equal_approx(float(while_paused.get("session_time", -1.0)), float(before_pause.get("session_time", -2.0))), "pause freezes the session timer")

	session.call("set_session_paused", false)
	_check(not paused and (pause_overlay == null or not pause_overlay.visible), "resume restores simulation and hides the menu")
	session.call("restart_with_seed", 7)
	var restarted: Dictionary = session.call("get_session_snapshot")
	_check(restarted.get("seed", -1) == 7, "restart regenerates the requested seed")
	_check(restarted.get("lap_count", -1) == 0 and is_zero_approx(float(restarted.get("session_time", -1.0))), "seed restart clears lap and timer state")


## Regression coverage for the off-by-one in the automatic-reset checkpoint wiring: an automatic
## reset only sets a flag the vehicle honours on the *next* physics tick, so the session's
## `_physics_process` sees the pre-teleport (off-track) position when it reseeds the checkpoint
## detector. Seeding it with that stale position instead of the pose the car is about to land at
## turns the off-track-to-safe-pose teleport into a fake "movement" the detector can credit as a
## driven checkpoint crossing. This drives the real session (restarted to seed 7 by
## `_verify_pause_and_restart`) through exactly that scenario and confirms lap progress does not
## move.
func _verify_automatic_reset_does_not_leak_checkpoint_progress(session: Node) -> void:
	var vehicle_mount := session.get_node_or_null("%VehicleMount")
	var track_mount := session.get_node_or_null("%TrackMount")
	var has_fixture := (
		vehicle_mount != null and vehicle_mount.get_child_count() > 0
		and track_mount != null and track_mount.get_child_count() > 0
	)
	_check(has_fixture, "session exposes a vehicle and track to drive the automatic-reset checkpoint regression")
	if not has_fixture:
		return

	var car := vehicle_mount.get_child(0) as TopDownCar
	var runtime := track_mount.get_child(0)
	var track_definition: TrackDefinition = runtime.definition

	var before: Dictionary = session.call("get_session_snapshot")
	_check(
		int(before.get("next_checkpoint", -1)) == 1 and int(before.get("lap_count", -1)) == 0,
		"baseline before the regression drive is a fresh, un-advanced lap"
	)

	# Position the car behind checkpoint 1 (where it will be "stuck"), and set the safe pose ahead
	# of the same gate. A detector reseeded with the stale off-track position would see a forward
	# crossing when the car actually lands at the safe pose; reseeded with the safe pose itself,
	# the segment collapses to zero length and nothing crosses.
	var checkpoint: Transform2D = track_definition.checkpoints[1]
	var forward := checkpoint.x.normalized()
	var offset := 40.0
	var stuck_pose := checkpoint.origin - forward * offset
	var safe_pose := checkpoint.origin + forward * offset

	var provider := Issue4TestSurfaceProvider.new()
	provider.force_off_track = true
	provider.distance_from_line = 10.0
	car.set_surface_query(provider)
	car.global_transform = Transform2D(0.0, stuck_pose)
	car.linear_velocity = Vector2.ZERO
	var pose_accepted := car.set_safe_reset_pose(Transform2D(0.0, safe_pose))
	_check(pose_accepted, "the engineered safe pose ahead of the gate is collision-clear")
	car.set_auto_reset_enabled(true)

	var tuning: VehicleTuning = car.tuning
	var ticks := int((tuning.auto_reset_stuck_seconds + 1.0) * 60.0)
	for tick in range(ticks):
		await physics_frame

	_check(
		car.global_position.distance_to(safe_pose) < 1.0,
		"the automatic reset lands the car at the engineered safe pose"
	)
	var after: Dictionary = session.call("get_session_snapshot")
	_check(
		int(after.get("next_checkpoint", -1)) == 1 and int(after.get("lap_count", -1)) == 0,
		"the automatic reset's off-track-to-safe-pose teleport is not credited as a driven checkpoint crossing"
	)


func _count_descendants_of_type(node: Node, type_name: String) -> int:
	var count := 0
	for child in node.get_children():
		if child.is_class(type_name):
			count += 1
		count += _count_descendants_of_type(child, type_name)
	return count


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Issue #5 main-session checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Issue #5 main-session check failed: %s" % failure)
	quit(1)
