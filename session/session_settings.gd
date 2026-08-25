class_name SessionSettings
extends Resource

## Settings shared by the root session and future seeded track generator.

@export var seed: int = 0
@export var diagnostics_visible_in_debug: bool = true
@export_range(0.0, 0.95, 0.01) var stick_deadzone: float = 0.2
@export_range(0.0, 0.95, 0.01) var trigger_deadzone: float = 0.1
@export var auto_reset_enabled: bool = false
