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
