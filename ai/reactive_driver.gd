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
##   further). Stuck behind a car that has stopped in its path, it goes round it rather than backing
##   out (#61); see PASS_BLOCKED_GAP_M.
##
## ## What it believes about its car
##
## A driver holds no car and no tuning -- the seam refuses both -- so what it knows about its own car
## is written below as beliefs, in metres. They are deliberately a little pessimistic against
## data/default_vehicle_tuning.tres: a driver that thinks its car stops harder than it does runs off.
##
## ## Skill (#59)
##
## One number per car in [0, 1), drawn from its own seed stream (`AiDriver.SKILL_STREAM`). It turns
## three dials together: how far ahead the driver senses, how hard it will corner, and how often it
## errs. At 1.0 every dial is where #58 left it, so a driver pinned to 1.0 with mistakes off IS #58's
## driver, control for control; lower skill only ever looks less far and corners more gently, both of
## which make it slower and not less safe. `set_skill` pins it.
##
## ## Mistakes (#59)
##
## A deliberate mistake and a bug look identical from outside, so no mistake here is emergent. Each is
##
## - **seeded**: mistake n's kind, size and timing gap are a pure function of the car's mistake stream
##   (`AiDriver.MISTAKE_STREAM`) and n -- see `mistake_plan`. No global RNG, clock or frame count;
## - **typed and logged**: `active_mistake` says what it is doing this tick, and `mistake_log` records
##   every mistake committed, the tick it began and the tick it ended;
## - **suppressible**: `mistakes_enabled` is false unless someone sets it. Off, nothing below runs:
##   no draw is made, no clock advances and no control is touched.
##
## Three kinds, each small and bounded to stay survivable:
##
## - **LATE_BRAKE**: where a corner asks for braking, the corner's brake is withheld for `amount`
##   metres of travel. Only the corner's: never the brake for a rival, an obstacle, a road edge or the
##   limit of vision.
## - **WIDE_LINE**: through a bend, the steering aims `amount` metres to the outside of the centreline.
##   The aim is capped WIDE_LINE_EDGE_KEEP_M from the edge, and -- because the car overshoots its aim
##   through a bend -- the mistake also ends the moment the car's own centre comes that close to
##   either edge, and cannot begin there. The bound the car achieves is measured, not promised: see
##   tests/skill_and_mistakes_test.gd.
## - **NEEDLESS_LIFT**: on a clear straight at speed, the throttle comes off for `seconds`.
##
## A mistake is only begun while the car is racing cleanly -- on the road, aligned with it, at speed,
## not recovering -- and the clock between mistakes only runs then. Leaving that state ends a mistake
## at once, so none can compound a recovery.

enum Mode { RACE, REVERSE }
enum Mistake { NONE, LATE_BRAKE, WIDE_LINE, NEEDLESS_LIFT }

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
## Seconds into a reversal by which the car must be rolling backwards at REVERSE_PROGRESS_SPEED_M at
## least, or the reversal ends. The car's reverse engages 0.4 s after it stops; on grass, starting from a
## creep forwards, a traced reversal was rolling back at about 10 px/s (0.8 m/s) by 0.8 s. A car backing
## into another stands still or is pushed forwards. A bound of STALL_SPEED_M (1 m/s) here, the first
## version, ended that grass reversal and left the car stuck: measured on reactive_driver_test's seed-0
## off-road start under --break-brake-distance, 141 ticks of the stuck rule's 120.
const REVERSE_PROGRESS_SECONDS := 0.8
const REVERSE_PROGRESS_SPEED_M := 0.25

## Going round a car stopped in the path (#61). A stall with a rival in the lane no further than
## PASS_BLOCKED_GAP_M ahead is a blocked stall: nothing in front of the car will ever move it on, and
## backing out only to drive up to the same car again cycles for as long as that car stays put. So the
## car goes round it forwards, without reversing: it aims PASS_CLEARANCE_M to the side of the rival with
## more road -- beside whatever rival is nearest ahead within PASS_TRACK_M -- never nearer an edge than
## PASS_EDGE_KEEP_M, at no more than PASS_SPEED_M. The pass ends once no rival has been that close ahead
## for PASS_CLEAR_SECONDS, or after PASS_TIMEOUT_SECONDS of racing. Only a second blocked stall while
## passing reverses, the nose swinging toward the other side, and passes on that side.
const PASS_BLOCKED_GAP_M := 8.0
const PASS_CLEARANCE_M := 4.0
const PASS_TRACK_M := 12.0
const PASS_EDGE_KEEP_M := 1.5
const PASS_SPEED_M := 8.0
const PASS_CLEAR_SECONDS := 1.0
const PASS_TIMEOUT_SECONDS := 6.0

