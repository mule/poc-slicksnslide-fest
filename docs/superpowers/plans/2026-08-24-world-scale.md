# World Scale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the car move at a believable speed and grow the circuit from a single-screen parking lot into a 2–3 km world roughly 8 × 8 screens across.

**Architecture:** Pixels stay the world unit, with an explicit `PIXELS_PER_METRE = 12.5` constant that every length-dimensioned value is expressed against. Vehicle tuning is rescaled in place ("baked"), the stadium-oval track sampler is replaced by a seeded Catmull-Rom closed loop, and a shared uniform segment grid keeps the per-tick surface lookup and the generator's self-intersection validation affordable at the new scale.

**Tech Stack:** Godot 4.7.1 stable (official build `a13da4feb`), GDScript, GL Compatibility renderer. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-24-world-scale-design.md`

## Global Constraints

- Godot **4.7.1 stable**, official build `a13da4feb`. GL Compatibility renderer.
- `PIXELS_PER_METRE = 12.5`. Every length, speed, and acceleration in `track/`, `vehicle/`, and `session/` is in pixels at this scale.
- No new dependencies, no new autoloads.
- `platform/` is reserved for platform adapters only. Track generation, vehicle physics, and session flow must not be placed there (`platform/README.md`).
- Tests are `SceneTree` scripts run headless: `godot --headless --path . --script res://tests/<name>.gd`. Exit code 0 = pass.
- Test harness pattern in this repo: `extends SceneTree`, `_initialize()` calls `call_deferred("_run")`, assertions go through a local `_check(condition, message)`, and `_finish()` calls `quit(0)` or `quit(1)`.
- **Full suite** (run at the end of every task):

```sh
godot --editor --headless --path . --quit
godot --headless --path . --script res://tests/headless_smoke.gd
godot --headless --path . --script res://tests/world_scale_contract_test.gd
godot --headless --path . --script res://tests/segment_grid_test.gd
godot --headless --path . --script res://tests/track_generator_test.gd
godot --headless --path . --script res://tests/issue_4_vehicle_maneuvers.gd
godot --headless --path . --script res://tests/issue_5_input_session_test.gd
godot --headless --path . --script res://tests/issue_5_main_session_test.gd
godot --headless --path . --script res://tests/issue_6_android_test.gd
```

(The first two new entries do not exist until Tasks 1 and 3 create them.)

## File Structure

| File | Responsibility |
| --- | --- |
| `world/world_scale.gd` (new) | The px↔m contract. Stateless constant + conversions. Consumed by `track/`, `vehicle/`, `session/`. |
| `world/segment_grid.gd` (new) | Uniform spatial index over a polyline's segments. Broadphase only — never decides geometry, only narrows candidates. |
| `tests/world_scale_contract_test.gd` (new) | Resource-level scale contract: conversions, tuning values survive their export ranges, analytic terminal speed. No physics. |
| `tests/segment_grid_test.gd` (new) | Grid-vs-brute-force equivalence. The old brute-force code is the oracle. |
| `vehicle/vehicle_tuning.gd` | Widened export ranges + new `camera_zoom`. |
| `data/default_vehicle_tuning.tres` | Rescaled values. |
| `vehicle/top_down_car.gd` | Scale-dependent literals, camera zoom, honest km/h. |
| `vehicle/top_down_car.tscn` | Dust particle velocities/scales. |
| `track/track_generator.gd` | Spline sampler, rescaled limits, grid-backed validation. |
| `track/track_surface_map.gd` | Grid-backed centreline distance. |
| `track/track_runtime.gd` | Proportional shoulder and edge widths. |

Note on task ordering: **Tasks 2 and 5 each deliver one of the two reported symptoms** (slow car, single-screen track), so each leaves the project visibly better on its own.

---

### Task 1: The scale contract

**Files:**
- Create: `world/world_scale.gd`
- Test: `tests/world_scale_contract_test.gd`

**Interfaces:**
- Consumes: nothing.
- Produces: `WorldScale.PIXELS_PER_METRE: float`, `WorldScale.metres(value_m: float) -> float`, `WorldScale.to_metres(value_px: float) -> float`, `WorldScale.to_kph(px_per_second: float) -> float`. Tasks 2 and 5 use these.

- [x] **Step 1: Write the failing test**

Create `tests/world_scale_contract_test.gd`:

```gdscript
extends SceneTree

const WORLD_SCALE_PATH := "res://world/world_scale.gd"

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_verify_scale_helpers()
	_finish()


func _verify_scale_helpers() -> void:
	var script := load(WORLD_SCALE_PATH) as GDScript
	_check(script != null, "world scale script loads")
	if script == null:
		return
	_check(is_equal_approx(WorldScale.PIXELS_PER_METRE, 12.5), "the world declares 12.5 px per metre")
	_check(is_equal_approx(WorldScale.metres(4.4), 55.0), "a 4.4 m car body measures 55 px")
	_check(is_equal_approx(WorldScale.to_metres(55.0), 4.4), "pixels-to-metres inverts metres-to-pixels")
	_check(is_equal_approx(WorldScale.to_kph(600.0), 172.8), "600 px/s reads as 172.8 km/h")
	_check(is_equal_approx(WorldScale.to_kph(0.0), 0.0), "a stopped car reads as zero")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("World scale contract checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("World scale contract check failed: %s" % failure)
	quit(1)
```

- [x] **Step 2: Run the test to verify it fails**

Run: `godot --headless --path . --script res://tests/world_scale_contract_test.gd`
Expected: FAIL, non-zero exit. Note the failure mode: because the test references the global class `WorldScale`, GDScript cannot resolve the identifier and the script fails to **parse** — you will see `Identifier "WorldScale" not declared in the current scope`, not a failing `_check`. That is still a valid red state; do not "fix" it by removing the reference.

- [x] **Step 3: Write the implementation**

Create `world/world_scale.gd`:

```gdscript
class_name WorldScale
extends RefCounted

## Single source of truth for the world's pixel-to-metre contract.
##
## The world unit is the pixel. Physics tuning, track dimensions, and any
## hardcoded speed threshold are expressed in pixels at this scale. Route
## scale-dependent literals through metres() so they stay greppable.

const PIXELS_PER_METRE := 12.5


static func metres(value_m: float) -> float:
	return value_m * PIXELS_PER_METRE


static func to_metres(value_px: float) -> float:
	return value_px / PIXELS_PER_METRE


static func to_kph(px_per_second: float) -> float:
	return px_per_second / PIXELS_PER_METRE * 3.6
```

- [x] **Step 4: Run the test to verify it passes**

Run: `godot --headless --path . --script res://tests/world_scale_contract_test.gd`
Expected: PASS, "World scale contract checks passed: 6 checks", exit code 0.

- [x] **Step 5: Run the full suite**

Run every command in the Global Constraints suite block except `segment_grid_test.gd` (not yet created).
Expected: all exit 0. Nothing consumes `WorldScale` yet, so no existing test changes behaviour.

- [x] **Step 6: Commit**

```bash
git add world/world_scale.gd tests/world_scale_contract_test.gd
git commit -m "feat: add explicit pixels-per-metre world scale contract"
```

---

### Task 2: Rescale the vehicle

