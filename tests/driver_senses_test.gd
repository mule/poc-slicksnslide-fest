extends SceneTree

## What a driver knows, and the proof that none of it is a world coordinate.
##
## The load-bearing check here is `_verify_senses_are_in_the_car_frame`. Everything else measures a
## single sense; that one places the same layout twice -- same road-relative pose, same rivals, same
## obstacles, same ground -- at two world positions 15,000 px apart and 137 degrees rotated, and
## demands every field of DriverSenses agree. A sensing pass that leaks a world-frame value cannot
## pass it, which is what the mutation below exists to demonstrate rather than assert in prose.
##
## Mutation:
##   -- --break-sense-frame   builds every pass with the car's basis replaced by an identity basis
##                            at the same origin, which is exactly "emit world-frame values instead
##                            of car-frame". The frame check fails and the script exits 1.
##
## The fixture worlds are built in a LOCAL frame and carried into the world by a placement
## transform: centerline, cars, rivals, obstacles and the height field all go through the same
## transform, so the two placements are congruent by construction and not by a number that happened
## to be typed twice.
##
## Nothing here drives. Cars are frozen, which holds both their pose and their velocity exactly as
## the fixture stated them, and a sensing pass integrates nothing, so every reading is of the pass
## alone with nothing moving underneath it. The only physics step in the file is the one
## `_build_cost_world` takes to get the track's own colliders into the broadphase -- see the comment
## there for why leaving it out is not the harmless simplification it looks like.

const CAR_SCENE := preload("res://vehicle/top_down_car.tscn")
const OBJECT_CATALOG_PATH := "res://data/default_offtrack_object_catalog.tres"

## The fixture road: a straight centerline in the fixture's local frame, sampled the way a
## generated one is, wide enough that a car sits comfortably inside it.
const LOCAL_ROAD_HALF_LENGTH := 2000.0
const LOCAL_ROAD_SPACING := 250.0
const FIXTURE_TRACK_WIDTH := 150.0
const FIXTURE_HALF_WIDTH := FIXTURE_TRACK_WIDTH * 0.5

const LOOK_AHEAD := 400.0
## Deliberately shorter than every rival and obstacle the fixture places, so a pass run at this
## horizon must come back empty. It is what proves look-ahead is a live parameter of the call and
## not a constant the pass reads from somewhere.
const SHORT_LOOK_AHEAD := 100.0

## The car under test, in the fixture's local frame: a quarter of the way to the right edge, nose
## ten degrees to the road's right.
const CAR_LOCAL_LATERAL := 25.0
const CAR_YAW_DEGREES := 10.0

## Everything around the car is placed in the CAR's frame and mapped out to the world through the
## car's own pose, so the expectations below are the placements themselves rather than numbers
## recomputed the way the pass computes them. +x is the car's right; forward is -y.
const OWN_VELOCITY_IN_CAR_FRAME := Vector2(-5.0, -300.0)
## Straight ahead and on the obstacle ray. Its capsule sits across the ray at 180 px, in front of
## the obstacle at 280 px, so the obstacle check below only reads 240 px if every car in the field
## really is excluded from the ray.
##
## Three rivals are ahead, and the nearest of them is neither the first nor the last in the field
## list. That ordering is the whole point: with the nearest one also first, "take the nearest" and
## "take the first you find" return the same car and no assertion can tell them apart -- verified by
## falsification, which is how the first version of this fixture was caught passing a pass that took
## the first. Mid is far enough to the left to clear both the obstacle ray and the near obstacle.
const RIVAL_MID_IN_CAR_FRAME := Vector2(-90.0, -240.0)
const RIVAL_MID_VELOCITY_IN_CAR_FRAME := Vector2(-10.0, -280.0)
const RIVAL_NEAR_IN_CAR_FRAME := Vector2(0.0, -180.0)
const RIVAL_NEAR_VELOCITY_IN_CAR_FRAME := Vector2(20.0, -240.0)
const RIVAL_FAR_IN_CAR_FRAME := Vector2(-45.0, -330.0)
const RIVAL_FAR_VELOCITY_IN_CAR_FRAME := Vector2(0.0, -400.0)
const RIVAL_BEHIND_IN_CAR_FRAME := Vector2(10.0, 120.0)
const RIVAL_BEYOND_IN_CAR_FRAME := Vector2(0.0, -(LOOK_AHEAD + 60.0))

## Far enough past the near rival that the rival's capsule (15 px around a 52 px body) is nowhere
## near this circle, so the two never touch and the only thing separating them is the exclusion.
const NEAR_OBSTACLE_IN_CAR_FRAME := Vector2(0.0, -280.0)
const NEAR_OBSTACLE_RADIUS := 40.0
const FAR_OBSTACLE_IN_CAR_FRAME := Vector2(0.0, -360.0)
const FAR_OBSTACLE_RADIUS := 30.0
## Where the ray meets the nearer circle: straight through its centre, so the near edge and nothing
## else. Computed from the two placements above and never from the pass.
const EXPECTED_OBSTACLE_DISTANCE := 280.0 - NEAR_OBSTACLE_RADIUS

## The second placement of the same layout. Neither a whole number of right angles nor a round
## translation, so a leak cannot cancel by symmetry.
const SECOND_PLACEMENT_DEGREES := 137.0
const SECOND_PLACEMENT_ORIGIN := Vector2(12000.0, -9000.0)

## Tolerances. Vector2 is single precision, and the second placement is 15,000 px from the origin,
## so a congruent value returns with a few thousandths of a pixel of rounding on it. A world-frame
## leak is off by hundreds of pixels or a whole radian; there is no value in between that these
## bounds would have to arbitrate.
const POSITION_TOLERANCE := 0.05
const ANGLE_TOLERANCE := 1e-4
const HEIGHT_TOLERANCE := 0.05

## The pass's fixed query budget, per car per tick.
const EXPECTED_ROAD_FRAME_QUERIES := 1
const EXPECTED_SURFACE_SAMPLE_QUERIES := 1
const EXPECTED_HEIGHT_QUERIES := 2
const EXPECTED_RAY_QUERIES := 1
const EXPECTED_TOTAL_QUERIES := 5

## Cost. The epic's budget is one 16.6 ms frame for a full field.
const FRAME_BUDGET_MS := 16.6
const FIELD_SIZE := 20
const COST_SEED := 0
const COST_BATCHES := 5
const COST_PASSES_PER_BATCH := 200
## Horizons the cost curve is printed at, spanning the range a skill spread plausibly covers.
const COST_HORIZONS := [200.0, 400.0, 600.0]

const AGREEMENT_SEEDS := [0, 7, 13]
const AGREEMENT_VERTEX_STRIDE := 37
const AGREEMENT_LATERALS := [-120.0, -40.0, 0.0, 40.0, 120.0]

var _failures: Array[String] = []
var _checks := 0
var _break_frame := false


## Counts what the pass asks of a surface query, at the interface the pass actually uses. Calls the
## real map makes to ITSELF -- sample_at asking its own distance_to_centerline -- happen inside the
## wrapped object and are correctly invisible here.
class CountingSurfaceQuery:
	extends SurfaceQuery

	var sample_calls := 0
	var road_frame_calls := 0
	var distance_calls := 0

	var _inner: SurfaceQuery


	func _init(wrapped: SurfaceQuery) -> void:
		_inner = wrapped


	func sample_at(world_position: Vector2) -> SurfaceSample:
		sample_calls += 1
		return _inner.sample_at(world_position)


	func distance_to_centerline(world_position: Vector2, search_radius: float) -> float:
		distance_calls += 1
		return _inner.distance_to_centerline(world_position, search_radius)


	func road_frame_at(world_position: Vector2, search_radius: float) -> RoadFrame:
		road_frame_calls += 1
		return _inner.road_frame_at(world_position, search_radius)


	func total_calls() -> int:
		return sample_calls + road_frame_calls + distance_calls


