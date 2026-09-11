class_name ReactiveDriver
extends AiDriver

## Senses in, controls out, one tick at a time.
##
## This driver has no route, no waypoint list and no memory of the lap. Each tick it reads the
## DriverSenses it was handed and decides. What it keeps between ticks is only what a driver keeps:
## whether it is backing out of something, how long it has been stuck, and which way it chose to
## turn round. Nothing it holds says where on the circuit it is.
##
## ## The four jobs
##
## - **Steer** toward where the road goes, with two terms: one for heading error and one for lateral
##   offset. Offset alone is an undamped spring -- the car overshoots the centreline and swings back
##   for ever -- and heading alone parks the car parallel to the road wherever it happens to be. The
##   heading term is the damping; see `_steer_toward_road`.
## - **Slow down** for what it senses: a corner in the road ahead, a road edge closing across the
##   nose, a rival it is catching, an obstacle in its path, and the limit of what it can see. Every
##   one of those is the same question -- can I shed enough speed in the distance I have -- and it is
##   answered by one function, `_braking_distance`, whose answer grows with the square of speed.
## - **Lift** when the ground ahead falls away, so the car does not leave a crest on full throttle.
##   "Falls away" is a rate, not a level: how fast the ground ahead drops relative to the ground under
##   the car as the car moves. A ramp's face makes it jump; terrain, whose slopes change over hundreds
##   of pixels, almost never gets there. A level would not do: across a 600 px horizon a plain
##   downhill falls further than a ramp's 9 px crest, and a ramp on rising ground can read level.
## - **Recover** from being stuck (reverse and swing the nose), from facing the wrong way (commit to
##   one direction of turn and hold it), from being off the road (the steering already heads back,
##   and a speed cap gives the grass's poor grip a chance), and from losing the road entirely (look
##   further).
##
## ## What it believes about its car
##
## A driver holds no car and no tuning -- the seam refuses both -- so what it knows about its own car
## is written below as beliefs, in metres. They are deliberately a little pessimistic against
## data/default_vehicle_tuning.tres: a driver that thinks its car stops harder than it does runs off.

enum Mode { RACE, REVERSE }

## m/s^2. The car brakes at 15.5 on dirt (brake_force / mass_kg).
const BRAKE_DECELERATION_M := 12.0
## m/s^2 of cornering it will ask of the tyres. Dirt holds 22 before the lateral limit.
const CORNERING_ACCELERATION_M := 13.6
## rad/s at full lock once steering has full authority, and the speed at which it gets there. Below
## that speed the car's yaw rate scales with speed (TopDownCar's steering_speed_factor).
const FULL_LOCK_YAW_RATE := 1.75
const FULL_AUTHORITY_SPEED_M := 18.0
const MIN_AUTHORITY_FRACTION := 0.12
## m/s. Below this the car reads as stopped and its steering acts as if rolling forward.
const STOPPED_SPEED_M := 0.75
## The tightest corner it expects any road to have, 16 m. What it assumes may be waiting just past
## the edge of what it can see.
const TIGHTEST_CORNER_RADIUS_M := 16.0

## How far ahead it looks. The main tunable: it bounds what the driver can see, so it bounds how fast
## the driver can safely go.
const LOOK_AHEAD_M := 48.0
## When the road is not found at all, look this far instead, until it is.
const LOST_LOOK_AHEAD_M := 120.0

## Steering, as a yaw rate asked for. With yaw = -HEADING_GAIN * heading - OFFSET_GAIN * offset / v,
## the offset obeys offset'' + HEADING_GAIN * offset' + OFFSET_GAIN * offset = 0 at every speed:
## critically damped when HEADING_GAIN^2 = 4 * OFFSET_GAIN, at a natural frequency of 1.2 rad/s.
const HEADING_GAIN := 2.4
const OFFSET_GAIN := 1.44
## The steepest angle, in radians, the offset term will ask the car to close on the centreline at.
const MAX_APPROACH_ANGLE := 0.6
## The offset term divides by speed; below this it stops growing.
const OFFSET_SPEED_FLOOR_M := 4.0
## How much of the road's turn across the look-ahead is steered for in advance.
const CURVE_FEEDFORWARD := 0.8
## A road that turns less than this across the look-ahead is read as straight, and no bend is read
## as shorter than MIN_BEND_M.
const MIN_ROAD_TURN := 0.03
const MIN_BEND_M := 1.0

