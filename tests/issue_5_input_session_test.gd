extends SceneTree

const CONTROLLER_INPUT_PATH := "res://input/controller_input.gd"
const TIME_TRIAL_STATE_PATH := "res://session/time_trial_state.gd"
const CHECKPOINT_DETECTOR_PATH := "res://session/checkpoint_crossing_detector.gd"

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Each verification reports whether it ran to completion. A GDScript runtime error aborts
	# only the function it occurs in and returns false to here, so without this the script
	# would exit 0 with assertions silently skipped. See tests/harness_contract_test.gd.
	_check(_verify_input_map_contract(), "the input map contract verification ran to completion")
	_check(_verify_analog_input_normalization(), "the analog input normalization verification ran to completion")
	_check(_verify_time_trial_state(), "the time trial state verification ran to completion")
	_check(_verify_checkpoint_crossings(), "the checkpoint crossings verification ran to completion")
	_finish()


func _verify_input_map_contract() -> bool:
	var expected_actions := [
		"steer_left",
		"steer_right",
		"throttle",
		"brake_reverse",
		"handbrake",
		"reset_car",
		"pause_back",
		"confirm",
	]
	for action in expected_actions:
		_check(InputMap.has_action(action), "InputMap defines %s" % action)
		if not InputMap.has_action(action):
			continue
		var events := InputMap.action_get_events(action)
		_check(events.any(func(event): return event is InputEventKey), "%s retains a keyboard fallback" % action)
		_check(events.any(func(event): return event is InputEventJoypadButton or event is InputEventJoypadMotion), "%s has a controller mapping" % action)

	_check(_has_joy_axis("steer_left", JOY_AXIS_LEFT_X, -1.0), "steer left uses the negative left-stick X axis")
	_check(_has_joy_axis("steer_right", JOY_AXIS_LEFT_X, 1.0), "steer right uses the positive left-stick X axis")
	_check(_has_joy_axis("throttle", JOY_AXIS_TRIGGER_RIGHT, 1.0), "throttle uses the right trigger")
	_check(_has_joy_axis("brake_reverse", JOY_AXIS_TRIGGER_LEFT, 1.0), "brake/reverse uses the left trigger")
	_check(_has_key("steer_left", KEY_A) and _has_key("steer_left", KEY_LEFT), "steer left supports A and Left (%d)" % KEY_LEFT)
	_check(_has_key("steer_right", KEY_D) and _has_key("steer_right", KEY_RIGHT), "steer right supports D and Right (%d)" % KEY_RIGHT)
	_check(_has_key("throttle", KEY_W) and _has_key("throttle", KEY_UP), "throttle supports W and Up (%d)" % KEY_UP)
	_check(_has_key("brake_reverse", KEY_S) and _has_key("brake_reverse", KEY_DOWN), "brake/reverse supports S and Down (%d)" % KEY_DOWN)
	_check(_has_key("handbrake", KEY_SPACE), "handbrake supports Space")
	_check(_has_key("reset_car", KEY_R), "reset supports R")
	_check(_has_key("pause_back", KEY_ESCAPE), "pause/back supports Escape (%d)" % KEY_ESCAPE)
	_check(_has_key("confirm", KEY_ENTER), "confirm supports Enter (%d)" % KEY_ENTER)
	_check(_has_joy_button("handbrake", JOY_BUTTON_X), "handbrake uses a face button")
	_check(_has_joy_button("reset_car", JOY_BUTTON_Y), "reset uses a separate face button")
	_check(_has_joy_button("pause_back", JOY_BUTTON_START), "pause/back uses Menu/Start")
	_check(_has_joy_button("confirm", JOY_BUTTON_A), "confirm uses the south face button")
	return true


func _has_joy_axis(action: StringName, axis: JoyAxis, axis_value: float) -> bool:
	if not InputMap.has_action(action):
		return false
	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadMotion and event.axis == axis and is_equal_approx(event.axis_value, axis_value):
			return true
	return false


func _has_key(action: StringName, key: Key) -> bool:
	if not InputMap.has_action(action):
		return false
	for event in InputMap.action_get_events(action):
		if event is InputEventKey and (event.keycode == key or event.physical_keycode == key):
			return true
	return false


func _has_joy_button(action: StringName, button: JoyButton) -> bool:
	if not InputMap.has_action(action):
		return false
	for event in InputMap.action_get_events(action):
		if event is InputEventJoypadButton and event.button_index == button:
			return true
	return false


