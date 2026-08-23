class_name CheckpointCrossingDetector
extends RefCounted

## Detects movement through finite checkpoint gates. Ordering and lap counting
## remain the responsibility of TimeTrialState/LapProgressTracker.

var _definition
var _previous_position := Vector2.ZERO
var _has_previous_position := false


func _init(definition) -> void:
	_definition = definition


func reset(position: Vector2) -> void:
	_previous_position = position
	_has_previous_position = true


func sample(position: Vector2) -> Dictionary:
	if not _has_previous_position:
		reset(position)
		return {}
	var movement := position - _previous_position
	var result := _find_forward_crossing(_previous_position, position, movement)
	_previous_position = position
	return result


func _find_forward_crossing(previous: Vector2, current: Vector2, movement: Vector2) -> Dictionary:
	if _definition == null or movement.length_squared() <= 0.000001:
		return {}
	for index in range(_definition.checkpoints.size()):
		var checkpoint: Transform2D = _definition.checkpoints[index]
		var forward := checkpoint.x.normalized()
		var previous_distance := (previous - checkpoint.origin).dot(forward)
		var current_distance := (current - checkpoint.origin).dot(forward)
		if previous_distance > 0.0 or current_distance <= 0.0:
			continue
		var forward_dot := movement.normalized().dot(forward)
		if forward_dot <= 0.0:
			continue
		var crossing_ratio := -previous_distance / (current_distance - previous_distance)
		var crossing_point := previous.lerp(current, crossing_ratio)
		var lateral := Vector2(-forward.y, forward.x)
		if absf((crossing_point - checkpoint.origin).dot(lateral)) > _definition.track_width * 0.5:
			continue
		return {"checkpoint": index, "forward_dot": forward_dot}
	return {}