class CountingHeightQuery:
	extends HeightQuery

	var sample_calls := 0

	var _inner: HeightQuery


	func _init(wrapped: HeightQuery) -> void:
		_inner = wrapped


	func sample_at(world_position: Vector2) -> HeightSample:
		sample_calls += 1
		return _inner.sample_at(world_position)


## A ground defined in the fixture's LOCAL frame and carried out to the world by the placement, so
## two placements of one layout describe the same hill. Deliberately not a plane: a ripple along the
## road makes the look-ahead POINT matter, so a pass that probes the ground somewhere other than in
## front of the nose reports a different number rather than the same slope twice.
class LocalGroundHeight:
	extends HeightQuery

	const SLOPE_ALONG := 0.02
	const SLOPE_ACROSS := 0.05
	const RIPPLE_HEIGHT := 30.0
	const RIPPLE_RATE := 1.0 / 400.0

	var _placement: Transform2D
	var _inverse: Transform2D


	func _init(placement: Transform2D) -> void:
		_placement = placement
		_inverse = placement.affine_inverse()


	func sample_at(world_position: Vector2) -> HeightSample:
		var local := _inverse * world_position
		var height := SLOPE_ALONG * local.x + SLOPE_ACROSS * local.y + RIPPLE_HEIGHT * sin(local.x * RIPPLE_RATE)
		var local_gradient := Vector2(
			SLOPE_ALONG + RIPPLE_HEIGHT * RIPPLE_RATE * cos(local.x * RIPPLE_RATE),
			SLOPE_ACROSS,
		)
		return HeightSample.new(height, _placement.basis_xform(local_gradient))


## TrackHeightMap's miss path, reproduced: ONE sample instance, rewritten on every query and never
## allocated again. A pass that keeps hold of the ground under the car while it queries the ground
## ahead reads the second answer twice and reports a flat world.
class SharedSampleHeight:
	extends HeightQuery

	var _sample := HeightSample.new()
	var _slope: float


	func _init(slope: float) -> void:
		_slope = slope


	func sample_at(world_position: Vector2) -> HeightSample:
		_sample.ground_height = _slope * world_position.x
		_sample.gradient = Vector2(_slope, 0.0)
		_sample.on_feature = false
		return _sample


## The pass, with the ray counted from outside it and the frame substitutable.
##
## Both overrides call up into production: the counter delegates, so the real ray still runs, and
## the frame delegates unless the mutation is on. `_verify_the_instrumented_pass_matches_production`
## pins that this subclass senses exactly what a plain SensingPass does, so nothing in this file is
## testing a thing that only the test owns.
class InstrumentedPass:
	extends SensingPass

	var ray_calls := 0

	var _world_frame: bool


	func _init(surface_query: SurfaceQuery, height_query: HeightQuery, world_frame: bool = false) -> void:
		super(surface_query, height_query)
		_world_frame = world_frame


	## --break-sense-frame. The pass reads its car's pose exactly once, here. Handing back an
	## identity basis at the same origin leaves every world position where it was and strips the
	## rotation that turns a world vector into a car-frame one, so the senses come out in the world
	## frame -- which is the mutation the issue names, expressed as the one substitution it is.
	func _car_frame(car: TopDownCar) -> Transform2D:
		if _world_frame:
			return Transform2D(0.0, car.global_position)
		return super(car)


	func _cast_obstacle_ray(space_state: PhysicsDirectSpaceState2D, query: PhysicsRayQueryParameters2D) -> Dictionary:
		ray_calls += 1
		return super(space_state, query)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_break_frame = OS.get_cmdline_user_args().has("--break-sense-frame")
	if _break_frame:
		print("NOTE: --break-sense-frame is on; every pass emits world-frame values.")
	_check(_verify_road_frame_agrees_with_the_distance_query(), "the road frame verification ran to completion")
	_check(_verify_lateral_offset_carries_its_sign(), "the lateral offset verification ran to completion")
	_check(_verify_heading_error_reads_the_yaw(), "the heading error verification ran to completion")
	_check(_verify_the_road_can_be_out_of_range(), "the lost-road verification ran to completion")
	_check(_verify_ground_ahead_survives_a_shared_sample(), "the shared-sample verification ran to completion")
	_check(_verify_rivals_come_from_the_field_list(), "the rival verification ran to completion")
	_check(_verify_obstacles_come_from_one_repeatable_ray(), "the obstacle verification ran to completion")
	_check(_verify_senses_are_in_the_car_frame(), "the car-frame verification ran to completion")
	_check(await _verify_the_query_budget_is_fixed(), "the query budget verification ran to completion")
	_check(_verify_the_pass_changes_nothing(), "the purity verification ran to completion")
	_check(_verify_the_instrumented_pass_matches_production(), "the instrumentation verification ran to completion")
	_check(_verify_a_tuningless_car_does_not_abort_a_pass(), "the tuningless-car verification ran to completion")
	_check(_verify_senses_carry_no_handles(), "the handle verification ran to completion")
	_check(await _verify_a_field_of_twenty_fits_the_frame(), "the cost verification ran to completion")
	print("Driver senses: %d checks, %d failures" % [_checks, _failures.size()])
	quit(0 if _failures.is_empty() else 1)


## The new road frame and the distance query it was grown from must never disagree, because the
## car's automatic reset reads one and a driver reads the other. Compared with `==` and not
## is_equal_approx: they walk the same grid over the same segments, so anything but bit equality is
## a divergence worth hearing about. The side is checked against the side the probe was PLACED on,
## which no part of the production code was consulted about.
func _verify_road_frame_agrees_with_the_distance_query() -> bool:
	var generator := TrackGenerator.new()
	var compared := 0
	var identical := 0
	for seed in AGREEMENT_SEEDS:
		var definition: TrackDefinition = generator.generate(seed)
		var map := TrackSurfaceMap.new(definition)
		var unique_count := definition.centerline.size() - 1
		var half_width: float = definition.track_width * 0.5
		var index := 0
		while index < unique_count:
			var previous: Vector2 = definition.centerline[(index - 1 + unique_count) % unique_count]
			var following: Vector2 = definition.centerline[(index + 1) % unique_count]
			var tangent := (following - previous).normalized()
			var right := SurfaceQuery.right_normal(tangent)
			for lateral: float in AGREEMENT_LATERALS:
				var probe: Vector2 = definition.centerline[index] + right * lateral
				var frame := map.road_frame_at(probe, LOOK_AHEAD)
				var legacy := map.distance_to_centerline(probe, LOOK_AHEAD)
				compared += 1
				identical += int(frame.distance == legacy)
				if frame.distance != legacy:
					_check(false, "seed %d vertex %d lateral %.0f: frame %.9f vs distance %.9f" % [seed, index, lateral, frame.distance, legacy])
				if not frame.found:
					_check(false, "seed %d vertex %d lateral %.0f: no road found within %.0f px" % [seed, index, lateral, LOOK_AHEAD])
					continue
				if absf(frame.lateral_offset) != frame.distance:
					_check(false, "seed %d vertex %d lateral %.0f: |offset| %.9f is not the distance %.9f" % [seed, index, lateral, absf(frame.lateral_offset), frame.distance])
				# A probe placed on the line has no side to be on, and asking signf() which one it is
				# would be asserting the tie-break of a value that is legitimately zero.
				if lateral != 0.0 and signf(frame.lateral_offset) != signf(lateral):
					_check(false, "seed %d vertex %d lateral %.0f: offset %.3f fell on the wrong side" % [seed, index, lateral, frame.lateral_offset])
				if lateral == 0.0 and frame.distance > 1e-3:
					_check(false, "seed %d vertex %d: a probe on the centreline reads %.9f px from it" % [seed, index, frame.distance])
				if not frame.tangent.is_normalized():
					_check(false, "seed %d vertex %d lateral %.0f: tangent %s is not a unit vector" % [seed, index, lateral, frame.tangent])
				if frame.half_width != half_width:
					_check(false, "seed %d vertex %d: half width %.3f is not the definition's %.3f" % [seed, index, frame.half_width, half_width])
			index += AGREEMENT_VERTEX_STRIDE
	print("road frame agreement: %d probes, %d bit-identical distances" % [compared, identical])
	# Without this the loop above would pass by never running: a stride that outgrew the centerline,
	# or a generator that started failing, would leave every assertion unexecuted and the script
	# green. Three seeds at five laterals per sampled vertex cannot produce fewer than this.
	_check(compared >= 150, "the agreement sweep took at least 150 probes (%d)" % compared)
	_check(identical == compared, "every probe's road frame distance equals distance_to_centerline bit for bit")
	return true


