class_name TopDownCar
extends RigidBody2D

## Force-based top-down car. Hardware input stays outside this class: callers
## provide a normalized VehicleInputState and a SurfaceQuery implementation.

@export var tuning: VehicleTuning

var _input_state := VehicleInputState.new()
var _surface_query: SurfaceQuery
var _surface_type := SurfaceQuery.SurfaceType.UNKNOWN
var _surface_grip := 1.0
var _surface_drag := 1.0
var _safe_reset_pose := Transform2D.IDENTITY
var _has_safe_reset_pose := false
var _reset_requested := false
var _local_velocity := Vector2.ZERO
var _slip_ratio := 0.0
var _peak_speed := 0.0
var _reverse_hold_time := 0.0
var _collision_count := 0
var _visited_surfaces: Dictionary = {}
var _safe_pose_elapsed := 0.0

@onready var _follow_camera: Camera2D = $FollowCamera
@onready var _dust: CPUParticles2D = $Dust
@onready var _skid_feedback: Line2D = $SkidFeedback


func _ready() -> void:
	if tuning == null:
		push_error("TopDownCar requires a VehicleTuning resource")
		set_physics_process(false)
		return
	mass = tuning.mass_kg
	_safe_reset_pose = global_transform
	_has_safe_reset_pose = true
	_follow_camera.top_level = true
	_follow_camera.zoom = Vector2.ONE * tuning.camera_zoom
	_follow_camera.global_position = global_position
	body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	if tuning == null:
		return
	var lead := linear_velocity * tuning.camera_lead_seconds
	lead = lead.limit_length(tuning.camera_max_lead)
	var target_camera_position := global_position + lead
	var camera_blend := 1.0 - exp(-tuning.camera_follow_response * delta)
	_follow_camera.global_position = _follow_camera.global_position.lerp(target_camera_position, camera_blend)
	var on_dirt := _surface_type == SurfaceQuery.SurfaceType.DIRT
	_dust.emitting = on_dirt and get_speed() > WorldScale.metres(4.0)
	_skid_feedback.visible = _slip_ratio >= tuning.feedback_slip_threshold or _input_state.handbrake > 0.25
	_skid_feedback.modulate.a = clampf((_slip_ratio - tuning.feedback_slip_threshold) * 2.5 + _input_state.handbrake * 0.7, 0.0, 0.85)


func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if tuning == null:
		return
	if _reset_requested:
		_apply_safe_reset(state)
		return

	_sample_surface(state.transform.origin)
	var delta := state.step
	var world_velocity := state.linear_velocity
	_local_velocity = state.transform.basis_xform_inv(world_velocity)
	var forward_speed := -_local_velocity.y
	var lateral_speed := _local_velocity.x
	var speed := world_velocity.length()
	_slip_ratio = absf(lateral_speed) / maxf(speed, WorldScale.metres(1.0))

	var forward := -state.transform.y.normalized()
	var lateral := state.transform.x.normalized()
	var surface_engine := tuning.off_track_engine_multiplier if _surface_type == SurfaceQuery.SurfaceType.OFF_TRACK else 1.0
	var longitudinal_acceleration := tuning.engine_force * _input_state.throttle * surface_engine / tuning.mass_kg
	if _input_state.brake > 0.0:
		if forward_speed > tuning.stop_speed:
			_reverse_hold_time = 0.0
			longitudinal_acceleration -= tuning.brake_force * _input_state.brake / tuning.mass_kg
		elif forward_speed < -tuning.stop_speed:
			longitudinal_acceleration -= tuning.reverse_force * _input_state.brake * surface_engine / tuning.mass_kg
		else:
			_reverse_hold_time += delta
			if _reverse_hold_time >= tuning.reverse_engage_delay:
				longitudinal_acceleration -= tuning.reverse_force * _input_state.brake * surface_engine / tuning.mass_kg
	else:
		_reverse_hold_time = 0.0
	world_velocity += forward * longitudinal_acceleration * delta

	var updated_local := state.transform.basis_xform_inv(world_velocity)
	var updated_forward_speed := -updated_local.y
	var drag_rate := tuning.rolling_drag * _surface_drag
	var drag_amount := (drag_rate * absf(updated_forward_speed) + tuning.aerodynamic_drag * updated_forward_speed * updated_forward_speed * _surface_drag) * delta
	updated_forward_speed = move_toward(updated_forward_speed, 0.0, drag_amount)
	world_velocity = forward * updated_forward_speed + lateral * updated_local.x

	var progressive_grip := _progressive_grip(_slip_ratio)
	var handbrake_grip := lerpf(1.0, tuning.handbrake_grip_multiplier, _input_state.handbrake)
	var lateral_response := tuning.lateral_grip * _surface_grip * progressive_grip * handbrake_grip
	var desired_lateral_change := -lateral_speed * (1.0 - exp(-lateral_response * delta))
	var lateral_change_limit := tuning.lateral_grip_acceleration * _surface_grip * handbrake_grip * delta
	desired_lateral_change = clampf(desired_lateral_change, -lateral_change_limit, lateral_change_limit)
	world_velocity += lateral * desired_lateral_change

	if speed < WorldScale.metres(2.0) and _input_state.throttle == 0.0 and _input_state.brake == 0.0:
		world_velocity = world_velocity.move_toward(Vector2.ZERO, tuning.low_speed_stabilization * delta)

	var steering_speed_factor := clampf(absf(updated_forward_speed) / maxf(tuning.steering_full_speed, 0.01), 0.12, 1.0)
	var travel_direction := signf(updated_forward_speed) if absf(updated_forward_speed) > tuning.stop_speed else 1.0
	var rotation_multiplier := lerpf(1.0, tuning.handbrake_rotation_multiplier, _input_state.handbrake)
	var target_angular_velocity := _input_state.steer * tuning.max_steering_rate * steering_speed_factor * travel_direction * rotation_multiplier
	var angular_response := tuning.steering_response * (1.0 + _input_state.handbrake * 0.45)
	state.angular_velocity = move_toward(state.angular_velocity, target_angular_velocity, angular_response * delta)
	if absf(_input_state.steer) < 0.02:
		state.angular_velocity = move_toward(state.angular_velocity, 0.0, tuning.steering_response * 0.65 * delta)
	state.angular_velocity = clampf(state.angular_velocity, -tuning.max_angular_speed, tuning.max_angular_speed)

	state.linear_velocity = world_velocity.limit_length(tuning.max_safe_speed)
	_peak_speed = maxf(_peak_speed, state.linear_velocity.length())
	_local_velocity = state.transform.basis_xform_inv(state.linear_velocity)
	_slip_ratio = absf(_local_velocity.x) / maxf(state.linear_velocity.length(), WorldScale.metres(1.0))
	_update_safe_pose_checkpoint(state, delta)


