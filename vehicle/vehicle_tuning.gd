class_name VehicleTuning
extends Resource

## Versioned home for vehicle physics values. Issue #4 will tune their behavior.

@export_group("Body")
@export_range(1.0, 5000.0, 1.0) var mass_kg: float = 1100.0

@export_group("Longitudinal")
@export_range(0.0, 50000.0, 10.0) var engine_force: float = 8500.0
@export_range(0.0, 50000.0, 10.0) var brake_force: float = 12000.0
@export_range(0.0, 10.0, 0.01) var rolling_drag: float = 0.8
@export_range(0.0, 10.0, 0.01) var aerodynamic_drag: float = 0.025

@export_group("Steering and grip")
@export_range(0.0, 10.0, 0.01) var steering_response: float = 2.6
@export_range(0.0, 50.0, 0.05) var lateral_grip: float = 8.0
@export_range(0.0, 1.0, 0.01) var handbrake_grip_multiplier: float = 0.35

@export_group("Surfaces")
@export_range(0.0, 2.0, 0.01) var dirt_grip_multiplier: float = 1.0
@export_range(0.0, 2.0, 0.01) var off_track_grip_multiplier: float = 0.55
@export_range(0.0, 5.0, 0.01) var off_track_drag_multiplier: float = 2.0