## Skill 0.0, the least skilled driver there is. Skill 1.0 is LOOK_AHEAD_M and
## CORNERING_ACCELERATION_M above; between the two every dial moves linearly.
const LOWEST_SKILL_LOOK_AHEAD_M := 36.0
const LOWEST_SKILL_CORNERING_M := 12.0
## Mean seconds of clean racing between one mistake ending and the next being chosen, at skill 0.0 and
## at 1.0. The gap actually drawn is between half and one and a half times the mean.
const LOWEST_SKILL_MISTAKE_GAP_S := 10.0
const HIGHEST_SKILL_MISTAKE_GAP_S := 30.0

## Racing cleanly, for the purpose of mistakes: at least this fast, as well as on the road, aligned
## and not recovering.
const MISTAKE_MIN_SPEED_M := 12.0
## Seconds of clean racing an armed mistake waits for its moment before it lapses and the next is
## drawn. Without it one late brake on a circuit whose corners never ask a slow driver to brake would
## wait all race, and that driver would stop erring at all.
const MISTAKE_PATIENCE_S := 15.0
## LATE_BRAKE: metres travelled past the point the corner asked for braking before it brakes.
const LATE_BRAKE_MIN_M := 4.0
const LATE_BRAKE_MAX_M := 12.0
## WIDE_LINE: metres outside the centreline, for how long, and the least bend it is taken on. The
## keep is how near the edge the aim may be, and how near the car's centre may come before the
## mistake lets go. It was 3 m, and that bounded only the aim: through a bend the car overshoots its
## aim by about 3 m, and forced wide lines put the car's centre 0.6-1.7 px from the edge of the
## narrowest roads. 6 m is the 3 m plus the overshoot.
const WIDE_LINE_MIN_M := 2.0
const WIDE_LINE_MAX_M := 5.0
const WIDE_LINE_MIN_SECONDS := 1.5
const WIDE_LINE_MAX_SECONDS := 3.0
const WIDE_LINE_MIN_TURN := 0.15
const WIDE_LINE_EDGE_KEEP_M := 6.0
## NEEDLESS_LIFT: for how long, and the least speed it is done at.
const NEEDLESS_LIFT_MIN_SECONDS := 0.4
const NEEDLESS_LIFT_MAX_SECONDS := 1.2
const NEEDLESS_LIFT_MIN_SPEED_M := 18.0

## A draw from a stream: `DomainSeed` yields fifteen hex digits, so dividing by 16^15 gives [0, 1).
const STREAM_RANGE := 1152921504606846976.0
## The four draws each mistake takes from the stream, as `DomainSeed.child(stream, n, draw)`.
const DRAW_GAP := 0
const DRAW_KIND := 1
const DRAW_AMOUNT := 2
const DRAW_SECONDS := 3

## Whether this driver makes deliberate mistakes. False unless someone sets it: a flawless driver is
## the default everywhere that is not about mistakes.
var mistakes_enabled: bool = false

var skill: float:
	get:
		return _skill
## The mistake being committed this tick, a Mistake. NONE whenever mistakes are off.
var active_mistake: int:
	get:
		return _active if _mistakes_on() else Mistake.NONE
## How many mistakes have been drawn from the stream so far, and how many of those lapsed without
## finding a moment. Both stay 0 while mistakes are off.
var mistakes_planned: int:
	get:
		return _planned
var mistakes_lapsed: int:
	get:
		return _lapsed

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
## How many times a blocked stall sent this driver round the car in front, and whether it is now.
var passes: int:
	get:
		return _passes
var passing: bool:
	get:
		return _pass_side != 0.0

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
## Going round a stopped car: the side (-1 the road's left, +1 its right, 0 not passing), the offset
## aimed at, seconds of racing spent passing, and seconds since a rival was last close ahead.
var _pass_side: float = 0.0
var _pass_target: float = 0.0
var _pass_time: float = 0.0
var _pass_clear_time: float = 0.0
## Whether a rival sat in the lane close ahead at any tick of the stall now being timed.
var _stalled_behind_a_rival: bool = false
var _passes: int = 0

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

## Skill, and the two dials it sets. See `set_skill`.
var _skill: float = 1.0
var _look_ahead_m: float = LOOK_AHEAD_M
var _cornering_m: float = CORNERING_ACCELERATION_M

