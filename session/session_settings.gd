class_name SessionSettings
extends Resource

## Settings shared by the root session and future seeded track generator.

@export var seed: int = 0
@export var diagnostics_visible_in_debug: bool = true
@export_range(0.0, 0.95, 0.01) var stick_deadzone: float = 0.2
@export_range(0.0, 0.95, 0.01) var trigger_deadzone: float = 0.1
@export var auto_reset_enabled: bool = false

@export_range(0, 20, 1) var opponent_count: int = 0:
	set(value):
		opponent_count = clampi(value, 0, 20)

## The field's one mistake switch: every rival the session spawns takes it. Off unless set, so a
## settings resource built in code -- which is how every test builds one -- races a flawless field,
## the same default ReactiveDriver has. The shipped game turns it on in
## data/default_session_settings.tres, because opponents that make deliberate mistakes are the
## epic's design (#55).
@export var opponent_mistakes_enabled: bool = false
