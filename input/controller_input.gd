class_name ControllerInput
extends RefCounted

## Polls raw device-independent action strengths and converts them into the
## normalized controls consumed by TopDownCar.

var _stick_deadzone: float
var _trigger_deadzone: float
var _suppressed_until_release := false
var _state := VehicleInputState.new()


func _init(stick_deadzone := 0.2, trigger_deadzone := 0.1) -> void:
	_stick_deadzone = clampf(stick_deadzone, 0.0, 0.95)
	_trigger_deadzone = clampf(trigger_deadzone, 0.0, 0.95)


func apply_raw_values(
	steer_value: float,
	throttle_value: float,
	brake_value: float,
	handbrake_pressed: bool,
) -> VehicleInputState:
	if _suppressed_until_release:
		_state.reset()
		if _controls_are_released(steer_value, throttle_value, brake_value, handbrake_pressed):
			_suppressed_until_release = false
		return _state
	_state.set_controls(
		_apply_signed_deadzone(steer_value, _stick_deadzone),
		_apply_positive_deadzone(throttle_value, _trigger_deadzone),
		_apply_positive_deadzone(brake_value, _trigger_deadzone),
		1.0 if handbrake_pressed else 0.0,
	)
	return _state


func poll_actions() -> VehicleInputState:
	var steer_value := (
		Input.get_action_raw_strength("steer_right")
		- Input.get_action_raw_strength("steer_left")
	)
	return apply_raw_values(
		steer_value,
		Input.get_action_raw_strength("throttle"),
		Input.get_action_raw_strength("brake_reverse"),
		Input.is_action_pressed("handbrake"),
	)


func suppress_until_controls_released() -> void:
	_suppressed_until_release = true
	_state.reset()


func _controls_are_released(steer_value: float, throttle_value: float, brake_value: float, handbrake_pressed: bool) -> bool:
	return (
		absf(steer_value) <= _stick_deadzone
		and throttle_value <= _trigger_deadzone
		and brake_value <= _trigger_deadzone
		and not handbrake_pressed
	)


func _apply_signed_deadzone(value: float, deadzone: float) -> float:
	var magnitude := _apply_positive_deadzone(absf(value), deadzone)
	return signf(value) * magnitude


func _apply_positive_deadzone(value: float, deadzone: float) -> float:
	return clampf((clampf(value, 0.0, 1.0) - deadzone) / (1.0 - deadzone), 0.0, 1.0)