## Mistakes. `_tick` counts the ticks this driver has driven with senses: the "when" in the log.
var _mistake_seed: int = 0
var _tick: int = 0
var _planned: int = 0
var _lapsed: int = 0
## The next mistake, drawn but not yet begun: the clean racing still to run before it is armed, and
## once armed, how long it has waited for its moment.
var _next_kind: int = Mistake.NONE
var _next_amount: float = 0.0
var _next_seconds: float = 0.0
var _next_gap: float = 0.0
var _armed: bool = false
var _waited: float = 0.0
## The mistake under way, how long it has run and how far the car has travelled in it.
var _active: int = Mistake.NONE
var _active_amount: float = 0.0
var _active_seconds: float = 0.0
var _active_time: float = 0.0
var _active_distance: float = 0.0
## One entry per mistake committed: n (its number in the plan), kind, tick, amount, seconds, and
## until (the first tick it no longer acted on; -1 while it is under way).
var _log: Array[Dictionary] = []


func _identity_fixed() -> void:
	_mistake_seed = _mistake_stream_seed()
	set_skill(_skill_from_seed())


## The car's mistake stream. `--break-mistake-seed` derives it without the car's index.
func _mistake_stream_seed() -> int:
	return _stream_seed(car_index, MISTAKE_STREAM)


## Skill in [0, 1), from the car's skill stream. `--break-skill-spread` collapses it to a constant.
func _skill_from_seed() -> float:
	return float(_stream_seed(car_index, SKILL_STREAM)) / STREAM_RANGE


## Pins the skill, clamped to [0, 1], and the dials it turns. Each dial is its skill-1.0 value less
## the skill still missing times its span, so at exactly 1.0 it is the constant #58 was reviewed at,
## with no arithmetic between them that could round.
func set_skill(value: float) -> void:
	_skill = clampf(value, 0.0, 1.0)
	var missing := 1.0 - _skill
	_look_ahead_m = LOOK_AHEAD_M - missing * (LOOK_AHEAD_M - LOWEST_SKILL_LOOK_AHEAD_M)
	_cornering_m = CORNERING_ACCELERATION_M - missing * (CORNERING_ACCELERATION_M - LOWEST_SKILL_CORNERING_M)


## m/s^2 of cornering this driver will ask for, at its skill.
func cornering_belief_m() -> float:
	return _cornering_m


## Mean seconds of clean racing between mistakes, at this driver's skill.
func mean_mistake_gap() -> float:
	return HIGHEST_SKILL_MISTAKE_GAP_S - (1.0 - _skill) * (HIGHEST_SKILL_MISTAKE_GAP_S - LOWEST_SKILL_MISTAKE_GAP_S)


## Mistake n as the stream decides it, before any road has had a say: its kind, its amount (metres
## for LATE_BRAKE and WIDE_LINE, 0 for NEEDLESS_LIFT), its seconds (0 for LATE_BRAKE, which lasts
## `amount` metres of travel), and the gap of clean racing before it is armed. Kind, amount and
## seconds come from the stream alone; only the gap reads skill. Pure: asking changes nothing.
func mistake_plan(n: int) -> Dictionary:
	var kind: int = Mistake.LATE_BRAKE + mini(int(_draw(n, DRAW_KIND) * 3.0), 2)
	var amount_draw := _draw(n, DRAW_AMOUNT)
	var seconds_draw := _draw(n, DRAW_SECONDS)
	var amount := 0.0
	var seconds := 0.0
	match kind:
		Mistake.LATE_BRAKE:
			amount = lerpf(LATE_BRAKE_MIN_M, LATE_BRAKE_MAX_M, amount_draw)
		Mistake.WIDE_LINE:
			amount = lerpf(WIDE_LINE_MIN_M, WIDE_LINE_MAX_M, amount_draw)
			seconds = lerpf(WIDE_LINE_MIN_SECONDS, WIDE_LINE_MAX_SECONDS, seconds_draw)
		Mistake.NEEDLESS_LIFT:
			seconds = lerpf(NEEDLESS_LIFT_MIN_SECONDS, NEEDLESS_LIFT_MAX_SECONDS, seconds_draw)
	return {"kind": kind, "amount": amount, "seconds": seconds, "gap": mean_mistake_gap() * (0.5 + _draw(n, DRAW_GAP))}


