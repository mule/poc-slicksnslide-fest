class_name HeightQuery
extends RefCounted

## Position-based ground height contract consumed by vehicle dynamics.
##
## Height is measured in world pixels above the flat plane, like every other length. The gradient is
## world-space dh/dx and dh/dy, so `velocity.dot(gradient)` is the ground's vertical rate under a
## moving body. `feature_height` is the part of the height a placed feature -- a jump ramp, with
## its flank -- contributes on top of the terrain: zero on bare ground however high or steep it
## is, and positive anywhere on a ramp. The car's safe-pose rule reads it to keep a reset off a
## ramp without refusing every pose on rolling terrain. The base implementation is flat ground:
## a provider with no notion of height keeps the car on the ground rather than erroring.


class HeightSample:
	extends RefCounted

	var ground_height: float
	var gradient: Vector2
	var feature_height: float


	func _init(initial_ground_height: float = 0.0, initial_gradient: Vector2 = Vector2.ZERO, initial_feature_height: float = 0.0) -> void:
		ground_height = initial_ground_height
		gradient = initial_gradient
		feature_height = initial_feature_height


func sample_at(_world_position: Vector2) -> HeightSample:
	return HeightSample.new()
