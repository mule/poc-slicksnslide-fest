extends SceneTree

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Each verification reports whether it ran to completion. A GDScript runtime error aborts
	# only the function it occurs in and returns false to here, so without this the script
	# would exit 0 with assertions silently skipped. See tests/harness_contract_test.gd.
	var main_scene := load("res://session/main.tscn") as PackedScene
	_check(main_scene != null, "main session scene loads")
	if main_scene == null:
		_finish()
		return
	var session = main_scene.instantiate()
	root.add_child(session)
	await process_frame
	await physics_frame

	_check(_verify_integrated_world(session), "the integrated world verification ran to completion")
	_check(_verify_single_viewport_ui(session), "the single viewport ui verification ran to completion")
	_check(_verify_pause_and_restart(session), "the pause and restart verification ran to completion")
	await process_frame
	await physics_frame
	_check(await _verify_automatic_reset_does_not_leak_checkpoint_progress(session), "the automatic reset does not leak checkpoint progress verification ran to completion")
	_check(await _verify_height_channel_is_wired(session), "the height channel wiring verification ran to completion")
	paused = false
	session.queue_free()
	await process_frame
	_finish()


func _verify_integrated_world(session: Node) -> bool:
	var track_mount := session.get_node_or_null("%TrackMount")
	var vehicle_mount := session.get_node_or_null("%VehicleMount")
	_check(track_mount != null and track_mount.get_child_count() == 1, "session installs one generated track")
	_check(vehicle_mount != null and vehicle_mount.get_child_count() == 1, "session installs one playable vehicle")
	if track_mount != null and track_mount.get_child_count() == 1:
		var runtime := track_mount.get_child(0)
		_check(runtime is TrackRuntime, "track mount contains runtime generated geometry")
		var start_finish := runtime.get_node_or_null("Checkpoint0") as Line2D
		_check(start_finish != null and start_finish.points.size() == 2, "generated finish checkpoint has a visible track-width marker")
		_check_highlighted_gate_tracks_session(session, runtime)
	if vehicle_mount != null and vehicle_mount.get_child_count() == 1:
		_check(vehicle_mount.get_child(0) is TopDownCar, "vehicle mount contains the real top-down car")
	_check(session.has_method("get_session_snapshot"), "session exposes observable time-trial state")
	if session.has_method("get_session_snapshot"):
		var snapshot: Dictionary = session.call("get_session_snapshot")
		_check(snapshot.get("seed", -1) == 0, "session starts from the configured seed")
		_check(snapshot.get("lap_count", -1) == 0 and snapshot.get("next_checkpoint", -1) == 1, "session starts with ordered lap progress")
	return true


func _verify_single_viewport_ui(session: Node) -> bool:
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
	return true


func _verify_pause_and_restart(session: Node) -> bool:
	_check(session.has_method("set_session_paused"), "session exposes pause control")
	_check(session.has_method("restart_with_seed"), "session exposes seed restart control")
	if not session.has_method("set_session_paused") or not session.has_method("restart_with_seed"):
		return false
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
	return true


func _verify_automatic_reset_does_not_leak_checkpoint_progress(session: Node) -> bool:
	var vehicle_mount := session.get_node_or_null("%VehicleMount")
	var track_mount := session.get_node_or_null("%TrackMount")
	var has_fixture := (
		vehicle_mount != null and vehicle_mount.get_child_count() > 0
		and track_mount != null and track_mount.get_child_count() > 0
	)
	_check(has_fixture, "session exposes a vehicle and track to drive the automatic-reset checkpoint regression")
	if not has_fixture:
		return false
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
	return true