func set_input_state(input_state: VehicleInputState) -> void:
	_input_state = input_state if input_state != null else VehicleInputState.new()


func set_surface_query(surface_query: SurfaceQuery) -> void:
	_surface_query = surface_query


func set_safe_reset_pose(safe_pose: Transform2D) -> bool:
	if not _is_pose_clear(safe_pose):
		return false
	_safe_reset_pose = safe_pose
	_has_safe_reset_pose = true
	_safe_pose_elapsed = 0.0
	return true


func request_safe_reset() -> void:
	_reset_requested = true
	sleeping = false


func get_speed() -> float:
	return linear_velocity.length()


func get_peak_speed() -> float:
	return _peak_speed


func get_collision_count() -> int:
	return _collision_count


func get_local_velocity() -> Vector2:
	return _local_velocity


func get_slip_ratio() -> float:
	return _slip_ratio


func get_surface_type() -> SurfaceQuery.SurfaceType:
	return _surface_type


func has_visited_surface(surface_type: SurfaceQuery.SurfaceType) -> bool:
	return _visited_surfaces.has(surface_type)


func get_diagnostics() -> Dictionary:
	return {
		"speed_kph": WorldScale.to_kph(get_speed()),
		"local_longitudinal": -_local_velocity.y,
		"local_lateral": _local_velocity.x,
		"slip": _slip_ratio,
		"steering": _input_state.steer,
		"throttle": _input_state.throttle,
		"brake": _input_state.brake,
		"handbrake": _input_state.handbrake,
		"surface": SurfaceQuery.SurfaceType.keys()[_surface_type].to_lower(),
	}


func _sample_surface(world_position: Vector2) -> void:
	if _surface_query == null:
		_surface_type = SurfaceQuery.SurfaceType.UNKNOWN
		_surface_grip = 1.0
		_surface_drag = 1.0
		return
	var sample := _surface_query.sample_at(world_position)
	_surface_type = sample.surface_type
	_visited_surfaces[_surface_type] = true
	var tuning_grip := 1.0
	var tuning_drag := 1.0
	match _surface_type:
		SurfaceQuery.SurfaceType.DIRT:
			tuning_grip = tuning.dirt_grip_multiplier
			tuning_drag = tuning.dirt_drag_multiplier
		SurfaceQuery.SurfaceType.OFF_TRACK:
			tuning_grip = tuning.off_track_grip_multiplier
			tuning_drag = tuning.off_track_drag_multiplier
	_surface_grip = maxf(sample.grip_multiplier * tuning_grip, 0.0)
	_surface_drag = maxf(sample.drag_multiplier * tuning_drag, 0.0)


func _progressive_grip(slip: float) -> float:
	var slip_range := maxf(tuning.full_slip - tuning.slip_onset, 0.01)
	var slip_blend := smoothstep(tuning.slip_onset, tuning.slip_onset + slip_range, slip)
	return lerpf(1.0, tuning.sliding_grip_multiplier, slip_blend)


func _apply_safe_reset(state: PhysicsDirectBodyState2D) -> void:
	_reset_requested = false
	if not _has_safe_reset_pose:
		return
	state.transform = _safe_reset_pose
	state.linear_velocity = Vector2.ZERO
	state.angular_velocity = 0.0
	state.sleeping = false
	_local_velocity = Vector2.ZERO
	_slip_ratio = 0.0
	_reverse_hold_time = 0.0
	_safe_pose_elapsed = 0.0


func _update_safe_pose_checkpoint(state: PhysicsDirectBodyState2D, delta: float) -> void:
	if _surface_type != SurfaceQuery.SurfaceType.DIRT or _slip_ratio > tuning.safe_pose_max_slip or state.get_contact_count() > 0:
		_safe_pose_elapsed = 0.0
		return
	_safe_pose_elapsed += delta
	if _safe_pose_elapsed < tuning.safe_pose_interval:
		return
	_safe_pose_elapsed = 0.0
	_safe_reset_pose = state.transform
	_has_safe_reset_pose = true


func _is_pose_clear(candidate: Transform2D) -> bool:
	if not is_inside_tree():
		return true
	var collision_shape := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if collision_shape == null or collision_shape.shape == null:
		return false
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = collision_shape.shape
	query.transform = candidate * collision_shape.transform
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	query.collide_with_areas = false
	query.collide_with_bodies = true
	return get_world_2d().direct_space_state.intersect_shape(query, 1).is_empty()


func _on_body_entered(_body: Node) -> void:
	_collision_count += 1