## A magnitude-only check passes with left and right swapped, so the sign is asserted against the
## side the car was placed on, and both sides are placed.
##
## Each placement is torn down before the next is built. Every fixture world here sits at the same
## origin, and two of them alive at once would share one physics space with their cars and obstacles
## stacked on top of each other.
func _verify_lateral_offset_carries_its_sign() -> bool:
	var world := _build_fixture_world(Transform2D.IDENTITY)
	var senses := _sense_fixture_car(world, LOOK_AHEAD)
	_check(senses.road_found, "the fixture car finds the road it is standing on")
	_check(absf(senses.lateral_offset - CAR_LOCAL_LATERAL) < POSITION_TOLERANCE, "a car %.0f px to the road's right reads offset %+.4f" % [CAR_LOCAL_LATERAL, senses.lateral_offset])
	_check(senses.lateral_offset > 0.0, "that offset is positive, which is the road's right")
	_check(absf(senses.distance_to_right_edge - (FIXTURE_HALF_WIDTH - CAR_LOCAL_LATERAL)) < POSITION_TOLERANCE, "the right edge is %.4f px away" % senses.distance_to_right_edge)
	_check(absf(senses.distance_to_left_edge - (FIXTURE_HALF_WIDTH + CAR_LOCAL_LATERAL)) < POSITION_TOLERANCE, "the left edge is %.4f px away" % senses.distance_to_left_edge)
	_check(senses.distance_to_left_edge > senses.distance_to_right_edge, "a car on the right is further from the left edge than the right")
	_check(senses.surface_type == SurfaceQuery.SurfaceType.DIRT, "the surface under a car inside the road reads dirt")
	_tear_down(world)

	# The mirror image. Same fixture, same everything, the car moved to the other side of the line.
	var mirrored := _build_fixture_world(Transform2D.IDENTITY, -CAR_LOCAL_LATERAL)
	var mirrored_senses := _sense_fixture_car(mirrored, LOOK_AHEAD)
	_check(absf(mirrored_senses.lateral_offset + CAR_LOCAL_LATERAL) < POSITION_TOLERANCE, "a car %.0f px to the road's left reads offset %+.4f" % [CAR_LOCAL_LATERAL, mirrored_senses.lateral_offset])
	_check(mirrored_senses.lateral_offset < 0.0, "that offset is negative, which is the road's left")
	_check(signf(senses.lateral_offset) != signf(mirrored_senses.lateral_offset), "the two sides do not read the same sign")
	_tear_down(mirrored)

	# On the line, and outside the road. Zero is the value a magnitude check cannot distinguish from
	# a broken sign, and a negative edge distance is how far outside a car that has run wide is.
	var centred := _build_fixture_world(Transform2D.IDENTITY, 0.0)
	var centred_senses := _sense_fixture_car(centred, LOOK_AHEAD)
	_check(absf(centred_senses.lateral_offset) < POSITION_TOLERANCE, "a car on the centreline reads %+.6f" % centred_senses.lateral_offset)
	_tear_down(centred)

	var beyond := FIXTURE_HALF_WIDTH + 40.0
	var wide := _build_fixture_world(Transform2D.IDENTITY, beyond)
	var wide_senses := _sense_fixture_car(wide, LOOK_AHEAD)
	_check(absf(wide_senses.distance_to_right_edge + 40.0) < POSITION_TOLERANCE, "a car 40 px past the right edge reads %.4f px to it" % wide_senses.distance_to_right_edge)
	_check(wide_senses.surface_type == SurfaceQuery.SurfaceType.OFF_TRACK, "the surface under a car past the edge reads off-track")
	_tear_down(wide)
	return true


func _verify_heading_error_reads_the_yaw() -> bool:
	for yaw_degrees: float in [0.0, CAR_YAW_DEGREES, -CAR_YAW_DEGREES, 47.0, 180.0]:
		var world := _build_fixture_world(Transform2D.IDENTITY, CAR_LOCAL_LATERAL, yaw_degrees)
		var senses := _sense_fixture_car(world, LOOK_AHEAD)
		var expected := deg_to_rad(yaw_degrees)
		# 180 degrees is the wrong-way case, and angle_to reports it as +PI or -PI depending on
		# which side of the turn a rounding error lands. Both readings say the same thing.
		var error := absf(absf(senses.heading_error) - absf(expected)) if absf(yaw_degrees) == 180.0 else absf(senses.heading_error - expected)
		_check(error < ANGLE_TOLERANCE, "a car yawed %+.0f degrees off the road reads %+.6f rad (expected %+.6f)" % [yaw_degrees, senses.heading_error, expected])
		if yaw_degrees > 0.0 and yaw_degrees < 180.0:
			_check(senses.heading_error > 0.0, "a nose turned to the road's right reads a positive heading error")
		if yaw_degrees < 0.0:
			_check(senses.heading_error < 0.0, "a nose turned to the road's left reads a negative heading error")
		_tear_down(world)
	return true


## The senses have to say "no road" rather than "on the line" when the road is out of range, because
## those two answers ask a driver to do opposite things.
func _verify_the_road_can_be_out_of_range() -> bool:
	var world := _build_fixture_world(Transform2D.IDENTITY, 5000.0)
	var senses := _sense_fixture_car(world, LOOK_AHEAD)
	_check(not senses.road_found, "a car 5000 px from the centreline finds no road within its %.0f px horizon" % LOOK_AHEAD)
	_check(senses.lateral_offset == 0.0 and senses.heading_error == 0.0, "the road fields are zeroed rather than left holding a stale answer")
	_check(senses.distance_to_left_edge == 0.0 and senses.distance_to_right_edge == 0.0, "the edge distances are zeroed too")
	_check(senses.surface_type == SurfaceQuery.SurfaceType.OFF_TRACK, "the surface still answers, because sample_at has no range limit")
	_tear_down(world)
	return true


