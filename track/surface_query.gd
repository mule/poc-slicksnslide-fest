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


## Where the road is, and which way it runs, at a world position.
##
## `distance_to_centerline` answers how far, and that is all the car's own rules ever needed. A
## driver needs which SIDE it is on and which way the road points, and neither is recoverable from
## the unsigned distance: the field's gradient is exactly zero on the centerline itself, which is
## where a car normally sits. Both come out of the nearest segment for free, so this returns the
## segment's frame rather than making a caller probe for it.
class RoadFrame:
	extends RefCounted

	## False when no centerline segment lay inside the search radius, and on any provider with no
	## centerline at all. Every other field is then meaningless and reads as zero.
	var found: bool
	## Unsigned distance to the centerline. Equal, bit for bit, to distance_to_centerline() called
	## with the same arguments; tests/driver_senses_test.gd pins that with `==`.
	var distance: float
	## `distance`, signed: positive when the position lies to the RIGHT of the road. Right is taken
	## from the road's own direction of travel -- the centerline's index order -- and not from any
	## car's heading, so the sign is a property of the track and stays put when a car spins.
	##
	## The magnitude is `distance` rather than the perpendicular component, so the two never
	## disagree. They differ only outside a segment's ends, where the nearest point is a vertex and
	## nothing is perpendicular to anything.
	var lateral_offset: float
	## Unit direction of the nearest segment, in index order.
	var tangent: Vector2
	## Half the track width, so a caller can turn `lateral_offset` into a distance to each edge
	## without needing the definition the provider was built from.
	var half_width: float


	func _init(
		initial_found: bool = false,
		initial_distance: float = 0.0,
		initial_lateral_offset: float = 0.0,
		initial_tangent: Vector2 = Vector2.RIGHT,
		initial_half_width: float = 0.0,
	) -> void:
		found = initial_found
		distance = initial_distance
		lateral_offset = initial_lateral_offset
		tangent = initial_tangent
		half_width = initial_half_width


## The road's own right-hand normal for a tangent. Screen y grows downward, so a tangent pointing
## east turns into a normal pointing south, which is a driver's right hand when it faces east --
## the same handedness as TopDownCar's local +x.
static func right_normal(tangent: Vector2) -> Vector2:
	return Vector2(-tangent.y, tangent.x)


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


## The nearest centerline segment's frame, subject to the same search_radius contract as
## distance_to_centerline.
##
## The base implementation reports `found = false` rather than "on the line". distance_to_centerline
## answers 0.0 there so that a distance rule never fires against a provider with no centerline;
## a driver asking where the road runs needs the opposite answer, because a fabricated tangent would
## have it steer confidently along a road that does not exist.
func road_frame_at(_world_position: Vector2, _search_radius: float) -> RoadFrame:
	return RoadFrame.new()