## Seconds between deciding to brake and the brakes biting, as distance per unit of speed to shed.
const REACTION_SECONDS := 0.15
## Distance kept in hand against the limit of vision, and against the edge.
const VISIBILITY_MARGIN_M := 2.0
const EDGE_MARGIN_M := 1.0
## The speed it wants in hand when its nose is about to cross an edge: slow enough to turn away.
const EDGE_TURN_SPEED_M := 14.0
## Margins, in metres of distance, over which throttle fades in and brake fades out.
const THROTTLE_BAND_M := 2.0
const BRAKE_BAND_M := 2.0
## m/s over which a speed cap fades the throttle out.
const SPEED_BAND_M := 1.5

## A rival counts as in the way when it is within this of the nose's line, and is followed at this
## gap. The car's body is about 2.4 m wide.
const RIVAL_LANE_HALF_WIDTH_M := 3.0
const FOLLOW_GAP_M := 6.0
## Distance kept from a tree, a rock or the play area's boundary.
const OBSTACLE_CLEARANCE_M := 4.0

## Speed caps. On grass the tyres hold a third of what dirt gives. Misaligned, the car slows so the
## steering can bring it round; wrong way round, it turns on the spot as near as the car allows.
const OFF_ROAD_SPEED_M := 12.0
const MISALIGNED_ANGLE := 0.35
const FULLY_MISALIGNED_ANGLE := 0.9
const SLIGHTLY_MISALIGNED_SPEED_M := 20.0
const MISALIGNED_SPEED_M := 10.0
const WRONG_WAY_ANGLE := PI * 0.5
const TURN_AROUND_SPEED_M := 5.0

## Lift: the ground ahead falling away, relative to the ground under the car, by more than this per
## pixel travelled, at more than this speed, releases the throttle. A ramp face is 0.06; measured
## over tuning laps, climbing one reads 0.043 to 0.073 and terrain rarely passes 0.03.
const LIFT_SLOPE_BREAK := 0.03
const LIFT_MIN_SPEED_M := 20.0

## Stuck: slower than this for this long while racing. Then reverse for REVERSE_SECONDS, swinging the
## nose toward the road, and give the car RECOVERY_GRACE_SECONDS to get going before judging again.
const STALL_SPEED_M := 1.0
const STALL_SECONDS := 0.5
const REVERSE_SECONDS := 1.6
const RECOVERY_GRACE_SECONDS := 1.0

var mode: int:
	get:
		return _mode
## Every recovery this driver has started, by kind, and in total.
var reversals: int:
	get:
		return _reversals
var turn_arounds: int:
	get:
		return _turn_arounds
var road_returns: int:
	get:
		return _road_returns
var recoveries: int:
	get:
		return _reversals + _turn_arounds + _road_returns

var _mode: int = Mode.RACE
var _mode_time: float = 0.0
var _stall_time: float = 0.0
var _grace: float = 0.0
var _reverse_steer: float = 0.0
## -1 or +1 once a turn-around has picked its direction; 0 otherwise. Held so a car facing exactly
## backwards does not flip between left and right as heading_error crosses +PI / -PI.
var _turn_around_direction: float = 0.0
var _was_off_road: bool = false
## Last tick's height_change_ahead, for the rate the lift reads. The only sense remembered a tick.
var _previous_height_change: float = 0.0
var _has_previous_height_change: bool = false
var _ground_falling_away: bool = false
var _was_wrong_way: bool = false
var _reversals: int = 0
var _turn_arounds: int = 0
var _road_returns: int = 0