## The brief's trap, made into an assertion. A provider that hands back one shared instance is the
## production TrackHeightMap's miss path; a pass that holds the first sample across the second query
## reports a flat world here and nowhere else.
func _verify_ground_ahead_survives_a_shared_sample() -> bool:
	var slope := 0.08
	var world := _build_fixture_world(Transform2D.IDENTITY)
	var pass_under_test := InstrumentedPass.new(world["surface"], SharedSampleHeight.new(slope), _break_frame)
	var car: TopDownCar = world["field"][0]
	var senses := pass_under_test.sense(world["field"], 0, LOOK_AHEAD)
	var travelled := (-car.global_transform.y.normalized() * LOOK_AHEAD).x
	var expected := slope * travelled
	print("shared sample: change=%.6f expected=%.6f travelled_x=%.4f" % [senses.height_change_ahead, expected, travelled])
	# Guards the check below against a fixture that made the answer zero either way: a horizon that
	# moved the probe nowhere along x would let a held sample pass unnoticed.
	_check(absf(expected) > 1.0, "the fixture ground really does change over the horizon (%.4f px)" % expected)
	_check(absf(senses.height_change_ahead - expected) < HEIGHT_TOLERANCE, "the ground ahead reads its own height and not the car's, through a shared sample")
	_tear_down(world)
	return true


## Three rivals ahead in an order that makes "nearest" mean something (see RIVAL_MID_IN_CAR_FRAME);
## one behind, so "ahead" is exercised; one past the horizon, so look-ahead is exercised as a
## parameter of the call.
##
## The ladder below removes the nearest rival twice and demands the answer walk outward each time.
## A single "the near one was found" would be satisfied by a pass that took the first car in the
## list, or the last, or the only one it happened to look at.
func _verify_rivals_come_from_the_field_list() -> bool:
	var world := _build_fixture_world(Transform2D.IDENTITY)
	var field: Array[TopDownCar] = world["field"]
	_check(field.size() == 6, "the fixture field holds the car under test and five rivals (%d)" % field.size())
	# The ordering the ladder rests on. If the nearest rival were also the first ahead in the list,
	# every check below would pass against a pass that never compared distances at all.
	_check(
		RIVAL_NEAR_IN_CAR_FRAME.length() < RIVAL_MID_IN_CAR_FRAME.length() and RIVAL_MID_IN_CAR_FRAME.length() < RIVAL_FAR_IN_CAR_FRAME.length(),
		"the three rivals ahead are at %.0f, %.0f and %.0f px" % [RIVAL_NEAR_IN_CAR_FRAME.length(), RIVAL_MID_IN_CAR_FRAME.length(), RIVAL_FAR_IN_CAR_FRAME.length()],
	)
	_check(field[1].global_position.distance_to(field[0].global_position) > field[2].global_position.distance_to(field[0].global_position), "and the nearest of them is not the first one in the field list")
	_check(field[3].global_position.distance_to(field[0].global_position) > field[2].global_position.distance_to(field[0].global_position), "nor the last one ahead in it")

	var senses := _sense_fixture_car(world, LOOK_AHEAD)
	_check(senses.has_rival_ahead, "a rival ahead is found")
	_check(_close(senses.rival_offset, RIVAL_NEAR_IN_CAR_FRAME), "the rival found is the near one at %s, not the mid one at %s or the far one at %s (read %s)" % [RIVAL_NEAR_IN_CAR_FRAME, RIVAL_MID_IN_CAR_FRAME, RIVAL_FAR_IN_CAR_FRAME, senses.rival_offset])
	_check(absf(senses.rival_distance - RIVAL_NEAR_IN_CAR_FRAME.length()) < POSITION_TOLERANCE, "its distance is %.4f px" % senses.rival_distance)
	_check(senses.rival_offset.y < 0.0, "the rival found is in front of the nose, not behind it")
	var expected_relative := RIVAL_NEAR_VELOCITY_IN_CAR_FRAME - OWN_VELOCITY_IN_CAR_FRAME
	_check(_close(senses.rival_relative_velocity, expected_relative), "its velocity relative to this car is %s (expected %s)" % [senses.rival_relative_velocity, expected_relative])
	_check(_close(senses.local_velocity, OWN_VELOCITY_IN_CAR_FRAME), "this car's own velocity in its own frame is %s" % senses.local_velocity)

	# Take the near one away and the answer must step out to mid, not jump to far and not stay put.
	var without_near: Array[TopDownCar] = [field[0], field[1], field[3], field[4], field[5]]
	var mid_senses := _make_pass(world).sense(without_near, 0, LOOK_AHEAD)
	_check(mid_senses.has_rival_ahead, "with the near rival gone, another is found")
	_check(_close(mid_senses.rival_offset, RIVAL_MID_IN_CAR_FRAME), "and it is the mid one at %s, not the far one at %s (read %s)" % [RIVAL_MID_IN_CAR_FRAME, RIVAL_FAR_IN_CAR_FRAME, mid_senses.rival_offset])

	# Take mid away too and only far is left ahead.
	var only_far: Array[TopDownCar] = [field[0], field[3], field[4], field[5]]
	var far_senses := _make_pass(world).sense(only_far, 0, LOOK_AHEAD)
	_check(far_senses.has_rival_ahead, "with the mid rival gone as well, the far one is found")
	_check(_close(far_senses.rival_offset, RIVAL_FAR_IN_CAR_FRAME), "and it is the far one at %s (read %s)" % [RIVAL_FAR_IN_CAR_FRAME, far_senses.rival_offset])

	# Only the car behind and the car past the horizon are left.
	var nothing_ahead: Array[TopDownCar] = [field[0], field[4], field[5]]
	var empty_senses := _make_pass(world).sense(nothing_ahead, 0, LOOK_AHEAD)
	_check(not empty_senses.has_rival_ahead, "a rival behind and a rival past the horizon are both ignored")
	_check(empty_senses.rival_offset == Vector2.ZERO and empty_senses.rival_distance == 0.0, "and the rival fields are left at zero")

	# The horizon is a parameter of the call. Same field, shorter look-ahead, no rival.
	var short_senses := _sense_fixture_car(world, SHORT_LOOK_AHEAD)
	_check(not short_senses.has_rival_ahead, "the same rival %0.f px ahead is invisible at a %.0f px horizon" % [RIVAL_NEAR_IN_CAR_FRAME.length(), SHORT_LOOK_AHEAD])
	_check(short_senses.look_ahead == SHORT_LOOK_AHEAD, "the senses report the horizon they were built at")
	_tear_down(world)
	return true


