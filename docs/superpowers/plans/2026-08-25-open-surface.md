# Open Surface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the track's walls with a distant containment boundary so the car can leave the circuit, pay for it in grip and drag, and be returned to the racing line automatically when the player opts in.

**Architecture:** The track's per-segment boundary collision is deleted and replaced by a four-segment rectangle around a new `play_area` field on `TrackDefinition`. Off-track physics, the safe-reset destination, and lap integrity already exist and are consumed unchanged. Auto-reset is a pair of conditions evaluated in `TopDownCar._integrate_forces` against thresholds stored in `VehicleTuning`, gated by a `SessionSettings` flag.

**Tech Stack:** Godot 4.7.1 stable (official build `a13da4feb`), GDScript, GL Compatibility renderer. No new dependencies, no new autoloads.

**Spec:** `docs/superpowers/specs/2026-08-25-open-surface-design.md`

## Global Constraints

- Godot **4.7.1 stable**, official build `a13da4feb`. GL Compatibility renderer.
- `PIXELS_PER_METRE = 12.5`. Every length, speed, and acceleration in `track/`, `vehicle/`, and `session/` is in pixels at this scale. Route scale-dependent literals through `WorldScale.metres()`.
- No new dependencies, no new autoloads.
- `platform/` is reserved for platform adapters only.
- Tests are `SceneTree` scripts run headless: `godot --headless --path . --script res://tests/<name>.gd`. Exit code 0 = pass.
- Test harness pattern: `extends SceneTree`, `_initialize()` calls `call_deferred("_run")`, assertions go through a local `_check(condition, message)`, and `_finish()` calls `quit(0)` or `quit(1)`.
- A fresh checkout has no import cache. Run `godot --editor --headless --path . --quit` once before any test script, or `load()` returns unusable scripts.
- **Full suite** (run at the end of every task):

```sh
godot --editor --headless --path . --quit
godot --headless --path . --script res://tests/headless_smoke.gd
godot --headless --path . --script res://tests/world_scale_contract_test.gd
godot --headless --path . --script res://tests/segment_grid_test.gd
godot --headless --path . --script res://tests/track_generator_test.gd
godot --headless --path . --script res://tests/track_collision_physics_test.gd
godot --headless --path . --script res://tests/issue_4_vehicle_maneuvers.gd
godot --headless --path . --script res://tests/issue_5_input_session_test.gd
godot --headless --path . --script res://tests/issue_5_main_session_test.gd
godot --headless --path . --script res://tests/issue_6_android_test.gd
```

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `track/track_definition.gd` | Serializable track contract | Add `play_area: Rect2` |
| `track/track_generator.gd` | Circuit generation and validation | Add `PLAY_AREA_MARGIN`, populate `play_area`, widen `MIN_WIDTH`/`MAX_WIDTH` |
| `track/track_runtime.gd` | Scene construction from a definition | Delete boundary collision, build `PlayAreaBounds` |
| `track/surface_query.gd` | Surface contract consumed by the vehicle | Add `distance_to_centerline()` with a safe default |
| `track/track_surface_map.gd` | Real surface provider | Expose the existing private distance calculation |
| `vehicle/vehicle_tuning.gd` | Physics tuning data | Add three auto-reset thresholds |
| `vehicle/top_down_car.gd` | Vehicle dynamics | Evaluate auto-reset conditions while off-track |
| `session/session_settings.gd` | Session configuration | Add `auto_reset_enabled` |
| `session/main.gd` | Session wiring and HUD | Pass the setting through, report auto-resets |
| `tests/track_collision_physics_test.gd` | Was boundary-wall coverage | Rewritten as containment coverage |
| `tests/issue_4_test_surface_provider.gd` | Deterministic test surface | Add a settable centerline distance |
| `tests/open_surface_auto_reset_test.gd` | New | Auto-reset condition coverage |

Task order keeps the game playable at every commit. Widening happens while the walls still exist, so the generator risk is measured in isolation before the fence is removed.

---

### Task 1: The play area contract

Adds the containment rectangle to the track contract without changing any behaviour. Purely additive.

**Files:**
- Modify: `track/track_definition.gd`
- Modify: `track/track_generator.gd:53-69`
- Test: `tests/track_generator_test.gd`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `TrackDefinition.play_area: Rect2` and `TrackGenerator.PLAY_AREA_MARGIN: float`. Task 3 builds collision from `play_area`; Task 5 asserts `auto_reset_lost_distance < PLAY_AREA_MARGIN`.

- [ ] **Step 1: Write the failing test**

Add to `tests/track_generator_test.gd`, inside the per-seed verification function that already receives `definition` and `seed` (the one containing the `width is within the driveable bound` check):

