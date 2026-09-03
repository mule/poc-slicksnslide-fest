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

@export_group("Automatic reset")
## Below this speed the car counts as stopped. The rule only ever applies off-track, where
## measured terminal speed is 259.2 px/s, so this still has a 10x margin and cannot fire during
## any controlled off-track run.
@export_range(0.0, 200.0, 0.1) var auto_reset_stuck_speed: float = 25.0
## Long enough to ride out a slow corner exit, short enough not to strand the player.
@export_range(0.1, 10.0, 0.1) var auto_reset_stuck_seconds: float = 2.0
## Half the generator's PLAY_AREA_MARGIN, so "lost" resolves before the containment boundary.
@export_range(0.0, 10000.0, 10.0) var auto_reset_lost_distance: float = 1000.0

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

@export_group("Height channel")
## WorldScale.metres(9.81). Baked so the resource holds the value the integrator uses.
@export_range(0.0, 1000.0, 0.001) var gravity: float = 122.625
## Fraction of the ground steering rate available in the air. Zero means the car flies straight.
@export_range(0.0, 1.0, 0.01) var airborne_steering_authority: float = 0.0
## Fraction of speed lost per metre-per-second of landing impact, clamped so a landing never
## removes more than 70% of speed.
@export_range(0.0, 0.2, 0.001) var landing_speed_loss: float = 0.03
@export_range(0.0, 2.0, 0.01) var landing_recovery_seconds: float = 0.35
@export_range(0.0, 1.0, 0.01) var landing_recovery_grip_multiplier: float = 0.5
## Height above which low obstacles (rocks) stop colliding. Must equal
## OfftrackObjectCatalog.low_obstacle_height; the contract test asserts it.
@export_range(0.0, 500.0, 0.1) var low_obstacle_clearance: float = 12.5
@export_range(0.0, 5.0, 0.05) var air_time_notice_seconds: float = 0.5
@export_range(0.0, 3.0, 0.05) var lift_pixels_per_pixel: float = 1.0
@export_range(0.0, 0.5, 0.005) var scale_per_metre: float = 0.04

@export_group("Presentation")
@export_range(0.0, 1.0, 0.01) var camera_lead_seconds: float = 0.38
@export_range(0.2, 2.0, 0.01) var camera_zoom: float = 0.8
@export_range(0.0, 500.0, 1.0) var camera_max_lead: float = 250.0
@export_range(0.0, 20.0, 0.1) var camera_follow_response: float = 6.0
@export_range(0.0, 2.0, 0.01) var feedback_slip_threshold: float = 0.14