func _verify_obstacles_come_from_one_repeatable_ray() -> bool:
	var world := _build_fixture_world(Transform2D.IDENTITY)
	var senses := _sense_fixture_car(world, LOOK_AHEAD)
	_check(senses.has_obstacle_ahead, "the ray finds the obstacle in front of the car")
	# The rival's capsule crosses this ray 40 px nearer than the obstacle's surface. Reading 220
	# rather than something around 180 is what says every car in the field was excluded.
	_check(absf(senses.obstacle_distance - EXPECTED_OBSTACLE_DISTANCE) < 0.05, "it is the %.0f px obstacle and not the rival's body at %.0f px (read %.4f)" % [EXPECTED_OBSTACLE_DISTANCE, RIVAL_NEAR_IN_CAR_FRAME.length(), senses.obstacle_distance])
	_check(absf(senses.obstacle_offset.x) < 0.05 and senses.obstacle_offset.y < 0.0, "the hit is straight ahead in the car's frame (%s)" % senses.obstacle_offset)
	_check(absf(senses.obstacle_offset.length() - senses.obstacle_distance) < 0.001, "the offset and the distance describe one hit")

	# Repeatability, bit for bit. Nothing moved between these calls, so anything but exact equality
	# is the unordered-result bug the whole sensing design exists to avoid.
	var repeats := 8
	var identical := 0
	for _repeat in range(repeats):
		var again := _sense_fixture_car(world, LOOK_AHEAD)
		identical += int(again.obstacle_distance == senses.obstacle_distance and again.obstacle_offset == senses.obstacle_offset and again.has_obstacle_ahead == senses.has_obstacle_ahead)
	_check(identical == repeats, "%d repeated identical rays returned the same hit bit for bit (%d)" % [repeats, identical])

	# The far obstacle is behind the near one and must never be the answer while the near one
	# stands. Removing the near one is what proves the ray was picking the nearest and not the only.
	var near_body: StaticBody2D = world["near_obstacle"]
	near_body.get_parent().remove_child(near_body)
	var far_senses := _sense_fixture_car(world, LOOK_AHEAD)
	_check(far_senses.has_obstacle_ahead, "with the near obstacle gone the far one is found")
	_check(absf(far_senses.obstacle_distance - (absf(FAR_OBSTACLE_IN_CAR_FRAME.y) - FAR_OBSTACLE_RADIUS)) < 0.05, "and it reads %.4f px, the far obstacle's near edge" % far_senses.obstacle_distance)
	near_body.free()

	var short_senses := _sense_fixture_car(world, SHORT_LOOK_AHEAD)
	_check(not short_senses.has_obstacle_ahead, "no obstacle is within a %.0f px horizon" % SHORT_LOOK_AHEAD)
	_check(short_senses.obstacle_distance == 0.0 and short_senses.obstacle_offset == Vector2.ZERO, "and the obstacle fields are left at zero")
	_tear_down(world)
	return true


## The assertion this task exists for.
##
## One layout, two placements: 15,000 px apart and 137 degrees rotated. Same road-relative pose,
## same rivals in the same places relative to the car, same obstacles, congruent ground. Every field
## of DriverSenses is walked and compared, so a field added later is covered without anybody
## remembering to add it here.
##
## `--break-sense-frame` fails this and is meant to.
func _verify_senses_are_in_the_car_frame() -> bool:
	var placement := Transform2D(deg_to_rad(SECOND_PLACEMENT_DEGREES), SECOND_PLACEMENT_ORIGIN)
	var first := _build_fixture_world(Transform2D.IDENTITY)
	var second := _build_fixture_world(placement)
	var first_car: TopDownCar = first["field"][0]
	var second_car: TopDownCar = second["field"][0]
	var first_senses := _sense_fixture_car(first, LOOK_AHEAD)
	var second_senses := _sense_fixture_car(second, LOOK_AHEAD)
	print("frame: first car at %s rot %.4f; second at %s rot %.4f" % [first_car.global_position, first_car.global_rotation, second_car.global_position, second_car.global_rotation])

	# The two placements really are different world states. Without this the comparison below could
	# be comparing a layout with itself, which every possible implementation passes.
	_check(first_car.global_position.distance_to(second_car.global_position) > 10000.0, "the two cars are in genuinely different places (%.0f px apart)" % first_car.global_position.distance_to(second_car.global_position))
	_check(absf(angle_difference(first_car.global_rotation, second_car.global_rotation)) > 1.0, "and pointing in genuinely different directions (%.4f rad apart)" % absf(angle_difference(first_car.global_rotation, second_car.global_rotation)))

	# Nothing here may be compared vacuously. Every sense that has an "off" value must be on, or a
	# pass that returned an empty DriverSenses twice would satisfy the walk below.
	_check(first_senses.road_found and first_senses.has_rival_ahead and first_senses.has_obstacle_ahead, "the first placement senses a road, a rival and an obstacle")
	_check(first_senses.lateral_offset != 0.0 and first_senses.heading_error != 0.0, "its road scalars are non-zero")
	_check(first_senses.gradient_ahead != Vector2.ZERO and first_senses.height_change_ahead != 0.0, "its ground senses are non-zero")
	_check(first_senses.rival_offset != Vector2.ZERO and first_senses.rival_relative_velocity != Vector2.ZERO, "its rival senses are non-zero")
	_check(first_senses.obstacle_offset != Vector2.ZERO and first_senses.local_velocity != Vector2.ZERO, "its obstacle and velocity senses are non-zero")

	var compared := 0
	var matched := 0
	var differences: Array[String] = []
	for property in DriverSenses.new().get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var field_name: String = property["name"]
		var left = first_senses.get(field_name)
		var right = second_senses.get(field_name)
		compared += 1
		if _fields_agree(field_name, left, right):
			matched += 1
			continue
		differences.append("%s: %s vs %s" % [field_name, left, right])
	for difference in differences:
		print("frame difference: %s" % difference)
	print("frame: %d fields compared, %d agreed" % [compared, matched])
	# Eighteen is what DriverSenses declares today; the bound is there so a walk that stopped seeing
	# properties cannot report "all zero fields agreed" and pass.
	_check(compared >= 18, "the walk saw every field of DriverSenses (%d)" % compared)
	_check(matched == compared, "the same car in the same road-relative pose at two different world positions and rotations reads identical senses")
	_tear_down(first)
	_tear_down(second)
	return true


## Five queries a tick, whatever the world holds, counted by fixtures the pass does not own. The
## count is pinned rather than described because it is the number that turns twenty cars from
## affordable into not, and because an extra ray is invisible in behaviour and obvious here.
func _verify_the_query_budget_is_fixed() -> bool:
	var world := _build_fixture_world(Transform2D.IDENTITY)
	var surface := CountingSurfaceQuery.new(world["surface"])
	var height := CountingHeightQuery.new(world["height"])
	var pass_under_test := InstrumentedPass.new(surface, height, _break_frame)
	var senses := pass_under_test.sense(world["field"], 0, LOOK_AHEAD)
	print("budget: road_frame=%d sample=%d distance=%d height=%d ray=%d" % [surface.road_frame_calls, surface.sample_calls, surface.distance_calls, height.sample_calls, pass_under_test.ray_calls])
	# A pass that bailed out early would spend nothing and satisfy an upper bound. The counts below
	# only mean something if this pass did the whole job.
	_check(senses.road_found and senses.has_rival_ahead and senses.has_obstacle_ahead, "the counted pass sensed the whole world rather than bailing out")
	_check(surface.road_frame_calls == EXPECTED_ROAD_FRAME_QUERIES, "a pass asks the surface query for the road frame exactly %d time" % EXPECTED_ROAD_FRAME_QUERIES)
	_check(surface.sample_calls == EXPECTED_SURFACE_SAMPLE_QUERIES, "a pass samples the surface exactly %d time" % EXPECTED_SURFACE_SAMPLE_QUERIES)
	_check(surface.distance_calls == 0, "a pass never calls distance_to_centerline directly")
	_check(height.sample_calls == EXPECTED_HEIGHT_QUERIES, "a pass samples the height query exactly %d times" % EXPECTED_HEIGHT_QUERIES)
	_check(pass_under_test.ray_calls == EXPECTED_RAY_QUERIES, "a pass casts exactly %d physics ray" % EXPECTED_RAY_QUERIES)
	_check(surface.total_calls() + height.sample_calls + pass_under_test.ray_calls == EXPECTED_TOTAL_QUERIES, "a pass spends exactly %d queries in total" % EXPECTED_TOTAL_QUERIES)

	# The count must not depend on what is out there. An empty field and a horizon that reaches
	# nothing still cost the same five.
	var lonely := CountingSurfaceQuery.new(world["surface"])
	var lonely_height := CountingHeightQuery.new(world["height"])
	var lonely_pass := InstrumentedPass.new(lonely, lonely_height, _break_frame)
	var alone: Array[TopDownCar] = [world["field"][0]]
	var lonely_senses := lonely_pass.sense(alone, 0, SHORT_LOOK_AHEAD)
	_check(not lonely_senses.has_rival_ahead and not lonely_senses.has_obstacle_ahead, "the second pass really did find nothing")
	_check(lonely.total_calls() + lonely_height.sample_calls + lonely_pass.ray_calls == EXPECTED_TOTAL_QUERIES, "a pass that finds nothing costs the same %d queries" % EXPECTED_TOTAL_QUERIES)
	_tear_down(world)

	# Twenty cars, twenty passes, and the total is twenty times one. A scan that queried per rival
	# would show up here and nowhere else.
	var crowd := await _build_cost_world()
	var crowd_surface := CountingSurfaceQuery.new(crowd["surface"])
	var crowd_height := CountingHeightQuery.new(crowd["height"])
	var crowd_pass := InstrumentedPass.new(crowd_surface, crowd_height, _break_frame)
	var crowd_field: Array[TopDownCar] = crowd["field"]
	for index in range(crowd_field.size()):
		crowd_pass.sense(crowd_field, index, LOOK_AHEAD)
	var crowd_total := crowd_surface.total_calls() + crowd_height.sample_calls + crowd_pass.ray_calls
	print("budget: %d cars spent %d queries" % [crowd_field.size(), crowd_total])
	_check(crowd_field.size() == FIELD_SIZE, "the crowd fixture really holds %d cars (%d)" % [FIELD_SIZE, crowd_field.size()])
	_check(crowd_total == FIELD_SIZE * EXPECTED_TOTAL_QUERIES, "a field of %d spends %d queries a tick, %d each" % [FIELD_SIZE, FIELD_SIZE * EXPECTED_TOTAL_QUERIES, EXPECTED_TOTAL_QUERIES])
	_tear_down(crowd)
	return true


