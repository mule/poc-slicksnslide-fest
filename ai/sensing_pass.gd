class_name SensingPass
extends RefCounted

## Builds one car's DriverSenses from the world, once per tick, from sources chosen so that the
## answer is the same on every machine.
##
## ## Who owns this
##
## Not the driver. A driver never holds a car, so it cannot sense for itself; whoever owns the
## field (task #60) owns one pass, runs it per car, and hands the resulting DriverSenses -- pure
## data, no handles -- to that car's driver. The pass may hold cars precisely because it is not one
## of the things the seam isolates.
##
## ## Which source answers which sense, and why
##
## | Sense | Source | Why |
## | --- | --- | --- |
## | Where the road is | `SurfaceQuery.road_frame_at` | Analytic, indexed, the same centerline the car's own rules read |
## | What is underneath | `SurfaceQuery.sample_at` | The car already samples exactly this |
## | The ground ahead | the injected `HeightQuery` | Lets a driver lift for a crest it is about to launch off |
## | Where the rivals are | the field's own list | You have the list. Do not raycast for it. |
## | Trees, rocks, the boundary | ONE ray, nearest hit | The only sense with no cheaper deterministic source |
##
## The last row is the constraint this whole class exists to hold. `intersect_ray` returns a single
## nearest hit; `intersect_shape` returns an array whose order Godot does not specify, and an
## unordered result is a determinism bug that reproduces on one machine and not another, months
## later, as a fingerprint that moved for no reason. There is exactly one physics query in a pass
## and it is a ray.
##
## ## The budget
##
## A pass costs a fixed **five** queries whatever the world contains: two on the surface query
## (`road_frame_at` and `sample_at`, both under the car), two on the height query (under the car and
## at the look-ahead point), and one physics ray. None of them sit inside a loop, and the rival
## scan issues none at all. tests/driver_senses_test.gd counts all five through its own fixtures
## and fails if the number moves.
##
## ## Purity
##
## A pass writes nothing and moves nothing: it reads poses and velocities and returns a new value.
## It also holds no sample across a query -- TrackHeightMap hands back one shared, re-zeroed sample
## on its miss path, so a held sample is silently rewritten by the next query. Every read happens
## before the next call, and the height block below is written in that order on purpose.

var _surface_query: SurfaceQuery
var _height_query: HeightQuery


## Either query may be left null, and a missing one reads as no information rather than as an
## error: no road found, an unknown surface, flat ground. That is how TopDownCar treats its own
## null queries, and it keeps a fixture that only cares about rivals from having to build a track.
func _init(surface_query: SurfaceQuery = null, height_query: HeightQuery = null) -> void:
	_surface_query = surface_query
	_height_query = height_query


## `field` is every car racing, the sensing car included; `car_index` picks whose point of view this
## is. `look_ahead` is the sensing horizon in pixels -- a parameter and not a constant, because how
## far ahead a driver sees is the one dial that most changes how it behaves, and task #59 varies it
## by skill. It bounds all three forward senses: the ground probe, the rival scan and the ray.
func sense(field: Array[TopDownCar], car_index: int, look_ahead: float) -> DriverSenses:
	var senses := DriverSenses.new()
	if car_index < 0 or car_index >= field.size():
		push_error("SensingPass.sense called for car %d of a field of %d" % [car_index, field.size()])
		return senses
	var car: TopDownCar = field[car_index]
	if car == null:
		push_error("SensingPass.sense called for a null car at index %d" % car_index)
		return senses

	senses.look_ahead = look_ahead
	var frame := _car_frame(car)
	var position := frame.origin
	var forward := -frame.y.normalized()
	var look_ahead_point := position + forward * look_ahead
	senses.local_velocity = frame.basis_xform_inv(car.linear_velocity)

	_sense_road(senses, position, forward, look_ahead)
	_sense_surface(senses, position)
	_sense_ground(senses, frame, position, look_ahead_point)
	_sense_rivals(senses, field, car_index, frame, position, car.linear_velocity, look_ahead)
	_sense_obstacle(senses, car, field, frame, position, look_ahead_point)
	return senses


## The pose every sense is built from, read once. Overriding this substitutes a different frame for
## the whole pass, which is what `--break-sense-frame` does: an identity basis at the car's own
## position turns every car-frame value back into the world-frame one it came from.
func _car_frame(car: TopDownCar) -> Transform2D:
	return car.global_transform


## The one physics query in a pass, behind a name so a test can count it without counting itself.
func _cast_obstacle_ray(space_state: PhysicsDirectSpaceState2D, query: PhysicsRayQueryParameters2D) -> Dictionary:
	return space_state.intersect_ray(query)


## The search radius the road is looked for in. Half a track width would find the road only while
## the car is on it, and a driver that has run wide needs to know which way back; the look-ahead is
## already the pass's statement of how far this driver sees, so the road is looked for that far to
## the side as well.
func _road_search_radius(look_ahead: float) -> float:
	return look_ahead