```gdscript
	var expected_margin: float = TrackGeneratorScript.PLAY_AREA_MARGIN
	_check(definition.play_area.encloses(definition.bounds), "seed %d play area encloses the track bounds" % seed)
	_check(
		is_equal_approx(definition.play_area.position.x, definition.bounds.position.x - expected_margin)
			and is_equal_approx(definition.play_area.position.y, definition.bounds.position.y - expected_margin),
		"seed %d play area starts one margin outside the bounds" % seed
	)
	_check(
		is_equal_approx(definition.play_area.size.x, definition.bounds.size.x + expected_margin * 2.0)
			and is_equal_approx(definition.play_area.size.y, definition.bounds.size.y + expected_margin * 2.0),
		"seed %d play area adds one margin on every side" % seed
	)
```

If `tests/track_generator_test.gd` does not already hold a `TrackGeneratorScript` constant, add it beside the existing path constants at the top of the file:

```gdscript
const TrackGeneratorScript := preload("res://track/track_generator.gd")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot --headless --path . --script res://tests/track_generator_test.gd`
Expected: FAIL — `play_area` is an empty `Rect2`, so `encloses` is false. Exit code 1.

- [ ] **Step 3: Add the field to the contract**

In `track/track_definition.gd`, directly after the `bounds` export:

```gdscript
@export var bounds: Rect2 = Rect2()
@export var play_area: Rect2 = Rect2()
```

- [ ] **Step 4: Populate it in the generator**

In `track/track_generator.gd`, add beside the other constants (after `FALLBACK_WIDTH`):

```gdscript
## Runoff beyond the track's own bounds before the containment boundary. Sized so a car that
## leaves the circuit has roughly 1.5 viewport widths to recover in before meeting anything solid.
const PLAY_AREA_MARGIN := 2000.0
```

`WorldScale.metres(160.0)` is the same number; the literal is used because GDScript constants must be compile-time expressions and `WorldScale.metres()` is a static function call. The relationship is recorded in the comment.

In `_build_definition`, immediately after the `bounds` assignment on line 67:

```gdscript
	definition.bounds = _combined_bounds(definition.left_boundary, definition.right_boundary)
	definition.play_area = definition.bounds.grow(PLAY_AREA_MARGIN)
```

Leave `_fingerprint()` untouched. It hashes width and centerline only, so `play_area` is derived data and must not enter the geometry fingerprint.

- [ ] **Step 5: Run the test to verify it passes**

Run: `godot --headless --path . --script res://tests/track_generator_test.gd`
Expected: PASS, exit code 0.

- [ ] **Step 6: Run the full suite**

Expected: all scripts exit 0.

- [ ] **Step 7: Commit**

```bash
git add track/track_definition.gd track/track_generator.gd tests/track_generator_test.gd
git commit -m "feat: add the play area containment rectangle to the track contract"
```

---

### Task 2: Widen the track

The spec's one substantive risk. Widening eats the generator's self-intersection clearance, so the fallback rate is measured before and after rather than assumed.

**Files:**
- Modify: `track/track_generator.gd:9-10`
- Test: `tests/track_generator_test.gd:8-9`

**Interfaces:**
- Consumes: nothing.
- Produces: `MIN_WIDTH = 200.0`, `MAX_WIDTH = 280.0`. Checkpoint gate width and `TrackSurfaceMap`'s off-track threshold are both `track_width * 0.5` and follow automatically.

- [ ] **Step 1: Record the fallback rate at the current width**

Run: `godot --headless --path . --script res://tests/track_generator_test.gd | grep -c "fallback=true"`

Write the number down. The test prints one `seed=... fallback=...` line per seed across 20 seeds. This is the baseline the widened rate is judged against.

- [ ] **Step 2: Update the test's expected bounds first**

In `tests/track_generator_test.gd`:

```gdscript
const EXPECTED_MIN_WIDTH := 200.0
const EXPECTED_MAX_WIDTH := 280.0
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `godot --headless --path . --script res://tests/track_generator_test.gd`
Expected: FAIL — `seed N width is within the driveable bound`, because the generator still produces 125–175. Exit code 1.

- [ ] **Step 4: Widen the generator**

In `track/track_generator.gd`:

```gdscript
const MIN_WIDTH := 200.0
const MAX_WIDTH := 280.0
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `godot --headless --path . --script res://tests/track_generator_test.gd`
Expected: PASS, exit code 0.

- [ ] **Step 6: Measure the widened fallback rate**

Run: `godot --headless --path . --script res://tests/track_generator_test.gd | grep -c "fallback=true"`

Compare against Step 1. The existing assertion bounds fallbacks at 2 of 20 seeds.

**If the rate exceeds that bound, do not loosen the bound.** Report both numbers and stop for a decision. The available levers are `DEFAULT_MAX_ATTEMPTS` (currently 30) and `MIN_LAP_LENGTH` (currently 25000.0); a wider ribbon needs either more attempts or a longer lap to route around itself. Raising the attempt budget costs generation time, which is already 26–283 ms and runs synchronously at session start.

