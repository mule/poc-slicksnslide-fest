class_name TrackSurfaceMap
extends SurfaceQuery

const DIRT_GRIP := 1.0
const DIRT_DRAG := 1.0
const GRASS_GRIP := 0.55
const GRASS_DRAG := 2.2

var _definition
var _grid: SegmentGrid


func _init(definition) -> void:
	_definition = definition
	if _definition != null and _definition.centerline.size() >= 2:
		_grid = SegmentGrid.new(_definition.centerline, maxf(_definition.track_width, 1.0))


func sample_at(world_position: Vector2) -> SurfaceSample:
	if _definition != null:
		var half_width: float = _definition.track_width * 0.5
		if distance_to_centerline(world_position, half_width) <= half_width:
			return SurfaceSample.new(SurfaceType.DIRT, DIRT_GRIP, DIRT_DRAG)
	return SurfaceSample.new(SurfaceType.OFF_TRACK, GRASS_GRIP, GRASS_DRAG)


func distance_to_centerline(world_position: Vector2, search_radius: float) -> float:
	if _grid == null:
		return INF
	var nearest_distance := INF
	for index in _grid.segments_near(world_position, search_radius):
		var closest := Geometry2D.get_closest_point_to_segment(
			world_position,
			_definition.centerline[index],
			_definition.centerline[index + 1],
		)
		nearest_distance = minf(nearest_distance, world_position.distance_to(closest))
	return nearest_distance


## The nearest segment's frame, from the same grid walk and the same geometry test as
## distance_to_centerline above.
##
## The two loops are deliberately not shared. This one has to remember WHICH segment won, which
## minf() throws away, and distance_to_centerline sits on the car's automatic-reset path where a
## refactor that is only probably bit-identical is not worth the risk. What keeps them honest is an
## assertion instead of a shared line: driver_senses_test compares the two answers with `==` across
## a sampled lap.
func road_frame_at(world_position: Vector2, search_radius: float) -> RoadFrame:
	if _grid == null:
		return RoadFrame.new()
	var half_width: float = _definition.track_width * 0.5
	var nearest_distance := INF
	var nearest_index := -1
	var nearest_point := Vector2.ZERO
	for index in _grid.segments_near(world_position, search_radius):
		var closest := Geometry2D.get_closest_point_to_segment(
			world_position,
			_definition.centerline[index],
			_definition.centerline[index + 1],
		)
		var candidate := world_position.distance_to(closest)
		if candidate < nearest_distance:
			nearest_distance = candidate
			nearest_index = index
			nearest_point = closest
	if nearest_index < 0:
		return RoadFrame.new()
	var tangent: Vector2 = (_definition.centerline[nearest_index + 1] - _definition.centerline[nearest_index]).normalized()
	# A repeated centerline point has no direction, and a fabricated one would point a driver
	# somewhere arbitrary. The generator never emits one -- its samples are spaced and its closing
	# point joins back to the first -- so this reports "no road here" rather than guessing, and a
	# hand-built fixture that trips it says so out loud instead of steering oddly.
	if tangent == Vector2.ZERO:
		return RoadFrame.new()
	var side := (world_position - nearest_point).dot(SurfaceQuery.right_normal(tangent))
	return RoadFrame.new(true, nearest_distance, signf(side) * nearest_distance, tangent, half_width)