## A sensing pass is a pure function of world state: it writes nothing, moves nothing, and answers
## the same twice. Poses and velocities are compared with `==` because nothing has stepped between
## the two reads, so any difference at all is the pass having reached out and touched something.
func _verify_the_pass_changes_nothing() -> bool:
	var world := _build_fixture_world(Transform2D.IDENTITY)
	var field: Array[TopDownCar] = world["field"]
	var poses: Array[Transform2D] = []
	var velocities: Array[Vector2] = []
	for car in field:
		poses.append(car.global_transform)
		velocities.append(car.linear_velocity)
	var first := _sense_fixture_car(world, LOOK_AHEAD)
	var second := _sense_fixture_car(world, LOOK_AHEAD)
	var moved := 0
	for index in range(field.size()):
		var car: TopDownCar = field[index]
		if car.global_transform != poses[index] or car.linear_velocity != velocities[index]:
			moved += 1
	_check(moved == 0, "no car in the field moved or changed velocity across two sensing passes (%d did)" % moved)
	var compared := 0
	var identical := 0
	for property in DriverSenses.new().get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		compared += 1
		identical += int(first.get(property["name"]) == second.get(property["name"]))
	_check(compared >= 18, "the repeat walk saw every field of DriverSenses (%d)" % compared)
	_check(identical == compared, "two passes over an unchanged world return bit-identical senses")
	_check(first != second, "and they are two distinct values, not one instance handed out twice")
	_tear_down(world)
	return true


## Everything else in this file runs through InstrumentedPass, whose overrides delegate upward. This
## is the check that says so: a plain production SensingPass senses exactly the same thing.
func _verify_the_instrumented_pass_matches_production() -> bool:
	if _break_frame:
		print("NOTE: skipped under --break-sense-frame, whose whole purpose is to make these differ.")
		return true
	var world := _build_fixture_world(Transform2D.IDENTITY)
	var production := SensingPass.new(world["surface"], world["height"])
	var instrumented := InstrumentedPass.new(world["surface"], world["height"], false)
	var expected := production.sense(world["field"], 0, LOOK_AHEAD)
	var actual := instrumented.sense(world["field"], 0, LOOK_AHEAD)
	var compared := 0
	var identical := 0
	for property in DriverSenses.new().get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		compared += 1
		identical += int(expected.get(property["name"]) == actual.get(property["name"]))
	_check(compared >= 18, "the production comparison saw every field of DriverSenses (%d)" % compared)
	_check(expected.road_found and expected.has_rival_ahead and expected.has_obstacle_ahead, "the production pass sensed the whole world")
	_check(identical == compared, "the instrumented pass this suite uses senses exactly what a production SensingPass does")
	_tear_down(world)
	return true


## Task #60 spawns the field, and task #56's review found a rival reaching _ready() before its tuning
## was assigned. Such a car has no collision level, so the obstacle ray has no mask to use. The pass
## must come back with the rest of its senses intact instead of aborting the function on a null
## access, which would leave a complete-looking DriverSenses whose obstacle block was quietly empty.
##
## The tuning is cleared after the car is in the tree, so TopDownCar._ready()'s own guard has already
## run and this prints no ERROR of its own. Any error line during this section is a real one.
func _verify_a_tuningless_car_does_not_abort_a_pass() -> bool:
	var world := _build_fixture_world(Transform2D.IDENTITY)
	var field: Array[TopDownCar] = world["field"]
	var healthy := _sense_fixture_car(world, LOOK_AHEAD)
	_check(healthy.has_obstacle_ahead, "the same fixture senses an obstacle while the car has tuning")

	field[0].tuning = null
	var senses := _sense_fixture_car(world, LOOK_AHEAD)
	_check(field[0].tuning == null, "the fixture car really has no tuning")
	# The whole point: everything that does not need a collision level still answers.
	_check(senses.road_found and absf(senses.lateral_offset - CAR_LOCAL_LATERAL) < POSITION_TOLERANCE, "a tuningless car still reads the road (offset %+.4f)" % senses.lateral_offset)
	_check(senses.has_rival_ahead and _close(senses.rival_offset, RIVAL_NEAR_IN_CAR_FRAME), "and still reads its rivals (%s)" % senses.rival_offset)
	_check(senses.height_change_ahead == healthy.height_change_ahead, "and still reads the ground ahead")
	# The assertion the guard has to earn. Falling back to "no obstacle" would have been the same
	# answer the crash produces, and no check could have told the two apart -- verified by removing
	# the guard, which left this file green while printing a SCRIPT ERROR that GDScript gives no way
	# to count. Sensing both layers is a different answer, so this fails when the guard goes.
	_check(senses.has_obstacle_ahead, "and still sees the obstacle in front of it, on both collision layers")
	_check(senses.obstacle_distance == healthy.obstacle_distance and senses.obstacle_offset == healthy.obstacle_offset, "reading it exactly where the tuned car did (%.4f px)" % senses.obstacle_distance)
	_tear_down(world)
	return true


## The same rule task #56 asserts on AiDriver, applied to the thing a driver is handed. A sense that
## carried a node would let a driver walk from its senses back to the car, the track and the field,
## and every determinism guarantee in the epic would rest on nobody noticing.
func _verify_senses_carry_no_handles() -> bool:
	var senses := DriverSenses.new()
	var declared := 0
	for property in senses.get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		declared += 1
		_check(
			int(property["type"]) not in [TYPE_NIL, TYPE_OBJECT, TYPE_NODE_PATH, TYPE_RID, TYPE_CALLABLE, TYPE_SIGNAL],
			"DriverSenses.%s is plain data, not a handle (type %d)" % [property["name"], property["type"]],
		)
	_check(declared >= 18, "DriverSenses declares the fields the check above walked (%d)" % declared)
	return true


