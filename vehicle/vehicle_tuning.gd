class_name VehicleTuning
extends Resource

## Versioned, inspector-friendly home for the top-down car model.

@export_group("Body")
@export_range(1.0, 5000.0, 1.0) var mass_kg: float = 1100.0

@export_group("Longitudinal")
@export_range(0.0, 500000.0, 100.0) var engine_force: float = 212500.0
@export_range(0.0, 500000.0, 100.0) var reverse_force: float = 81250.0
@export_range(0.0, 500000.0, 100.0) var brake_force: float = 212500.0
@export_range(0.0, 10.0, 0.001) var rolling_drag: float = 0.064
@export_range(0.0, 1.0, 0.00001) var aerodynamic_drag: float = 0.00043
@export_range(0.0, 2000.0, 1.0) var max_safe_speed: float = 640.0
@export_range(0.0, 200.0, 0.1) var stop_speed: float = 9.4
@export_range(0.0, 2.0, 0.01) var reverse_engage_delay: float = 0.4

@export_group("Safety")
@export_range(0.1, 5.0, 0.1) var safe_pose_interval: float = 0.5
@export_range(0.0, 1.0, 0.01) var safe_pose_max_slip: float = 0.28

@export_group("Steering and grip")
@export_range(0.0, 10.0, 0.01) var steering_response: float = 3.4
@export_range(0.0, 10.0, 0.01) var max_steering_rate: float = 1.75
@export_range(0.0, 1000.0, 1.0) var steering_full_speed: float = 225.0
@export_range(0.0, 10.0, 0.01) var max_angular_speed: float = 2.6
@export_range(0.0, 50.0, 0.05) var lateral_grip: float = 5.5
@export_range(0.0, 2000.0, 1.0) var lateral_grip_acceleration: float = 300.0
@export_range(0.0, 2.0, 0.01) var slip_onset: float = 0.16
@export_range(0.0, 2.0, 0.01) var full_slip: float = 0.72
@export_range(0.0, 1.0, 0.01) var sliding_grip_multiplier: float = 0.58
@export_range(0.0, 1.0, 0.01) var handbrake_grip_multiplier: float = 0.22
@export_range(1.0, 3.0, 0.01) var handbrake_rotation_multiplier: float = 1.65
@export_range(0.0, 500.0, 0.5) var low_speed_stabilization: float = 50.0

@export_group("Surfaces")
@export_range(0.0, 2.0, 0.01) var dirt_grip_multiplier: float = 0.92
@export_range(0.0, 2.0, 0.01) var dirt_drag_multiplier: float = 1.0
@export_range(0.0, 2.0, 0.01) var off_track_grip_multiplier: float = 0.46
@export_range(0.0, 5.0, 0.01) var off_track_drag_multiplier: float = 2.6
@export_range(0.0, 1.0, 0.01) var off_track_engine_multiplier: float = 0.62

@export_group("Presentation")
@export_range(0.0, 1.0, 0.01) var camera_lead_seconds: float = 0.38
@export_range(0.2, 2.0, 0.01) var camera_zoom: float = 0.8
@export_range(0.0, 500.0, 1.0) var camera_max_lead: float = 250.0
@export_range(0.0, 20.0, 0.1) var camera_follow_response: float = 6.0
@export_range(0.0, 2.0, 0.01) var feedback_slip_threshold: float = 0.14