- [ ] **Step 7: Run the full suite**

Expected: all scripts exit 0. `tests/track_collision_physics_test.gd` still passes here — the walls are still present at this point, merely further apart.

- [ ] **Step 8: Commit**

```bash
git add track/track_generator.gd tests/track_generator_test.gd
git commit -m "feat: widen the circuit to 200-280 px"
```

---

### Task 3: Replace the fence with containment

The behavioural centre of this plan. After this task the car can leave the track.

**Files:**
- Modify: `track/track_runtime.gd:71-88`
- Modify: `tests/track_generator_test.gd:173`
- Rewrite: `tests/track_collision_physics_test.gd`

**Interfaces:**
- Consumes: `TrackDefinition.play_area` (Task 1).
- Produces: a `StaticBody2D` child of `TrackRuntime` named `PlayAreaBounds` carrying four `CollisionShape2D` children named `Edge0`–`Edge3`. The node named `TrackEdges` no longer exists.

- [ ] **Step 1: Rewrite the collision test as containment coverage**

Replace the entire contents of `tests/track_collision_physics_test.gd`:

```gdscript
extends SceneTree

## Containment coverage. The circuit has no walls; a single rectangle far outside the track
## keeps the car recoverable and stops it reaching the featureless void beyond the background.

const ORDINARY_RACING_SPEED := 300.0
const TEST_TICKS_PER_SECOND := 60.0
const TEST_BODY_RADIUS := 4.0
const ESCAPE_TICKS := 240
## The probe is a point-like body; allow its radius plus solver margin outside the nominal edge.
const CONTAINMENT_TOLERANCE := 8.0

var _failures: Array[String] = []
var _checks := 0
var _physics_ticks := 0
var _break_collision := false


func _initialize() -> void:
	_break_collision = OS.get_cmdline_user_args().has("--break-collision")
	call_deferred("_run")


func _run() -> void:
	var generator_script := load("res://track/track_generator.gd") as GDScript
	var runtime_script := load("res://track/track_runtime.gd") as GDScript
	_check(generator_script != null, "real TrackGenerator loads")
	_check(runtime_script != null, "real TrackRuntime loads")
	if generator_script == null or runtime_script == null:
		_finish()
		return

	var generator = generator_script.new()
	for seed in [0, 4, 9]:
		var definition = generator.generate(seed)
		var world := Node2D.new()
		world.name = "PhysicsWorldSeed%d" % seed
		root.add_child(world)
		var runtime = runtime_script.new(definition)
		world.add_child(runtime)
		await physics_frame
		_physics_ticks += 1

		_verify_bounds_body_exists(runtime, seed)
		if _break_collision:
			_remove_containment(runtime)
		await _verify_probe_stays_inside(world, definition, seed)

		world.queue_free()
		await process_frame
		await physics_frame
		_physics_ticks += 1

	_finish()


func _verify_bounds_body_exists(runtime: Node, seed: int) -> void:
	var body := runtime.get_node_or_null("PlayAreaBounds") as StaticBody2D
	_check(body != null, "seed %d builds a PlayAreaBounds body" % seed)
	if body == null:
		return
	_check(body.get_child_count() == 4, "seed %d containment is four segments (got %d)" % [seed, body.get_child_count()])
	_check(runtime.get_node_or_null("TrackEdges") == null, "seed %d builds no per-segment track walls" % seed)


func _remove_containment(runtime: Node) -> void:
	var body := runtime.get_node_or_null("PlayAreaBounds") as StaticBody2D
	if body == null:
		return
	for child in body.get_children():
		body.remove_child(child)
		child.queue_free()


## Drive a probe outward from the track towards each side of the play area and confirm the
## containment boundary stops it. Four runs per seed, one per edge.
func _verify_probe_stays_inside(world: Node2D, definition, seed: int) -> void:
	var play_area: Rect2 = definition.play_area
	var directions := [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]
	var names := ["right", "left", "down", "up"]
	for index in range(directions.size()):
		var body := _create_test_body()
		world.add_child(body)
		body.position = definition.centerline[0]
		await physics_frame
		_physics_ticks += 1

		var direction: Vector2 = directions[index]
		for tick in range(ESCAPE_TICKS):
			body.move_and_collide(direction * ORDINARY_RACING_SPEED / TEST_TICKS_PER_SECOND)
			await physics_frame
			_physics_ticks += 1

		var grown := play_area.grow(CONTAINMENT_TOLERANCE)
		_check(
			grown.has_point(body.position),
			"seed %d probe driven %s stays inside the play area (at %.1f,%.1f)" % [seed, names[index], body.position.x, body.position.y]
		)
		body.queue_free()
		await process_frame


func _create_test_body() -> CharacterBody2D:
	var body := CharacterBody2D.new()
	body.name = "ContainmentProbe"
	body.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	body.collision_layer = 2
	body.collision_mask = 1
	body.safe_margin = 0.05
	var collision_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = TEST_BODY_RADIUS
	collision_shape.shape = circle
	body.add_child(collision_shape)
	return body


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	print("track_containment physics_ticks=%d checks=%d mutation=%s" % [_physics_ticks, _checks, str(_break_collision)])
	if _failures.is_empty():
		print("Track containment checks passed")
		quit(0)
		return
	for failure in _failures:
		push_error("Track containment check failed: %s" % failure)
	quit(1)
```