## Cost, measured on a generated track with its real trees and rocks in the space, stated as the
## per-car figure the epic asked for and that figure times twenty against a 16.6 ms frame.
##
## Measured twice, because the ray's cost depends on whether it hits. On a real circuit the nearest
## solid stands 375 px from the centreline -- further than a horizon's worth of look-ahead -- so a
## car ON the road casts a ray that runs its full length and finds nothing. That is the racing case
## and the ray's worst case, and it is the figure quoted. The second field parks cars in front of
## the solids so the hitting case is measured rather than assumed to be the same.
func _verify_a_field_of_twenty_fits_the_frame() -> bool:
	var world := await _build_cost_world()
	var solids: PackedVector2Array = world["solids"]
	print("cost: seed %d, %d cars, look-ahead %.0f px, %d solid colliders" % [COST_SEED, FIELD_SIZE, LOOK_AHEAD, int(world["collider_count"])])
	_check(int(world["collider_count"]) > 100, "the cost fixture holds the track's real solids (%d colliders)" % int(world["collider_count"]))
	_check(solids.size() == int(world["collider_count"]), "and the definition agrees on how many there are (%d)" % solids.size())
	# The guard the first version of this file did not have. A shape added to a body that is already
	# in the tree is invisible to every ray until physics has stepped, and `collider_count()` counts
	# nodes, so it reports all 174 either way. Without a ray that actually connects, the whole cost
	# measurement below could be of a space with nothing in it.
	_check(_a_probe_ray_finds_a_solid(world), "and a probe ray fired through one of them connects, so they are in the broadphase")

	var racing := _measure_cost(world, world["field"])
	var crowding := _build_obstacle_facing_field(world)
	var closing := _measure_cost(world, crowding)
	var field_cost_ms := float(racing["median"]) * FIELD_SIZE / 1000.0
	print("cost: racing line   per car %.2f us (%.2f..%.2f), road found %d/%d, obstacle found %d/%d" % [
		racing["median"], racing["fastest"], racing["slowest"], racing["roads"], racing["passes"], racing["obstacles"], racing["passes"],
	])
	print("cost: facing solids per car %.2f us (%.2f..%.2f), road found %d/%d, obstacle found %d/%d" % [
		closing["median"], closing["fastest"], closing["slowest"], closing["roads"], closing["passes"], closing["obstacles"], closing["passes"],
	])
	print("cost: %d cars x %.2f us = %.3f ms of a %.1f ms frame (%.1f%%)" % [
		FIELD_SIZE, racing["median"], field_cost_ms, FRAME_BUDGET_MS, 100.0 * field_cost_ms / FRAME_BUDGET_MS,
	])
	# Look-ahead is the one dial the issue names and the one task #59 varies by skill. It is also
	# what the road query's search radius is taken from, so it is the dial that moves the cost.
	# Printed as a curve rather than asserted, so whoever sets a skill's horizon can see its price.
	for horizon: float in COST_HORIZONS:
		var sample := _measure_cost(world, world["field"], horizon)
		print("cost: look-ahead %4.0f px -> %6.2f us per car, %.3f ms for %d" % [horizon, sample["median"], float(sample["median"]) * FIELD_SIZE / 1000.0, FIELD_SIZE])
	_check(int(racing["roads"]) == int(racing["passes"]), "every pass on the racing line found the road (%d of %d)" % [racing["roads"], racing["passes"]])
	# The second field is only worth its lines if its rays really do hit. Without this the "facing
	# solids" figure could be a second measurement of the same miss.
	_check(int(closing["obstacles"]) > 0, "the second field's rays really do hit something (%d of %d)" % [closing["obstacles"], closing["passes"]])
	_check(float(racing["median"]) > 0.0, "the measurement resolved a non-zero per-pass cost (%.3f us)" % racing["median"])
	_check(field_cost_ms < FRAME_BUDGET_MS, "%d cars sense in %.3f ms, inside one %.1f ms frame" % [FIELD_SIZE, field_cost_ms, FRAME_BUDGET_MS])
	_tear_down(world)
	return true


## Fires a ray straight through the middle of a known solid. A hit says the track's colliders are in
## the broadphase; a miss says the fixture is a scene graph and nothing more.
func _a_probe_ray_finds_a_solid(world: Dictionary) -> bool:
	var solids: PackedVector2Array = world["solids"]
	if solids.is_empty():
		return false
	var car: TopDownCar = world["field"][0]
	var centre: Vector2 = solids[0]
	var probe := PhysicsRayQueryParameters2D.create(
		centre + Vector2(200.0, 0.0),
		centre - Vector2(200.0, 0.0),
		OfftrackObjectCollisions.TALL_LAYER | OfftrackObjectCollisions.LOW_LAYER,
	)
	return not car.get_world_2d().direct_space_state.intersect_ray(probe).is_empty()


## Twenty cars parked a little way in front of twenty of the track's solids, pointing at them, so
## the ray's hitting cost is measured on the real objects rather than estimated from the miss.
func _build_obstacle_facing_field(world: Dictionary) -> Array[TopDownCar]:
	var holder: Node2D = world["holder"]
	var solids: PackedVector2Array = world["solids"]
	var field: Array[TopDownCar] = []
	for index in range(FIELD_SIZE):
		var target: Vector2 = solids[(index * solids.size()) / FIELD_SIZE]
		# Approached from a different bearing each time, so twenty cars do not queue up along one
		# axis and shadow each other.
		var forward := Vector2.RIGHT.rotated(TAU * float(index) / float(FIELD_SIZE))
		var pose := Transform2D(atan2(forward.x, -forward.y), target - forward * (LOOK_AHEAD * 0.5))
		field.append(_add_car(holder, pose, forward * WorldScale.metres(25.0)))
	return field


## One timed run: a warm-up batch that is thrown away, then COST_BATCHES batches whose median is
## taken. The first batch pays for the script's first walk through every branch and for cold grid
## cells, neither of which a running game pays every frame.
func _measure_cost(world: Dictionary, field: Array[TopDownCar], look_ahead: float = LOOK_AHEAD) -> Dictionary:
	var sensing := _make_pass(world)
	var passes := 0
	var roads := 0
	var obstacles := 0
	var batches: Array[float] = []
	for batch in range(COST_BATCHES + 1):
		var started := Time.get_ticks_usec()
		for repeat in range(COST_PASSES_PER_BATCH):
			var senses := sensing.sense(field, repeat % field.size(), look_ahead)
			passes += 1
			roads += int(senses.road_found)
			obstacles += int(senses.has_obstacle_ahead)
		var elapsed := Time.get_ticks_usec() - started
		if batch > 0:
			batches.append(float(elapsed) / float(COST_PASSES_PER_BATCH))
	batches.sort()
	return {
		"median": batches[batches.size() / 2],
		"fastest": batches[0],
		"slowest": batches[-1],
		"passes": passes,
		"roads": roads,
		"obstacles": obstacles,
	}