## The senses this tick, copied out of the DriverSenses as plain values. Only what the driver reads.
var _has_senses: bool = false
var _road_found: bool = false
var _lateral_offset: float = 0.0
var _heading_error: float = 0.0
var _left_margin: float = 0.0
var _right_margin: float = 0.0
var _road_ahead_found: bool = false
var _road_ahead_offset: float = 0.0
var _road_ahead_heading: float = 0.0
var _off_road: bool = false
var _height_change_ahead: float = 0.0
var _rival_ahead: bool = false
var _rival_offset: Vector2 = Vector2.ZERO
var _rival_distance: float = 0.0
var _rival_velocity: Vector2 = Vector2.ZERO
var _obstacle_ahead: bool = false
var _obstacle_distance: float = 0.0
var _local_velocity: Vector2 = Vector2.ZERO
var _look_ahead: float = 0.0


func perceive(senses: DriverSenses) -> void:
	_has_senses = true
	_road_found = senses.road_found
	_lateral_offset = senses.lateral_offset
	_heading_error = senses.heading_error
	_left_margin = senses.distance_to_left_edge
	_right_margin = senses.distance_to_right_edge
	_road_ahead_found = senses.road_ahead_found
	_road_ahead_offset = senses.road_ahead_lateral_offset
	_road_ahead_heading = senses.road_ahead_heading_error
	_off_road = senses.surface_type == SurfaceQuery.SurfaceType.OFF_TRACK
	_height_change_ahead = senses.height_change_ahead
	_rival_ahead = senses.has_rival_ahead
	_rival_offset = senses.rival_offset
	_rival_distance = senses.rival_distance
	_rival_velocity = senses.rival_relative_velocity
	_obstacle_ahead = senses.has_obstacle_ahead
	_obstacle_distance = senses.obstacle_distance
	_local_velocity = senses.local_velocity
	_look_ahead = senses.look_ahead


func sensing_horizon() -> float:
	if _has_senses and not _road_found:
		return WorldScale.metres(LOST_LOOK_AHEAD_M)
	return WorldScale.metres(LOOK_AHEAD_M)


func drive(delta: float) -> VehicleInputState:
	var controls := VehicleInputState.new()
	if not _has_senses:
		return controls
	var speed := -_local_velocity.y
	_count_episodes()
	_watch_the_ground_ahead(delta, speed)
	if _mode == Mode.REVERSE:
		_mode_time += delta
		if _mode_time < REVERSE_SECONDS:
			controls.set_controls(_reverse_steer, 0.0, 1.0, 0.0)
			return controls
		_mode = Mode.RACE
		_mode_time = 0.0
		_grace = RECOVERY_GRACE_SECONDS
	var yaw := _steer_toward_road(speed)
	var pedals := _pedals(speed)
	controls.set_controls(_steer_for_yaw(yaw, speed), pedals.x, pedals.y, 0.0)
	_watch_for_a_stall(delta, speed, yaw)
	return controls


## The two steering terms, as a yaw rate. Positive yaw turns the nose to the right.
##
## Wrong way round, the terms are set aside for a committed full-lock turn in one direction: near
## +/-PI the sign of heading_error is a coin toss, and following it tick by tick would dither.
func _steer_toward_road(speed: float) -> float:
	if not _road_found:
		return 0.0
	if absf(_heading_error) > WRONG_WAY_ANGLE:
		if _turn_around_direction == 0.0:
			_turn_around_direction = -signf(_heading_error) if _heading_error != 0.0 else 1.0
		return _turn_around_direction * FULL_LOCK_YAW_RATE
	_turn_around_direction = 0.0
	var yaw := -_heading_term(_course_error(speed)) - _offset_term(_lateral_offset, speed)
	return yaw + CURVE_FEEDFORWARD * _road_turn_rate(speed)


## The heading error of the car's direction of travel rather than its nose. They differ by the slip
## angle: a car sliding wide points at the road while it travels off it, and damping the nose alone
## steers a slide as if it were not happening. At walking pace the velocity's direction means
## nothing, so there it is the nose.
func _course_error(speed: float) -> float:
	if speed < WorldScale.metres(OFFSET_SPEED_FLOOR_M):
		return _heading_error
	return wrapf(_heading_error + atan2(_local_velocity.x, -_local_velocity.y), -PI, PI)