Delivers the first reported symptom: the car stops crawling. Terminal speed goes from 24.9 px/s to 600 px/s.

**Files:**
- Modify: `vehicle/vehicle_tuning.gd`
- Modify: `data/default_vehicle_tuning.tres`
- Modify: `vehicle/top_down_car.gd`
- Test: `tests/world_scale_contract_test.gd` (extend), `tests/issue_4_vehicle_maneuvers.gd` (update)

**Interfaces:**
- Consumes: `WorldScale.metres()`, `WorldScale.to_kph()` from Task 1.
- Produces: `VehicleTuning.camera_zoom: float` (default 0.8), read by `TopDownCar._ready()`. Task 6 does not depend on it; nothing else does.

**Why the export ranges must widen first:** `vehicle_tuning.gd` declares `@export_range(0.0, 50000.0, 10.0) var engine_force`, but the new value is 212500. Worse, `aerodynamic_drag` is declared with a **step of 0.001** while the new value is **0.00043** — the Godot inspector would round that to 0.0 and silently delete all aerodynamic drag. Widen the ranges in the same task as the value change, never after.

- [x] **Step 1: Write the failing test — resource-level**

Add to `tests/world_scale_contract_test.gd`. Add the constant at the top:

```gdscript
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
```

Change `_run()` to:

```gdscript
func _run() -> void:
	_verify_scale_helpers()
	_verify_rescaled_tuning()
	_finish()
```

Add this function:

```gdscript
func _verify_rescaled_tuning() -> void:
	var tuning := load(TUNING_PATH) as VehicleTuning
	_check(tuning != null, "default vehicle tuning loads")
	if tuning == null:
		return

	# Values must survive their @export_range declarations. aerodynamic_drag is
	# the dangerous one: a step of 0.001 would round 0.00043 down to zero.
	_check(is_equal_approx(tuning.engine_force, 212500.0), "engine force is rescaled to pixel space")
	_check(is_equal_approx(tuning.brake_force, 212500.0), "brake force is rescaled to pixel space")
	_check(is_equal_approx(tuning.reverse_force, 81250.0), "reverse force is rescaled to pixel space")
	_check(is_equal_approx(tuning.rolling_drag, 0.064), "rolling drag is rebalanced")
	_check(tuning.aerodynamic_drag > 0.0004 and tuning.aerodynamic_drag < 0.00046, "aerodynamic drag survives its export step (got %.6f)" % tuning.aerodynamic_drag)
	_check(is_equal_approx(tuning.max_safe_speed, 640.0), "the safety limiter is rescaled")
	_check(is_equal_approx(tuning.steering_full_speed, 225.0), "steering authority speed is rescaled")
	_check(is_equal_approx(tuning.lateral_grip_acceleration, 300.0), "lateral grip acceleration is rescaled")
	_check(is_equal_approx(tuning.low_speed_stabilization, 50.0), "low speed stabilization is rescaled")
	_check(is_equal_approx(tuning.camera_max_lead, 250.0), "camera lead stays a screen-space budget")
	_check(is_equal_approx(tuning.camera_zoom, 0.8), "camera zoom frames 1600 px of world")

	# Rates, angles, and ratios are dimensionless or per-second: they must NOT scale.
	_check(is_equal_approx(tuning.lateral_grip, 5.5), "lateral grip is a rate and does not scale")
	_check(is_equal_approx(tuning.steering_response, 3.4), "steering response is a rate and does not scale")
	_check(is_equal_approx(tuning.max_angular_speed, 2.6), "angular speed is in rad/s and does not scale")
	_check(is_equal_approx(tuning.slip_onset, 0.16), "slip onset is a ratio and does not scale")

	# The design's headline number, derived rather than asserted by hand:
	# terminal speed solves engine_accel = rolling*v + aero*v^2.
	var terminal := _solve_terminal_speed(tuning)
	_check(terminal >= 595.0 and terminal <= 605.0, "analytic terminal speed is the designed 600 px/s (got %.1f)" % terminal)
	_check(terminal < tuning.max_safe_speed, "the limiter sits above terminal speed, so it is a real safety net")


func _solve_terminal_speed(tuning: VehicleTuning) -> float:
	var engine_acceleration: float = tuning.engine_force / tuning.mass_kg
	var a: float = tuning.aerodynamic_drag
	var b: float = tuning.rolling_drag
	var c: float = -engine_acceleration
	return (-b + sqrt(b * b - 4.0 * a * c)) / (2.0 * a)
```

- [x] **Step 2: Run the test to verify it fails**

Run: `godot --headless --path . --script res://tests/world_scale_contract_test.gd`
Expected: FAIL, non-zero exit. `tuning` is typed as `VehicleTuning` and `camera_zoom` is not declared on it yet, so this fails to **parse** (`Invalid access to property or key 'camera_zoom'`) rather than failing a `_check`. Once Step 3 declares the property, the remaining old values fail as ordinary check failures.

- [x] **Step 3: Widen the export ranges and add `camera_zoom`**

In `vehicle/vehicle_tuning.gd`, replace these lines exactly:

```gdscript
@export_range(0.0, 500000.0, 100.0) var engine_force: float = 212500.0
@export_range(0.0, 500000.0, 100.0) var reverse_force: float = 81250.0
@export_range(0.0, 500000.0, 100.0) var brake_force: float = 212500.0
@export_range(0.0, 10.0, 0.001) var rolling_drag: float = 0.064
@export_range(0.0, 1.0, 0.00001) var aerodynamic_drag: float = 0.00043
@export_range(0.0, 2000.0, 1.0) var max_safe_speed: float = 640.0
@export_range(0.0, 200.0, 0.1) var stop_speed: float = 9.4
```

```gdscript
@export_range(0.0, 1000.0, 1.0) var steering_full_speed: float = 225.0
@export_range(0.0, 2000.0, 1.0) var lateral_grip_acceleration: float = 300.0
@export_range(0.0, 500.0, 0.5) var low_speed_stabilization: float = 50.0
```

In the `Presentation` group, add `camera_zoom` after `camera_lead_seconds`:

```gdscript
@export_range(0.2, 2.0, 0.01) var camera_zoom: float = 0.8
```

Leave `mass_kg`, `reverse_engage_delay`, the whole `Safety` group, `steering_response`, `max_steering_rate`, `max_angular_speed`, `lateral_grip`, `slip_onset`, `full_slip`, every grip multiplier, the whole `Surfaces` group, `camera_lead_seconds`, `camera_follow_response`, and `feedback_slip_threshold` untouched — they are rates, angles, times, or dimensionless ratios.

- [x] **Step 4: Rescale the tuning resource**

In `data/default_vehicle_tuning.tres`, set these fields (leave every other line as-is):

```
engine_force = 212500.0
reverse_force = 81250.0
brake_force = 212500.0
rolling_drag = 0.064
aerodynamic_drag = 0.00043
max_safe_speed = 640.0
stop_speed = 9.4
steering_full_speed = 225.0
lateral_grip_acceleration = 300.0
low_speed_stabilization = 50.0
camera_max_lead = 250.0
camera_zoom = 0.8
```

- [x] **Step 5: Run the resource test to verify it passes**

