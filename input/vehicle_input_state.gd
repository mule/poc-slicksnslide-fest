class_name VehicleInputState
extends RefCounted

## Hardware-independent controls consumed by vehicle dynamics.

var steer: float = 0.0
var throttle: float = 0.0
var brake: float = 0.0
var handbrake: float = 0.0


func set_controls(
	steer_value: float,
	throttle_value: float,
	brake_value: float,
	handbrake_value: float,
) -> void:
	steer = clampf(steer_value, -1.0, 1.0)
	throttle = clampf(throttle_value, 0.0, 1.0)
	brake = clampf(brake_value, 0.0, 1.0)
	handbrake = clampf(handbrake_value, 0.0, 1.0)


func reset() -> void:
	set_controls(0.0, 0.0, 0.0, 0.0)
