# Issue #4 vehicle physics

`TopDownCar` is a tunable `RigidBody2D` that consumes `VehicleInputState`; it never reads hardware input and applies no drive acceleration when throttle and brake are released. `SurfaceQuery` is the only surface boundary. The issue tests install a deterministic local provider so this work does not depend on the unfinished procedural track.

## Model and tuning

The vehicle decomposes world velocity into local longitudinal and lateral components every fixed physics tick. Engine, service-brake/reverse, linear rolling drag and quadratic aerodynamic drag affect the longitudinal component. Progressive lateral correction is capped by available acceleration; the correction fades from static to sliding grip between `slip_onset` and `full_slip`, while the handbrake lowers grip and raises a bounded target yaw rate. Counter-steering therefore changes the target yaw without cancelling lateral momentum instantaneously.

The default resource at `data/default_vehicle_tuning.tres` owns mass, engine/reverse/brake forces, drag, speed and yaw safety limits, steering response, progressive grip/slip, handbrake, dirt/off-track, safe-reset, camera, and feedback settings. Surface provider multipliers are combined with the dirt/off-track tuning multipliers. Off-track defaults use 46% grip, 260% drag, and 62% drive force.

Collision safety uses a capsule, ray continuous collision detection, low restitution, a 48 world-unit/s hard safety bound, and a 2.6 rad/s yaw bound. Stable dirt poses with low slip and no contacts become reset checkpoints every 0.5 seconds. Candidate checkpoints overlapping a physics body are rejected; reset restores the previous valid transform and clears both velocities.

The velocity-led `Camera2D` is rotation-independent and bounded to 110 world units. Dirt dust begins above 4 world units/s, and skid feedback follows slip/handbrake. `get_diagnostics()` reports km/h, local longitudinal/lateral velocity, slip, all four normalized controls, and surface.

## Repeatable maneuver ranges

Run with Godot 4.7.1:

```sh
godot --headless --path . --script res://tests/issue_4_vehicle_maneuvers.gd
```

The checked default-tuning ranges are intentionally broad enough for solver portability and narrow enough to catch material regressions:

| Maneuver | Fixed-tick expectation |
| --- | --- |
| Straight acceleration | Full throttle reaches 20–34 units/s after 4 s; half throttle is 38–65% of full; 1 s coast loses at least 0.25 units/s. |
| Brake/reverse | Approach speed is at least 17 units/s; after 1.5 s braking speed is at most 2.5; continued hold yields 5–17 units/s reverse. |
| Analog steering | A one-second 0.8 input rotates at least 0.65 rad; a 0.4 input produces 35–65% of the full-input rotation. |
| Constant steering | 0.65 steer for 1.5 s after acceleration turns 0.35–2.4 rad; yaw never exceeds 2.6 rad/s; counter-steer reduces residual slip by at least 0.03. |
| Handbrake | One-second rotation exceeds the normal turn by at least 0.18 rad and remains below 2.8 rad. |
| Surface transition | The deterministic boundary records off-track and final speed is at most 88% of the dirt-only run. Identical meaningful-slip starts recover below 0.12 within four seconds, with off-track recovery taking at least 15 ticks longer than dirt. |
| Wall impact | A real body contact occurs; the capsule remains on the approach side; peak speed stays at or below 48; post-impact speed does not exceed approach peak by more than 5% + 0.5. |
| Reset | Transform is restored within 0.1 units / 0.01 rad, velocities clear, overlapping candidates are rejected, and stable dirt driving advances the checkpoint. |
| Frame stability | Identical 180-tick inputs at 30 and 144 render FPS differ by at most 0.25 units/s and 0.75 world units. |

## Evidence

The strict RED/GREEN record is in [red-green.txt](evidence/red-green.txt). [Drift/recovery still](evidence/issue-4-drift-recovery.svg) shows the early counter-steer phase, and the representative [post-impact still](evidence/issue-4-gameplay-still.svg) shows the car physically touching the wall with `contacts 1`, `POST-IMPACT`, center y 387.0, and settled speed 2.8 km/h. `issue-4-gameplay-capture.webm` records the complete eight-second acceleration, handbrake rotation, counter-steer recovery, reset, surface transition, real wall contact, and post-impact state with live diagnostics.

The evidence script renders real maneuver telemetry to 120 SVG frames so capture remains reproducible with Godot's CI dummy renderer. Recreate and package the capture from the repository root with these exact commands:

```sh
godot --headless --path . --script res://tests/capture_issue_4_gameplay.gd
gst-launch-1.0 -q multifilesrc location='/tmp/issue-4-gameplay-frames/frame_%03d.svg' index=0 caps='image/svg+xml,framerate=15/1' ! rsvgdec ! videoconvert ! video/x-raw,framerate=15/1 ! vp8enc deadline=1 ! webmmux ! filesink location='docs/vehicle/evidence/issue-4-gameplay-capture.webm'
gst-discoverer-1.0 docs/vehicle/evidence/issue-4-gameplay-capture.webm
```

The deterministic capture must finish with at least one `TopDownCar.get_collision_count()` contact and speed at or below 2 world units/s; otherwise the script exits nonzero. The packaged media is 1280×720 VP8 WebM at 15 FPS with an eight-second duration.

Limitations: brake doubles as reverse after a deliberate 0.4-second near-stop hold; there is no drivetrain, wheel-by-wheel suspension, damage, production audio, or persistent tire-mark system. The default main scene is intentionally untouched, so integration installs `vehicle/top_down_car.tscn` through the existing session vehicle mount in follow-up composition work.