Run: `godot --headless --path . --script res://tests/world_scale_contract_test.gd`
Expected: PASS, exit code 0. If `aerodynamic_drag` reads back as `0.0`, the export step in Step 3 was not applied — fix it before continuing.

- [x] **Step 6: Commit the resource contract**

```bash
git add vehicle/vehicle_tuning.gd data/default_vehicle_tuning.tres tests/world_scale_contract_test.gd
git commit -m "feat: rescale vehicle tuning to pixel-space world units"
```

- [x] **Step 7: Fix the scale-dependent literals in the car**

In `vehicle/top_down_car.gd` there are four hardcoded speeds. Each is in px/s and must scale. Route them through `WorldScale.metres()` so they stay greppable — a missed one presents as a feature bug ("dust never emits"), not a units bug.

Replace the slip-ratio divisor inside `_integrate_forces` (first occurrence, just after `var speed := world_velocity.length()`):

```gdscript
	_slip_ratio = absf(lateral_speed) / maxf(speed, WorldScale.metres(1.0))
```

Replace the low-speed stabiliser gate:

```gdscript
	if speed < WorldScale.metres(2.0) and _input_state.throttle == 0.0 and _input_state.brake == 0.0:
```

Replace the second slip-ratio divisor (near the end of `_integrate_forces`, after `state.linear_velocity` is assigned):

```gdscript
	_slip_ratio = absf(_local_velocity.x) / maxf(state.linear_velocity.length(), WorldScale.metres(1.0))
```

Replace the dust gate in `_process`:

```gdscript
	_dust.emitting = on_dirt and get_speed() > WorldScale.metres(4.0)
```

- [x] **Step 8: Make the HUD honest and apply the camera zoom**

In `vehicle/top_down_car.gd`, in `get_diagnostics()` replace the first entry:

```gdscript
		"speed_kph": WorldScale.to_kph(get_speed()),
```

In `_ready()`, after `_follow_camera.top_level = true`, add:

```gdscript
	_follow_camera.zoom = Vector2.ONE * tuning.camera_zoom
```

- [x] **Step 9: Update the maneuver test's rescaled assertions**

In `tests/issue_4_vehicle_maneuvers.gd`, these assertions scale by 12.5:

Line ~71, `_test_proportional_acceleration_and_no_hidden_drive`:

```gdscript
	_check(full.speed >= 450.0 and full.speed <= 550.0, "full throttle reaches 450..550 px/s after 4 s (got %.2f)" % full.speed)
```

Line ~83:

```gdscript
	_check(speed_after_release < speed_before_release - 3.1, "released controls add no hidden drive force (%.2f -> %.2f)" % [speed_before_release, speed_after_release])
```

Line ~178, in the wall-impact test, the absolute tolerance scales too:

```gdscript
	_check(car.get_speed() <= pre_impact_peak * 1.05 + 6.25, "wall impact injects no unbounded energy (before %.2f, after %.2f)" % [pre_impact_peak, car.get_speed()])
```

Line ~251, in the frame-rate stability test:

```gdscript
	_check(absf(low_fps.speed - high_fps.speed) <= 3.1, "180 fixed ticks are render-frame-rate stable (30 FPS %.2f, 144 FPS %.2f)" % [low_fps.speed, high_fps.speed])
```

- [x] **Step 10: Update the two assertions that change structurally**

These are **not** rescales. Read the reasoning before editing — a plain ×12.5 leaves both failing.

**(a) Half-throttle proportionality, line ~72.** With linear-dominant drag `v_terminal ∝ A`; with aero-dominant drag `v_terminal ∝ √A`. The rebalance moves the throttle→speed transfer toward square-root, so the half/full ratio rises from ~0.61 to ~0.675 — above the current 0.65 ceiling. Widen the band:

```gdscript
	_check(half.speed >= full.speed * 0.55 and half.speed <= full.speed * 0.80, "half throttle produces proportional speed (half %.2f, full %.2f)" % [half.speed, full.speed])
```

**(b) The brake window, `_test_service_brake_and_reverse`.** The test accelerates 3.0 s then brakes 1.5 s. Under the old tuning the approach was ~23 px/s and braking at 15.45 px/s² stopped it in almost exactly 1.5 s — the window was fitted to the old curve. The new approach is ~430 px/s and braking at 193.18 px/s² needs ~2.2 s, so the window must grow. **Do not raise `brake_force` instead:** 193.18 px/s² is already 1.6 g, beyond a road car on tarmac, and this is dirt.

Change the first `await _simulate_seconds(1.5)` (the braking phase, immediately after `controls.set_controls(0.0, 0.0, 1.0, 0.0)`) to:

```gdscript
	await _simulate_seconds(2.5)
```

Leave the *second* `await _simulate_seconds(1.5)` (the reverse phase) alone. Then update the three assertions:

```gdscript
	_check(approach_speed >= 380.0, "braking maneuver has a meaningful approach speed (got %.2f)" % approach_speed)
	_check(stopped_speed <= 31.0, "service brake stops without overshoot jitter (got %.2f)" % stopped_speed)
	_check(reverse_local.y >= 62.5 and reverse_local.y <= 212.5, "held brake provides bounded reverse (local y %.2f)" % reverse_local.y)
```

The reverse band is a plain ×12.5 and it still holds: the car stops ~2.2 s into the 2.5 s window, banking 0.3 s against the 0.4 s `reverse_engage_delay`, so reverse engages ~0.1 s into the following 1.5 s and reaches `73.9 px/s² × 1.4 s ≈ 95 px/s` net of drag — comfortably inside 62.5..212.5.

- [x] **Step 11: Add the simulated scale-contract test**

Still in `tests/issue_4_vehicle_maneuvers.gd`. This reuses the existing fixture helpers rather than duplicating them into a new file. `_spawn_vehicle(scene, tuning)` defaults to `with_wall = false`, so the car has open space for the full run.

Add the call in `_run()`, immediately before `_finish()`:

```gdscript
	await _test_scale_contract(vehicle_scene, tuning)
```

Add the function:

```gdscript
func _test_scale_contract(scene: PackedScene, tuning: VehicleTuning) -> void:
	var fixture := await _spawn_vehicle(scene, tuning)
	fixture.controls.set_controls(0.0, 1.0, 0.0, 0.0)
	await _simulate_seconds(25.0)
	var terminal: float = fixture.car.get_speed()
	_check(terminal >= 570.0 and terminal <= 630.0, "sustained throttle settles at the designed 600 px/s terminal speed (got %.1f)" % terminal)
	var viewport_width: float = 1280.0 / tuning.camera_zoom
	var crossing_seconds := viewport_width / maxf(terminal, 0.001)
	_check(crossing_seconds >= 2.5 and crossing_seconds <= 3.0, "the car crosses one viewport width in 2.5..3.0 s (got %.2f)" % crossing_seconds)
	_check(WorldScale.to_kph(terminal) >= 160.0 and WorldScale.to_kph(terminal) <= 185.0, "the HUD reads a truthful ~173 km/h (got %.1f)" % WorldScale.to_kph(terminal))
	await _dispose_fixture(fixture)
```

- [x] **Step 12: Run the maneuver test to verify it passes**

Run: `godot --headless --path . --script res://tests/issue_4_vehicle_maneuvers.gd`
Expected: PASS, exit code 0.

