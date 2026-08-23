class_name TimeTrialState
extends RefCounted

## Deterministic session state kept separate from scene/UI concerns so pause,
## restart, and lap validity share one source of truth.

var current_lap_time := 0.0
var session_time := 0.0
var last_lap_time := 0.0
var best_lap_time := 0.0
var paused := false

var lap_count: int:
	get:
		return _progress.lap_count

var next_checkpoint: int:
	get:
		return _progress.next_checkpoint

var _progress: LapProgressTracker


func _init(checkpoint_count: int) -> void:
	_progress = LapProgressTracker.new(checkpoint_count)


func advance_time(delta: float) -> void:
	if paused:
		return
	var safe_delta := maxf(delta, 0.0)
	current_lap_time += safe_delta
	session_time += safe_delta


func cross_checkpoint(checkpoint_index: int, forward_dot: float) -> bool:
	if paused or not _progress.cross_checkpoint(checkpoint_index, forward_dot):
		return false
	last_lap_time = current_lap_time
	if best_lap_time <= 0.0 or last_lap_time < best_lap_time:
		best_lap_time = last_lap_time
	current_lap_time = 0.0
	return true


func set_paused(is_paused: bool) -> void:
	paused = is_paused


func restart() -> void:
	_progress.reset()
	current_lap_time = 0.0
	session_time = 0.0
	last_lap_time = 0.0
	best_lap_time = 0.0
	paused = false
