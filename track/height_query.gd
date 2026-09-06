class_name HeightQuery
extends RefCounted

## Position-based ground height contract consumed by vehicle dynamics.
##
## Height is measured in world pixels above the flat plane, like every other length. The gradient is
## world-space dh/dx and dh/dy, so `velocity.dot(gradient)` is the ground's vertical rate under a
## moving body. `on_feature` says whether the position lies inside a placed feature -- a jump
## ramp, with its flank -- as opposed to bare terrain however high or steep it is. It is a boolean
## and not the feature's height on purpose: the one consumer, the car's safe-pose rule, needs
## membership and nothing else, and a height would invite the reading "raised means feature",
## which a dip carved into the road would falsify. The base implementation is flat ground: a
## provider with no notion of height keeps the car on the ground rather than erroring.


class HeightSample:
	extends RefCounted

	var ground_height: float
	var gradient: Vector2
	var on_feature: bool


	func _init(initial_ground_height: float = 0.0, initial_gradient: Vector2 = Vector2.ZERO, initial_on_feature: bool = false) -> void:
		ground_height = initial_ground_height
		gradient = initial_gradient
		on_feature = initial_on_feature


func sample_at(_world_position: Vector2) -> HeightSample:
	return HeightSample.new()