If the wall-impact test fails, note that the car now closes on the wall 13× faster; report the actual numbers rather than widening the tolerance blindly.

- [x] **Step 13: Run the full suite**

Run every command in the Global Constraints suite block except `segment_grid_test.gd`.
Expected: all exit 0.

- [x] **Step 14: Commit**

```bash
git add vehicle/top_down_car.gd tests/issue_4_vehicle_maneuvers.gd
git commit -m "feat: scale car speed thresholds and report honest km/h"
```

---

### Task 3: The shared segment grid

**Files:**
- Create: `world/segment_grid.gd`
- Test: `tests/segment_grid_test.gd`

**Interfaces:**
- Consumes: nothing.
- Produces: `SegmentGrid.new(points: PackedVector2Array, cell_size: float)`, `segments_near(point: Vector2, radius: float) -> PackedInt32Array`, `segments_overlapping(from: Vector2, to: Vector2) -> PackedInt32Array`, `candidate_pairs() -> Array` (of `Vector2i`, each `(lower_index, higher_index)`). Tasks 4 and 5 consume all four.

**Contract:** this is a **broadphase**. Every method returns a *superset* of the true answer and never decides geometry itself. The tests assert the superset property, which is what callers rely on — asserting exact equality would be wrong and would break on diagonal segments.

- [x] **Step 1: Write the failing test**

Create `tests/segment_grid_test.gd`. The brute-force scan that `TrackSurfaceMap` and `TrackGenerator` use today is the oracle:

```gdscript
extends SceneTree

const SEGMENT_GRID_PATH := "res://world/segment_grid.gd"

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var script := load(SEGMENT_GRID_PATH) as GDScript
	_check(script != null, "segment grid script loads")
	if script != null:
		_verify_proximity_matches_brute_force()
		_verify_pairs_cover_every_real_intersection()
		_verify_degenerate_inputs_are_safe()
	_finish()


func _verify_proximity_matches_brute_force() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260824
	for trial in range(8):
		var points := _random_polyline(rng, 240, 4000.0)
		var radius := 150.0
		var grid := SegmentGrid.new(points, radius)
		var misses := 0
		for probe in range(60):
			var query := Vector2(rng.randf_range(-4200.0, 4200.0), rng.randf_range(-4200.0, 4200.0))
			var expected := _brute_force_near(points, query, radius)
			var actual := {}
			for index in grid.segments_near(query, radius):
				actual[index] = true
			for index in expected:
				if not actual.has(index):
					misses += 1
		_check(misses == 0, "trial %d: grid proximity returns every segment brute force finds (%d misses)" % [trial, misses])


func _verify_pairs_cover_every_real_intersection() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99001
	for trial in range(6):
		var points := _random_polyline(rng, 120, 2000.0)
		var grid := SegmentGrid.new(points, 200.0)
		var offered := {}
		for pair in grid.candidate_pairs():
			offered[Vector2i(mini(pair.x, pair.y), maxi(pair.x, pair.y))] = true
		var misses := 0
		var segment_count := points.size() - 1
		for first in range(segment_count):
			for second in range(first + 2, segment_count):
				if Geometry2D.segment_intersects_segment(points[first], points[first + 1], points[second], points[second + 1]) == null:
					continue
				if not offered.has(Vector2i(first, second)):
					misses += 1
		_check(misses == 0, "trial %d: candidate pairs cover every real intersection (%d misses)" % [trial, misses])


func _verify_degenerate_inputs_are_safe() -> void:
	var empty := SegmentGrid.new(PackedVector2Array(), 50.0)
	_check(empty.segments_near(Vector2.ZERO, 100.0).is_empty(), "an empty polyline yields no candidates")
	_check(empty.candidate_pairs().is_empty(), "an empty polyline yields no pairs")
	var single := SegmentGrid.new(PackedVector2Array([Vector2.ZERO]), 50.0)
	_check(single.segments_near(Vector2.ZERO, 100.0).is_empty(), "a one-point polyline has no segments")
	var zero_cell := SegmentGrid.new(PackedVector2Array([Vector2.ZERO, Vector2(10.0, 0.0)]), 0.0)
	_check(zero_cell.segments_near(Vector2(5.0, 0.0), 10.0).size() == 1, "a zero cell size is clamped rather than dividing by zero")


func _random_polyline(rng: RandomNumberGenerator, count: int, extent: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	var cursor := Vector2.ZERO
	for index in range(count):
		points.append(cursor)
		cursor += Vector2(rng.randf_range(-extent / count, extent / count), rng.randf_range(-extent / count, extent / count)) * 8.0
	points.append(points[0])
	return points


func _brute_force_near(points: PackedVector2Array, query: Vector2, radius: float) -> Array:
	var found := []
	for index in range(points.size() - 1):
		var closest := Geometry2D.get_closest_point_to_segment(query, points[index], points[index + 1])
		if query.distance_to(closest) <= radius:
			found.append(index)
	return found


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Segment grid checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Segment grid check failed: %s" % failure)
	quit(1)
```

- [x] **Step 2: Run the test to verify it fails**

Run: `godot --headless --path . --script res://tests/segment_grid_test.gd`
Expected: FAIL, non-zero exit. As in Task 1, the test references the global class `SegmentGrid`, so this is a **parse** failure (`Identifier "SegmentGrid" not declared in the current scope`), not a failing `_check`.

- [x] **Step 3: Write the implementation**

Create `world/segment_grid.gd`:

```gdscript
class_name SegmentGrid
extends RefCounted

## Uniform spatial index over a polyline's segments.
##
## This is a broadphase: every query returns a superset of the true answer,
## and callers still run the exact geometry test on what comes back. It exists
## so that centerline proximity (queried every physics tick) and generator
## self-intersection validation stay affordable once a circuit spans
## thousands of samples instead of a hundred.

var _cell_size := 1.0
var _cells: Dictionary = {}


func _init(points: PackedVector2Array, cell_size: float) -> void:
	_cell_size = maxf(cell_size, 1.0)
	for index in range(maxi(points.size() - 1, 0)):
		for cell in _cells_for_bounds(points[index], points[index + 1]):
			if not _cells.has(cell):
				_cells[cell] = PackedInt32Array()
			_cells[cell].append(index)


func segments_near(point: Vector2, radius: float) -> PackedInt32Array:
	return _collect(_cells_for_bounds(point - Vector2(radius, radius), point + Vector2(radius, radius)))


func segments_overlapping(from: Vector2, to: Vector2) -> PackedInt32Array:
	return _collect(_cells_for_bounds(from, to))


func candidate_pairs() -> Array:
	var pairs := {}
	for bucket in _cells.values():
		for first_slot in range(bucket.size()):
			for second_slot in range(first_slot + 1, bucket.size()):
				var first: int = bucket[first_slot]
				var second: int = bucket[second_slot]
				pairs[Vector2i(mini(first, second), maxi(first, second))] = true
	return pairs.keys()


func _collect(cells: Array) -> PackedInt32Array:
	var found := PackedInt32Array()
	var seen := {}
	for cell in cells:
		for index in _cells.get(cell, PackedInt32Array()):
			if not seen.has(index):
				seen[index] = true
				found.append(index)
	return found


func _cells_for_bounds(first: Vector2, second: Vector2) -> Array:
	var min_cell := _cell_of(Vector2(minf(first.x, second.x), minf(first.y, second.y)))
	var max_cell := _cell_of(Vector2(maxf(first.x, second.x), maxf(first.y, second.y)))
	var cells := []
	for x in range(min_cell.x, max_cell.x + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			cells.append(Vector2i(x, y))
	return cells


func _cell_of(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / _cell_size), floori(point.y / _cell_size))
```