func _verify_height_channel_is_wired(session: Node) -> bool:
	# The file keeps `session` typed as Node like its sibling verifications, so calls go through
	# call() rather than static member access.
	session.call("restart_with_seed", 3)
	await process_frame
	var snapshot: Dictionary = session.call("get_session_snapshot")
	_check(str(snapshot.get("height_fingerprint", "")).length() == 64, "the snapshot reports a SHA-256 height fingerprint")
	var runtime := session.get_node_or_null("World/TrackMount/GeneratedTrack") as TrackRuntime
	var ramps := runtime.get_node_or_null("JumpRamps") as JumpRampVisuals if runtime != null else null
	_check(ramps != null, "the generated track mounts a JumpRamps visual layer")
	var definition: TrackDefinition = runtime.definition
	_check(ramps != null and ramps.visual_count() == definition.jump_ramps.size(), "one wedge per generated ramp")
	# The placer's fingerprint hashes only the catalog version and the placements, so every
	# rampless seed hashes alike. Seeds 3 and 4 are chosen because both place ramps, which keeps the
	# wedge counts and the fingerprint comparison below from passing vacuously on two empty tracks.
	_check(not definition.jump_ramps.is_empty(), "seed 3 places at least one ramp, so its wedge count is not vacuously zero")
	var first_fingerprint := str(snapshot.get("height_fingerprint", ""))
	var first_ramps := ramps

	# Seed restart replaces the ramp set entirely.
	session.call("restart_with_seed", 4)
	await process_frame
	var second: Dictionary = session.call("get_session_snapshot")
	_check(str(second.get("height_fingerprint", "")) != first_fingerprint, "restarting with another seed changes the height fingerprint")
	_check(session.get_node("World/TrackMount").get_child_count() == 1, "the previous track, including its ramps, is freed on restart")
	_check(not is_instance_valid(first_ramps), "the previous track's wedge layer is freed with it, not merely detached")
	var second_runtime := session.get_node_or_null("World/TrackMount/GeneratedTrack") as TrackRuntime
	var second_ramps := second_runtime.get_node_or_null("JumpRamps") as JumpRampVisuals if second_runtime != null else null
	var second_definition: TrackDefinition = second_runtime.definition
	_check(
		second_ramps != null and second_ramps.visual_count() == second_definition.jump_ramps.size(),
		"the restarted track's wedges match the new definition's ramps, not the old one's"
	)

	var car := session.get_node("World/VehicleMount/PlayerCar") as TopDownCar

	# The height query the *session* installed, exercised without replacing it -- coverage for the
	# one line this wiring owns. A parked car cannot climb onto a crest, because the grounded
	# branch caps its rise at the rate the ground under it rises and that rate is zero at a
	# standstill. `_apply_safe_reset` is the exception: it re-seats the ride height by sampling the
	# pose it teleports to, through whatever query the car already holds. So a car reset onto a
	# crest reports that crest's height only if the session installed a TrackHeightMap built from
	# this definition; with no query installed it reads flat ground and stays at zero.
	var crest_ramp: JumpRampPlacement = second_definition.jump_ramps[0] if not second_definition.jump_ramps.is_empty() else null
	_check(crest_ramp != null, "seed 4 places at least one ramp to reset the car onto")
	if crest_ramp != null:
		_check(car.set_safe_reset_pose(Transform2D(0.0, crest_ramp.transform.origin)), "the ramp crest is a collision-clear safe pose")
		car.request_safe_reset()
		await physics_frame
		_check(
			absf(car.get_height() - crest_ramp.crest_height) < 0.001,
			"the session's own height query seats the car on the crest (height %.3f px, crest %.3f px)" % [car.get_height(), crest_ramp.crest_height]
		)

	# A scripted fall long enough for the notice proves the car is wired to the session's status.
	# This one deliberately replaces the query, to isolate the car-to-session-to-HUD latch path
	# from whatever the generated track happens to place.
	var provider := HeightChannelTestHeightProvider.new()
	provider.mode = HeightChannelTestHeightProvider.Mode.PLATEAU
	provider.plateau_height = 40.0
	car.set_height_query(provider)
	# Two ticks on the plateau so the car snaps up to 40 px, then pull the ground away everywhere.
	await physics_frame
	await physics_frame
	provider.plateau_end_x = -INF
	var label := session.get_node("%StatusLabel") as Label
	var saw_air_time := false
	for tick in range(180):
		await physics_frame
		await process_frame
		if label.text.begins_with("Air time"):
			saw_air_time = true
			break
	_check(saw_air_time, "a flight of at least half a second shows the air time status line")
	return true


func _count_descendants_of_type(node: Node, type_name: String) -> int:
	var count := 0
	for child in node.get_children():
		if child.is_class(type_name):
			count += 1
		count += _count_descendants_of_type(child, type_name)
	return count


## The bright gate must be the one the session says comes next. Ordered gates void the lap when
## crossed out of sequence, so a marker that disagrees with LapProgressTracker would actively
## mislead the driver rather than merely fail to help.
func _check_highlighted_gate_tracks_session(session, runtime) -> void:
	var highlighted := -1
	var index := 0
	while true:
		var marker := runtime.get_node_or_null("Checkpoint%d" % index) as Line2D
		if marker == null:
			break
		if marker.default_color.a >= 1.0:
			highlighted = index
		index += 1
	_check(index > 0, "the session's track has checkpoint markers to highlight")
	if index == 0:
		return
	var progress: Dictionary = session.call("get_session_snapshot")
	var expected: int = int(progress.get("next_checkpoint", -1))
	_check(
		highlighted == expected,
		"the highlighted gate is the one the session says comes next (highlighted %d, expected %d)" % [highlighted, expected]
	)


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