## Yaw asked for per radian of heading error: the damping. `--break-steer-heading` drops it.
func _heading_term(heading_error: float) -> float:
	return HEADING_GAIN * heading_error


## Yaw asked for by lateral offset, as the approach angle it would close on the centreline at,
## bounded so a car far off the road heads back at a sane angle rather than straight across.
func _offset_term(lateral_offset: float, speed: float) -> float:
	var closing_speed := maxf(absf(speed), WorldScale.metres(OFFSET_SPEED_FLOOR_M))
	var approach := clampf(OFFSET_GAIN * lateral_offset / (HEADING_GAIN * closing_speed), -MAX_APPROACH_ANGLE, MAX_APPROACH_ANGLE)
	return HEADING_GAIN * approach


## How fast the road ahead is turning, as the yaw rate that would follow it at this speed: the turn
## between the road here and the road at the look-ahead point, spread over the look-ahead. The car's
## own heading cancels out of `heading - heading_ahead`, so this adds no heading term of its own.
func _road_turn_rate(speed: float) -> float:
	var turn := _road_turn()
	if absf(turn) < MIN_ROAD_TURN or absf(turn) > WRONG_WAY_ANGLE or _look_ahead <= 0.0:
		return 0.0
	return maxf(speed, 0.0) * turn / _look_ahead


## Radians the road turns between the car and the look-ahead point. Positive: it turns right.
func _road_turn() -> float:
	if not (_road_found and _road_ahead_found):
		return 0.0
	return wrapf(_heading_error - _road_ahead_heading, -PI, PI)


## A yaw rate as a steering input: divided by what full lock gives at this speed, and reversed when
## the car is rolling backwards, where TopDownCar turns the other way for the same input.
func _steer_for_yaw(yaw: float, speed: float) -> float:
	var authority := FULL_LOCK_YAW_RATE * clampf(absf(speed) / WorldScale.metres(FULL_AUTHORITY_SPEED_M), MIN_AUTHORITY_FRACTION, 1.0)
	var steer := clampf(yaw / authority, -1.0, 1.0)
	if speed < -WorldScale.metres(STOPPED_SPEED_M):
		steer = -steer
	return steer


## Distance the car covers shedding speed from one speed down to a lower one, at the braking the
## driver believes in, plus the distance it covers before the brakes bite. Grows with the square of
## speed: that is the whole reason braking has to start further out the faster the car is going.
## Only ever asked with `from_speed > to_speed` (see `_braking_margin`). `--break-brake-distance`
## replaces it with a constant.
func _braking_distance(from_speed: float, to_speed: float) -> float:
	var deceleration := WorldScale.metres(BRAKE_DECELERATION_M)
	return (from_speed * from_speed - to_speed * to_speed) / (2.0 * deceleration) + (from_speed - to_speed) * REACTION_SECONDS


## Distance to spare if the car must be down to `required` within `distance`: negative means braking
## should already have started. A car below the speed it needs has nothing to shed; its margin is
## the distance plus its headroom -- the braking belief run backwards from `required` down to its
## speed -- which shrinks to nothing as it reaches `required`, so the throttle fades out rather than
## switching off. The headroom is not a braking distance and the mutation leaves it alone.
func _braking_margin(distance: float, speed: float, required: float) -> float:
	if speed > required:
		return distance - _braking_distance(speed, required)
	var deceleration := WorldScale.metres(BRAKE_DECELERATION_M)
	return distance + (required * required - speed * speed) / (2.0 * deceleration)