**Why the superset property holds for `segments_near`:** if a segment's closest point to the query lies within `radius`, that point sits inside the query's bounding box, and the segment's own AABB therefore covers the cell containing it — a cell the query enumerates.

- [x] **Step 4: Run the test to verify it passes**

Run: `godot --headless --path . --script res://tests/segment_grid_test.gd`
Expected: PASS, exit code 0.

- [x] **Step 5: Run the full suite**

Run every command in the Global Constraints suite block. All of them exist now.
Expected: all exit 0. Nothing consumes `SegmentGrid` yet.

- [x] **Step 6: Commit**

```bash
git add world/segment_grid.gd tests/segment_grid_test.gd
git commit -m "feat: add uniform segment grid broadphase"
```

---

### Task 4: Put the surface map on the index

`TrackSurfaceMap._distance_to_centerline` scans every centreline segment **every physics tick** — 150 segments × 60 Hz = 9,000 distance tests/sec today, and 1,250 × 60 = **75,000/sec** at the new scale, growing with lap length and car count.

**Files:**
- Modify: `track/track_surface_map.gd`
- Test: `tests/segment_grid_test.gd` (extend)

**Interfaces:**
- Consumes: `SegmentGrid.new()`, `segments_near()` from Task 3.
- Produces: no signature change. `sample_at(world_position: Vector2) -> SurfaceSample` behaves identically.

- [x] **Step 1: Write the failing test**

Add to `tests/segment_grid_test.gd`. Add the constant at the top:

```gdscript
const SURFACE_MAP_PATH := "res://track/track_surface_map.gd"
const TRACK_GENERATOR_PATH := "res://track/track_generator.gd"
```

Add the call inside `_run()`, after `_verify_degenerate_inputs_are_safe()`:

```gdscript
		_verify_surface_map_agrees_with_brute_force()
```

Add this function. It compares the indexed lookup against the exact same brute-force rule the old implementation used, over points sampled around a real generated track:

```gdscript
func _verify_surface_map_agrees_with_brute_force() -> void:
	var generator_script := load(TRACK_GENERATOR_PATH) as GDScript
	var surface_script := load(SURFACE_MAP_PATH) as GDScript
	_check(generator_script != null and surface_script != null, "generator and surface map scripts load")
	if generator_script == null or surface_script == null:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var generator = generator_script.new()
	var disagreements := 0
	var on_track_hits := 0
	for seed in range(3):
		var definition = generator.generate(seed)
		var surface_map = surface_script.new(definition)
		var half_width: float = definition.track_width * 0.5
		for probe in range(400):
			# Probe near the centerline so both on-track and off-track cases occur.
			var anchor: Vector2 = definition.centerline[rng.randi_range(0, definition.centerline.size() - 2)]
			var query := anchor + Vector2(rng.randf_range(-half_width * 3.0, half_width * 3.0), rng.randf_range(-half_width * 3.0, half_width * 3.0))
			var expected_on_track := _brute_force_distance(definition.centerline, query) <= half_width
			var actual_on_track: bool = surface_map.sample_at(query).surface_type == SurfaceQuery.SurfaceType.DIRT
			if expected_on_track:
				on_track_hits += 1
			if expected_on_track != actual_on_track:
				disagreements += 1
	_check(on_track_hits > 0, "the probe actually covered on-track positions (%d hits)" % on_track_hits)
	_check(disagreements == 0, "indexed surface lookup agrees with brute force everywhere (%d disagreements)" % disagreements)


func _brute_force_distance(points: PackedVector2Array, query: Vector2) -> float:
	var nearest := INF
	for index in range(points.size() - 1):
		var closest := Geometry2D.get_closest_point_to_segment(query, points[index], points[index + 1])
		nearest = minf(nearest, query.distance_to(closest))
	return nearest
```

- [x] **Step 2: Run the test to verify it fails**

Run: `godot --headless --path . --script res://tests/segment_grid_test.gd`
Expected: FAIL — but read the failure. Before the surface map is indexed, this test compares brute force against brute force and **passes trivially**. That is expected and correct: the test's job is to hold the behaviour still while Step 3 swaps the implementation underneath. If it passes here, record that and proceed; the meaningful run is Step 4.

- [x] **Step 3: Index the surface map**

Rewrite `track/track_surface_map.gd`, keeping `sample_at` and the surface constants exactly as they are:

```gdscript
class_name TrackSurfaceMap
extends SurfaceQuery

const DIRT_GRIP := 1.0
const DIRT_DRAG := 1.0
const GRASS_GRIP := 0.55
const GRASS_DRAG := 2.2

var _definition
var _grid: SegmentGrid


func _init(definition) -> void:
	_definition = definition
	if _definition != null and _definition.centerline.size() >= 2:
		_grid = SegmentGrid.new(_definition.centerline, maxf(_definition.track_width, 1.0))


func sample_at(world_position: Vector2) -> SurfaceSample:
	if _definition != null and _distance_to_centerline(world_position) <= _definition.track_width * 0.5:
		return SurfaceSample.new(SurfaceType.DIRT, DIRT_GRIP, DIRT_DRAG)
	return SurfaceSample.new(SurfaceType.OFF_TRACK, GRASS_GRIP, GRASS_DRAG)


func _distance_to_centerline(world_position: Vector2) -> float:
	if _grid == null:
		return INF
	var half_width: float = _definition.track_width * 0.5
	var nearest_distance := INF
	for index in _grid.segments_near(world_position, half_width):
		var closest := Geometry2D.get_closest_point_to_segment(
			world_position,
			_definition.centerline[index],
			_definition.centerline[index + 1],
		)
		nearest_distance = minf(nearest_distance, world_position.distance_to(closest))
	return nearest_distance
```

Note the query radius is `half_width`, matching exactly the threshold `sample_at` tests against — so "no candidate returned" and "further than half a track width" are the same answer, and the fast path agrees with the slow path by construction rather than by luck.

- [x] **Step 4: Run the test to verify it passes**

Run: `godot --headless --path . --script res://tests/segment_grid_test.gd`
Expected: PASS, exit code 0, with `disagreements == 0`. This run is the meaningful one — the brute-force oracle is now comparing against the indexed implementation.

- [x] **Step 5: Run the full suite**

Expected: all exit 0. In particular `issue_4_vehicle_maneuvers.gd` must still pass — it drives across surface boundaries.

- [x] **Step 6: Commit**

```bash
git add track/track_surface_map.gd tests/segment_grid_test.gd
git commit -m "perf: index centerline proximity lookups with the segment grid"
```

---

### Task 5: Meandering circuits at rally scale

Delivers the second reported symptom: the world stops fitting on one screen. Bounds go from ~806 × 326 px to roughly 10,000 × 10,000 px — about 8 × 8 screens.

