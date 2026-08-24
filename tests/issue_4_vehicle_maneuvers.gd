extends SceneTree

## Repeatable, real-physics acceptance maneuvers for GitHub issue #4.

const VEHICLE_SCENE_PATH := "res://vehicle/top_down_car.tscn"
const DEFAULT_TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const START_POSE := Transform2D(0.0, Vector2(320.0, 520.0))
const TEST_TICKS_PER_SECOND := 60

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var vehicle_scene := load(VEHICLE_SCENE_PATH) as PackedScene
	_check(vehicle_scene != null, "top-down RigidBody2D vehicle scene loads")
	var tuning := load(DEFAULT_TUNING_PATH) as VehicleTuning
	_check(tuning != null, "default issue #4 tuning loads")
	if vehicle_scene == null or tuning == null:
		_finish()
		return
	if "--break-countersteer" in OS.get_cmdline_user_args():
		await _test_constant_steering_and_countersteer(vehicle_scene, tuning)
		_finish()
		return
	if "--break-proportional-steering" in OS.get_cmdline_user_args():
		await _test_proportional_steering_response(vehicle_scene, tuning)
		_finish()
		return
	if "--break-surface-recovery" in OS.get_cmdline_user_args():
		await _test_surface_transition_changes_recovery(vehicle_scene, tuning)
		_finish()
		return
	if "--surface-only" in OS.get_cmdline_user_args():
		await _test_surface_transition_changes_recovery(vehicle_scene, tuning)
		_finish()
		return
	if "--reset-only" in OS.get_cmdline_user_args():
		await _test_safe_reset_restores_latest_valid_pose(vehicle_scene, tuning)
		await _test_reset_rejects_pose_inside_boundary(vehicle_scene, tuning)
		await _test_driving_updates_latest_valid_reset_pose(vehicle_scene, tuning)
		_finish()
		return
	if "--collision-only" in OS.get_cmdline_user_args():
		await _test_wall_impact_does_not_tunnel_or_gain_energy(vehicle_scene, tuning)
		_finish()
		return

	await _test_proportional_acceleration_and_no_hidden_drive(vehicle_scene, tuning)
	await _test_service_brake_and_reverse(vehicle_scene, tuning)
	await _test_proportional_steering_response(vehicle_scene, tuning)
	await _test_constant_steering_and_countersteer(vehicle_scene, tuning)
	await _test_handbrake_rotation_is_useful_and_bounded(vehicle_scene, tuning)
	await _test_surface_transition_changes_recovery(vehicle_scene, tuning)
	await _test_wall_impact_does_not_tunnel_or_gain_energy(vehicle_scene, tuning)
	await _test_safe_reset_restores_latest_valid_pose(vehicle_scene, tuning)
	await _test_reset_rejects_pose_inside_boundary(vehicle_scene, tuning)
	await _test_driving_updates_latest_valid_reset_pose(vehicle_scene, tuning)
	await _test_camera_feedback_and_diagnostics(vehicle_scene, tuning)
	await _test_render_frame_rate_does_not_change_fixed_tick_result(vehicle_scene, tuning)
	await _test_scale_contract(vehicle_scene, tuning)
	_finish()


func _test_proportional_acceleration_and_no_hidden_drive(scene: PackedScene, tuning: VehicleTuning) -> void:
	var full := await _run_straight_acceleration(scene, tuning, 1.0)
	var half := await _run_straight_acceleration(scene, tuning, 0.5)
	_check(full.speed >= 450.0 and full.speed <= 550.0, "full throttle reaches 450..550 px/s after 4 s (got %.2f)" % full.speed)
	_check(half.speed >= full.speed * 0.55 and half.speed <= full.speed * 0.80, "half throttle produces proportional speed (half %.2f, full %.2f)" % [half.speed, full.speed])

	var fixture := await _spawn_vehicle(scene, tuning)
	var car = fixture.car
	var controls: VehicleInputState = fixture.controls
	controls.set_controls(0.0, 1.0, 0.0, 0.0)
	await _simulate_seconds(2.5)
	var speed_before_release: float = car.get_speed()
	controls.reset()
	await _simulate_seconds(1.0)
	var speed_after_release: float = car.get_speed()
	_check(speed_after_release < speed_before_release - 3.1, "released controls add no hidden drive force (%.2f -> %.2f)" % [speed_before_release, speed_after_release])
	await _dispose_fixture(fixture)


