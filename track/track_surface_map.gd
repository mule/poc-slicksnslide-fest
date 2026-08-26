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