**Files:**
- Modify: `track/track_generator.gd`
- Test: `tests/track_generator_test.gd`

**Interfaces:**
- Consumes: `SegmentGrid` from Task 3.
- Produces: no signature change. `generate(requested_seed: int, limit_overrides: Dictionary = {})` still returns a `TrackDefinition` with every existing field populated, and the deterministic seed contract is unchanged.

**Spec gap this task fills:** the spec specifies the spline but not how `start_straight_length` is derived once `half_straight` no longer exists. This plan measures the longest low-curvature run and **rotates the sample array so index 0 sits at its start**, which both defines the field and guarantees the car spawns on a straight. Control points 0, 1, and N−1 are pinned to `base_radius` so such a run exists by construction rather than by luck.

- [x] **Step 1: Write the failing test**

In `tests/track_generator_test.gd`, replace the constants block at lines 8–14:

```gdscript
const EXPECTED_MIN_WIDTH := 125.0
const EXPECTED_MAX_WIDTH := 175.0
const EXPECTED_MIN_LAP_LENGTH := 25000.0
const EXPECTED_MAX_LAP_LENGTH := 37500.0
const EXPECTED_MAX_CURVATURE := 0.005
const EXPECTED_MIN_START_STRAIGHT := 1875.0
const EXPECTED_MAX_SAMPLE_GAP := 30.0
```

`EXPECTED_MAX_SAMPLE_GAP` rises because `SAMPLE_SPACING` goes from 10 to 25; 30 leaves the same proportional margin the old 12-against-10 did.

Then add a check that the world is genuinely larger than one screen. Add this function:

```gdscript
func _verify_world_exceeds_one_screen(definition, seed: int) -> void:
	_check(definition.bounds.size.x >= 5000.0, "seed %d spans several screens horizontally (%.0f px)" % [seed, definition.bounds.size.x])
	_check(definition.bounds.size.y >= 5000.0, "seed %d spans several screens vertically (%.0f px)" % [seed, definition.bounds.size.y])
```

Call it from `_verify_driveable_definition`, immediately after the existing start-straight check on line 66:

```gdscript
	_verify_world_exceeds_one_screen(definition, seed)
```

- [x] **Step 2: Run the test to verify it fails**

Run: `godot --headless --path . --script res://tests/track_generator_test.gd`
Expected: FAIL — the generator still produces ~1500 px stadium ovals, so width, lap length, start straight, and both bounds checks all fail. Exit code 1.

- [x] **Step 3: Rescale the generator's constants**

In `track/track_generator.gd`, replace the constants block:

```gdscript
const DEFAULT_MAX_ATTEMPTS := 6
const SAMPLE_SPACING := 25.0
const CHECKPOINT_COUNT := 8
const MIN_WIDTH := 125.0
const MAX_WIDTH := 175.0
const MIN_LAP_LENGTH := 25000.0
const MAX_LAP_LENGTH := 37500.0
const MAX_CURVATURE := 0.005
const MIN_START_STRAIGHT := 1875.0

const CONTROL_POINT_COUNT := 14
const RADIUS_JITTER_MIN := 0.55
const RADIUS_JITTER_MAX := 1.0
const SPLINE_SAMPLES_PER_SPAN := 24
const STRAIGHT_CURVATURE := 0.0005

const FALLBACK_HALF_STRAIGHT := 3728.0
const FALLBACK_RADIUS := 2600.0
const FALLBACK_WIDTH := 150.0
```

The fallback stadium is sized to land inside the new band: `4 × 3728 + 2π × 2600 = 31,248 px`, its arc curvature is `1/2600 = 0.000385` (under 0.005), and its start straight is `2 × 3728 = 7456 px` (over 1875).

`MAX_CURVATURE` **drops** rather than scaling: curvature is 1/length, so the dimensional rule would give 0.0016 — a 50 m minimum corner radius, far too gentle for rally. 0.005 is a 16 m hairpin, which expresses the intent rather than preserving an accident of the old scale.

- [x] **Step 4: Replace the sampler and the attempt loop**

In `track/track_generator.gd`, replace `generate()` and `_build_definition()`:

```gdscript
func generate(requested_seed: int, limit_overrides: Dictionary = {}):
	var started_usec := Time.get_ticks_usec()
	var maximum_attempts := clampi(int(limit_overrides.get("max_attempts", DEFAULT_MAX_ATTEMPTS)), 1, DEFAULT_MAX_ATTEMPTS)
	var rng := RandomNumberGenerator.new()
	rng.seed = requested_seed
	var last_reason := "candidate_not_generated"
	for attempt in range(1, maximum_attempts + 1):
		var target_lap_length := rng.randf_range(MIN_LAP_LENGTH, MAX_LAP_LENGTH)
		var width := float(rng.randi_range(25, 35) * 5)
		var centerline := _sample_loop(rng, target_lap_length)
		var candidate = _build_definition(requested_seed, centerline, width)
		candidate.generation_attempts = attempt
		last_reason = _validation_reason(candidate, limit_overrides)
		if last_reason.is_empty():
			candidate.diagnostic_reason = "accepted"
			candidate.generation_usec = Time.get_ticks_usec() - started_usec
			return candidate

	var fallback = _build_definition(requested_seed, _sample_stadium(FALLBACK_HALF_STRAIGHT, FALLBACK_RADIUS), FALLBACK_WIDTH)
	fallback.generation_attempts = maximum_attempts
	fallback.used_fallback = true
	fallback.diagnostic_reason = "retry_exhausted:%s; fallback=known_valid_stadium" % last_reason
	fallback.generation_usec = Time.get_ticks_usec() - started_usec
	return fallback


func _build_definition(requested_seed: int, centerline: PackedVector2Array, width: float):
	var definition = TrackDefinitionScript.new()
	definition.seed = requested_seed
	definition.track_width = width
	definition.centerline = centerline
	var boundaries := _derive_boundaries(definition.centerline, width)
	definition.left_boundary = boundaries.left
	definition.right_boundary = boundaries.right
	definition.lap_length = _polyline_length(definition.centerline)
	definition.max_curvature = _measure_max_curvature(definition.centerline)
	definition.start_straight_length = _straight_run_length(definition.centerline, 0)
	definition.forward_direction = (definition.centerline[1] - definition.centerline[0]).normalized()
	definition.spawn_transform = Transform2D(definition.forward_direction.angle() + PI * 0.5, definition.centerline[0])
	definition.checkpoints = _build_checkpoints(definition.centerline)
	definition.bounds = _combined_bounds(definition.left_boundary, definition.right_boundary)
	definition.geometry_fingerprint = _fingerprint(definition)
	return definition
```

Width uses `randi_range(25, 35) * 5` → 125..175 px in 5 px steps, which is 10–14 m: four to five car widths against the 34 px car body.

Add the spline sampler and its helpers:

```gdscript
func _sample_loop(rng: RandomNumberGenerator, target_lap_length: float) -> PackedVector2Array:
	var base_radius := target_lap_length / TAU
	var radii := []
	for index in range(CONTROL_POINT_COUNT):
		radii.append(base_radius * rng.randf_range(RADIUS_JITTER_MIN, RADIUS_JITTER_MAX))
	# Pin three consecutive control points to the nominal radius so at least one
	# gentle span exists. Without this the start-straight constraint would be a
	# gamble on the jitter, and most seeds would fall back to the stadium.
	radii[0] = base_radius
	radii[1] = base_radius
	radii[CONTROL_POINT_COUNT - 1] = base_radius

	var controls := PackedVector2Array()
	for index in range(CONTROL_POINT_COUNT):
		var angle := TAU * float(index) / float(CONTROL_POINT_COUNT)
		controls.append(Vector2(cos(angle), sin(angle)) * radii[index])

	var loop := _catmull_rom_closed(controls)
	# Scale before resampling, not after. The spec lists resample-then-scale,
	# but scaling a uniformly-spaced polyline multiplies its spacing too, which
	# would leave samples SAMPLE_SPACING * factor apart instead of
	# SAMPLE_SPACING. Scaling first makes the spacing correct at final size.
	loop = _scale_to_lap_length(loop, target_lap_length)
	loop = _resample_uniform(loop, SAMPLE_SPACING)
	return _rotate_to_start_straight(loop)


func _catmull_rom_closed(controls: PackedVector2Array) -> PackedVector2Array:
	var points := PackedVector2Array()
	var count := controls.size()
	for index in range(count):
		var p0 := controls[(index - 1 + count) % count]
		var p1 := controls[index]
		var p2 := controls[(index + 1) % count]
		var p3 := controls[(index + 2) % count]
		for step in range(SPLINE_SAMPLES_PER_SPAN):
			var t := float(step) / float(SPLINE_SAMPLES_PER_SPAN)
			var t2 := t * t
			var t3 := t2 * t
			points.append(0.5 * (
				2.0 * p1
				+ (-p0 + p2) * t
				+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
				+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
			))
	points.append(points[0])
	return points


func _scale_to_lap_length(points: PackedVector2Array, target_length: float) -> PackedVector2Array:
	var current := _polyline_length(points)
	if current <= 0.0:
		return points
	var factor := target_length / current
	var scaled := PackedVector2Array()
	for point in points:
		scaled.append(point * factor)
	return scaled


func _resample_uniform(points: PackedVector2Array, spacing: float) -> PackedVector2Array:
	var total := _polyline_length(points)
	var target_count := maxi(int(round(total / spacing)), 8)
	var step := total / float(target_count)
	var resampled := PackedVector2Array([points[0]])
	var travelled := 0.0
	var next_mark := step
	var index := 0
	while index < points.size() - 1 and resampled.size() < target_count:
		var segment_length := points[index].distance_to(points[index + 1])
		if segment_length <= 0.0:
			index += 1
			continue
		if travelled + segment_length >= next_mark:
			var ratio := (next_mark - travelled) / segment_length
			resampled.append(points[index].lerp(points[index + 1], ratio))
			next_mark += step
		else:
			travelled += segment_length
			index += 1
	resampled.append(resampled[0])
	return resampled
```

Add the curvature and rotation helpers:

```gdscript
func _curvature_at(points: PackedVector2Array, index: int) -> float:
	var unique_count := points.size() - 1
	var incoming := points[index] - points[(index - 1 + unique_count) % unique_count]
	var outgoing := points[(index + 1) % unique_count] - points[index]
	var distance := (incoming.length() + outgoing.length()) * 0.5
	if distance <= 0.0:
		return 0.0
	return absf(incoming.angle_to(outgoing)) / distance


func _straight_run_length(points: PackedVector2Array, start: int) -> float:
	var unique_count := points.size() - 1
	var length := 0.0
	for offset in range(unique_count):
		var index := (start + offset) % unique_count
		if _curvature_at(points, index) > STRAIGHT_CURVATURE:
			break
		length += points[index].distance_to(points[(index + 1) % unique_count])
	return length


func _rotate_to_start_straight(points: PackedVector2Array) -> PackedVector2Array:
	var unique_count := points.size() - 1
	# Precompute curvature once, then find the longest gentle run in a single
	# wrapped pass. Calling _straight_run_length from every index would be
	# O(n^2) over ~1250 samples.
	var gentle := []
	for index in range(unique_count):
		gentle.append(_curvature_at(points, index) <= STRAIGHT_CURVATURE)
	var best_start := 0
	var best_length := -1.0
	var run_start := -1
	var run_length := 0.0
	for offset in range(unique_count * 2):
		var index := offset % unique_count
		if not gentle[index]:
			run_start = -1
			run_length = 0.0
			continue
		if run_start < 0:
			run_start = index
			run_length = 0.0
		run_length += points[index].distance_to(points[(index + 1) % unique_count])
		if run_length > best_length:
			best_length = run_length
			best_start = run_start
	var rotated := PackedVector2Array()
	for offset in range(unique_count):
		rotated.append(points[(best_start + offset) % unique_count])
	rotated.append(rotated[0])
	return rotated
```

Finally, make `_measure_max_curvature` reuse `_curvature_at` instead of duplicating the maths:

```gdscript
func _measure_max_curvature(points: PackedVector2Array) -> float:
	var maximum := 0.0
	for index in range(points.size() - 1):
		maximum = maxf(maximum, _curvature_at(points, index))
	return maximum
```

Keep `_sample_stadium`, `_derive_boundaries`, `_build_checkpoints`, `_validation_reason`, `_polyline_length`, `_combined_bounds`, and `_fingerprint` exactly as they are.

- [x] **Step 5: Put validation on the index**

Still in `track/track_generator.gd`, replace both brute-force checks. At ~1250 samples the old code runs ~781k pairs per check and ~14M segment-intersection calls per generation — seconds, not microseconds.

```gdscript
func _has_self_intersection(points: PackedVector2Array) -> bool:
	var segment_count := points.size() - 1
	var grid := SegmentGrid.new(points, SAMPLE_SPACING * 4.0)
	for pair in grid.candidate_pairs():
		var first: int = mini(pair.x, pair.y)
		var second: int = maxi(pair.x, pair.y)
		if second - first <= 1:
			continue
		if first == 0 and second == segment_count - 1:
			continue
		if Geometry2D.segment_intersects_segment(points[first], points[first + 1], points[second], points[second + 1]) != null:
			return true
	return false


func _boundaries_intersect(left: PackedVector2Array, right: PackedVector2Array) -> bool:
	var grid := SegmentGrid.new(left, SAMPLE_SPACING * 4.0)
	for right_index in range(right.size() - 1):
		for left_index in grid.segments_overlapping(right[right_index], right[right_index + 1]):
			if Geometry2D.segment_intersects_segment(left[left_index], left[left_index + 1], right[right_index], right[right_index + 1]) != null:
				return true
	return false
```

- [x] **Step 6: Run the generator test to verify it passes**

Run: `godot --headless --path . --script res://tests/track_generator_test.gd`
Expected: PASS, exit code 0.

- [x] **Step 7: Measure the fallback rate**

The generator already prints `seed=N fingerprint=... generation_usec=N` per seed. Add a fallback tally so a silent regression to boring ovals is visible. In `tests/track_generator_test.gd`, inside the `for seed in range(10)` loop, extend the existing `print` call to include the two diagnostic fields:

```gdscript
			print("seed=%d fingerprint=%s generation_usec=%d attempts=%d fallback=%s" % [
				seed,
				definition.geometry_fingerprint,
				definition.generation_usec,
				definition.generation_attempts,
				definition.used_fallback,
			])
```

