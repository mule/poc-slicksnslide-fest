class_name Issue4TestSurfaceProvider
extends SurfaceQuery

## Deterministic, track-independent surface boundary for issue #4 maneuvers.

var boundary_y: float = -INF
var dirt_grip: float = 1.0
var dirt_drag: float = 1.0
var off_track_grip: float = 1.0
var off_track_drag: float = 1.0
var distance_from_line: float = 0.0


func sample_at(world_position: Vector2) -> SurfaceSample:
	if world_position.y <= boundary_y:
		return SurfaceSample.new(SurfaceType.OFF_TRACK, off_track_grip, off_track_drag)
	return SurfaceSample.new(SurfaceType.DIRT, dirt_grip, dirt_drag)


func distance_to_centerline(_world_position: Vector2, _search_radius: float) -> float:
	return distance_from_line
