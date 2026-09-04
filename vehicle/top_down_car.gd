class_name TopDownCar
extends RigidBody2D

## Force-based top-down car. Hardware input stays outside this class: callers
## provide a normalized VehicleInputState and a SurfaceQuery implementation.

const TALL_LAYER := 1
const LOW_LAYER := 2

## Predicted ballistic height must exceed the ground ahead by this much before the car counts as
## airborne. Small enough that a car cresting at walking pace still lifts off; large enough that
## float noise on flat ground never does.
const LIFT_OFF_TOLERANCE := 0.05
## A landing can never remove more than 70% of speed.
const MIN_LANDING_SPEED_FRACTION := 0.3

@export var tuning: VehicleTuning

var _input_state := VehicleInputState.new()
var _surface_query: SurfaceQuery
var _surface_type := SurfaceQuery.SurfaceType.UNKNOWN
var _surface_grip := 1.0
var _surface_drag := 1.0
var _safe_reset_pose := Transform2D.IDENTITY
var _has_safe_reset_pose := false
var _reset_requested := false
var _auto_reset_enabled := false
var _auto_reset_notice := false
var _off_track_stopped_elapsed := 0.0
var _local_velocity := Vector2.ZERO
var _slip_ratio := 0.0
var _peak_speed := 0.0
var _reverse_hold_time := 0.0
var _collision_count := 0
var _visited_surfaces: Dictionary = {}
var _safe_pose_elapsed := 0.0
var _height_query: HeightQuery
var _ground_height := 0.0
var _ground_gradient := Vector2.ZERO
var _height := 0.0
var _vertical_velocity := 0.0
var _airborne := false
var _air_time := 0.0
var _air_time_notice := 0.0
var _landing_recovery_remaining := 0.0
var _landed_this_tick := false

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


## The mask is a body property, not part of the integrator's state, so it is applied from
## _physics_process before the step rather than from inside _integrate_forces. It reflects the
## previous tick's height; at 60 Hz that is at most 2 px of vertical travel.
func _physics_process(_delta: float) -> void:
	if tuning == null:
		return
	collision_mask = get_collision_level_mask()


func get_collision_level_mask() -> int:
	if _height > tuning.low_obstacle_clearance:
		return TALL_LAYER
	return TALL_LAYER | LOW_LAYER


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
	_sample_ground(state.transform.origin)
	var delta := state.step
	var world_velocity := state.linear_velocity
	_local_velocity = state.transform.basis_xform_inv(world_velocity)
	var forward_speed := -_local_velocity.y
	var lateral_speed := _local_velocity.x
	var speed := world_velocity.length()
	_slip_ratio = absf(lateral_speed) / maxf(speed, WorldScale.metres(1.0))

	var forward := -state.transform.y.normalized()
	var lateral := state.transform.x.normalized()
	var ground_authority := 0.0 if _airborne else 1.0
	var surface_engine := tuning.off_track_engine_multiplier if _surface_type == SurfaceQuery.SurfaceType.OFF_TRACK else 1.0
	var longitudinal_acceleration := tuning.engine_force * _input_state.throttle * surface_engine * ground_authority / tuning.mass_kg
	if _input_state.brake > 0.0 and not _airborne:
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
	if not _airborne:
		# Climbing a face costs speed, descending one returns it.
		longitudinal_acceleration -= tuning.gravity * _ground_gradient.dot(forward)
	world_velocity += forward * longitudinal_acceleration * delta

	var updated_local := state.transform.basis_xform_inv(world_velocity)
	var updated_forward_speed := -updated_local.y
	var drag_rate := tuning.rolling_drag * _surface_drag * ground_authority
	# The surface factor stays the last multiplication, exactly where it was, so a grounded car's
	# drag is bit-identical to the model before the height channel rather than merely equal in
	# practice: float multiplication does not re-associate.
	var aero_surface := 1.0 if _airborne else _surface_drag
	var drag_amount := (drag_rate * absf(updated_forward_speed) + tuning.aerodynamic_drag * updated_forward_speed * updated_forward_speed * aero_surface) * delta
	updated_forward_speed = move_toward(updated_forward_speed, 0.0, drag_amount)
	world_velocity = forward * updated_forward_speed + lateral * updated_local.x

	var progressive_grip := _progressive_grip(_slip_ratio)
	var handbrake_grip := lerpf(1.0, tuning.handbrake_grip_multiplier, _input_state.handbrake)
	var recovery_grip := tuning.landing_recovery_grip_multiplier if _landing_recovery_remaining > 0.0 else 1.0
	var lateral_response := tuning.lateral_grip * _surface_grip * progressive_grip * handbrake_grip * recovery_grip * ground_authority
	var desired_lateral_change := -lateral_speed * (1.0 - exp(-lateral_response * delta))
	var lateral_change_limit := tuning.lateral_grip_acceleration * _surface_grip * handbrake_grip * recovery_grip * ground_authority * delta
	desired_lateral_change = clampf(desired_lateral_change, -lateral_change_limit, lateral_change_limit)
	world_velocity += lateral * desired_lateral_change

	if speed < WorldScale.metres(2.0) and _input_state.throttle == 0.0 and _input_state.brake == 0.0 and not _airborne:
		world_velocity = world_velocity.move_toward(Vector2.ZERO, tuning.low_speed_stabilization * delta)

	var steering_speed_factor := clampf(absf(updated_forward_speed) / maxf(tuning.steering_full_speed, 0.01), 0.12, 1.0)
	var travel_direction := signf(updated_forward_speed) if absf(updated_forward_speed) > tuning.stop_speed else 1.0
	var rotation_multiplier := lerpf(1.0, tuning.handbrake_rotation_multiplier, _input_state.handbrake)
	var steering_authority := tuning.airborne_steering_authority if _airborne else 1.0
	var target_angular_velocity := _input_state.steer * tuning.max_steering_rate * steering_speed_factor * travel_direction * rotation_multiplier * steering_authority
	var angular_response := tuning.steering_response * (1.0 + _input_state.handbrake * 0.45)
	state.angular_velocity = move_toward(state.angular_velocity, target_angular_velocity, angular_response * delta)
	if absf(_input_state.steer) < 0.02:
		state.angular_velocity = move_toward(state.angular_velocity, 0.0, tuning.steering_response * 0.65 * delta)
	state.angular_velocity = clampf(state.angular_velocity, -tuning.max_angular_speed, tuning.max_angular_speed)

	state.linear_velocity = world_velocity.limit_length(tuning.max_safe_speed)
	_update_height_channel(state, delta)
	_peak_speed = maxf(_peak_speed, state.linear_velocity.length())
	_local_velocity = state.transform.basis_xform_inv(state.linear_velocity)
	_slip_ratio = absf(_local_velocity.x) / maxf(state.linear_velocity.length(), WorldScale.metres(1.0))
	_update_safe_pose_checkpoint(state, delta)
	_update_auto_reset(state, delta)