Run the generator test and read the output.

Expected: **at most 2 of 10 seeds report `fallback=true`.** If more do, the radial jitter is too aggressive for the curvature limit — raise `RADIUS_JITTER_MIN` from 0.55 toward 0.70 (gentler dips, less curvature) and re-run until the rate is acceptable. Record the value you settled on in the commit message. Also check `generation_usec`: it should be well under 100,000 (0.1 s) per seed. If it is not, the grid is not being used — re-check Step 5.

- [x] **Step 8: Run the full suite**

Expected: all exit 0. `issue_5_main_session_test.gd` builds the real scene against a real generated track, so it exercises the new geometry end to end.

- [x] **Step 9: Commit**

```bash
git add track/track_generator.gd tests/track_generator_test.gd
git commit -m "feat: generate meandering 2-3 km circuits instead of single-screen ovals"
```

---

### Task 6: Presentation, fixtures, and evidence

**Files:**
- Modify: `track/track_runtime.gd`
- Modify: `vehicle/top_down_car.tscn`
- Modify: `tests/capture_procedural_tracks.gd`
- Modify: `tests/issue_5_input_session_test.gd`
- Modify: `README.md`, `docs/procedural-tracks.md`, `docs/controller-time-trial.md`

**Interfaces:**
- Consumes: everything from Tasks 1–5. Produces nothing new.

- [x] **Step 1: Make the track's render widths proportional**

In `track/track_runtime.gd`, the grass shoulder is `track_width + 24.0` — a 24 px band that was 2 m at the old scale and renders as a hairline now. Replace the two `_build_line` calls in `_ready()`:

```gdscript
	_build_line("GrassShoulder", definition.track_width * 1.4, GRASS_COLOR, -3)
	_build_line("Dirt", definition.track_width, DIRT_COLOR, -2)
```

In `_build_boundary_line`, replace the width:

```gdscript
	line.width = 6.0
```

In `_build_start_finish_line`, replace the width:

```gdscript
	line.width = 15.0
```

Note `tests/track_generator_test.gd:161` asserts `grass_shoulder.width > dirt_line.width`, which `× 1.4` still satisfies.

- [x] **Step 2: Scale the dust particles**

In `vehicle/top_down_car.tscn`, in the `ParticleProcess_dust` sub-resource, the dust drifts at 7–15 px/s while the car now travels at 600. Replace:

```
initial_velocity_min = 87.5
initial_velocity_max = 187.5
gravity = Vector3(0, 37.5, 0)
scale_min = 12.5
scale_max = 30.0
```

- [x] **Step 3: Match the capture script's shoulder to the runtime**

In `tests/capture_procedural_tracks.gd`, lines 35–38 duplicate the old widths. The `scale_factor` on line 33 already derives from `definition.bounds`, so it adapts to the bigger world on its own — only the widths need to follow Step 1:

```gdscript
		_draw_polyline(image, definition.centerline, scale_factor, offset, definition.track_width * 1.4 * scale_factor, GRASS)
		_draw_polyline(image, definition.centerline, scale_factor, offset, definition.track_width * scale_factor, DIRT)
		_draw_polyline(image, definition.left_boundary, scale_factor, offset, 2.0, EDGE)
		_draw_polyline(image, definition.right_boundary, scale_factor, offset, 2.0, EDGE)
```

The two `2.0` edge widths stay: they are in **image** pixels, not world pixels, and the image is still 1280 wide.

- [x] **Step 4: Update the checkpoint-gate fixture**

`tests/issue_5_input_session_test.gd` builds a synthetic `TrackDefinition` with `track_width = 40.0` — now below `MIN_WIDTH`, so it describes a track the generator can no longer produce. Widening it changes the geometry the gate test depends on, so **both** values must move together: the gate is at `(100, 50)` and the "outside the gate" probe sits at `y = 80`, which is 30 px laterally. At width 150 the half-width becomes 75, so `y = 80` would fall *inside* the gate and the assertion would invert.

In `_verify_checkpoint_crossings`, replace:

```gdscript
	definition.track_width = 150.0
```

and replace the outside-gate probe (the last three lines of the function before `_check`):

```gdscript
	detector.reset(Vector2(95.0, 180.0))
	var outside_gate: Dictionary = detector.sample(Vector2(105.0, 180.0))
	_check(outside_gate.is_empty(), "crossing outside the finite track-width gate is ignored")
```

`y = 180` is 130 px laterally, comfortably outside the 75 px half-width.

- [x] **Step 5: Run the full suite**

Expected: all exit 0.

- [x] **Step 6: Regenerate the visual evidence**

These need a graphical Godot session, not `--headless`:

```sh
godot --path . --script res://tests/capture_procedural_tracks.gd
godot --path . --script res://tests/capture_issue_4_gameplay.gd
godot --path . --script res://tests/capture_issue_5_session.gd
```

Open the regenerated images under `docs/evidence` and `docs/screenshots` and confirm by eye: the track is a meandering loop rather than an oval, the car occupies a small fraction of the visible area, and the dirt band is several car widths wide.

- [x] **Step 7: Update the documentation**

In `README.md`, add `world/` to the "Project boundaries" table:

```
| `world/` | The pixel-per-metre scale contract and shared spatial indexing |
```

Add a sentence to the same section:

```
The world unit is the pixel at **12.5 px per metre** (`world/world_scale.gd`). Every length, speed, and acceleration in `track/`, `vehicle/`, and `session/` is expressed in pixels at that scale; route new scale-dependent literals through `WorldScale.metres()` so they stay greppable.
```

Add the two new test commands to the "Verification" section:

```sh
godot --headless --path . --script res://tests/world_scale_contract_test.gd
godot --headless --path . --script res://tests/segment_grid_test.gd
```

In `docs/procedural-tracks.md`, update the documented generator constants to the Task 5 values (width 125–175 px, lap 25,000–37,500 px, sample spacing 25, max curvature 0.005, min start straight 1875) and describe the Catmull-Rom sampler, the pinned control points, and the start-straight rotation.

In `docs/controller-time-trial.md`, update any quoted tuning values to the Task 2 numbers.

- [x] **Step 8: Commit**

```bash
git add track/track_runtime.gd vehicle/top_down_car.tscn tests/capture_procedural_tracks.gd tests/issue_5_input_session_test.gd README.md docs/
git commit -m "feat: scale track rendering, fixtures, and evidence to the new world"
```

- [ ] **Step 9: Re-export the Android build**

Follow `docs/android-export.md`. The export is unaffected by scale, but the checked-in artefact predates every change here and the issue #6 evidence should reflect the current build.

---

## Deferred (explicitly out of scope)

- Camera `limit_*` clamping to track bounds. The background is a screen-space `ColorRect`, so there is no visible void to hide.
- Spatial partitioning beyond the uniform grid. Measure before reaching for anything more.
- `TrackRuntime` now builds ~2,500 `SegmentShape2D` children per track (2 × 1,250 boundary segments) versus ~300 before. Godot's broadphase handles this and it is a one-time build cost, but if track load time becomes noticeable, merging collinear runs into fewer segments is the first thing to try.