`ESCAPE_TICKS = 240` is four seconds at 5 px/tick, i.e. 1,200 px of travel. The margin is 2,000 px, so a probe starting on the centerline cannot reach the boundary by distance alone — it is stopped because the boundary is solid, not because it ran out of ticks. Increase this only if a seed's bounds place the start line closer than 1,200 px to an edge.

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot --headless --path . --script res://tests/track_collision_physics_test.gd`
Expected: FAIL — `seed 0 builds a PlayAreaBounds body`, because `TrackRuntime` still builds `TrackEdges`. Exit code 1.

- [ ] **Step 3: Replace the collision construction**

In `track/track_runtime.gd`, replace `_build_collision()` and delete `_add_boundary_collision()` entirely:

```gdscript
## The circuit has no walls. A single rectangle far outside the track keeps the car recoverable
## without turning the boundary line into a barrier. This also drops collision shapes per track
## from roughly 2,500 to 4.
func _build_collision() -> void:
	var body := StaticBody2D.new()
	body.name = "PlayAreaBounds"
	add_child(body)
	var area: Rect2 = definition.play_area
	var corners := [
		area.position,
		Vector2(area.end.x, area.position.y),
		area.end,
		Vector2(area.position.x, area.end.y),
	]
	for index in range(corners.size()):
		var shape := SegmentShape2D.new()
		shape.a = corners[index]
		shape.b = corners[(index + 1) % corners.size()]
		var collision := CollisionShape2D.new()
		collision.name = "Edge%d" % index
		collision.shape = shape
		body.add_child(collision)
```

Leave `_build_boundary_line()` and its two call sites untouched. The track edge stays visible; it simply stops being solid.

- [ ] **Step 4: Update the generator test's node assertion**

In `tests/track_generator_test.gd` line 173, the assertion looks for `TrackEdges`. Replace that lookup and the check that follows it:

```gdscript
	var collision_body := runtime.get_node_or_null("PlayAreaBounds") as StaticBody2D
	_check(collision_body != null and collision_body.get_child_count() == 4, "prototype track builds a four-segment containment boundary")
```

- [ ] **Step 5: Run both tests to verify they pass**

Run: `godot --headless --path . --script res://tests/track_collision_physics_test.gd`
Expected: PASS, exit code 0.

Run: `godot --headless --path . --script res://tests/track_generator_test.gd`
Expected: PASS, exit code 0.

- [ ] **Step 6: Verify the containment assertion can fail**

Run: `godot --headless --path . --script res://tests/track_collision_physics_test.gd -- --break-collision`
Expected: FAIL, exit code 1, with `probe driven ... stays inside the play area` failures.

If this exits 0, the assertion is inert and the task is not done. A probe with the containment shapes removed must escape.

- [ ] **Step 7: Run the full suite**

Expected: all scripts exit 0.

- [ ] **Step 8: Commit**

```bash
git add track/track_runtime.gd tests/track_collision_physics_test.gd tests/track_generator_test.gd
git commit -m "feat: replace the track fence with a distant containment boundary"
```

---

### Task 4: Expose distance to the centerline

`TrackSurfaceMap` already computes this privately. The auto-reset needs it, so it is promoted to the surface contract.

**Files:**
- Modify: `track/surface_query.gd`
- Modify: `track/track_surface_map.gd`
- Modify: `tests/issue_4_test_surface_provider.gd`
- Test: `tests/segment_grid_test.gd`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `SurfaceQuery.distance_to_centerline(world_position: Vector2, search_radius: float) -> float`. Returns `0.0` from the base class; the real provider returns `INF` beyond `search_radius`. Task 5 calls this with `tuning.auto_reset_lost_distance`.

- [ ] **Step 1: Write the failing test**

Add to `tests/segment_grid_test.gd`, called from `_run()` alongside the existing surface verification:

```gdscript
func _verify_distance_agrees_with_surface_classification() -> void:
	var generator_script := load(TRACK_GENERATOR_PATH) as GDScript
	var surface_map_script := load(SURFACE_MAP_PATH) as GDScript
	var definition = generator_script.new().generate(0)
	var surface_map = surface_map_script.new(definition)
	var half_width: float = definition.track_width * 0.5

	var centre: Vector2 = definition.centerline[10]
	_check(
		surface_map.distance_to_centerline(centre, half_width) < 1.0,
		"a point on the centerline reports a near-zero distance"
	)

	var lateral: Vector2 = (definition.centerline[11] - definition.centerline[10]).normalized().orthogonal()
	var just_inside: Vector2 = centre + lateral * (half_width - 5.0)
	var just_outside: Vector2 = centre + lateral * (half_width + 5.0)
	_check(
		surface_map.sample_at(just_inside).surface_type == SurfaceQuery.SurfaceType.DIRT
			and surface_map.distance_to_centerline(just_inside, half_width) <= half_width,
		"a point inside the track is DIRT and within half a width of the line"
	)
	var far_distance: float = surface_map.distance_to_centerline(just_outside, half_width * 8.0)
	_check(
		surface_map.sample_at(just_outside).surface_type == SurfaceQuery.SurfaceType.OFF_TRACK
			and far_distance > half_width and far_distance < half_width * 2.0,
		"a point just outside the track is OFF_TRACK and reports a real distance, not INF"
	)
	_check(
		is_inf(surface_map.distance_to_centerline(centre + lateral * (half_width * 20.0), half_width)),
		"a point beyond the search radius saturates to INF rather than lying about the distance"
	)


func _verify_base_surface_query_never_reports_lost() -> void:
	var base := SurfaceQuery.new()
	_check(
		is_zero_approx(base.distance_to_centerline(Vector2(9999.0, 9999.0), 1000.0)),
		"the base SurfaceQuery reports zero distance so providers without a centerline never read as lost"
	)
```

Add both calls inside `_run()` after the existing verification calls.

- [ ] **Step 2: Run the test to verify it fails**

Run: `godot --headless --path . --script res://tests/segment_grid_test.gd`
Expected: FAIL — `Invalid call. Nonexistent function 'distance_to_centerline'`. Exit code 1.

- [ ] **Step 3: Add the method to the contract**

In `track/surface_query.gd`, after `sample_at()`:

```gdscript
## Distance from a world position to the track centerline, accurate out to search_radius.
##
## Beyond search_radius an implementation may return INF instead of a true distance. The real
## provider answers from a spatial grid queried with exactly this radius, so a caller pays only
## for the range it needs. Callers must pass the largest distance they care about and read INF as
## "further away than that".
##
## The base implementation returns 0.0 rather than pushing an error: a provider with no notion of
## a centerline should read as "on the line" so distance-based rules never fire against it.
## Returning INF here would make every such provider permanently "lost".
func distance_to_centerline(_world_position: Vector2, _search_radius: float) -> float:
	return 0.0
```

- [ ] **Step 4: Implement it on the real provider**

In `track/track_surface_map.gd`, rename the private method to the public contract name and update its one caller:

```gdscript
func sample_at(world_position: Vector2) -> SurfaceSample:
	if _definition != null:
		var half_width: float = _definition.track_width * 0.5
		if distance_to_centerline(world_position, half_width) <= half_width:
			return SurfaceSample.new(SurfaceType.DIRT, DIRT_GRIP, DIRT_DRAG)
	return SurfaceSample.new(SurfaceType.OFF_TRACK, GRASS_GRIP, GRASS_DRAG)


func distance_to_centerline(world_position: Vector2, search_radius: float) -> float:
	if _grid == null:
		return INF
	var nearest_distance := INF
	for index in _grid.segments_near(world_position, search_radius):
		var closest := Geometry2D.get_closest_point_to_segment(
			world_position,
			_definition.centerline[index],
			_definition.centerline[index + 1],
		)
		nearest_distance = minf(nearest_distance, world_position.distance_to(closest))
	return nearest_distance
```

**The search radius is a parameter, not a fixed half-width, and this is load-bearing.** The original
private method queried the grid with `half_width`, so *any* off-track position returned `INF` —
there were no segments in range to measure against. Classification only ever asked "inside or
outside", so that was sufficient. Task 5 asks "how far outside", and against a fixed half-width
radius the answer would always be `INF`, firing the lost condition the instant the car left the
track and making `auto_reset_lost_distance` meaningless.

`sample_at` keeps paying only for `half_width`, so the per-tick classification cost is unchanged.
Task 5 passes the distance it actually cares about, and only while off-track.

- [ ] **Step 5: Give the test provider a settable distance**

In `tests/issue_4_test_surface_provider.gd`, add the field and override so auto-reset tests can drive the lost condition:

```gdscript
var distance_from_line: float = 0.0


func distance_to_centerline(_world_position: Vector2, _search_radius: float) -> float:
	return distance_from_line
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `godot --headless --path . --script res://tests/segment_grid_test.gd`
Expected: PASS, exit code 0.

- [ ] **Step 7: Run the full suite**

Expected: all scripts exit 0.

- [ ] **Step 8: Commit**