func _test_service_brake_and_reverse(scene: PackedScene, tuning: VehicleTuning) -> void:
	var fixture := await _spawn_vehicle(scene, tuning)
	var car = fixture.car
	var controls: VehicleInputState = fixture.controls
	controls.set_controls(0.0, 1.0, 0.0, 0.0)
	await _simulate_seconds(3.0)
	var approach_speed: float = car.get_speed()
	controls.set_controls(0.0, 0.0, 1.0, 0.0)
	await _simulate_seconds(2.5)
	var stopped_speed: float = car.get_speed()
	await _simulate_seconds(1.5)
	var reverse_local: Vector2 = car.get_local_velocity()
	_check(approach_speed >= 380.0, "braking maneuver has a meaningful approach speed (got %.2f)" % approach_speed)
	_check(stopped_speed <= 31.0, "service brake stops without overshoot jitter (got %.2f)" % stopped_speed)
	_check(reverse_local.y >= 62.5 and reverse_local.y <= 212.5, "held brake provides bounded reverse (local y %.2f)" % reverse_local.y)
	await _dispose_fixture(fixture)


func _test_proportional_steering_response(scene: PackedScene, tuning: VehicleTuning) -> void:
	var full_rotation := await _run_rotation_maneuver(scene, tuning, 0.0, 0.8)
	var half_steer := 0.8 if "--break-proportional-steering" in OS.get_cmdline_user_args() else 0.4
	var half_rotation := await _run_rotation_maneuver(scene, tuning, 0.0, half_steer)
	_check(full_rotation >= 0.65, "full steering creates a meaningful one-second rotation (%.2f rad)" % full_rotation)
	_check(half_rotation >= full_rotation * 0.35 and half_rotation <= full_rotation * 0.65, "half steering produces proportional rotation (half %.2f, full %.2f rad)" % [half_rotation, full_rotation])


func _test_constant_steering_and_countersteer(scene: PackedScene, tuning: VehicleTuning) -> void:
	var fixture := await _spawn_vehicle(scene, tuning)
	var car = fixture.car
	var controls: VehicleInputState = fixture.controls
	controls.set_controls(0.0, 1.0, 0.0, 0.0)
	await _simulate_seconds(2.5)
	controls.set_controls(0.65, 0.75, 0.0, 0.0)
	await _simulate_seconds(1.5)
	var turned_radians: float = absf(car.rotation)
	var slip_before: float = car.get_slip_ratio()
	if "--break-countersteer" in OS.get_cmdline_user_args():
		controls.set_controls(0.65, 0.75, 0.0, 1.0)
	else:
		controls.set_controls(-0.65, 0.25, 0.0, 0.0)
	await _simulate_seconds(1.5)
	var slip_after: float = car.get_slip_ratio()
	_check(turned_radians >= 0.35 and turned_radians <= 2.4, "constant analog steering creates a progressive turn (%.2f rad)" % turned_radians)
	_check(absf(car.angular_velocity) <= tuning.max_angular_speed + 0.01, "steering angular speed remains bounded (%.2f rad/s)" % absf(car.angular_velocity))
	_check(slip_after <= slip_before - 0.03, "counter-steer meaningfully reduces slip (%.2f -> %.2f)" % [slip_before, slip_after])
	await _dispose_fixture(fixture)


func _test_handbrake_rotation_is_useful_and_bounded(scene: PackedScene, tuning: VehicleTuning) -> void:
	var normal_rotation := await _run_rotation_maneuver(scene, tuning, 0.0, 0.8)
	var handbrake_rotation := await _run_rotation_maneuver(scene, tuning, 1.0, 0.8)
	_check(handbrake_rotation >= normal_rotation + 0.18, "handbrake adds useful rotation (normal %.2f, handbrake %.2f rad)" % [normal_rotation, handbrake_rotation])
	_check(handbrake_rotation <= 2.8, "one-second handbrake input cannot snap or spin indefinitely (%.2f rad)" % handbrake_rotation)