## One draw, in [0, 1), from the car's mistake stream: draw `draw` of mistake `n`.
func _draw(n: int, draw: int) -> float:
	return float(DomainSeed.child(_mistake_seed, n, draw)) / STREAM_RANGE


## Every mistake committed so far, oldest first, as copies.
func mistake_log() -> Array[Dictionary]:
	var copy: Array[Dictionary] = []
	for entry in _log:
		copy.append(entry.duplicate())
	return copy


static func mistake_name(kind: int) -> String:
	match kind:
		Mistake.LATE_BRAKE:
			return "late brake"
		Mistake.WIDE_LINE:
			return "wide line"
		Mistake.NEEDLESS_LIFT:
			return "needless lift"
	return "none"


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
	return WorldScale.metres(_look_ahead_m)


func drive(delta: float) -> VehicleInputState:
	var controls := VehicleInputState.new()
	if not _has_senses:
		return controls
	var speed := -_local_velocity.y
	_count_episodes()
	_watch_the_ground_ahead(delta, speed)
	if _mistakes_on():
		_decide_mistakes(delta, speed)
	elif _active != Mistake.NONE:
		# Switched off mid-mistake: it ends here, logged, rather than waiting, stale, to resume.
		_end_mistake()
	_tick += 1
	if _mode == Mode.REVERSE:
		_mode_time += delta
		# A reversal that has had time to get going and is still not rolling backwards is backing into
		# something it cannot see -- in a field, the car queued behind -- and holding it only wastes
		# the time the car has to get moving again.
		var backing_into_something := _mode_time >= REVERSE_PROGRESS_SECONDS and speed > -WorldScale.metres(REVERSE_PROGRESS_SPEED_M)
		if _mode_time < REVERSE_SECONDS and not backing_into_something:
			controls.set_controls(_reverse_steer, 0.0, 1.0, 0.0)
			return controls
		_mode = Mode.RACE
		_mode_time = 0.0
		_grace = RECOVERY_GRACE_SECONDS
	_follow_the_pass(delta)
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
	var offset := _lateral_offset
	if _committing(Mistake.WIDE_LINE):
		offset -= _wide_line_target()
	if _pass_side != 0.0:
		offset -= _pass_target
	var yaw := -_heading_term(_course_error(speed)) - _offset_term(offset, speed)
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
	margin = minf(margin, _visibility_margin(forward_speed))
	# A late brake withholds the corner's brake, and only the corner's, for its metres.
	if not _committing(Mistake.LATE_BRAKE):
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
	if _committing(Mistake.NEEDLESS_LIFT):
		throttle = 0.0
	return Vector2(throttle, brake)


## What it cannot see: the tightest corner it expects may start just past the horizon.
func _visibility_margin(speed: float) -> float:
	var tight_corner_speed := sqrt(WorldScale.metres(_cornering_m) * WorldScale.metres(TIGHTEST_CORNER_RADIUS_M))
	return _braking_margin(_look_ahead - WorldScale.metres(VISIBILITY_MARGIN_M), speed, tight_corner_speed)


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
	var corner_speed := sqrt(WorldScale.metres(_cornering_m) * radius)
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
	if not _rival_ahead or absf(_rival_path_offset() - _pass_shift()) > WorldScale.metres(RIVAL_LANE_HALF_WIDTH_M):
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
	if _pass_side != 0.0:
		cap = minf(cap, WorldScale.metres(PASS_SPEED_M))
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
		_stalled_behind_a_rival = false
		return
	if absf(speed) >= WorldScale.metres(STALL_SPEED_M):
		_stall_time = 0.0
		_stalled_behind_a_rival = false
		return
	_stall_time += delta
	# Remembered across the stall rather than read on its last tick: in a knot of cars the nearest one
	# ahead changes from tick to tick, and the one that stopped this car may be beside it by then.
	_stalled_behind_a_rival = _stalled_behind_a_rival or _blocked_by_a_rival()
	if _stall_time < STALL_SECONDS:
		return
	_stall_time = 0.0
	var blocked := _stalled_behind_a_rival and _rival_ahead
	_stalled_behind_a_rival = false
	if blocked and _pass_side == 0.0:
		# Stalled nose to tail: go round it forwards. Backing out first would back into whatever has
		# queued up behind, which the car cannot see.
		_start_a_pass(_side_with_more_road())
		_grace = RECOVERY_GRACE_SECONDS
		return
	_mode = Mode.REVERSE
	_mode_time = 0.0
	_reversals += 1
	var wanted := signf(yaw)
	if wanted == 0.0:
		wanted = -signf(_lateral_offset) if _lateral_offset != 0.0 else 1.0
	if blocked:
		# Stalled again while going round: that side did not work. Back out toward the other.
		_start_a_pass(-_pass_side)
		wanted = _pass_side
	else:
		_pass_side = 0.0
	# Rolling backwards, TopDownCar turns the other way for the same input, so the nose swings toward
	# `wanted` with the input reversed.
	_reverse_steer = -wanted