## Throttle in x, brake in y.
##
## Every "slow down for" is a distance and a speed the car must be down to by then. The margin is the
## distance left over once the braking distance is spent; the tightest margin sets the pedals. On top
## of that sit speed caps for the car's state here and now, and the lift.
func _pedals(speed: float) -> Vector2:
	var margin := INF
	var forward_speed := maxf(speed, 0.0)
	var tight_corner_speed := sqrt(WorldScale.metres(CORNERING_ACCELERATION_M) * WorldScale.metres(TIGHTEST_CORNER_RADIUS_M))
	# What it cannot see: the tightest corner it expects may start just past the horizon.
	margin = minf(margin, _braking_margin(_look_ahead - WorldScale.metres(VISIBILITY_MARGIN_M), forward_speed, tight_corner_speed))
	margin = minf(margin, _corner_margin(forward_speed))
	margin = minf(margin, _edge_margin(forward_speed))
	margin = minf(margin, _rival_margin())
	if _obstacle_ahead:
		margin = minf(margin, _braking_margin(_obstacle_distance - WorldScale.metres(OBSTACLE_CLEARANCE_M), forward_speed, 0.0))
	var throttle := clampf(margin / WorldScale.metres(THROTTLE_BAND_M), 0.0, 1.0)
	var brake := clampf(-margin / WorldScale.metres(BRAKE_BAND_M), 0.0, 1.0)

	var cap := _speed_cap()
	var band := WorldScale.metres(SPEED_BAND_M)
	if speed > cap:
		throttle = 0.0
		brake = maxf(brake, clampf((speed - cap) / band, 0.0, 1.0))
	else:
		throttle = minf(throttle, clampf((cap - speed) / band, 0.0, 1.0))

	if _ground_falling_away:
		throttle = 0.0
	return Vector2(throttle, brake)


## How fast the ground ahead is dropping away from the ground under the car, per pixel travelled:
## the slope under the car minus the slope ahead, which is what a crest between the two looks like
## from the driver's seat.
func _watch_the_ground_ahead(delta: float, speed: float) -> void:
	_ground_falling_away = false
	var travelled := speed * delta
	if _has_previous_height_change and speed > WorldScale.metres(LIFT_MIN_SPEED_M) and travelled > 0.0:
		_ground_falling_away = (_previous_height_change - _height_change_ahead) / travelled > LIFT_SLOPE_BREAK
	_previous_height_change = _height_change_ahead
	_has_previous_height_change = true


## The corner in the road ahead, from two readings: how far the road turns across the look-ahead,
## and how far off the road the look-ahead point has ended up beyond what the car's own offset and
## heading put it. Read as a straight that becomes an arc, the two give where the arc starts and how
## tight it is: an arc of length b and radius R turns b / R and pushes a point on the straight's line
## b^2 / (2R) outside it. When the readings disagree about which way the road turns -- the point
## found a different stretch of the lap -- the turn is spread over the whole look-ahead instead.
func _corner_margin(speed: float) -> float:
	var turn := absf(_road_turn())
	if turn < MIN_ROAD_TURN:
		return INF
	var unexplained := _road_ahead_offset - _lateral_offset - _look_ahead * sin(_heading_error)
	var bend := _look_ahead
	if unexplained * _road_turn() < 0.0:
		bend = clampf(2.0 * absf(unexplained) / turn, WorldScale.metres(MIN_BEND_M), _look_ahead)
	var radius := maxf(bend / turn, WorldScale.metres(TIGHTEST_CORNER_RADIUS_M))
	var corner_speed := sqrt(WorldScale.metres(CORNERING_ACCELERATION_M) * radius)
	return _braking_margin(_look_ahead - bend, speed, corner_speed)


## A road edge closing across the nose: how far along the nose the car would cross the edge it is
## pointing at, were the road straight, against the speed it wants in hand to turn away before then.
func _edge_margin(speed: float) -> float:
	if not _road_found or absf(_heading_error) < MIN_ROAD_TURN or absf(_heading_error) > WRONG_WAY_ANGLE:
		return INF
	var edge := _right_margin if _heading_error > 0.0 else _left_margin
	if edge <= 0.0:
		return INF
	var along_nose := edge / sin(absf(_heading_error)) - WorldScale.metres(EDGE_MARGIN_M)
	return _braking_margin(along_nose, speed, WorldScale.metres(EDGE_TURN_SPEED_M))