```bash
git add track/surface_query.gd track/track_surface_map.gd tests/issue_4_test_surface_provider.gd tests/segment_grid_test.gd
git commit -m "feat: promote centerline distance to the surface contract"
```

---

### Task 5: Automatic reset

**Files:**
- Modify: `vehicle/vehicle_tuning.gd`
- Modify: `vehicle/top_down_car.gd`
- Modify: `session/session_settings.gd`
- Modify: `session/main.gd:67-70`
- Create: `tests/open_surface_auto_reset_test.gd`

**Interfaces:**
- Consumes: `SurfaceQuery.distance_to_centerline(position, search_radius)` (Task 4), `TrackGenerator.PLAY_AREA_MARGIN` (Task 1). The car passes `tuning.auto_reset_lost_distance` as the search radius.
- Produces: `TopDownCar.set_auto_reset_enabled(enabled: bool) -> void` and `TopDownCar.consume_auto_reset_notice() -> bool`, which returns `true` once after an automatic reset has fired and `false` thereafter.

- [ ] **Step 1: Write the failing test**

Create `tests/open_surface_auto_reset_test.gd`:

```gdscript
extends SceneTree

## Automatic reset fires when the car is stuck off-track or has strayed far from the racing line,
## and stays silent otherwise. Uses a deterministic surface provider rather than a generated track
## so each condition can be driven in isolation.

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const GENERATOR_PATH := "res://track/track_generator.gd"
const START := Vector2(4000.0, 6500.0)

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _verify_stuck_off_track_triggers_reset()
	await _verify_straying_far_triggers_reset()
	await _verify_disabled_never_triggers()
	await _verify_moving_off_track_near_the_line_does_not_trigger()
	_verify_lost_distance_stays_inside_the_play_area()
	_finish()


func _verify_stuck_off_track_triggers_reset() -> void:
	var context := _make_car(true)
	var car: TopDownCar = context.car
	var provider = context.provider
	provider.force_off_track = true
	provider.distance_from_line = 10.0
	var tuning: VehicleTuning = car.tuning
	var ticks := int((tuning.auto_reset_stuck_seconds + 0.5) * 60.0)
	for tick in range(ticks):
		await physics_frame
	_check(car.consume_auto_reset_notice(), "sitting still off-track triggers an automatic reset")
	_check(car.global_position.distance_to(START) < 1.0, "the automatic reset returns the car to its safe pose")
	context.world.queue_free()
	await process_frame


func _verify_straying_far_triggers_reset() -> void:
	var context := _make_car(true)
	var car: TopDownCar = context.car
	var provider = context.provider
	provider.force_off_track = true
	var tuning: VehicleTuning = car.tuning
	provider.distance_from_line = tuning.auto_reset_lost_distance + 100.0
	for tick in range(5):
		await physics_frame
	_check(car.consume_auto_reset_notice(), "straying beyond the lost distance triggers an automatic reset")
	context.world.queue_free()
	await process_frame


func _verify_disabled_never_triggers() -> void:
	var context := _make_car(false)
	var car: TopDownCar = context.car
	var provider = context.provider
	provider.force_off_track = true
	var tuning: VehicleTuning = car.tuning
	provider.distance_from_line = tuning.auto_reset_lost_distance + 100.0
	var ticks := int((tuning.auto_reset_stuck_seconds + 1.0) * 60.0)
	for tick in range(ticks):
		await physics_frame
	_check(not car.consume_auto_reset_notice(), "auto reset stays silent when the setting is disabled")
	context.world.queue_free()
	await process_frame


func _verify_moving_off_track_near_the_line_does_not_trigger() -> void:
	var context := _make_car(true)
	var car: TopDownCar = context.car
	var provider = context.provider
	provider.force_off_track = true
	provider.distance_from_line = 50.0
	var tuning: VehicleTuning = car.tuning
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var ticks := int((tuning.auto_reset_stuck_seconds + 1.0) * 60.0)
	for tick in range(ticks):
		await physics_frame
	_check(
		not car.consume_auto_reset_notice(),
		"a deliberate off-track run at speed near the line is not interrupted"
	)
	context.world.queue_free()
	await process_frame


func _verify_lost_distance_stays_inside_the_play_area() -> void:
	var tuning = load(TUNING_PATH) as VehicleTuning
	var margin: float = (load(GENERATOR_PATH) as GDScript).PLAY_AREA_MARGIN
	_check(
		tuning.auto_reset_lost_distance < margin,
		"the lost distance (%.1f) resolves before the containment boundary (%.1f)" % [tuning.auto_reset_lost_distance, margin]
	)


func _make_car(auto_reset_enabled: bool) -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = load(TUNING_PATH) as VehicleTuning
	car.global_transform = Transform2D(0.0, START)
	var provider := Issue4TestSurfaceProvider.new()
	car.set_surface_query(provider)
	world.add_child(car)
	car.set_safe_reset_pose(Transform2D(0.0, START))
	car.set_auto_reset_enabled(auto_reset_enabled)
	return {"world": world, "car": car, "provider": provider}


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	print("auto_reset checks=%d" % _checks)
	if _failures.is_empty():
		print("Auto reset checks passed")
		quit(0)
		return
	for failure in _failures:
		push_error("Auto reset check failed: %s" % failure)
	quit(1)
```