func set_input_state(input_state: VehicleInputState) -> void:
	_input_state = input_state if input_state != null else VehicleInputState.new()


func set_surface_query(surface_query: SurfaceQuery) -> void:
	_surface_query = surface_query


## Also seats the car on the ground under it. The ride can only rise with the ground, so a car
## placed on raised ground has to start there rather than climb to it.
func set_height_query(height_query: HeightQuery) -> void:
	_height_query = height_query
	_height = _sample_ground_at(global_position).ground_height


func is_airborne() -> bool:
	return _airborne


func get_height() -> float:
	return _height


func get_vertical_velocity() -> float:
	return _vertical_velocity


func get_air_time() -> float:
	return _air_time


func get_landing_recovery_remaining() -> float:
	return _landing_recovery_remaining


## Seconds of the last flight that lasted at least air_time_notice_seconds, once; then 0.0. The
## session polls this to show a status line without the car knowing about the HUD.
func consume_air_time_notice() -> float:
	var notice := _air_time_notice
	_air_time_notice = 0.0
	return notice


## True once per landing. Presentation reads it for the dust burst.
func consume_landing_event() -> bool:
	var landed := _landed_this_tick
	_landed_this_tick = false
	return landed


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


## The pose a pending reset will land the car at. `request_safe_reset()` and an automatic reset
## both only set a flag consumed at the top of the next `_integrate_forces`, so a caller that needs
## to know where the car is about to be -- such as re-seeding checkpoint detection -- must read this
## rather than `global_position`, which still holds the pre-reset pose for one more physics tick.
func get_safe_reset_pose() -> Transform2D:
	return _safe_reset_pose


func set_auto_reset_enabled(enabled: bool) -> void:
	_auto_reset_enabled = enabled
	if not enabled:
		_off_track_stopped_elapsed = 0.0


## True once after an automatic reset, then false until the next one. The session polls this to
## show a status message without the car needing a reference to the HUD.
func consume_auto_reset_notice() -> bool:
	var notice := _auto_reset_notice
	_auto_reset_notice = false
	return notice


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
		"height_m": WorldScale.to_metres(_height),
		"vertical_speed_mps": WorldScale.to_metres(_vertical_velocity),
		"airborne": _airborne,
		"air_time": _air_time,
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


func _sample_ground(world_position: Vector2) -> void:
	var sample := _sample_ground_at(world_position)
	_ground_height = sample.ground_height
	_ground_gradient = sample.gradient


func _sample_ground_at(world_position: Vector2) -> HeightQuery.HeightSample:
	if _height_query == null:
		return HeightQuery.HeightSample.new()
	return _height_query.sample_at(world_position)


