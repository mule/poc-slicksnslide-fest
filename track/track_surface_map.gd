class_name TrackSurfaceMap
extends SurfaceQuery

const DIRT_GRIP := 1.0
const DIRT_DRAG := 1.0
const GRASS_GRIP := 0.55
const GRASS_DRAG := 2.2

var _definition


func _init(definition) -> void:
	_definition = definition


func sample_at(world_position: Vector2) -> SurfaceSample:
	if _definition != null and _distance_to_centerline(world_position) <= _definition.track_width * 0.5:
		return SurfaceSample.new(SurfaceType.DIRT, DIRT_GRIP, DIRT_DRAG)
	return SurfaceSample.new(SurfaceType.OFF_TRACK, GRASS_GRIP, GRASS_DRAG)


func _distance_to_centerline(world_position: Vector2) -> float:
	var nearest_distance := INF
	for index in range(_definition.centerline.size() - 1):
		var closest := Geometry2D.get_closest_point_to_segment(
			world_position,
			_definition.centerline[index],
			_definition.centerline[index + 1],
		)
		nearest_distance = minf(nearest_distance, world_position.distance_to(closest))
	return nearest_distance