The test refers to `provider.force_off_track`, which `Issue4TestSurfaceProvider` does not have — its `sample_at` keys off `boundary_y`. Add it in Step 2 alongside the tuning fields, since the test cannot run without it.

`TUNING_PATH` is the resource `session/main.tscn` loads as `id="4_tuning"`, so the test exercises
the same tuning the shipped game uses rather than a freshly constructed default.

- [ ] **Step 2: Add the test provider flag and the tuning fields**

In `tests/issue_4_test_surface_provider.gd`, add the field and honour it first in `sample_at`:

```gdscript
var force_off_track: bool = false


func sample_at(world_position: Vector2) -> SurfaceSample:
	if force_off_track:
		return SurfaceSample.new(SurfaceType.OFF_TRACK, off_track_grip, off_track_drag)
	if world_position.y <= boundary_y:
		return SurfaceSample.new(SurfaceType.OFF_TRACK, off_track_grip, off_track_drag)
	return SurfaceSample.new(SurfaceType.DIRT, dirt_grip, dirt_drag)
```

In `vehicle/vehicle_tuning.gd`, add a group after `Safety`:

```gdscript
@export_group("Automatic reset")
## Below this speed the car counts as stopped. Terminal speed is 600 px/s, so this cannot fire
## during any controlled off-track run.
@export_range(0.0, 200.0, 0.1) var auto_reset_stuck_speed: float = 25.0
## Long enough to ride out a slow corner exit, short enough not to strand the player.
@export_range(0.1, 10.0, 0.1) var auto_reset_stuck_seconds: float = 2.0
## Half the generator's PLAY_AREA_MARGIN, so "lost" resolves before the containment boundary.
@export_range(0.0, 10000.0, 10.0) var auto_reset_lost_distance: float = 1000.0
```

The checked-in resource `data/default_vehicle_tuning.tres` stores only properties that differ from
the script defaults, so it needs no edit for the car to pick these up. Confirm that after a headless
import by checking the resource still loads and the test's invariant check passes. Add the values by
hand only if a later tuning pass changes them from the defaults above:

```
auto_reset_stuck_speed = 25.0
auto_reset_stuck_seconds = 2.0
auto_reset_lost_distance = 1000.0
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `godot --headless --path . --script res://tests/open_surface_auto_reset_test.gd`
Expected: FAIL — `Invalid call. Nonexistent function 'set_auto_reset_enabled'`. Exit code 1.

- [ ] **Step 4: Implement the conditions in the car**

In `vehicle/top_down_car.gd`, add state beside the existing reset fields:

```gdscript
var _auto_reset_enabled := false
var _auto_reset_notice := false
var _off_track_stopped_elapsed := 0.0
```

Add the two public methods beside `request_safe_reset()`:

```gdscript
func set_auto_reset_enabled(enabled: bool) -> void:
	_auto_reset_enabled = enabled
	if not enabled:
		_off_track_stopped_elapsed = 0.0


## True once after an automatic reset, then false until the next one. The session polls this to
## show a status message without the car needing a reference to the HUD.
func consume_auto_reset_notice() -> bool:
	var notice := _auto_reset_notice
	_auto_reset_notice = false
	return notice
```

Add the evaluator:

```gdscript
## Two conditions, either sufficient, evaluated only while off-track: the car has stopped, or it
## has strayed far from the racing line. Returning to dirt clears both.
##
## The search radius passed below is the lost distance itself: TrackSurfaceMap answers from a grid
## queried with exactly that radius, so anything further away returns INF -- which is precisely the
## "lost" answer. Passing a smaller radius would report INF for every off-track position and fire
## the reset the moment the car left the track.
##
## The comparison is written as "not less than or equal" rather than "greater than" so that INF
## resolves correctly and a NAN from a degenerate provider fails safe by not resetting.
func _update_auto_reset(state: PhysicsDirectBodyState2D, delta: float) -> void:
	if not _auto_reset_enabled or _surface_type != SurfaceQuery.SurfaceType.OFF_TRACK:
		_off_track_stopped_elapsed = 0.0
		return

	if state.linear_velocity.length() < tuning.auto_reset_stuck_speed:
		_off_track_stopped_elapsed += delta
	else:
		_off_track_stopped_elapsed = 0.0

	var stuck := _off_track_stopped_elapsed >= tuning.auto_reset_stuck_seconds
	var lost := false
	if _surface_query != null:
		var distance := _surface_query.distance_to_centerline(state.transform.origin, tuning.auto_reset_lost_distance)
		lost = not (distance <= tuning.auto_reset_lost_distance)

	if stuck or lost:
		_off_track_stopped_elapsed = 0.0
		_auto_reset_notice = true
		_reset_requested = true
```