func _test_surface_transition_changes_recovery(scene: PackedScene, tuning: VehicleTuning) -> void:
	var dirt := Issue4TestSurfaceProvider.new()
	dirt.boundary_y = -INF
	var grass := Issue4TestSurfaceProvider.new()
	grass.boundary_y = 505.0
	var dirt_result := await _run_surface_maneuver(scene, tuning, dirt)
	var grass_result := await _run_surface_maneuver(scene, tuning, grass)
	_check(grass_result.visited_off_track, "local provider crosses the dirt/off-track boundary")
	_check(grass_result.speed <= dirt_result.speed * 0.88, "off-track drag measurably lowers speed (dirt %.2f, grass %.2f)" % [dirt_result.speed, grass_result.speed])

	var recovery_tuning := tuning
	if "--break-surface-recovery" in OS.get_cmdline_user_args():
		recovery_tuning = tuning.duplicate(true) as VehicleTuning
		recovery_tuning.off_track_grip_multiplier = recovery_tuning.dirt_grip_multiplier
		recovery_tuning.off_track_drag_multiplier = recovery_tuning.dirt_drag_multiplier
	var all_grass := Issue4TestSurfaceProvider.new()
	all_grass.boundary_y = INF
	var dirt_recovery := await _run_slip_recovery(scene, recovery_tuning, dirt)
	var grass_recovery := await _run_slip_recovery(scene, recovery_tuning, all_grass)
	_check(dirt_recovery.initial_slip >= 0.45 and grass_recovery.initial_slip >= 0.45, "surface recovery maneuvers begin with equivalent meaningful slip (dirt %.2f, off-track %.2f)" % [dirt_recovery.initial_slip, grass_recovery.initial_slip])
	_check(dirt_recovery.recovered and grass_recovery.recovered, "both surfaces recover below 0.12 slip within four seconds")
	_check(grass_recovery.ticks >= dirt_recovery.ticks + 15, "reduced off-track grip takes at least 15 more ticks to recover (dirt %d, off-track %d)" % [dirt_recovery.ticks, grass_recovery.ticks])


func _test_wall_impact_does_not_tunnel_or_gain_energy(scene: PackedScene, tuning: VehicleTuning) -> void:
	var fixture := await _spawn_vehicle(scene, tuning, true)
	var car = fixture.car
	var controls: VehicleInputState = fixture.controls
	controls.reset()
	car.linear_velocity = Vector2(0.0, -tuning.max_safe_speed)
	var pre_impact_peak: float = car.get_speed()
	await _simulate_seconds(3.0)
	_check(car.has_method("get_collision_count") and car.get_collision_count() >= 1, "wall maneuver records a real collision")
	_check(car.global_position.y >= 450.0, "continuous collision detection prevents tunneling through the wall (y %.2f)" % car.global_position.y)
	_check(car.get_peak_speed() <= tuning.max_safe_speed + 0.01, "impact cannot exceed configured safe speed (peak %.2f)" % car.get_peak_speed())
	_check(pre_impact_peak >= tuning.max_safe_speed - 0.1, "wall maneuver starts at the documented maximum expected speed (%.2f)" % pre_impact_peak)
	_check(car.get_speed() <= pre_impact_peak * 1.05 + 6.25, "wall impact injects no unbounded energy (before %.2f, after %.2f)" % [pre_impact_peak, car.get_speed()])
	await _dispose_fixture(fixture)


func _test_safe_reset_restores_latest_valid_pose(scene: PackedScene, tuning: VehicleTuning) -> void:
	var fixture := await _spawn_vehicle(scene, tuning)
	var car = fixture.car
	var safe_pose := Transform2D(0.42, Vector2(410.0, 430.0))
	car.set_safe_reset_pose(safe_pose)
	car.global_position = Vector2(80.0, 80.0)
	car.rotation = -2.0
	car.linear_velocity = Vector2(100.0, -100.0)
	car.angular_velocity = 12.0
	car.request_safe_reset()
	await physics_frame
	_check(car.global_position.distance_to(safe_pose.origin) <= 0.1, "reset restores the latest valid track position")
	_check(absf(wrapf(car.global_rotation - safe_pose.get_rotation(), -PI, PI)) <= 0.01, "reset restores the latest valid orientation")
	_check(car.linear_velocity.length() <= 0.01 and absf(car.angular_velocity) <= 0.01, "reset clears unsafe linear and angular velocity")
	await _dispose_fixture(fixture)