func _start_a_pass(side: float) -> void:
	_pass_side = side
	_pass_target = _pass_offset()
	_pass_time = 0.0
	_pass_clear_time = 0.0
	_passes += 1


## A rival in the lane, close enough in front that the car's own stall is its doing.
func _blocked_by_a_rival() -> bool:
	return _rival_ahead and _rival_distance <= WorldScale.metres(PASS_BLOCKED_GAP_M) and absf(_rival_path_offset()) <= WorldScale.metres(RIVAL_LANE_HALF_WIDTH_M)


## Where across the road the nearest rival ahead sits, as a lateral offset like the car's own.
func _rival_road_offset() -> float:
	return _lateral_offset + _rival_path_offset()


## +1 to go round on the road's right of the rival ahead, -1 on its left: whichever has more road.
func _side_with_more_road() -> float:
	var rival := _rival_road_offset()
	var half_width := 0.5 * (_left_margin + _right_margin)
	return 1.0 if half_width - rival >= half_width + rival else -1.0


## The offset the pass aims at: PASS_CLEARANCE_M to the chosen side of the rival ahead, kept
## PASS_EDGE_KEEP_M inside the road.
func _pass_offset() -> float:
	var half_width := 0.5 * (_left_margin + _right_margin)
	var room := maxf(half_width - WorldScale.metres(PASS_EDGE_KEEP_M), 0.0)
	return clampf(_rival_road_offset() + _pass_side * WorldScale.metres(PASS_CLEARANCE_M), -room, room)


## One racing tick of going round: aim beside whatever rival is close ahead, and let go once none has
## been for PASS_CLEAR_SECONDS, or the pass has taken PASS_TIMEOUT_SECONDS.
func _follow_the_pass(delta: float) -> void:
	if _pass_side == 0.0:
		return
	_pass_time += delta
	if _rival_ahead and _road_found and _rival_distance <= WorldScale.metres(PASS_TRACK_M):
		_pass_target = _pass_offset()
		_pass_clear_time = 0.0
	else:
		_pass_clear_time += delta
	if _pass_clear_time >= PASS_CLEAR_SECONDS or _pass_time >= PASS_TIMEOUT_SECONDS or not _road_found:
		_pass_side = 0.0


## While going round, a rival is judged against the line the car is aiming for, not the one it is on:
## the rival it is passing is beside that line by construction, and would otherwise hold it back.
func _pass_shift() -> float:
	return _pass_target - _lateral_offset if _pass_side != 0.0 else 0.0


## Counts a recovery each time the car enters a state it has to recover from.
func _count_episodes() -> void:
	if _off_road and not _was_off_road:
		_road_returns += 1
	_was_off_road = _off_road
	var wrong_way := _road_found and absf(_heading_error) > WRONG_WAY_ANGLE
	if wrong_way and not _was_wrong_way:
		_turn_arounds += 1
	_was_wrong_way = wrong_way


## The mistake machinery, one tick. Only ever called with mistakes on.
##
## A mistake under way runs until it is over or the car stops racing cleanly. Otherwise the next one
## is drawn from the stream, its gap of clean racing counts down, and once it has run out the mistake
## waits, armed, for the road to offer it: a corner that asks for braking, a bend, a clear straight.
## The stream decides what and how much; the road decides where. An armed mistake the road has not
## offered a moment in MISTAKE_PATIENCE_S lapses, and the next is drawn.
func _decide_mistakes(delta: float, speed: float) -> void:
	var clean := _racing_cleanly(speed)
	if _active != Mistake.NONE:
		_active_time += delta
		_active_distance += maxf(speed, 0.0) * delta
		if clean and not _mistake_is_over():
			return
		_end_mistake()
	if not clean:
		return
	if _next_kind == Mistake.NONE:
		_plan_next_mistake()
	if not _armed:
		_next_gap -= delta
		if _next_gap > 0.0:
			return
		_armed = true
	if _mistake_has_its_moment(_next_kind, speed):
		_commit_mistake()
		return
	_waited += delta
	if _waited >= MISTAKE_PATIENCE_S:
		_lapsed += 1
		_next_kind = Mistake.NONE