Call it at the end of `_integrate_forces`, immediately after the existing `_update_safe_pose_checkpoint(state, delta)` call:

```gdscript
	_update_safe_pose_checkpoint(state, delta)
	_update_auto_reset(state, delta)
```

Placing it last means the reset is honoured on the following tick through the existing `_reset_requested` path at the top of `_integrate_forces`, reusing `_apply_safe_reset` unchanged.

- [ ] **Step 5: Run the test to verify it passes**

Run: `godot --headless --path . --script res://tests/open_surface_auto_reset_test.gd`
Expected: PASS, exit code 0.

- [ ] **Step 6: Wire the setting through the session**

In `session/session_settings.gd`:

```gdscript
@export var auto_reset_enabled: bool = false
```

In `session/main.gd`, inside `restart_with_seed`, after the existing `_vehicle.set_safe_reset_pose(...)` call:

```gdscript
	_vehicle.set_safe_reset_pose(_track_definition.spawn_transform)
	_vehicle.set_auto_reset_enabled(bool(session_settings.get("auto_reset_enabled")))
```

In `_physics_process`, after the manual reset block:

```gdscript
	if Input.is_action_just_pressed("reset_car"):
		_vehicle.request_safe_reset()
		_checkpoint_detector.reset(_vehicle.global_position)
		_show_status("Car reset to the last safe pose")
	if _vehicle.consume_auto_reset_notice():
		_checkpoint_detector.reset(_vehicle.global_position)
		_show_status("Returned to the track")
```

Resetting the checkpoint detector matters: without it the detector's `_previous_position` still holds the off-track position, and the teleport back to the racing line would be read as a movement segment that can cross a gate the player never drove through.

- [ ] **Step 7: Add the setting to the full suite and run it**

Add the new script to the full-suite list in this plan's Global Constraints and in `README.md`'s verification section:

```sh
godot --headless --path . --script res://tests/open_surface_auto_reset_test.gd
```

Run the whole suite. Expected: all scripts exit 0.

- [ ] **Step 8: Commit**

```bash
git add vehicle/vehicle_tuning.gd vehicle/top_down_car.gd session/session_settings.gd session/main.gd tests/open_surface_auto_reset_test.gd tests/issue_4_test_surface_provider.gd README.md
git commit -m "feat: add opt-in automatic reset when stuck or lost off-track"
```

---

### Task 6: Documentation and evidence

**Files:**
- Modify: `README.md`
- Create: `docs/open-surface.md`
- Modify: `docs/evidence/procedural-tracks-seeds-0-5.png` (regenerated)

- [ ] **Step 1: Regenerate the track evidence at the new width**

Run: `godot --headless --path . --script res://tests/capture_procedural_tracks.gd`

Confirm `docs/evidence/procedural-tracks-seeds-0-5.png` is rewritten and shows visibly wider ribbons.

- [ ] **Step 2: Write the feature documentation**

Create `docs/open-surface.md` covering: that the circuit has no walls and the boundary line is decorative; the containment rectangle and its 2,000 px margin; the off-track penalty as the product of the surface map's 0.55/2.2 and the tuning's 0.46/2.6/0.62; that checkpoint gates stay `track_width * 0.5` wide, so straying past one costs the lap; and the auto-reset conditions with their default values and the `auto_reset_enabled` setting.

- [ ] **Step 3: Update the README**

In the Quick start section, note that the track has no walls, that leaving it is expected, and that automatic reset is off by default and enabled through `SessionSettings.auto_reset_enabled`.

- [ ] **Step 4: Run the full suite**

Expected: all scripts exit 0.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/open-surface.md docs/evidence/
git commit -m "docs: document the open surface and regenerate track evidence"
```

---

## Deferred (explicitly out of scope)

- **Sideline objects** (sub-project B). Scenery or obstacles along the boundary.
- **The height channel** (sub-project C). Jumping, air time and landings, layered onto 2D as GTA 1/2 did rather than by rebuilding in 3D.
- **Off-track visual treatment.** The grass shoulder is currently `track_width * 1.4` wide and everything past it is flat background. Once the surface is genuinely drivable it will want texture or debris to convey speed, but that is presentation work best judged after driving it.
- **Camera limits.** Deliberately not clamped to the play area; the containment boundary already prevents the car reaching anywhere the camera would show pure void.
- **Retuning the off-track constants.** `GRASS_GRIP`, `GRASS_DRAG`, and the three `off_track_*` tuning multipliers were authored for an unreachable surface. Expect to revisit them after the first drive; that is a tuning pass, not part of this plan.
