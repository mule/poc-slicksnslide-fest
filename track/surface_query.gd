class_name SurfaceQuery
extends RefCounted

## Position-based surface contract consumed by vehicle dynamics.

enum SurfaceType {
	UNKNOWN,
	DIRT,
	OFF_TRACK,
}


class SurfaceSample:
	extends RefCounted

	var surface_type: SurfaceType
	var grip_multiplier: float
	var drag_multiplier: float


	func _init(
		initial_surface_type: SurfaceType = SurfaceType.UNKNOWN,
		initial_grip_multiplier: float = 1.0,
		initial_drag_multiplier: float = 1.0,
	) -> void:
		surface_type = initial_surface_type
		grip_multiplier = initial_grip_multiplier
		drag_multiplier = initial_drag_multiplier


func sample_at(_world_position: Vector2) -> SurfaceSample:
	push_error("SurfaceQuery.sample_at must be implemented by a track surface provider")
	return SurfaceSample.new()


## Distance from a world position to the track centerline, accurate out to search_radius.
##
## Beyond search_radius an implementation may return INF instead of a true distance. The real
## provider answers from a spatial grid queried with exactly this radius, so a caller pays only
## for the range it needs. Callers must pass the largest distance they care about and read INF as
## "further away than that".
##
## The base implementation returns 0.0 rather than pushing an error: a provider with no notion of
## a centerline should read as "on the line" so distance-based rules never fire against it.
## Returning INF here would make every such provider permanently "lost".
func distance_to_centerline(_world_position: Vector2, _search_radius: float) -> float:
	return 0.0