## On the road, aligned with it, at speed and not recovering. The only state a mistake is begun in,
## the only state the gap between mistakes counts down in, and the state leaving which ends one.
func _racing_cleanly(speed: float) -> bool:
	return _mode == Mode.RACE and _grace <= 0.0 and _pass_side == 0.0 and _road_found and not _off_road and absf(_heading_error) <= MISALIGNED_ANGLE and speed >= WorldScale.metres(MISTAKE_MIN_SPEED_M)


func _plan_next_mistake() -> void:
	var plan := mistake_plan(_planned)
	_planned += 1
	_next_kind = plan.kind
	_next_amount = plan.amount
	_next_seconds = plan.seconds
	_next_gap = plan.gap
	_armed = false
	_waited = 0.0


## Where the road offers the armed mistake a place to happen.
##
## - A late brake needs a corner that is asking for braking now, and is what asks for it: a corner
##   the limit of vision already brakes harder for would hide the mistake.
## - A wide line needs a bend worth the name.
## - A needless lift needs no reason to lift: a straight, at speed, nothing in the way.
func _mistake_has_its_moment(kind: int, speed: float) -> bool:
	var forward_speed := maxf(speed, 0.0)
	var turn := absf(_road_turn())
	match kind:
		Mistake.LATE_BRAKE:
			var corner := _corner_margin(forward_speed)
			return corner < 0.0 and corner <= _visibility_margin(forward_speed)
		Mistake.WIDE_LINE:
			return turn >= WIDE_LINE_MIN_TURN and turn <= WRONG_WAY_ANGLE and _nearest_edge() >= WorldScale.metres(WIDE_LINE_EDGE_KEEP_M)
		Mistake.NEEDLESS_LIFT:
			return speed >= WorldScale.metres(NEEDLESS_LIFT_MIN_SPEED_M) and turn < MIN_ROAD_TURN and _rival_margin() == INF and not _obstacle_ahead
	return false


func _commit_mistake() -> void:
	_active = _next_kind
	_active_amount = _next_amount
	_active_seconds = _next_seconds
	_active_time = 0.0
	_active_distance = 0.0
	_log.append({"n": _planned - 1, "kind": _active, "tick": _tick, "amount": _active_amount, "seconds": _active_seconds, "until": -1})
	_next_kind = Mistake.NONE
	_armed = false


## A late brake is over once the car has travelled its metres; the others last their seconds. A wide
## line is also over the moment the car itself -- not the line it aims at -- comes within
## WIDE_LINE_EDGE_KEEP_M of an edge: the aim is capped the same distance from the edge, but the car
## overshoots its aim through a bend, and it is the car that must stay on the road.
func _mistake_is_over() -> bool:
	if _active == Mistake.LATE_BRAKE:
		return _active_distance >= WorldScale.metres(_active_amount)
	if _active == Mistake.WIDE_LINE and _nearest_edge() < WorldScale.metres(WIDE_LINE_EDGE_KEEP_M):
		return true
	return _active_time >= _active_seconds


## How far the car's centre is from the nearer road edge.
func _nearest_edge() -> float:
	return minf(_left_margin, _right_margin)


## `until` is the first tick the mistake no longer acts on: it acted on ticks [tick, until).
func _end_mistake() -> void:
	_log[_log.size() - 1]["until"] = _tick
	_active = Mistake.NONE


func _committing(kind: int) -> bool:
	return _mistakes_on() and _active == kind


## The one switch, read in the three places a mistake could show: deciding, acting, and the
## `active_mistake` getter.
func _mistakes_on() -> bool:
	return mistakes_enabled


## The offset a wide line aims at: its amount to the outside of the bend -- left of the centreline
## when the road turns right -- but the AIM is never nearer the edge than WIDE_LINE_EDGE_KEEP_M. The
## car itself is bounded separately, in `_mistake_is_over`. On a straight, or a reading from another
## stretch of the lap, the centreline.
func _wide_line_target() -> float:
	var turn := _road_turn()
	if absf(turn) < MIN_ROAD_TURN or absf(turn) > WRONG_WAY_ANGLE:
		return 0.0
	var half_width := 0.5 * (_left_margin + _right_margin)
	var room := maxf(half_width - WorldScale.metres(WIDE_LINE_EDGE_KEEP_M), 0.0)
	return -signf(turn) * minf(WorldScale.metres(_active_amount), room)