## A rival in the car's path: the gap left over, beyond the following gap, once the closing speed is
## shed. Only the rival list answers this -- rivals are never on the obstacle ray. A rival ahead that
## is not being caught costs nothing until the car is inside the following gap; there the margin is
## what is left of the gap, so a car that has crept up at equal speed drops back rather than riding
## the rival's bumper. (The first version returned no constraint at all whenever the car was not
## closing, and a field of six drove nose to tail in contact for most of a lap.)
func _rival_margin() -> float:
	if not _rival_ahead or absf(_rival_path_offset()) > WorldScale.metres(RIVAL_LANE_HALF_WIDTH_M):
		return INF
	var gap := _rival_distance - WorldScale.metres(FOLLOW_GAP_M)
	# The rival's velocity minus this car's: a rival ahead (negative y) gets closer as that y grows.
	var closing := _rival_velocity.y
	if closing <= 0.0:
		return gap
	return _braking_margin(gap, closing, 0.0)


## How far the rival sits across the road from the line this car is driving, which runs with the road
## at the car's own offset. Measuring it off the nose line instead would say a car stopped in the
## middle of a bend is beside the path when it is squarely in it. The rival's offset is turned from
## the car's frame into the road's by the heading error, and the road's own bend is taken off: a road
## turning by `turn` across the look-ahead moves sideways by curvature * along^2 / 2 at a distance
## `along` down it.
func _rival_path_offset() -> float:
	var along_nose := -_rival_offset.y
	var across_nose := _rival_offset.x
	if not _road_found or absf(_heading_error) > WRONG_WAY_ANGLE:
		return across_nose
	var across_road := along_nose * sin(_heading_error) + across_nose * cos(_heading_error)
	var along_road := along_nose * cos(_heading_error) - across_nose * sin(_heading_error)
	var turn := _road_turn()
	if absf(turn) > WRONG_WAY_ANGLE or _look_ahead <= 0.0:
		return across_road
	return across_road - (turn / _look_ahead) * along_road * along_road * 0.5


func _speed_cap() -> float:
	var cap := INF
	if _off_road:
		cap = WorldScale.metres(OFF_ROAD_SPEED_M)
	if _road_found:
		var misalignment := absf(_heading_error)
		if misalignment > WRONG_WAY_ANGLE:
			cap = minf(cap, WorldScale.metres(TURN_AROUND_SPEED_M))
		elif misalignment > MISALIGNED_ANGLE:
			var blend := clampf((misalignment - MISALIGNED_ANGLE) / (FULLY_MISALIGNED_ANGLE - MISALIGNED_ANGLE), 0.0, 1.0)
			cap = minf(cap, lerpf(WorldScale.metres(SLIGHTLY_MISALIGNED_SPEED_M), WorldScale.metres(MISALIGNED_SPEED_M), blend))
	return cap


## Slower than walking pace for long enough while racing means something is in the way. Back out,
## steering so the nose swings the way the road steering wanted to go.
func _watch_for_a_stall(delta: float, speed: float, yaw: float) -> void:
	if _grace > 0.0:
		_grace -= delta
		_stall_time = 0.0
		return
	if absf(speed) >= WorldScale.metres(STALL_SPEED_M):
		_stall_time = 0.0
		return
	_stall_time += delta
	if _stall_time < STALL_SECONDS:
		return
	_stall_time = 0.0
	_mode = Mode.REVERSE
	_mode_time = 0.0
	_reversals += 1
	var wanted := signf(yaw)
	if wanted == 0.0:
		wanted = -signf(_lateral_offset) if _lateral_offset != 0.0 else 1.0
	# Rolling backwards, TopDownCar turns the other way for the same input, so the nose swings toward
	# `wanted` with the input reversed.
	_reverse_steer = -wanted


## Counts a recovery each time the car enters a state it has to recover from.
func _count_episodes() -> void:
	if _off_road and not _was_off_road:
		_road_returns += 1
	_was_off_road = _off_road
	var wrong_way := _road_found and absf(_heading_error) > WRONG_WAY_ANGLE
	if wrong_way and not _was_wrong_way:
		_turn_arounds += 1
	_was_wrong_way = wrong_way
