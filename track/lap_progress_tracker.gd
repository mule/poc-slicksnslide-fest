class_name LapProgressTracker
extends RefCounted

var lap_count := 0
var next_checkpoint := 1
var _checkpoint_count: int


func _init(checkpoint_count: int) -> void:
	_checkpoint_count = maxi(checkpoint_count, 2)


func cross_checkpoint(checkpoint_index: int, forward_dot: float) -> bool:
	if forward_dot <= 0.0 or checkpoint_index != next_checkpoint:
		return false
	if checkpoint_index == 0:
		lap_count += 1
		next_checkpoint = 1
		return true
	next_checkpoint = (next_checkpoint + 1) % _checkpoint_count
	return false


func reset() -> void:
	lap_count = 0
	next_checkpoint = 1