func _verify_analog_input_normalization() -> bool:
	var controller_script := load(CONTROLLER_INPUT_PATH) as GDScript
	_check(controller_script != null, "controller input adapter loads")
	if controller_script == null:
		return false
	var controller = controller_script.new(0.2, 0.1)
	var state = controller.apply_raw_values(0.1, 0.05, 0.0, false)
	_check(state.steer == 0.0 and state.throttle == 0.0, "stick and trigger noise inside deadzones is removed")

	state = controller.apply_raw_values(-0.6, 0.55, 0.325, true)
	_check(is_equal_approx(state.steer, -0.5), "steering preserves remapped analog magnitude")
	_check(is_equal_approx(state.throttle, 0.5), "throttle preserves remapped analog magnitude")
	_check(is_equal_approx(state.brake, 0.25), "brake preserves remapped analog magnitude")
	_check(state.handbrake == 1.0, "digital handbrake maps to the normalized vehicle contract")

	controller.suppress_until_controls_released()
	state = controller.apply_raw_values(0.8, 1.0, 0.0, false)
	_check(state.steer == 0.0 and state.throttle == 0.0, "held controls stay neutral after input suppression")
	controller.apply_raw_values(0.0, 0.0, 0.0, false)
	state = controller.apply_raw_values(0.8, 0.55, 0.0, false)
	_check(state.steer > 0.7 and is_equal_approx(state.throttle, 0.5), "controls rearm only after a neutral sample")

	_check(controller.has_method("poll_actions"), "controller adapter polls only named InputMap actions")
	if controller.has_method("poll_actions"):
		Input.action_press("steer_right", 0.6)
		Input.action_press("throttle", 0.55)
		state = controller.poll_actions()
		_check(is_equal_approx(state.steer, 0.5) and is_equal_approx(state.throttle, 0.5), "real InputMap polling preserves analog action strength")
		Input.action_release("steer_right")
		Input.action_release("throttle")
	return true


func _verify_time_trial_state() -> bool:
	var state_script := load(TIME_TRIAL_STATE_PATH) as GDScript
	_check(state_script != null, "time-trial state loads")
	if state_script == null:
		return false
	var trial = state_script.new(8)
	trial.advance_time(3.0)
	trial.cross_checkpoint(2, 1.0)
	trial.cross_checkpoint(1, -1.0)
	trial.cross_checkpoint(0, 1.0)
	_check(trial.lap_count == 0 and trial.next_checkpoint == 1, "wrong-order, reverse, and early finish crossings are ignored")

	trial.set_paused(true)
	trial.advance_time(2.0)
	_check(is_equal_approx(trial.current_lap_time, 3.0) and is_equal_approx(trial.session_time, 3.0), "pause freezes lap and session clocks")
	trial.set_paused(false)
	trial.advance_time(7.0)
	for checkpoint_index in range(1, 8):
		trial.cross_checkpoint(checkpoint_index, 1.0)
	var completed: bool = bool(trial.cross_checkpoint(0, 1.0))
	_check(completed and trial.lap_count == 1, "one complete forward checkpoint sequence counts one lap")
	_check(is_equal_approx(trial.last_lap_time, 10.0) and is_equal_approx(trial.best_lap_time, 10.0), "a completed lap records last and best time")
	_check(is_equal_approx(trial.current_lap_time, 0.0) and is_equal_approx(trial.session_time, 10.0), "lap completion resets only the current lap clock")

	trial.restart()
	_check(trial.lap_count == 0 and trial.next_checkpoint == 1, "seed restart clears lap progress")
	_check(trial.session_time == 0.0 and trial.best_lap_time == 0.0, "seed restart clears timing results")
	return true


func _verify_checkpoint_crossings() -> bool:
	var detector_script := load(CHECKPOINT_DETECTOR_PATH) as GDScript
	_check(detector_script != null, "checkpoint crossing detector loads")
	if detector_script == null:
		return false
	var definition := TrackDefinition.new()
	definition.track_width = 150.0
	definition.checkpoints = [Transform2D(0.0, Vector2(100.0, 50.0))]
	var detector = detector_script.new(definition)
	detector.reset(Vector2(95.0, 50.0))
	var forward_crossing: Dictionary = detector.sample(Vector2(105.0, 50.0))
	_check(forward_crossing.get("checkpoint", -1) == 0, "crossing a checkpoint gate forward emits its index")
	_check(float(forward_crossing.get("forward_dot", 0.0)) > 0.0, "forward checkpoint crossing carries positive travel direction")

	detector.reset(Vector2(105.0, 50.0))
	var reverse_crossing: Dictionary = detector.sample(Vector2(95.0, 50.0))
	_check(reverse_crossing.is_empty(), "crossing the finish plane backward is ignored")
	detector.reset(Vector2(95.0, 180.0))
	var outside_gate: Dictionary = detector.sample(Vector2(105.0, 180.0))
	_check(outside_gate.is_empty(), "crossing outside the finite track-width gate is ignored")
	return true


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Issue #5 input/session checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Issue #5 input/session check failed: %s" % failure)
	quit(1)