func _test_reset_rejects_pose_inside_boundary(scene: PackedScene, tuning: VehicleTuning) -> void:
	var fixture := await _spawn_vehicle(scene, tuning, true)
	var car = fixture.car
	var wall_pose := Transform2D(0.0, Vector2(320.0, 430.0))
	var accepted = car.set_safe_reset_pose(wall_pose)
	car.request_safe_reset()
	await physics_frame
	_check(not accepted, "reset rejects a candidate pose overlapping a boundary")
	_check(car.global_position.distance_to(START_POSE.origin) <= 0.1, "rejected reset candidate preserves the previous safe pose")
	await _dispose_fixture(fixture)


func _test_driving_updates_latest_valid_reset_pose(scene: PackedScene, tuning: VehicleTuning) -> void:
	var fixture := await _spawn_vehicle(scene, tuning)
	var car = fixture.car
	fixture.controls.set_controls(0.0, 1.0, 0.0, 0.0)
	await _simulate_seconds(1.2)
	var latest_valid_position: Vector2 = car.global_position
	car.global_position = Vector2(80.0, 80.0)
	car.linear_velocity = Vector2(90.0, -90.0)
	car.request_safe_reset()
	await physics_frame
	_check(car.global_position.y < START_POSE.origin.y - 3.0, "dirt driving advances the latest valid reset checkpoint")
	_check(car.global_position.distance_to(latest_valid_position) <= 100.0, "automatic reset checkpoint remains near the latest stable track pose")
	await _dispose_fixture(fixture)


func _test_camera_feedback_and_diagnostics(scene: PackedScene, tuning: VehicleTuning) -> void:
	var fixture := await _spawn_vehicle(scene, tuning)
	var car = fixture.car
	var controls: VehicleInputState = fixture.controls
	controls.set_controls(0.8, 1.0, 0.0, 1.0)
	await _simulate_seconds(3.0)
	await process_frame
	var diagnostics: Dictionary = car.get_diagnostics()
	var camera := car.get_node_or_null("FollowCamera") as Camera2D
	var dust := car.get_node_or_null("Dust") as CPUParticles2D
	var skid := car.get_node_or_null("SkidFeedback") as Line2D
	_check(diagnostics.has_all(["speed_kph", "local_longitudinal", "local_lateral", "slip", "steering", "throttle", "brake", "handbrake", "surface"]), "diagnostics report motion, controls, slip, and surface")
	_check(camera != null and camera.global_position.distance_to(car.global_position) > 1.0, "camera applies readable velocity lead at speed")
	_check(dust != null and dust.emitting, "dust feedback emits while driving on dirt")
	_check(skid != null and skid.visible, "skid feedback becomes visible during meaningful slip")
	await _dispose_fixture(fixture)


func _test_render_frame_rate_does_not_change_fixed_tick_result(scene: PackedScene, tuning: VehicleTuning) -> void:
	var old_max_fps := Engine.max_fps
	Engine.max_fps = 30
	var low_fps := await _run_straight_acceleration(scene, tuning, 0.8, 180)
	Engine.max_fps = 144
	var high_fps := await _run_straight_acceleration(scene, tuning, 0.8, 180)
	Engine.max_fps = old_max_fps
	_check(absf(low_fps.speed - high_fps.speed) <= 3.1, "180 fixed ticks are render-frame-rate stable (30 FPS %.2f, 144 FPS %.2f)" % [low_fps.speed, high_fps.speed])
	_check(low_fps.position.distance_to(high_fps.position) <= 0.75, "fixed-tick trajectory is render-frame-rate stable (delta %.3f)" % low_fps.position.distance_to(high_fps.position))


func _test_scale_contract(scene: PackedScene, tuning: VehicleTuning) -> void:
	var fixture := await _spawn_vehicle(scene, tuning)
	fixture.controls.set_controls(0.0, 1.0, 0.0, 0.0)
	await _simulate_seconds(25.0)
	var terminal: float = fixture.car.get_speed()
	_check(terminal >= 570.0 and terminal <= 630.0, "sustained throttle settles at the designed 600 px/s terminal speed (got %.1f)" % terminal)
	var viewport_width: float = 1280.0 / tuning.camera_zoom
	var crossing_seconds := viewport_width / maxf(terminal, 0.001)
	_check(crossing_seconds >= 2.5 and crossing_seconds <= 3.0, "the car crosses one viewport width in 2.5..3.0 s (got %.2f)" % crossing_seconds)
	_check(WorldScale.to_kph(terminal) >= 160.0 and WorldScale.to_kph(terminal) <= 185.0, "the HUD reads a truthful ~173 km/h (got %.1f)" % WorldScale.to_kph(terminal))
	await _dispose_fixture(fixture)