## The fixture layout, placed. Everything below goes through `placement`, so two calls with two
## transforms describe the same world seen from two places.
func _build_fixture_world(placement: Transform2D, lateral: float = CAR_LOCAL_LATERAL, yaw_degrees: float = CAR_YAW_DEGREES) -> Dictionary:
	var holder := Node2D.new()
	root.add_child(holder)

	var definition := TrackDefinition.new()
	var centerline := PackedVector2Array()
	var x := -LOCAL_ROAD_HALF_LENGTH
	while x <= LOCAL_ROAD_HALF_LENGTH:
		centerline.append(placement * Vector2(x, 0.0))
		x += LOCAL_ROAD_SPACING
	definition.centerline = centerline
	definition.track_width = FIXTURE_TRACK_WIDTH

	# The car's pose: `lateral` px to the road's right, nose `yaw_degrees` off the road's direction.
	# Built in the local frame and carried out by the placement, like everything else.
	var local_forward := Vector2.RIGHT.rotated(deg_to_rad(yaw_degrees))
	var local_pose := Transform2D(atan2(local_forward.x, -local_forward.y), Vector2(0.0, lateral))
	var car_pose := placement * local_pose

	# Mid, near, far -- in that order on purpose. See RIVAL_MID_IN_CAR_FRAME.
	var field: Array[TopDownCar] = []
	field.append(_add_car(holder, car_pose, car_pose.basis_xform(OWN_VELOCITY_IN_CAR_FRAME)))
	field.append(_add_car(holder, Transform2D(car_pose.get_rotation(), car_pose * RIVAL_MID_IN_CAR_FRAME), car_pose.basis_xform(RIVAL_MID_VELOCITY_IN_CAR_FRAME)))
	field.append(_add_car(holder, Transform2D(car_pose.get_rotation(), car_pose * RIVAL_NEAR_IN_CAR_FRAME), car_pose.basis_xform(RIVAL_NEAR_VELOCITY_IN_CAR_FRAME)))
	field.append(_add_car(holder, Transform2D(car_pose.get_rotation(), car_pose * RIVAL_FAR_IN_CAR_FRAME), car_pose.basis_xform(RIVAL_FAR_VELOCITY_IN_CAR_FRAME)))
	field.append(_add_car(holder, Transform2D(car_pose.get_rotation(), car_pose * RIVAL_BEHIND_IN_CAR_FRAME), Vector2.ZERO))
	field.append(_add_car(holder, Transform2D(car_pose.get_rotation(), car_pose * RIVAL_BEYOND_IN_CAR_FRAME), Vector2.ZERO))

	var near_obstacle := _add_obstacle(holder, car_pose * NEAR_OBSTACLE_IN_CAR_FRAME, NEAR_OBSTACLE_RADIUS)
	var far_obstacle := _add_obstacle(holder, car_pose * FAR_OBSTACLE_IN_CAR_FRAME, FAR_OBSTACLE_RADIUS)

	return {
		"holder": holder,
		"definition": definition,
		"surface": TrackSurfaceMap.new(definition),
		"height": LocalGroundHeight.new(placement),
		"field": field,
		"near_obstacle": near_obstacle,
		"far_obstacle": far_obstacle,
	}


## A real generated circuit with its real trees and rocks in the space, and twenty cars racing it:
## spread around the lap, spread across the road's width, pointing the way the road runs. This is
## what the cost figure is measured on.
##
## The physics frame is not optional. OfftrackObjectCollisions adds each chunk body first and its
## shapes afterwards, and a shape added to a body that is already in the tree does not reach the
## broadphase until a step has run. Without the await below the track's 174 colliders are in the
## scene and invisible to every ray, and a cost measured against them is a cost of nothing --
## `collider_count()` counts nodes and would report all 174 regardless.
func _build_cost_world() -> Dictionary:
	var holder := Node2D.new()
	root.add_child(holder)
	var definition: TrackDefinition = TrackGenerator.new().generate(COST_SEED)
	var collisions := OfftrackObjectCollisions.new()
	holder.add_child(collisions)
	collisions.build(definition.offtrack_objects, load(OBJECT_CATALOG_PATH) as OfftrackObjectCatalog)
	await physics_frame

	var unique_count := definition.centerline.size() - 1
	var half_width: float = definition.track_width * 0.5
	var field: Array[TopDownCar] = []
	for index in range(FIELD_SIZE):
		var vertex := (index * unique_count) / FIELD_SIZE
		var following: Vector2 = definition.centerline[(vertex + 1) % unique_count]
		var forward := (following - definition.centerline[vertex]).normalized()
		# Across the road as well as around it, so the road query is answered from a spread of
		# offsets rather than from the one point on the centreline that every grid cell is built
		# around.
		var lateral := (float(index % 5) / 4.0 - 0.5) * half_width
		var origin: Vector2 = definition.centerline[vertex] + SurfaceQuery.right_normal(forward) * lateral
		var pose := Transform2D(atan2(forward.x, -forward.y), origin)
		field.append(_add_car(holder, pose, forward * WorldScale.metres(25.0)))
	return {
		"holder": holder,
		"definition": definition,
		"surface": TrackSurfaceMap.new(definition),
		"height": TrackHeightMap.new(definition),
		"field": field,
		"collider_count": collisions.collider_count(),
		"solids": _solid_positions(definition),
	}


## Where the track's solid objects actually stand. Used to prove the space really holds them, and
## to build the second cost field -- the one whose rays hit.
func _solid_positions(definition: TrackDefinition) -> PackedVector2Array:
	var positions := PackedVector2Array()
	for placement: OfftrackObjectPlacement in definition.offtrack_objects:
		if placement != null and placement.solid:
			positions.append(placement.transform.origin)
	return positions


func _add_car(holder: Node2D, pose: Transform2D, velocity: Vector2) -> TopDownCar:
	var car := CAR_SCENE.instantiate() as TopDownCar
	# Frozen and process-less: the fixture states a pose and a velocity and they stay stated. No
	# physics step is taken in this file, so nothing integrates them either way; freezing means a
	# stray one could not.
	car.freeze = true
	holder.add_child(car)
	car.set_process(false)
	car.global_transform = pose
	car.linear_velocity = velocity
	return car


func _add_obstacle(holder: Node2D, position: Vector2, radius: float) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.collision_layer = OfftrackObjectCollisions.TALL_LAYER
	body.collision_mask = 0
	body.position = position
	var shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = radius
	shape.shape = circle
	body.add_child(shape)
	holder.add_child(body)
	return body


func _make_pass(world: Dictionary) -> InstrumentedPass:
	return InstrumentedPass.new(world["surface"], world["height"], _break_frame)


func _sense_fixture_car(world: Dictionary, look_ahead: float) -> DriverSenses:
	return _make_pass(world).sense(world["field"], 0, look_ahead)


func _tear_down(world: Dictionary) -> void:
	var holder: Node2D = world["holder"]
	holder.get_parent().remove_child(holder)
	holder.free()


func _close(actual: Vector2, expected: Vector2) -> bool:
	return actual.distance_to(expected) < POSITION_TOLERANCE


## Compares one DriverSenses field between two placements, with the tolerance its unit earns. Bools,
## ints and enums must match exactly; lengths carry the rounding of a rigid motion 15,000 px from
## the origin, and the one angle is held to a far tighter bound because rotating a fixture does not
## cost an angle any precision.
func _fields_agree(field_name: String, left, right) -> bool:
	if typeof(left) != typeof(right):
		return false
	match typeof(left):
		TYPE_VECTOR2:
			return (left as Vector2).distance_to(right as Vector2) < POSITION_TOLERANCE
		TYPE_FLOAT:
			var tolerance := ANGLE_TOLERANCE if field_name == "heading_error" else POSITION_TOLERANCE
			return absf((left as float) - (right as float)) < tolerance
		_:
			return left == right


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
