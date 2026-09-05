class_name HeightQuery
extends RefCounted

## Position-based ground height contract consumed by vehicle dynamics.
##
## Height is measured in world pixels above the flat plane, like every other length. The gradient is
## world-space dh/dx and dh/dy, so `velocity.dot(gradient)` is the ground's vertical rate under a
## moving body. The base implementation is flat ground: a provider with no notion of height keeps
## the car on the ground rather than erroring.


class HeightSample:
	extends RefCounted

	var ground_height: float
	var gradient: Vector2


	func _init(initial_ground_height: float = 0.0, initial_gradient: Vector2 = Vector2.ZERO) -> void:
		ground_height = initial_ground_height
		gradient = initial_gradient


func sample_at(_world_position: Vector2) -> HeightSample:
	return HeightSample.new()