## The only place grounded and airborne meet. Grounded: ride the ground and decide whether the
## ballistic path has left it. Airborne: fall, and land when the path meets the ground again.
func _update_height_channel(state: PhysicsDirectBodyState2D, delta: float) -> void:
	var next_position := state.transform.origin + state.linear_velocity * delta
	var ahead := _sample_ground_at(next_position)
	if _airborne:
		_vertical_velocity -= tuning.gravity * delta
		_height += _vertical_velocity * delta
		_air_time += delta
		if _height <= ahead.ground_height:
			_land(state, ahead)
		return
	_landing_recovery_remaining = maxf(_landing_recovery_remaining - delta, 0.0)
	_vertical_velocity = state.linear_velocity.dot(_ground_gradient)
	var predicted := _height + _vertical_velocity * delta - 0.5 * tuning.gravity * delta * delta
	# Two ways to leave the ground, because a single-tick lookahead sees a drop-off and a crest
	# differently. Over a drop-off the ballistic path clears the ground ahead outright. A crest is a
	# break in the gradient that the path straddles, so that margin shrinks to nothing when a tick
	# happens to land on the crest itself; there the question is whether the ground ahead falls away
	# faster than one tick of gravity can pull the car onto it.
	var ground_rate_ahead := state.linear_velocity.dot(ahead.gradient)
	var clears_the_ground_ahead := predicted > ahead.ground_height + LIFT_OFF_TOLERANCE
	# The second conjunct rejects a height map's vertical walls -- every generated ramp has one at
	# its lateral boundary. Driving into one, the car is on flat ground (rate 0) while the face
	# behind the wall reads as falling away, which would otherwise open a flight onto ground that
	# is above the car. At a crest the margin bottoms out at -0.5 * g * delta^2, so the conjunct is
	# always satisfied there.
	var ground_falls_away := ground_rate_ahead < _vertical_velocity - tuning.gravity * delta and predicted > ahead.ground_height - LIFT_OFF_TOLERANCE
	if clears_the_ground_ahead or ground_falls_away:
		_airborne = true
		_air_time = 0.0
		_height = maxf(predicted, ahead.ground_height)
		return
	# Riding the ground follows it down as far as it goes, but rises only as fast as the ground
	# itself rises. On any continuous surface those are the same number, so a face is ridden
	# exactly; at a wall the rise is refused, which is the grounded half of the same defect the
	# conjunct above fixes for flight. Without it the car steps up the wall for free.
	var rise_limit := maxf(maxf(_vertical_velocity, ground_rate_ahead) * delta, 0.0)
	_height = minf(ahead.ground_height, _height + rise_limit)


func _land(state: PhysicsDirectBodyState2D, ground: HeightQuery.HeightSample) -> void:
	var ground_rate := state.linear_velocity.dot(ground.gradient)
	var impact := maxf(ground_rate - _vertical_velocity, 0.0)
	var kept := clampf(1.0 - tuning.landing_speed_loss * WorldScale.to_metres(impact), MIN_LANDING_SPEED_FRACTION, 1.0)
	state.linear_velocity *= kept
	_height = ground.ground_height
	_vertical_velocity = ground_rate
	_airborne = false
	_landed_this_tick = true
	if _air_time >= tuning.air_time_notice_seconds:
		_air_time_notice = _air_time
	_air_time = 0.0
	_landing_recovery_remaining = tuning.landing_recovery_seconds


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
	_height = _sample_ground_at(_safe_reset_pose.origin).ground_height
	_vertical_velocity = 0.0
	_airborne = false
	_air_time = 0.0
	_landing_recovery_remaining = 0.0


func _update_safe_pose_checkpoint(state: PhysicsDirectBodyState2D, delta: float) -> void:
	if _airborne or _ground_height > 0.0 or _landing_recovery_remaining > 0.0 or _surface_type != SurfaceQuery.SurfaceType.DIRT or _slip_ratio > tuning.safe_pose_max_slip or state.get_contact_count() > 0:
		_safe_pose_elapsed = 0.0
		return
	_safe_pose_elapsed += delta
	if _safe_pose_elapsed < tuning.safe_pose_interval:
		return
	_safe_pose_elapsed = 0.0
	_safe_reset_pose = state.transform
	_has_safe_reset_pose = true


## Two conditions, either sufficient, evaluated only while off-track: the car has stopped, or it
## has strayed far from the racing line. Returning to dirt clears both.
##
## The search radius passed below is the lost distance itself: TrackSurfaceMap answers from a grid
## queried with exactly that radius, so anything further away returns INF -- which is precisely the
## "lost" answer. Passing a smaller radius would report INF for every off-track position and fire
## the reset the moment the car left the track.
##
## The comparison is written as "greater than" rather than its negation so that INF still resolves
## as lost (INF > r is true) while a NAN from a degenerate provider fails safe by not resetting
## (NAN > r is false).
func _update_auto_reset(state: PhysicsDirectBodyState2D, delta: float) -> void:
	if not _auto_reset_enabled or _airborne or _surface_type != SurfaceQuery.SurfaceType.OFF_TRACK:
		_off_track_stopped_elapsed = 0.0
		return

	if state.linear_velocity.length() < tuning.auto_reset_stuck_speed:
		_off_track_stopped_elapsed += delta
	else:
		_off_track_stopped_elapsed = 0.0

	var stuck := _off_track_stopped_elapsed >= tuning.auto_reset_stuck_seconds
	var lost := false
	if _surface_query != null:
		var distance := _surface_query.distance_to_centerline(state.transform.origin, tuning.auto_reset_lost_distance)
		lost = distance > tuning.auto_reset_lost_distance

	if stuck or lost:
		_off_track_stopped_elapsed = 0.0
		_auto_reset_notice = true
		_reset_requested = true


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