func _run_straight_acceleration(scene: PackedScene, tuning: VehicleTuning, throttle: float, ticks := 240) -> Dictionary:
	var fixture := await _spawn_vehicle(scene, tuning)
	fixture.controls.set_controls(0.0, throttle, 0.0, 0.0)
	await _simulate_ticks(ticks)
	var result := {"speed": fixture.car.get_speed(), "position": fixture.car.global_position}
	await _dispose_fixture(fixture)
	return result


func _run_rotation_maneuver(scene: PackedScene, tuning: VehicleTuning, handbrake: float, steer: float) -> float:
	var fixture := await _spawn_vehicle(scene, tuning)
	fixture.controls.set_controls(0.0, 1.0, 0.0, 0.0)
	await _simulate_seconds(2.5)
	var start_rotation: float = fixture.car.rotation
	fixture.controls.set_controls(steer, 0.55, 0.0, handbrake)
	await _simulate_seconds(1.0)
	var rotation_delta := absf(wrapf(fixture.car.rotation - start_rotation, -PI, PI))
	await _dispose_fixture(fixture)
	return rotation_delta


func _run_surface_maneuver(scene: PackedScene, tuning: VehicleTuning, provider: SurfaceQuery) -> Dictionary:
	var fixture := await _spawn_vehicle(scene, tuning, false, provider)
	fixture.controls.set_controls(0.7, 1.0, 0.0, 0.0)
	await _simulate_seconds(4.0)
	var result := {
		"speed": fixture.car.get_speed(),
		"slip": fixture.car.get_slip_ratio(),
		"surface": fixture.car.get_surface_type(),
		"visited_off_track": fixture.car.has_method("has_visited_surface") and fixture.car.has_visited_surface(SurfaceQuery.SurfaceType.OFF_TRACK),
	}
	await _dispose_fixture(fixture)
	return result


func _run_slip_recovery(scene: PackedScene, tuning: VehicleTuning, provider: SurfaceQuery) -> Dictionary:
	var fixture := await _spawn_vehicle(scene, tuning, false, provider)
	fixture.controls.reset()
	fixture.car.linear_velocity = Vector2(150.0, -225.0)
	await physics_frame
	var initial_slip: float = fixture.car.get_slip_ratio()
	var ticks := 0
	while fixture.car.get_slip_ratio() > 0.12 and ticks < 240:
		await physics_frame
		ticks += 1
	var result := {
		"initial_slip": initial_slip,
		"ticks": ticks,
		"recovered": fixture.car.get_slip_ratio() <= 0.12,
	}
	await _dispose_fixture(fixture)
	return result


func _spawn_vehicle(scene: PackedScene, tuning: VehicleTuning, with_wall := false, provider: SurfaceQuery = null) -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	if with_wall:
		var wall := StaticBody2D.new()
		wall.position = Vector2(320.0, 430.0)
		var wall_shape := CollisionShape2D.new()
		var rectangle := RectangleShape2D.new()
		rectangle.size = Vector2(700.0, 24.0)
		wall_shape.shape = rectangle
		wall.add_child(wall_shape)
		world.add_child(wall)
	var car = scene.instantiate()
	car.tuning = tuning
	car.global_transform = START_POSE
	var controls := VehicleInputState.new()
	car.set_input_state(controls)
	var surface_provider := provider if provider != null else Issue4TestSurfaceProvider.new()
	car.set_surface_query(surface_provider)
	world.add_child(car)
	car.set_safe_reset_pose(START_POSE)
	await physics_frame
	return {"world": world, "car": car, "controls": controls}


func _dispose_fixture(fixture: Dictionary) -> void:
	fixture.world.queue_free()
	await process_frame
	await physics_frame


func _simulate_seconds(seconds: float) -> void:
	await _simulate_ticks(roundi(seconds * TEST_TICKS_PER_SECOND))


func _simulate_ticks(ticks: int) -> void:
	for _tick in ticks:
		await physics_frame


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Issue #4 maneuvers passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Issue #4 maneuver failed: %s" % failure)
	print("Issue #4 maneuvers failed: %d/%d checks" % [_failures.size(), _checks])
	quit(1)
