# Controller-first time trial

The playable slice consumes only named Godot InputMap actions. `MainSession` polls those actions through `ControllerInput`; `TopDownCar` receives a normalized `VehicleInputState` and never reads device codes.

## Default mapping

| InputMap action | Controller default | Keyboard fallback |
| --- | --- | --- |
| `steer_left` / `steer_right` | Left stick X | A/D or Left/Right |
| `throttle` | Right trigger | W or Up |
| `brake_reverse` | Left trigger | S or Down |
| `handbrake` | West face button | Space |
| `reset_car` | North face button | R |
| `pause_back` | Menu/Start | Esc |
| `confirm` | South face button | Enter |

The UI uses generic control names because face-button letters differ between controller families. Godot's SDL-backed standard joypad mapping presents XInput-compatible controllers and Steam Deck controls as the same left-stick, separate-trigger, and face-button layout. Keyboard and controller inputs share the actions, so either can take over during a running session.

## Analog processing and disconnect safety

The versioned defaults in `data/default_session_settings.tres` are:

- stick deadzone: `0.20`;
- trigger deadzone: `0.10`.

Values outside a deadzone are remapped across the remaining 0–1 range rather than converted to buttons, preserving proportional steering, throttle, and brake. InputMap deadzones remain zero because the adapter owns this single, testable normalization step.

Pause, seed restart, and controller disconnect clear the shared vehicle input state and suppress drive controls until a neutral sample is observed. A held stick or trigger therefore cannot reactivate the car on resume or hot-plug. Reset and pause use pressed-edge events, and pause-menu buttons emit once per confirmation, protecting destructive session actions from held-button repeat.

## Time-trial rules

- The generated start transform supplies the car spawn and initial safe-reset pose.
- A lap counts only after checkpoints 1 through 7 and then finish checkpoint 0 are crossed in order and in the forward direction.
- Crossing a checkpoint plane outside the finite track-width gate, backward, or out of order is ignored.
- Pause freezes the scene tree, vehicle physics, current-lap clock, and total session clock. The overlay remains active and gives visible controller focus.
- Restart rebuilds track geometry, surface lookup, checkpoint detector, and vehicle from the requested seed as one operation.
- The seed/lap/time HUD and pause menu overlay the same gameplay canvas. No lower panel or secondary viewport is used.

## Controller verification matrix

| Path | Mapping/logic | Manual hardware | Notes |
| --- | --- | --- | --- |
| Keyboard | Automated | Pending graphical pass | WASD, arrows, Space, R, Esc, and Enter are mapped. |
| XInput-compatible external controller | Automated | Not run: no connected controller in the implementation environment | Left stick, separate triggers, face buttons, Menu/Start, hot-switch, disconnect neutralization. |
| Steam Deck built-in controls | Automated mapping path | Deferred to issue #7 hardware validation | Uses the same standard Godot joypad actions; no device-specific gameplay branch. |

Automated coverage lives in `tests/issue_5_input_session_test.gd` and `tests/issue_5_main_session_test.gd`. A hardware pass should drive at analog half/full values, switch to keyboard and back, disconnect while holding throttle/steer, navigate the paused menu without a pointer, and verify held reset/restart inputs do not repeat.