func _sense_road(senses: DriverSenses, position: Vector2, forward: Vector2, look_ahead: float) -> void:
	if _surface_query == null:
		return
	var road := _surface_query.road_frame_at(position, _road_search_radius(look_ahead))
	senses.road_found = road.found
	if not road.found:
		return
	senses.lateral_offset = road.lateral_offset
	senses.heading_error = road.tangent.angle_to(forward)
	# Positive offset is to the road's right, so it eats into the right edge's margin and adds to
	# the left's. Left unclamped: a negative distance is a car that has crossed that edge and how
	# far outside it is, which a recovery rule needs and a clamp to zero would erase.
	senses.distance_to_right_edge = road.half_width - road.lateral_offset
	senses.distance_to_left_edge = road.half_width + road.lateral_offset


func _sense_surface(senses: DriverSenses, position: Vector2) -> void:
	if _surface_query == null:
		return
	var sample := _surface_query.sample_at(position)
	senses.surface_type = sample.surface_type
	senses.surface_grip = sample.grip_multiplier
	senses.surface_drag = sample.drag_multiplier


## Two height queries, and the first sample's value is taken out of it before the second is issued.
## TrackHeightMap's miss path returns one shared instance that the next query rewrites, so holding
## `here` across the `sample_at` below would silently give the ground ahead twice and report a flat
## world. The order of these five lines is the contract, not a style choice.
func _sense_ground(senses: DriverSenses, frame: Transform2D, position: Vector2, look_ahead_point: Vector2) -> void:
	if _height_query == null:
		return
	var here := _height_query.sample_at(position)
	var ground_here := here.ground_height
	var ahead := _height_query.sample_at(look_ahead_point)
	senses.height_change_ahead = ahead.ground_height - ground_here
	senses.gradient_ahead = frame.basis_xform_inv(ahead.gradient)


## A list scan, no queries. "Ahead" is a positive component along the nose and within the horizon;
## "nearest" is by straight-line distance. Ties keep the lower index, so a field that has not moved
## produces the same answer twice.
func _sense_rivals(
	senses: DriverSenses,
	field: Array[TopDownCar],
	car_index: int,
	frame: Transform2D,
	position: Vector2,
	velocity: Vector2,
	look_ahead: float,
) -> void:
	var nearest_distance := INF
	var nearest_index := -1
	for index in range(field.size()):
		if index == car_index:
			continue
		var rival: TopDownCar = field[index]
		if rival == null:
			continue
		var separation := rival.global_position - position
		var distance := separation.length()
		if distance > look_ahead or distance >= nearest_distance:
			continue
		if frame.basis_xform_inv(separation).y >= 0.0:
			continue
		nearest_distance = distance
		nearest_index = index
	if nearest_index < 0:
		return
	var rival: TopDownCar = field[nearest_index]
	senses.has_rival_ahead = true
	senses.rival_offset = frame.basis_xform_inv(rival.global_position - position)
	senses.rival_distance = nearest_distance
	senses.rival_relative_velocity = frame.basis_xform_inv(rival.linear_velocity - velocity)


## One ray, nearest hit, along the nose, as far as the horizon.
##
## The mask is the car's own collision level, so a car flying high enough to clear the low obstacles
## stops sensing them -- it senses what it can actually hit. Every car in the field is excluded:
## cars share the tall layer with trees by design, and rivals are already a list.
func _sense_obstacle(
	senses: DriverSenses,
	car: TopDownCar,
	field: Array[TopDownCar],
	frame: Transform2D,
	position: Vector2,
	look_ahead_point: Vector2,
) -> void:
	# A car outside the tree has no World2D and therefore no space to cast into, so there is nothing
	# to sense and no way to say so in the senses: the result is the same has_obstacle_ahead = false
	# that a genuinely clear road produces, and no assertion could tell those apart. It is reported
	# rather than left silent for the same reason sense() reports a bad index — task #60 spawns the
	# field, and "the rivals never see anything" is a great deal easier to diagnose from one error
	# line than from a driver that calmly drives through trees.
	if not car.is_inside_tree():
		push_error("SensingPass cannot sense obstacles for car %s: it is not in the scene tree" % car.name)
		return
	# A car with no tuning has no collision level to ask for -- TopDownCar reads its clearance out of
	# the tuning -- and reaching for one anyway aborts this function on a null access, which leaves
	# the rest of the senses looking complete while the obstacle block stays quietly empty, once per
	# car per tick. Task #56's review found the same hole in the camera gate and task #60 spawns the
	# field, so a rival reaching a sensing pass before its tuning is assigned is a path that ships.
	#
	# It falls back to BOTH layers, which is exactly what a grounded car's mask is, rather than to
	# no obstacle sense: missing tuning is a reason to see everything the car could hit, not a reason
	# to go blind. Falling back to "no obstacle" would also have been indistinguishable from the
	# crash it replaces, and an unprovable guard is not a guard.
	var mask := TopDownCar.TALL_LAYER | TopDownCar.LOW_LAYER
	if car.tuning != null:
		mask = car.get_collision_level_mask()
	var excluded: Array[RID] = []
	for other in field:
		if other != null:
			excluded.append(other.get_rid())
	var query := PhysicsRayQueryParameters2D.create(
		position,
		look_ahead_point,
		mask,
		excluded,
	)
	var hit := _cast_obstacle_ray(car.get_world_2d().direct_space_state, query)
	if hit.is_empty():
		return
	var separation: Vector2 = hit["position"] - position
	senses.has_obstacle_ahead = true
	senses.obstacle_offset = frame.basis_xform_inv(separation)
	senses.obstacle_distance = separation.length()
