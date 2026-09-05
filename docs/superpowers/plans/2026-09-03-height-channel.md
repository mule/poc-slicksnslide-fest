# Height Channel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every circuit deterministic jump ramps, give the car a vertical channel so it crests, flies, and lands with a cost, and let an airborne car clear rocks but never trees.

**Architecture:** A `HeightQuery` contract beside `SurfaceQuery` is sampled by the car every physics tick; `TrackHeightMap` answers it from `JumpRampPlacement` records that a domain-seeded `JumpRampPlacer` attaches to `TrackDefinition` after road acceptance. The car carries `height` and `vertical_velocity`, compares its predicted ballistic height with the ground ahead to decide grounded versus airborne, and toggles a collision-mask bit by height. Presentation lifts the body away from a grounded shadow and draws ramp wedges on the dirt.

**Tech Stack:** Godot 4.7.1 stable (`a13da4feb`), GDScript, `Resource`, `RandomNumberGenerator`, SHA-256 text hashing, `RigidBody2D` custom integrator, `StaticBody2D` collision layers, `Polygon2D`/`Line2D`, GL Compatibility renderer, headless `SceneTree` test scripts.

**Spec:** `docs/superpowers/specs/2026-09-03-height-channel-design.md`

## Global Constraints

- The project stays a 2D `RigidBody2D` game. Height is a scalar channel; nothing is rebuilt in 3D.
- The world unit is the pixel at `WorldScale.PIXELS_PER_METRE = 12.5`. Every new scale-dependent literal goes through `WorldScale.metres()` or is a baked pixel value in a resource.
- Ramp placement uses a domain-separated seed (`version|track_seed|"height_channel"`) and may not consume `TrackGenerator`'s road RNG. `geometry_fingerprint` and `offtrack_object_fingerprint` must stay byte-for-byte identical for seeds `0..19`.
- Ramps are symmetric humps on straight runs only: `half_length` 150 px (12 m), `slope` 0.12, crest 18 px (1.44 m), approach clearance 500 px, landing clearance 1000 px, spawn exclusion 1000 px, checkpoint exclusion 500 px, minimum crest spacing 1500 px, two to four per lap. Underfill is diagnostic and never regenerates the road. Zero ramps is valid.
- Gravity is `WorldScale.metres(9.81)` = 122.625 px/s^2. In the air: no engine, brake, reverse, rolling drag, or lateral grip correction; aerodynamic drag and `max_safe_speed` still apply; steering is scaled by `airborne_steering_authority` (default 0.0).
- Landing multiplies speed by `clampf(1 - landing_speed_loss * impact_mps, 0.3, 1.0)` and opens a `landing_recovery_seconds` window with `landing_recovery_grip_multiplier` on lateral grip.
- Safe poses are captured only when grounded, on flat ground, and outside the recovery window. The automatic reset never evaluates while airborne. A reset zeroes height and vertical velocity.
- Rocks (`obstacle_height` 12.5 px) sit on low-level bodies on collision layer 2; trees (75 px) and the play-area bounds stay on layer 1. The car's mask is `1 | 2` at or below `low_obstacle_clearance` (12.5 px) and `1` above it. `VehicleTuning.low_obstacle_clearance` must equal `OfftrackObjectCatalog.low_obstacle_height`.
- Gates crossed in the air count; `CheckpointCrossingDetector` is not edited.
- Every verification helper is typed `-> bool`, ends in `return true`, and is called through `_check(...)` so a GDScript runtime error cannot exit green. See `tests/harness_contract_test.gd`.
- Every mutation command named below must exit non-zero. A mutation that remains green blocks the task.
- No new input actions, HUD panels, autoloads, dependencies, or touch controls.
- Preserve untracked `.codex/` and `AGENTS.md`; do not stage them. Do not stage `*.uid` files that belong to files you did not create; do stage the `.uid` Godot generates for each new script you add.
- Godot binary: `/home/japurane/.local/bin/godot`. Every test command below is `godot --headless --path . --script res://tests/<file>.gd`; mutation flags follow ` -- `.

## Parallel Execution Boundary

Task 1 lands first and freezes every shared type. Then:

| Lane | Owns | Must not edit |
| --- | --- | --- |
| Task 2 placement | `world/height/jump_ramp_placer.gd`, `track/track_height_map.gd`, placement tests | `vehicle/`, `track/track_generator.gd`, `track/track_runtime.gd`, `session/` |
| Task 3 vehicle | `vehicle/top_down_car.gd`, vehicle test and its fixture | `world/`, `track/`, `session/` |

Tasks 2 and 3 run in parallel in separate worktrees. Task 4 and Task 5 both edit the vehicle, so they run after Task 3 in that order. Task 6 is the only task that edits `track_generator.gd`, `track_runtime.gd`, and `session/main.gd` for wiring. Task 7 runs last.

## File Structure

### New production files

| File | Responsibility |
| --- | --- |
| `track/height_query.gd` | `HeightQuery` contract and `HeightSample` |
| `track/track_height_map.gd` | Seeded `HeightQuery` provider over ramp placements |
| `world/domain_seed.gd` | Shared domain and child seed derivation |
| `world/height/jump_ramp_placement.gd` | Serializable data for one ramp |
| `world/height/height_channel_catalog.gd` | Versioned ramp geometry and placement rules |
| `world/height/jump_ramp_placement_result.gd` | Typed placement output plus timing and diagnostics |
| `world/height/jump_ramp_placer.gd` | Bounded deterministic ramp placement |
| `world/height/jump_ramp_visuals.gd` | One wedge per ramp |
| `data/default_height_channel_catalog.tres` | Default catalog data |

### Modified production files

| File | Change |
| --- | --- |
| `world/offtrack/offtrack_seed.gd` | Thin wrapper over `DomainSeed` |
| `world/offtrack/offtrack_object_archetype.gd` | `obstacle_height` |
| `world/offtrack/offtrack_object_catalog.gd` | `low_obstacle_height` |
| `world/offtrack/offtrack_object_collisions.gd` | Low and tall bodies per chunk |
| `data/default_offtrack_object_catalog.tres` | Obstacle heights, threshold |
| `track/track_definition.gd` | Ramp fields |
| `track/track_generator.gd` | `_attach_jump_ramps()` |
| `track/track_runtime.gd` | `_build_jump_ramps()` |
| `vehicle/vehicle_tuning.gd` | `Height channel` group |
| `data/default_vehicle_tuning.tres` | Baked height values |
| `vehicle/top_down_car.gd` | Height channel, collision level, presentation |
| `vehicle/top_down_car.tscn` | `Lift` node, mask |
| `session/diagnostics_overlay.gd` | `set_height_metrics()` |
| `session/main.gd` | Height query wiring, air-time status, snapshot field |

### Test files

| File | Task |
| --- | --- |
| `tests/height_channel_contract_test.gd` | 1 |
| `tests/jump_ramp_placement_test.gd` | 2 |
| `tests/height_channel_test_height_provider.gd` | 3 (fixture, also used by 4, 5, 6) |
| `tests/vehicle_height_channel_test.gd` | 3 |
| `tests/airborne_obstacle_level_test.gd` | 4 |
| `tests/jump_ramp_visuals_test.gd` | 5 |
| `tests/issue_5_main_session_test.gd`, `tests/headless_smoke.gd` | 6 (extended) |
| `tests/capture_height_channel_evidence.gd` | 7 |

---

### Task 1: Shared contract and data

**Files:**
- Create: `track/height_query.gd`, `world/domain_seed.gd`, `world/height/jump_ramp_placement.gd`, `world/height/height_channel_catalog.gd`, `world/height/jump_ramp_placement_result.gd`, `data/default_height_channel_catalog.tres`
- Modify: `world/offtrack/offtrack_seed.gd`, `world/offtrack/offtrack_object_archetype.gd`, `world/offtrack/offtrack_object_catalog.gd`, `data/default_offtrack_object_catalog.tres`, `track/track_definition.gd`, `vehicle/vehicle_tuning.gd`, `data/default_vehicle_tuning.tres`
- Test: `tests/height_channel_contract_test.gd`

**Interfaces:**
- Consumes: `WorldScale.metres()`, `OfftrackSeed.domain_seed()/cell_seed()` known vectors in `tests/offtrack_object_contract_test.gd`.
- Produces: `HeightQuery.sample_at(Vector2) -> HeightSample{ground_height: float, gradient: Vector2}`; `DomainSeed.derive(version: int, track_seed: int, domain: String) -> int`, `DomainSeed.child(parent_seed: int, first: int, second: int) -> int`; `JumpRampPlacement{stable_id, transform, half_length, crest_height, width}.is_valid() -> bool`; `HeightChannelCatalog{version, ramps_per_lap_min, ramps_per_lap_max, half_length, slope, approach_clearance, landing_clearance, spawn_exclusion, checkpoint_exclusion, minimum_spacing}.crest_height() -> float`; `JumpRampPlacementResult{placements, fingerprint, generation_usec, diagnostics}`; `TrackDefinition.jump_ramps/height_fingerprint/height_generation_usec/height_diagnostics`; `VehicleTuning` fields `gravity, airborne_steering_authority, landing_speed_loss, landing_recovery_seconds, landing_recovery_grip_multiplier, low_obstacle_clearance, air_time_notice_seconds, lift_pixels_per_pixel, scale_per_metre`; `OfftrackObjectArchetype.obstacle_height`; `OfftrackObjectCatalog.low_obstacle_height`.

- [ ] **Step 1: Write the failing contract test**

```gdscript
# tests/height_channel_contract_test.gd
extends SceneTree

## Pins the height channel's shared types before any consumer exists: the flat base query, the
## shared seed routine (and the off-track vectors it must keep producing), ramp record validity,
## catalog derivations, definition and tuning fields, and the clearance/obstacle agreement.

const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const HEIGHT_CATALOG_PATH := "res://data/default_height_channel_catalog.tres"
const OBJECT_CATALOG_PATH := "res://data/default_offtrack_object_catalog.tres"

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(_verify_base_query_is_flat(), "the base query verification ran to completion")
	_check(_verify_domain_seed_vectors(), "the domain seed verification ran to completion")
	_check(_verify_placement_validity(), "the placement validity verification ran to completion")
	_check(_verify_catalog_defaults(), "the catalog defaults verification ran to completion")
	_check(_verify_definition_fields(), "the definition fields verification ran to completion")
	_check(_verify_tuning_fields(), "the tuning fields verification ran to completion")
	_check(_verify_clearance_agrees_with_obstacle_height(), "the clearance agreement verification ran to completion")
	_finish()


func _verify_base_query_is_flat() -> bool:
	var query := HeightQuery.new()
	var sample := query.sample_at(Vector2(123.0, -456.0))
	_check(sample.ground_height == 0.0, "the base height query reports flat ground")
	_check(sample.gradient == Vector2.ZERO, "the base height query reports a zero gradient")
	return true


func _verify_domain_seed_vectors() -> bool:
	# The off-track vectors are the ones already pinned in offtrack_object_contract_test.gd. They
	# must survive the extraction into DomainSeed unchanged.
	_check(DomainSeed.derive(1, 0, "offtrack_objects") == 845162064041503952, "DomainSeed reproduces the off-track seed 0 vector")
	_check(DomainSeed.derive(1, 42, "offtrack_objects") == 365479572614719053, "DomainSeed reproduces the off-track seed 42 vector")
	_check(DomainSeed.child(845162064041503952, 3, -2) == 173704369122287513, "DomainSeed reproduces the off-track cell vector")
	_check(OfftrackSeed.domain_seed(0, 1) == 845162064041503952, "OfftrackSeed still produces its seed 0 vector")
	_check(DomainSeed.derive(1, 0, "height_channel") != DomainSeed.derive(1, 0, "offtrack_objects"), "the height domain is separated from the off-track domain")
	_check(DomainSeed.derive(1, 0, "height_channel") > 0, "domain seeds are positive 64-bit integers")
	return true


func _verify_placement_validity() -> bool:
	var ramp := JumpRampPlacement.new()
	ramp.stable_id = "h1:0:12"
	ramp.transform = Transform2D(0.3, Vector2(100.0, 200.0))
	ramp.half_length = 150.0
	ramp.crest_height = 18.0
	ramp.width = 240.0
	_check(ramp.is_valid(), "a finite, positive ramp record is valid")
	var bad_height := ramp.duplicate() as JumpRampPlacement
	bad_height.crest_height = 0.0
	_check(not bad_height.is_valid(), "a zero crest height is invalid")
	var bad_length := ramp.duplicate() as JumpRampPlacement
	bad_length.half_length = -1.0
	_check(not bad_length.is_valid(), "a negative half length is invalid")
	var bad_origin := ramp.duplicate() as JumpRampPlacement
	bad_origin.transform = Transform2D(0.0, Vector2(INF, 0.0))
	_check(not bad_origin.is_valid(), "a non-finite origin is invalid")
	var bad_width := ramp.duplicate() as JumpRampPlacement
	bad_width.width = 0.0
	_check(not bad_width.is_valid(), "a zero width is invalid")
	return true


func _verify_catalog_defaults() -> bool:
	var catalog := load(HEIGHT_CATALOG_PATH) as HeightChannelCatalog
	_check(catalog != null, "the default height catalog loads")
	if catalog == null:
		return false
	_check(catalog.version == 1, "catalog version is 1")
	_check(is_equal_approx(catalog.half_length, WorldScale.metres(12.0)), "half length is 12 m")
	_check(is_equal_approx(catalog.slope, 0.12), "slope is 0.12")
	_check(is_equal_approx(catalog.crest_height(), WorldScale.metres(1.44)), "crest height derives as slope times half length")
	_check(catalog.ramps_per_lap_min == 2 and catalog.ramps_per_lap_max == 4, "two to four ramps are requested per lap")
	_check(catalog.ramps_per_lap_min <= catalog.ramps_per_lap_max, "ramp count range is ordered")
	_check(is_equal_approx(catalog.approach_clearance, WorldScale.metres(40.0)), "approach clearance is 40 m")
	_check(is_equal_approx(catalog.landing_clearance, WorldScale.metres(80.0)), "landing clearance is 80 m")
	_check(is_equal_approx(catalog.spawn_exclusion, WorldScale.metres(80.0)), "spawn exclusion is 80 m")
	_check(is_equal_approx(catalog.checkpoint_exclusion, WorldScale.metres(40.0)), "checkpoint exclusion is 40 m")
	_check(is_equal_approx(catalog.minimum_spacing, WorldScale.metres(120.0)), "minimum crest spacing is 120 m")
	_check(catalog.minimum_run_length() > catalog.approach_clearance + catalog.landing_clearance, "minimum run length includes both faces")
	return true


func _verify_definition_fields() -> bool:
	var definition := TrackDefinition.new()
	_check(definition.jump_ramps.is_empty(), "a fresh definition has no ramps")
	_check(definition.height_fingerprint == "", "a fresh definition has no height fingerprint")
	_check(definition.height_generation_usec == 0, "a fresh definition has no height timing")
	_check(definition.height_diagnostics.is_empty(), "a fresh definition has no height diagnostics")
	return true


func _verify_tuning_fields() -> bool:
	var tuning := load(TUNING_PATH) as VehicleTuning
	_check(tuning != null, "the default tuning loads")
	if tuning == null:
		return false
	_check(is_equal_approx(tuning.gravity, WorldScale.metres(9.81)), "gravity is 9.81 m/s^2 in pixels")
	_check(tuning.airborne_steering_authority == 0.0, "airborne steering authority defaults to none")
	_check(is_equal_approx(tuning.landing_speed_loss, 0.03), "landing speed loss is 3% per m/s")
	_check(is_equal_approx(tuning.landing_recovery_seconds, 0.35), "landing recovery lasts 0.35 s")
	_check(is_equal_approx(tuning.landing_recovery_grip_multiplier, 0.5), "landing recovery halves grip")
	_check(is_equal_approx(tuning.air_time_notice_seconds, 0.5), "air time notice needs half a second")
	_check(is_equal_approx(tuning.lift_pixels_per_pixel, 1.0), "body lift is one pixel per pixel of height")
	_check(is_equal_approx(tuning.scale_per_metre, 0.04), "body scale gains 4% per metre")
	return true


func _verify_clearance_agrees_with_obstacle_height() -> bool:
	var tuning := load(TUNING_PATH) as VehicleTuning
	var catalog := load(OBJECT_CATALOG_PATH) as OfftrackObjectCatalog
	_check(is_equal_approx(tuning.low_obstacle_clearance, catalog.low_obstacle_height), "vehicle clearance equals the catalog's low obstacle height")
	_check(is_equal_approx(catalog.low_obstacle_height, WorldScale.metres(1.0)), "low obstacles are at most 1 m")
	var rock := catalog.archetype_by_id(&"rock")
	var tree := catalog.archetype_by_id(&"tree")
	var grass := catalog.archetype_by_id(&"grass")
	_check(rock != null and rock.obstacle_height <= catalog.low_obstacle_height, "rocks are low obstacles")
	_check(tree != null and tree.obstacle_height > catalog.low_obstacle_height, "trees are tall obstacles")
	_check(grass != null and grass.obstacle_height == 0.0, "decorative archetypes have no obstacle height")
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
		print("Height channel contract checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Height channel contract check failed: %s" % failure)
	quit(1)
```

- [ ] **Step 2: Run it and watch it fail**

Run: `godot --headless --path . --script res://tests/height_channel_contract_test.gd`
Expected: parse errors naming `HeightQuery`, `DomainSeed`, `JumpRampPlacement`, `HeightChannelCatalog` as unknown identifiers. Exit code non-zero.

- [ ] **Step 3: Add the height query contract**

```gdscript
# track/height_query.gd
class_name HeightQuery
extends RefCounted

## Position-based ground height contract consumed by vehicle dynamics.
##
## Height is measured in world pixels above the flat plane, like every other length. The gradient is
## world-space dh/dx and dh/dy, so `velocity.dot(gradient)` is the ground's vertical rate under a
## moving body. The base implementation is flat ground: a provider with no notion of height keeps
## the car on the ground rather than erroring.


class HeightSample:
	extends RefCounted

	var ground_height: float
	var gradient: Vector2


	func _init(initial_ground_height: float = 0.0, initial_gradient: Vector2 = Vector2.ZERO) -> void:
		ground_height = initial_ground_height
		gradient = initial_gradient


func sample_at(_world_position: Vector2) -> HeightSample:
	return HeightSample.new()
```

- [ ] **Step 4: Extract the shared seed routine**

```gdscript
# world/domain_seed.gd
class_name DomainSeed
extends RefCounted

## Fixed integer-mixing routine shared by every deterministic placement domain. The text layout
## is a persistence contract: changing it changes every fingerprint on every platform.


static func derive(version: int, track_seed: int, domain: String) -> int:
	return from_text("%d|%d|%s" % [version, track_seed, domain])


static func child(parent_seed: int, first: int, second: int) -> int:
	return from_text("%d|%d|%d" % [parent_seed, first, second])


static func from_text(material: String) -> int:
	# Fifteen hexadecimal digits fit in a positive signed 64-bit integer.
	return material.sha256_text().substr(0, 15).hex_to_int()
```

Replace the body of `world/offtrack/offtrack_seed.gd` so it delegates and keeps its API:

```gdscript
class_name OfftrackSeed
extends RefCounted

const DOMAIN := "offtrack_objects"


static func domain_seed(track_seed: int, version: int) -> int:
	return DomainSeed.derive(version, track_seed, DOMAIN)


static func cell_seed(initial_domain_seed: int, cell: Vector2i) -> int:
	return DomainSeed.child(initial_domain_seed, cell.x, cell.y)
```

- [ ] **Step 5: Add the ramp record, catalog, and result**

```gdscript
# world/height/jump_ramp_placement.gd
class_name JumpRampPlacement
extends Resource

## One generated jump ramp: a symmetric hump whose crest is the transform origin and whose faces
## run along the transform's x axis. Data only; never holds nodes or callbacks.

@export var stable_id: String = ""
@export var transform: Transform2D = Transform2D.IDENTITY
@export_range(1.0, 2000.0, 0.5) var half_length: float = 150.0
@export_range(0.0, 500.0, 0.1) var crest_height: float = 18.0
@export_range(1.0, 500.0, 0.5) var width: float = 240.0


func is_valid() -> bool:
	var origin := transform.origin
	if not is_finite(origin.x) or not is_finite(origin.y):
		return false
	if not is_finite(transform.get_rotation()):
		return false
	return half_length > 0.0 and crest_height > 0.0 and width > 0.0
```

```gdscript
# world/height/height_channel_catalog.gd
class_name HeightChannelCatalog
extends Resource

## Versioned ramp geometry and placement rules. Every length is a baked pixel value.

@export var version: int = 1
@export_range(0, 16, 1) var ramps_per_lap_min: int = 2
@export_range(0, 16, 1) var ramps_per_lap_max: int = 4
@export_range(1.0, 2000.0, 0.5) var half_length: float = 150.0
@export_range(0.0, 1.0, 0.001) var slope: float = 0.12
@export_range(0.0, 10000.0, 1.0) var approach_clearance: float = 500.0
@export_range(0.0, 10000.0, 1.0) var landing_clearance: float = 1000.0
@export_range(0.0, 10000.0, 1.0) var spawn_exclusion: float = 1000.0
@export_range(0.0, 10000.0, 1.0) var checkpoint_exclusion: float = 500.0
@export_range(0.0, 20000.0, 1.0) var minimum_spacing: float = 1500.0


func crest_height() -> float:
	return slope * half_length


## Straight run needed to hold one ramp: approach, both faces, and the landing zone.
func minimum_run_length() -> float:
	return approach_clearance + 2.0 * half_length + landing_clearance
```

```gdscript
# world/height/jump_ramp_placement_result.gd
class_name JumpRampPlacementResult
extends RefCounted

var placements: Array[JumpRampPlacement] = []
var fingerprint := ""
var generation_usec := 0
var diagnostics: Dictionary = {}
```

```text
# data/default_height_channel_catalog.tres
[gd_resource type="Resource" script_class="HeightChannelCatalog" load_steps=2 format=3]

[ext_resource type="Script" path="res://world/height/height_channel_catalog.gd" id="1_catalog"]

[resource]
script = ExtResource("1_catalog")
version = 1
ramps_per_lap_min = 2
ramps_per_lap_max = 4
half_length = 150.0
slope = 0.12
approach_clearance = 500.0
landing_clearance = 1000.0
spawn_exclusion = 1000.0
checkpoint_exclusion = 500.0
minimum_spacing = 1500.0
```

- [ ] **Step 6: Extend the definition, tuning, and object catalog**

Append to `track/track_definition.gd` after `offtrack_object_diagnostics`:

```gdscript
@export var jump_ramps: Array[JumpRampPlacement] = []
@export var height_fingerprint: String = ""
@export var height_generation_usec: int = 0
@export var height_diagnostics: Dictionary = {}
```

Append a group to `vehicle/vehicle_tuning.gd` after the `Surfaces` group:

```gdscript
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
```

Append the same nine values to `data/default_vehicle_tuning.tres` after `off_track_engine_multiplier`:

```text
gravity = 122.625
airborne_steering_authority = 0.0
landing_speed_loss = 0.03
landing_recovery_seconds = 0.35
landing_recovery_grip_multiplier = 0.5
low_obstacle_clearance = 12.5
air_time_notice_seconds = 0.5
lift_pixels_per_pixel = 1.0
scale_per_metre = 0.04
```

Add to `world/offtrack/offtrack_object_archetype.gd` after `collision_radius`:

```gdscript
## Height of the obstacle in pixels. Zero for decorative archetypes. At or below the catalog's
## low_obstacle_height the object is on the low collision level an airborne car can clear.
@export_range(0.0, 500.0, 0.1) var obstacle_height: float = 0.0
```

Add to `world/offtrack/offtrack_object_catalog.gd` after `spawn_checkpoint_exclusion`:

```gdscript
## Solid archetypes at or below this height go on collision layer 2, which the car drops from its
## mask while above VehicleTuning.low_obstacle_clearance.
@export var low_obstacle_height: float = 12.5
```

In `data/default_offtrack_object_catalog.tres` add `obstacle_height = 75.0` to `Archetype_tree`, `obstacle_height = 12.5` to `Archetype_rock`, and `low_obstacle_height = 12.5` to the `[resource]` block after `spawn_checkpoint_exclusion`.

- [ ] **Step 7: Run the contract test and the existing suites it touches**

Run:
```
godot --headless --path . --script res://tests/height_channel_contract_test.gd
godot --headless --path . --script res://tests/offtrack_object_contract_test.gd
godot --headless --path . --script res://tests/offtrack_object_placement_test.gd
godot --headless --path . --script res://tests/world_scale_contract_test.gd
godot --headless --path . --script res://tests/headless_smoke.gd
```
Expected: all exit 0. The off-track placement suite proves the `DomainSeed` extraction changed no object fingerprint.

- [ ] **Step 8: Commit**

```bash
git add track/height_query.gd track/height_query.gd.uid world/domain_seed.gd world/domain_seed.gd.uid world/height/ data/default_height_channel_catalog.tres world/offtrack/offtrack_seed.gd world/offtrack/offtrack_object_archetype.gd world/offtrack/offtrack_object_catalog.gd data/default_offtrack_object_catalog.tres track/track_definition.gd vehicle/vehicle_tuning.gd data/default_vehicle_tuning.tres tests/height_channel_contract_test.gd tests/height_channel_contract_test.gd.uid
git commit -m "feat: add the height channel contract, catalog, and tuning fields"
```

---

### Task 2: Deterministic ramp placement and height map

**Files:**
- Create: `world/height/jump_ramp_placer.gd`, `track/track_height_map.gd`
- Test: `tests/jump_ramp_placement_test.gd`

**Interfaces:**
- Consumes: Task 1 types; `TrackGenerator.generate(seed)`, `TrackGenerator.STRAIGHT_CURVATURE`, `TrackGenerator.SAMPLE_SPACING`; `ROAD_FINGERPRINTS` from `tests/offtrack_object_placement_test.gd` (the pre-B baseline table).
- Produces: `JumpRampPlacer.new().place(definition: TrackDefinition, catalog: HeightChannelCatalog) -> JumpRampPlacementResult`; `TrackHeightMap.new(definition) -> HeightQuery`; stable IDs `h<version>:<seed>:<run-start-index>`; diagnostics keys `eligible_runs, requested, placed, rejected_spawn, rejected_checkpoint, rejected_spacing, underfilled`.

- [ ] **Step 1: Write the failing placement test**

```gdscript
# tests/jump_ramp_placement_test.gd
extends SceneTree

## Ramps are deterministic per seed, live on straight runs with their clearances, respect the spawn,
## gate, and spacing exclusions, and never touch the road or object fingerprints. Mutations:
##   -- --break-height-seed   bumps the catalog version on the second run, so repeat checks fail
##   -- --break-clearance     zeroes the checkpoint exclusion, so the gate oracle fails

const CATALOG_PATH := "res://data/default_height_channel_catalog.tres"
const BASELINE_PATH := "res://tests/offtrack_object_placement_test.gd"
const SEED_COUNT := 20
const PLACEMENT_P95_BUDGET_USEC := 5000
const QUERY_COUNT := 10000
const QUERY_BUDGET_USEC := 20000

var _failures: Array[String] = []
var _checks := 0
var _break_seed := false
var _break_clearance := false


func _initialize() -> void:
	_break_seed = OS.get_cmdline_user_args().has("--break-height-seed")
	_break_clearance = OS.get_cmdline_user_args().has("--break-clearance")
	call_deferred("_run")


func _run() -> void:
	_check(_verify_sweep(), "the seed sweep verification ran to completion")
	_check(_verify_height_map_profile(), "the height map profile verification ran to completion")
	_check(_verify_height_map_skips_invalid_records(), "the invalid record verification ran to completion")
	_check(_verify_fallback(), "the fallback verification ran to completion")
	_finish()


func _verify_sweep() -> bool:
	var generator := TrackGenerator.new()
	var placer := JumpRampPlacer.new()
	var catalog := load(CATALOG_PATH) as HeightChannelCatalog
	var baseline: Dictionary = (load(BASELINE_PATH) as GDScript).ROAD_FINGERPRINTS
	var times: Array[int] = []
	for seed in range(SEED_COUNT):
		_check(_verify_seed(seed, generator, placer, catalog, baseline, times), "seed %d verification completed" % seed)
	times.sort()
	var p95: int = times[int(floor(0.95 * float(times.size() - 1)))]
	print("placement_usec_p95=%d" % p95)
	_check(p95 <= PLACEMENT_P95_BUDGET_USEC, "ramp placement p95 (%d us) is within the 5 ms budget" % p95)
	return true


func _verify_seed(seed: int, generator: TrackGenerator, placer: JumpRampPlacer, catalog: HeightChannelCatalog, baseline: Dictionary, times: Array[int]) -> bool:
	var definition: TrackDefinition = generator.generate(seed)
	var road_fingerprint := definition.geometry_fingerprint
	var object_fingerprint := definition.offtrack_object_fingerprint
	var first := placer.place(definition, catalog)
	times.append(first.generation_usec)
	var second_catalog := catalog.duplicate(true) as HeightChannelCatalog
	if _break_seed:
		second_catalog.version += 1
	if _break_clearance:
		second_catalog.checkpoint_exclusion = 0.0
	var second := placer.place(definition, second_catalog)
	var checked := second.placements if _break_clearance else first.placements
	print("seed=%d ramps=%d requested=%d eligible_runs=%d usec=%d" % [seed, first.placements.size(), int(first.diagnostics.get("requested", -1)), int(first.diagnostics.get("eligible_runs", -1)), first.generation_usec])

	_check(first.fingerprint.length() == 64, "seed %d produces a SHA-256 height fingerprint" % seed)
	_check(first.fingerprint == second.fingerprint, "seed %d height fingerprint repeats" % seed)
	_check(_placements_equal(first.placements, second.placements), "seed %d placements repeat exactly" % seed)
	_check(definition.geometry_fingerprint == road_fingerprint, "seed %d road fingerprint is unchanged by placement" % seed)
	_check(definition.geometry_fingerprint == baseline[seed], "seed %d road fingerprint matches the pre-B baseline" % seed)
	_check(definition.offtrack_object_fingerprint == object_fingerprint, "seed %d object fingerprint is unchanged by placement" % seed)
	_check(_verify_rules(definition, checked, catalog, seed), "seed %d rule verification completed" % seed)
	_check(_verify_diagnostics(first, catalog, seed), "seed %d diagnostics verification completed" % seed)
	return true


func _verify_rules(definition: TrackDefinition, placements: Array[JumpRampPlacement], catalog: HeightChannelCatalog, seed: int) -> bool:
	var unique_count := definition.centerline.size() - 1
	var generator_script := load("res://track/track_generator.gd") as GDScript
	var straight_curvature: float = generator_script.STRAIGHT_CURVATURE
	var crest_positions: Array[Vector2] = []
	for ramp in placements:
		_check(ramp.is_valid(), "seed %d ramp %s is valid" % [seed, ramp.stable_id])
		_check(ramp.stable_id.begins_with("h%d:%d:" % [catalog.version, seed]), "seed %d ramp id carries version and seed" % seed)
		_check(is_equal_approx(ramp.half_length, catalog.half_length), "seed %d ramp uses the catalog half length" % seed)
		_check(is_equal_approx(ramp.crest_height, catalog.crest_height()), "seed %d ramp uses the catalog crest height" % seed)
		_check(is_equal_approx(ramp.width, definition.track_width), "seed %d ramp spans the road width" % seed)
		# The crest sits on a centerline sample, and every sample under the approach, both faces,
		# and the landing zone is gentle.
		var crest_index := _nearest_sample(definition.centerline, ramp.transform.origin)
		_check(definition.centerline[crest_index].distance_to(ramp.transform.origin) < 0.01, "seed %d crest sits on a centerline sample" % seed)
		var spacing := definition.lap_length / float(unique_count)
		var before := int(ceil((catalog.approach_clearance + catalog.half_length) / spacing))
		var after := int(ceil((catalog.landing_clearance + catalog.half_length) / spacing))
		var all_gentle := true
		for offset in range(-before, after + 1):
			var index := (crest_index + offset + unique_count) % unique_count
			if _curvature_at(definition.centerline, index) > straight_curvature:
				all_gentle = false
		_check(all_gentle, "seed %d ramp %s has a gentle approach and landing zone" % [seed, ramp.stable_id])
		var axis := ramp.transform.x.normalized()
		var tangent := (definition.centerline[(crest_index + 1) % unique_count] - definition.centerline[crest_index]).normalized()
		_check(absf(axis.dot(tangent)) > 0.999, "seed %d ramp axis follows the centerline" % seed)
		var spawn_distance := ramp.transform.origin.distance_to(definition.spawn_transform.origin)
		_check(spawn_distance >= catalog.spawn_exclusion + catalog.half_length, "seed %d ramp keeps clear of the spawn" % seed)
		for checkpoint in definition.checkpoints:
			var gate_distance := ramp.transform.origin.distance_to(checkpoint.origin)
			_check(gate_distance >= catalog.checkpoint_exclusion + catalog.half_length, "seed %d ramp keeps clear of a gate (%.1f px)" % [seed, gate_distance])
		for other in crest_positions:
			_check(other.distance_to(ramp.transform.origin) >= catalog.minimum_spacing, "seed %d crests respect minimum spacing" % seed)
		crest_positions.append(ramp.transform.origin)
	return true


func _verify_diagnostics(result: JumpRampPlacementResult, catalog: HeightChannelCatalog, seed: int) -> bool:
	var diagnostics := result.diagnostics
	for key in ["eligible_runs", "requested", "placed", "rejected_spawn", "rejected_checkpoint", "rejected_spacing", "underfilled"]:
		_check(diagnostics.has(key), "seed %d diagnostics report %s" % [seed, key])
	var requested := int(diagnostics.get("requested", -1))
	var placed := int(diagnostics.get("placed", -1))
	_check(requested >= catalog.ramps_per_lap_min and requested <= catalog.ramps_per_lap_max, "seed %d requested count is inside the catalog range" % seed)
	_check(placed == result.placements.size(), "seed %d placed count matches the placement array" % seed)
	_check(bool(diagnostics.get("underfilled")) == (placed < requested), "seed %d underfill flag is honest" % seed)
	return true


func _verify_height_map_profile() -> bool:
	var definition := TrackDefinition.new()
	definition.track_width = 240.0
	var ramp := JumpRampPlacement.new()
	ramp.stable_id = "h1:0:0"
	ramp.transform = Transform2D(0.0, Vector2(1000.0, 500.0))
	ramp.half_length = 150.0
	ramp.crest_height = 18.0
	ramp.width = 240.0
	definition.jump_ramps.append(ramp)
	var map := TrackHeightMap.new(definition)
	var slope := 18.0 / 150.0
	_check(map.sample_at(Vector2(800.0, 500.0)).ground_height == 0.0, "flat before the ramp")
	_check(is_equal_approx(map.sample_at(Vector2(925.0, 500.0)).ground_height, 9.0), "halfway up the rising face is half the crest")
	_check(map.sample_at(Vector2(925.0, 500.0)).gradient.is_equal_approx(Vector2(slope, 0.0)), "the rising face slopes up along the axis")
	_check(is_equal_approx(map.sample_at(Vector2(1000.0, 500.0)).ground_height, 18.0), "the crest is the crest height")
	_check(is_equal_approx(map.sample_at(Vector2(1075.0, 500.0)).ground_height, 9.0), "halfway down the falling face is half the crest")
	_check(map.sample_at(Vector2(1075.0, 500.0)).gradient.is_equal_approx(Vector2(-slope, 0.0)), "the falling face slopes down along the axis")
	_check(map.sample_at(Vector2(1200.0, 500.0)).ground_height == 0.0, "flat after the ramp")
	_check(map.sample_at(Vector2(1000.0, 500.0 + 121.0)).ground_height == 0.0, "flat beside the road")
	_check(is_equal_approx(map.sample_at(Vector2(1000.0, 500.0 - 119.0)).ground_height, 18.0), "the ramp spans the road width")
	var rotated := ramp.duplicate() as JumpRampPlacement
	rotated.transform = Transform2D(PI * 0.5, Vector2(0.0, 0.0))
	var rotated_definition := TrackDefinition.new()
	rotated_definition.jump_ramps.append(rotated)
	var rotated_map := TrackHeightMap.new(rotated_definition)
	_check(is_equal_approx(rotated_map.sample_at(Vector2(0.0, -75.0)).ground_height, 9.0), "a rotated ramp is sampled in its own frame")
	_check(rotated_map.sample_at(Vector2(0.0, -75.0)).gradient.is_equal_approx(Vector2(0.0, slope)), "a rotated ramp's gradient follows its axis")

	var four := TrackDefinition.new()
	for index in range(4):
		var extra := ramp.duplicate() as JumpRampPlacement
		extra.transform = Transform2D(0.0, Vector2(2000.0 * float(index), 0.0))
		four.jump_ramps.append(extra)
	var four_map := TrackHeightMap.new(four)
	var started := Time.get_ticks_usec()
	var accumulated := 0.0
	for query in range(QUERY_COUNT):
		accumulated += four_map.sample_at(Vector2(float(query % 8000), 0.0)).ground_height
	var elapsed := Time.get_ticks_usec() - started
	print("height_query_usec_per_10k=%d accumulated=%.1f" % [elapsed, accumulated])
	_check(elapsed <= QUERY_BUDGET_USEC, "ten thousand height queries (%d us) stay under 20 ms" % elapsed)
	return true


func _verify_height_map_skips_invalid_records() -> bool:
	var definition := TrackDefinition.new()
	var bad := JumpRampPlacement.new()
	bad.transform = Transform2D(0.0, Vector2(0.0, 0.0))
	bad.crest_height = 0.0
	definition.jump_ramps.append(bad)
	definition.jump_ramps.append(null)
	var map := TrackHeightMap.new(definition)
	_check(map.sample_at(Vector2.ZERO).ground_height == 0.0, "an invalid ramp record contributes no height")
	_check(map.ramp_count() == 0, "invalid and null records are not retained")
	return true


func _verify_fallback() -> bool:
	var generator := TrackGenerator.new()
	var definition: TrackDefinition = generator.generate(17, {"max_attempts": 1})
	_check(definition.used_fallback, "seed 17 with one attempt uses the fallback stadium")
	var catalog := load(CATALOG_PATH) as HeightChannelCatalog
	var result := JumpRampPlacer.new().place(definition, catalog)
	_check(result.placements.size() > 0, "the fallback stadium receives ramps on its straights")
	_check(_verify_rules(definition, result.placements, catalog, 17), "fallback rule verification completed")
	return true


func _nearest_sample(centerline: PackedVector2Array, position: Vector2) -> int:
	var best := 0
	var best_distance := INF
	for index in range(centerline.size() - 1):
		var distance := centerline[index].distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best = index
	return best


func _curvature_at(points: PackedVector2Array, index: int) -> float:
	var unique_count := points.size() - 1
	var incoming := points[index] - points[(index - 1 + unique_count) % unique_count]
	var outgoing := points[(index + 1) % unique_count] - points[index]
	var distance := (incoming.length() + outgoing.length()) * 0.5
	if distance <= 0.0:
		return 0.0
	return absf(incoming.angle_to(outgoing)) / distance


func _placements_equal(first: Array[JumpRampPlacement], second: Array[JumpRampPlacement]) -> bool:
	if first.size() != second.size():
		return false
	for index in range(first.size()):
		var a := first[index]
		var b := second[index]
		if a.stable_id != b.stable_id or not a.transform.is_equal_approx(b.transform):
			return false
		if not is_equal_approx(a.half_length, b.half_length) or not is_equal_approx(a.crest_height, b.crest_height) or not is_equal_approx(a.width, b.width):
			return false
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
		print("Jump ramp placement checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Jump ramp placement check failed: %s" % failure)
	quit(1)
```

- [ ] **Step 2: Run it and watch it fail**

Run: `godot --headless --path . --script res://tests/jump_ramp_placement_test.gd`
Expected: parse errors for `JumpRampPlacer` and `TrackHeightMap`. Exit non-zero.

- [ ] **Step 3: Write the placer**

```gdscript
# world/height/jump_ramp_placer.gd
class_name JumpRampPlacer
extends RefCounted

## Places symmetric jump ramps on straight runs of an accepted centerline. Runs after road
## acceptance, draws from a domain-separated seed, and never touches the road RNG.

const DOMAIN := "height_channel"


func place(definition: TrackDefinition, catalog: HeightChannelCatalog) -> JumpRampPlacementResult:
	var started_usec := Time.get_ticks_usec()
	var result := JumpRampPlacementResult.new()
	if definition == null or catalog == null or definition.centerline.size() < 3:
		result.fingerprint = _fingerprint(catalog.version if catalog != null else 0, result.placements)
		result.generation_usec = Time.get_ticks_usec() - started_usec
		result.diagnostics = {"invalid_input": 1}
		return result

	var diagnostics := {
		"eligible_runs": 0,
		"requested": 0,
		"placed": 0,
		"rejected_spawn": 0,
		"rejected_checkpoint": 0,
		"rejected_spacing": 0,
		"underfilled": false,
	}
	var centerline := definition.centerline
	var unique_count := centerline.size() - 1
	# Generated definitions carry lap_length; a hand-built fixture may not, so measure when needed.
	var lap_length := definition.lap_length if definition.lap_length > 0.0 else _polyline_length(centerline)
	var spacing := lap_length / float(unique_count)
	var runs := _straight_runs(centerline, catalog, spacing)
	diagnostics["eligible_runs"] = runs.size()

	var domain_seed := DomainSeed.derive(catalog.version, definition.seed, DOMAIN)
	var rng := RandomNumberGenerator.new()
	rng.seed = domain_seed
	var requested := rng.randi_range(catalog.ramps_per_lap_min, catalog.ramps_per_lap_max)
	diagnostics["requested"] = requested

	# Samples a face-plus-clearance occupies, rounded up so the whole zone is inside the run.
	var before := int(ceil((catalog.approach_clearance + catalog.half_length) / spacing))
	var after := int(ceil((catalog.landing_clearance + catalog.half_length) / spacing))
	var crests: Array[Vector2] = []
	for run in runs:
		if result.placements.size() >= requested:
			break
		var run_start: int = run.start
		var run_count: int = run.count
		var window_size := run_count - before - after
		if window_size <= 0:
			continue
		# Every run draws from its own child seed, so a rejection here cannot shift another run.
		rng.seed = DomainSeed.child(domain_seed, run_start, run_count)
		var crest_index := (run_start + before + rng.randi_range(0, window_size - 1)) % unique_count
		var crest := centerline[crest_index]
		var reason := _rejection_reason(crest, definition, catalog, crests)
		if not reason.is_empty():
			diagnostics["rejected_" + reason] = int(diagnostics["rejected_" + reason]) + 1
			continue
		var next := centerline[(crest_index + 1) % unique_count]
		var previous := centerline[(crest_index - 1 + unique_count) % unique_count]
		var axis := (next - previous).normalized()
		var placement := JumpRampPlacement.new()
		placement.stable_id = "h%d:%d:%d" % [catalog.version, definition.seed, run_start]
		placement.transform = Transform2D(axis.angle(), crest)
		placement.half_length = catalog.half_length
		placement.crest_height = catalog.crest_height()
		placement.width = definition.track_width
		result.placements.append(placement)
		crests.append(crest)

	result.placements.sort_custom(func(a: JumpRampPlacement, b: JumpRampPlacement) -> bool: return a.stable_id < b.stable_id)
	diagnostics["placed"] = result.placements.size()
	diagnostics["underfilled"] = result.placements.size() < requested
	result.diagnostics = diagnostics
	result.fingerprint = _fingerprint(catalog.version, result.placements)
	result.generation_usec = Time.get_ticks_usec() - started_usec
	return result


## Maximal runs of consecutive gentle samples, as {start, count}, in centerline order. The
## generator rotates the loop so the longest straight starts at index 0 and the sample before it is
## curved, but the scan still wraps so a fallback or fixture loop is handled the same way.
func _straight_runs(centerline: PackedVector2Array, catalog: HeightChannelCatalog, spacing: float) -> Array[Dictionary]:
	var unique_count := centerline.size() - 1
	var gentle: Array[bool] = []
	var first_curved := -1
	for index in range(unique_count):
		var is_gentle := _curvature_at(centerline, index) <= TrackGenerator.STRAIGHT_CURVATURE
		gentle.append(is_gentle)
		if not is_gentle and first_curved < 0:
			first_curved = index
	var minimum_samples := int(ceil(catalog.minimum_run_length() / spacing))
	var runs: Array[Dictionary] = []
	if first_curved < 0:
		if unique_count >= minimum_samples:
			runs.append({"start": 0, "count": unique_count})
		return runs
	var run_start := -1
	var run_count := 0
	for offset in range(1, unique_count + 1):
		var index := (first_curved + offset) % unique_count
		if gentle[index]:
			if run_start < 0:
				run_start = index
				run_count = 0
			run_count += 1
			continue
		if run_start >= 0 and run_count >= minimum_samples:
			runs.append({"start": run_start, "count": run_count})
		run_start = -1
		run_count = 0
	runs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.start) < int(b.start))
	return runs


func _rejection_reason(crest: Vector2, definition: TrackDefinition, catalog: HeightChannelCatalog, crests: Array[Vector2]) -> String:
	if crest.distance_to(definition.spawn_transform.origin) < catalog.spawn_exclusion + catalog.half_length:
		return "spawn"
	for checkpoint in definition.checkpoints:
		if crest.distance_to(checkpoint.origin) < catalog.checkpoint_exclusion + catalog.half_length:
			return "checkpoint"
	for other in crests:
		if other.distance_to(crest) < catalog.minimum_spacing:
			return "spacing"
	return ""


func _curvature_at(points: PackedVector2Array, index: int) -> float:
	var unique_count := points.size() - 1
	var incoming := points[index] - points[(index - 1 + unique_count) % unique_count]
	var outgoing := points[(index + 1) % unique_count] - points[index]
	var distance := (incoming.length() + outgoing.length()) * 0.5
	if distance <= 0.0:
		return 0.0
	return absf(incoming.angle_to(outgoing)) / distance


func _polyline_length(points: PackedVector2Array) -> float:
	var length := 0.0
	for index in range(points.size() - 1):
		length += points[index].distance_to(points[index + 1])
	return length


func _fingerprint(version: int, placements: Array[JumpRampPlacement]) -> String:
	var components := PackedStringArray(["version=%d" % version])
	for placement in placements:
		var origin := placement.transform.origin
		components.append("%s|%.3f,%.3f|%.6f|%.3f|%.3f|%.3f" % [
			placement.stable_id,
			origin.x,
			origin.y,
			placement.transform.get_rotation(),
			placement.half_length,
			placement.crest_height,
			placement.width,
		])
	return "|".join(components).sha256_text()
```

- [ ] **Step 4: Write the height map**

```gdscript
# track/track_height_map.gd
class_name TrackHeightMap
extends HeightQuery

## Answers ground height from a definition's jump ramps. Ramps never overlap, so the first ramp
## whose local frame contains the position is the only one. With at most a handful of ramps per
## track a linear scan beats an index; the placement test bounds its cost.

var _ramps: Array[JumpRampPlacement] = []
var _inverses: Array[Transform2D] = []


func _init(definition) -> void:
	if definition == null:
		return
	for ramp in definition.jump_ramps:
		if ramp == null or not ramp.is_valid():
			continue
		_ramps.append(ramp)
		_inverses.append(ramp.transform.affine_inverse())


func ramp_count() -> int:
	return _ramps.size()


func sample_at(world_position: Vector2) -> HeightSample:
	for index in range(_ramps.size()):
		var ramp := _ramps[index]
		var local := _inverses[index] * world_position
		if absf(local.x) > ramp.half_length or absf(local.y) > ramp.width * 0.5:
			continue
		var slope := ramp.crest_height / ramp.half_length
		var height := ramp.crest_height * (1.0 - absf(local.x) / ramp.half_length)
		# Rising toward the crest from either side: the gradient points at the crest.
		var along := -signf(local.x) * slope
		return HeightSample.new(height, ramp.transform.x.normalized() * along)
	return HeightSample.new()
```

- [ ] **Step 5: Run the placement test until it passes, then the mutations**

Run: `godot --headless --path . --script res://tests/jump_ramp_placement_test.gd`
Expected: exit 0. Print lines show `ramps=` between 0 and 4 per seed; a seed reporting fewer ramps than `requested` must also report `underfilled=true` (the diagnostics check enforces this).

Run: `godot --headless --path . --script res://tests/jump_ramp_placement_test.gd -- --break-height-seed`
Expected: exit 1 with `FAIL: seed N height fingerprint repeats` for every seed that placed at least one ramp.

Run: `godot --headless --path . --script res://tests/jump_ramp_placement_test.gd -- --break-clearance`
Expected: exit 1 with at least one `FAIL: seed N ramp keeps clear of a gate`. The oracle checks the unmutated catalog's exclusion against placements made with the zeroed one; with eight gates per lap roughly a third of unconstrained draws land inside 650 px of a gate, so across twenty seeds at least one must. Do not weaken the oracle.

- [ ] **Step 6: Commit**

```bash
git add world/height/jump_ramp_placer.gd world/height/jump_ramp_placer.gd.uid track/track_height_map.gd track/track_height_map.gd.uid tests/jump_ramp_placement_test.gd tests/jump_ramp_placement_test.gd.uid
git commit -m "feat: place deterministic jump ramps and answer ground height from them"
```

---

### Task 3: Vehicle height channel

**Files:**
- Modify: `vehicle/top_down_car.gd` (whole file; the integrator gains a vertical channel)
- Create: `tests/height_channel_test_height_provider.gd`
- Test: `tests/vehicle_height_channel_test.gd`

**Interfaces:**
- Consumes: `HeightQuery.sample_at()`, `VehicleTuning` height fields from Task 1, `Issue4TestSurfaceProvider` for scripted surfaces.
- Produces on `TopDownCar`: `set_height_query(query: HeightQuery)`, `is_airborne() -> bool`, `get_height() -> float`, `get_vertical_velocity() -> float`, `get_air_time() -> float`, `get_landing_recovery_remaining() -> float`, `consume_air_time_notice() -> float` (last flight's seconds once, else `0.0`), `consume_landing_event() -> bool` (used by Task 5 for the dust burst), diagnostics keys `height_m`, `vertical_speed_mps`, `airborne`, `air_time`.
- Produces for tests: `HeightChannelTestHeightProvider` with `Mode.HUMP` and `Mode.PLATEAU`.

- [ ] **Step 1: Write the scripted height fixture**

```gdscript
# tests/height_channel_test_height_provider.gd
class_name HeightChannelTestHeightProvider
extends HeightQuery

## Scripted ground for vehicle tests. HUMP is one symmetric ramp along +X centred at crest_x that
## spans every Y. PLATEAU is flat ground at plateau_height for x < plateau_end_x and zero beyond,
## so a car can be held at a height or driven off an edge without a generated track.

enum Mode { HUMP, PLATEAU }

var mode := Mode.HUMP
var crest_x := 0.0
var half_length := 150.0
var crest_height := 18.0
var plateau_height := 0.0
var plateau_end_x := INF
var sample_count := 0


func sample_at(world_position: Vector2) -> HeightSample:
	sample_count += 1
	if mode == Mode.PLATEAU:
		if world_position.x < plateau_end_x:
			return HeightSample.new(plateau_height, Vector2.ZERO)
		return HeightSample.new()
	var along := world_position.x - crest_x
	if absf(along) > half_length:
		return HeightSample.new()
	var slope := crest_height / half_length
	return HeightSample.new(crest_height * (1.0 - absf(along) / half_length), Vector2(-signf(along) * slope, 0.0))
```

- [ ] **Step 2: Write the failing vehicle test**

```gdscript
# tests/vehicle_height_channel_test.gd
extends SceneTree

## The car crests a scripted hump, flies the analytic arc, lands with the documented cost, and
## keeps its ground-only rules (safe pose, auto reset) out of the air. Mutations:
##   -- --break-gravity   zeroes gravity, so the car never lands and the flight loop times out
##   -- --break-landing   zeroes the speed loss and recovery grip effect, so landing costs nothing

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const START := Vector2(-2200.0, 0.0)
const CREST_X := 0.0
const HALF_LENGTH := 150.0
const CREST_HEIGHT := 18.0
const HEADING_PLUS_X := PI * 0.5
const MAX_FLIGHT_TICKS := 300
const TICK := 1.0 / 60.0

var _failures: Array[String] = []
var _checks := 0
var _break_gravity := false
var _break_landing := false


func _initialize() -> void:
	_break_gravity = OS.get_cmdline_user_args().has("--break-gravity")
	_break_landing = OS.get_cmdline_user_args().has("--break-landing")
	call_deferred("_run")


func _run() -> void:
	_check(await _verify_flight_matches_the_analytic_arc(), "the analytic arc verification ran to completion")
	_check(await _verify_landing_recovery_reduces_grip(), "the landing recovery verification ran to completion")
	_check(await _verify_slow_car_stays_on_the_downslope(), "the downslope verification ran to completion")
	_check(await _verify_ground_only_rules(), "the ground-only rules verification ran to completion")
	_check(await _verify_reset_zeroes_height(), "the reset verification ran to completion")
	_finish()


## One flight, many assertions: lift-off vertical speed, flight time, landing distance, speed loss,
## throttle and steering having no effect in the air.
func _verify_flight_matches_the_analytic_arc() -> bool:
	var context := _make_car()
	var car: TopDownCar = context.car
	var tuning: VehicleTuning = car.tuning
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	# Full steer is applied by _fly on the lift-off tick, not before: steering on the approach
	# would turn the car away from the ramp.
	var flight := await _fly(car, controls)
	_check(flight.launched, "the car leaves the ground at the crest")
	if not flight.launched:
		context.world.queue_free()
		return true
	var slope := CREST_HEIGHT / HALF_LENGTH
	var expected_vz: float = float(flight.launch_speed) * slope
	_check(absf(float(flight.launch_vz) - expected_vz) <= expected_vz * 0.05, "lift-off vertical speed (%.1f) is within 5%% of speed times slope (%.1f)" % [flight.launch_vz, expected_vz])
	_check(float(flight.launch_x) >= CREST_X - HALF_LENGTH and float(flight.launch_x) <= CREST_X + 30.0, "lift-off happens on the rising face or at the crest (x=%.1f)" % flight.launch_x)
	_check(flight.landed, "the car lands within %d ticks" % MAX_FLIGHT_TICKS)
	if not flight.landed:
		context.world.queue_free()
		return true
	var g: float = tuning.gravity
	var h0: float = flight.launch_height
	var vz: float = flight.launch_vz
	var expected_time := (vz + sqrt(vz * vz + 2.0 * g * h0)) / g
	var measured_time := float(flight.air_ticks) * TICK
	_check(float(flight.landing_x) > CREST_X + HALF_LENGTH, "the landing is on flat ground past the ramp, so the flat-ground formula applies")
	_check(absf(measured_time - expected_time) <= 2.0 * TICK, "flight time (%.3f s) matches the analytic %.3f s within two ticks" % [measured_time, expected_time])
	var k: float = tuning.aerodynamic_drag
	var v0: float = flight.launch_speed
	var expected_distance := log(1.0 + k * v0 * expected_time) / k
	var measured_distance: float = float(flight.landing_x) - float(flight.launch_x)
	_check(absf(measured_distance - expected_distance) <= expected_distance * 0.05, "landing distance (%.1f) matches the drag integral (%.1f) within 5%%" % [measured_distance, expected_distance])
	var impact_mps := WorldScale.to_metres(maxf(-float(flight.last_vz) + g * TICK, 0.0))
	var expected_ratio := clampf(1.0 - tuning.landing_speed_loss * impact_mps, 0.3, 1.0)
	var measured_ratio: float = float(flight.speed_after) / float(flight.speed_before)
	_check(absf(measured_ratio - expected_ratio) <= 0.03, "landing keeps %.3f of speed, expected %.3f" % [measured_ratio, expected_ratio])
	_check(expected_ratio < 0.97, "the landing is hard enough that the loss assertion is live")
	_check(flight.speed_never_rose, "throttle adds no speed in the air")
	_check(absf(float(flight.rotation_change)) < 0.01, "full steer does not rotate the car in the air at zero authority")
	_check(flight.recovery_after_landing > 0.0, "landing opens a recovery window")
	_check(car.consume_air_time_notice() > tuning.air_time_notice_seconds, "a long flight leaves an air time notice")
	_check(car.consume_air_time_notice() == 0.0, "the notice is consumed once")
	context.world.queue_free()
	await process_frame
	return true


## Two identical landings, one with the recovery multiplier and one without: the recovering car
## must slide more under the same steering input.
func _verify_landing_recovery_reduces_grip() -> bool:
	var recovering := await _peak_slip_after_landing(true)
	var control := await _peak_slip_after_landing(false)
	print("peak_slip recovering=%.3f control=%.3f" % [recovering, control])
	_check(recovering > control + 0.02, "reduced grip after landing produces more slip (%.3f) than full grip (%.3f)" % [recovering, control])
	return true


func _peak_slip_after_landing(apply_recovery: bool) -> float:
	var context := _make_car()
	var car: TopDownCar = context.car
	if not apply_recovery:
		var tuning := (car.tuning as VehicleTuning).duplicate() as VehicleTuning
		tuning.landing_recovery_grip_multiplier = 1.0
		car.tuning = tuning
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var flight := await _fly(car, controls)
	var peak := 0.0
	if flight.landed:
		controls.steer = 1.0
		controls.throttle = 0.0
		car.set_input_state(controls)
		var window := int(ceil((car.tuning as VehicleTuning).landing_recovery_seconds / TICK))
		for tick in range(window):
			await physics_frame
			peak = maxf(peak, car.get_slip_ratio())
	context.world.queue_free()
	await process_frame
	return peak


func _verify_slow_car_stays_on_the_downslope() -> bool:
	var context := _make_car()
	var car: TopDownCar = context.car
	car.global_transform = Transform2D(HEADING_PLUS_X, Vector2(CREST_X + 10.0, 0.0))
	car.linear_velocity = Vector2(30.0, 0.0)
	var left_ground := false
	for tick in range(60):
		await physics_frame
		if car.is_airborne():
			left_ground = true
	_check(not left_ground, "a slow car rolling down the far face stays on the ground")
	_check(car.get_height() >= 0.0 and car.get_height() <= CREST_HEIGHT, "the grounded car's height follows the face")
	context.world.queue_free()
	await process_frame
	return true


func _verify_ground_only_rules() -> bool:
	var context := _make_car()
	var car: TopDownCar = context.car
	var provider: Issue4TestSurfaceProvider = context.surface
	var tuning: VehicleTuning = car.tuning
	car.set_auto_reset_enabled(true)
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var noticed_in_air := false
	var pose_moved_in_air_or_on_ramp := false
	var launched := false
	for tick in range(MAX_FLIGHT_TICKS + 200):
		await physics_frame
		if car.is_airborne() and not launched:
			launched = true
			# Become "lost" exactly while airborne. Nothing may fire until the wheels are down.
			provider.force_off_track = true
			provider.distance_from_line = tuning.auto_reset_lost_distance + 100.0
		if car.is_airborne():
			if car.consume_auto_reset_notice():
				noticed_in_air = true
			var pose_x := car.get_safe_reset_pose().origin.x
			if pose_x > CREST_X - HALF_LENGTH:
				pose_moved_in_air_or_on_ramp = true
		elif launched:
			break
	_check(launched, "the ground-only scenario reaches the air")
	_check(not noticed_in_air, "auto reset does not fire while airborne")
	_check(not pose_moved_in_air_or_on_ramp, "no safe pose is captured in the air or on a ramp face")
	for tick in range(10):
		await physics_frame
	_check(car.consume_auto_reset_notice(), "the same lost condition fires once the car has landed")
	context.world.queue_free()
	await process_frame
	return true


func _verify_reset_zeroes_height() -> bool:
	var context := _make_car()
	var car: TopDownCar = context.car
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	for tick in range(MAX_FLIGHT_TICKS):
		await physics_frame
		if car.is_airborne():
			break
	_check(car.is_airborne(), "the reset scenario reaches the air")
	car.request_safe_reset()
	await physics_frame
	await physics_frame
	_check(not car.is_airborne(), "a reset lands the car")
	_check(car.get_height() == 0.0 and car.get_vertical_velocity() == 0.0, "a reset zeroes height and vertical speed")
	_check(car.global_position.distance_to(START) < 1.0, "a reset returns to the safe pose")
	context.world.queue_free()
	await process_frame
	return true


## Drives from START until the car has launched and landed (or the tick budget runs out), and
## records everything the assertions need. Full steer is held from lift-off to landing so the
## steering-authority assertion is exercised without disturbing the approach.
func _fly(car: TopDownCar, controls: VehicleInputState) -> Dictionary:
	var flight := {
		"launched": false, "landed": false, "launch_speed": 0.0, "launch_vz": 0.0, "launch_x": 0.0,
		"launch_height": 0.0, "launch_rotation": 0.0, "air_ticks": 0, "landing_x": 0.0,
		"speed_before": 0.0, "speed_after": 0.0, "last_vz": 0.0, "speed_never_rose": true,
		"rotation_change": 0.0, "recovery_after_landing": 0.0,
	}
	var previous_speed := 0.0
	for tick in range(MAX_FLIGHT_TICKS + 600):
		await physics_frame
		var airborne := car.is_airborne()
		if airborne and not flight.launched:
			flight.launched = true
			flight.launch_speed = car.get_speed()
			flight.launch_vz = car.get_vertical_velocity()
			flight.launch_x = car.global_position.x
			flight.launch_height = car.get_height()
			flight.launch_rotation = car.rotation
			previous_speed = car.get_speed()
			controls.steer = 1.0
			car.set_input_state(controls)
		if airborne:
			flight.air_ticks += 1
			if car.get_speed() > previous_speed + 0.01:
				flight.speed_never_rose = false
			previous_speed = car.get_speed()
			flight.speed_before = car.get_speed()
			flight.last_vz = car.get_vertical_velocity()
			if flight.air_ticks > MAX_FLIGHT_TICKS:
				break
		elif flight.launched:
			flight.landed = true
			flight.landing_x = car.global_position.x
			flight.speed_after = car.get_speed()
			flight.rotation_change = car.rotation - flight.launch_rotation
			flight.recovery_after_landing = car.get_landing_recovery_remaining()
			controls.steer = 0.0
			car.set_input_state(controls)
			break
	return flight


func _make_car() -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	var tuning := (load(TUNING_PATH) as VehicleTuning).duplicate() as VehicleTuning
	if _break_gravity:
		tuning.gravity = 0.0
	if _break_landing:
		tuning.landing_speed_loss = 0.0
		tuning.landing_recovery_grip_multiplier = 1.0
	car.tuning = tuning
	car.global_transform = Transform2D(HEADING_PLUS_X, START)
	var surface := Issue4TestSurfaceProvider.new()
	car.set_surface_query(surface)
	var height := HeightChannelTestHeightProvider.new()
	height.mode = HeightChannelTestHeightProvider.Mode.HUMP
	height.crest_x = CREST_X
	height.half_length = HALF_LENGTH
	height.crest_height = CREST_HEIGHT
	car.set_height_query(height)
	world.add_child(car)
	car.set_safe_reset_pose(Transform2D(HEADING_PLUS_X, START))
	return {"world": world, "car": car, "surface": surface, "height": height}


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Vehicle height channel checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Vehicle height channel check failed: %s" % failure)
	quit(1)
```

- [ ] **Step 3: Run it and watch it fail**

Run: `godot --headless --path . --script res://tests/vehicle_height_channel_test.gd`
Expected: parse error, `set_height_query` not found on `TopDownCar`. Exit non-zero.

- [ ] **Step 4: Add the height channel to the car**

Edit `vehicle/top_down_car.gd`. New state after `_safe_pose_elapsed`:

```gdscript
var _height_query: HeightQuery
var _ground_height := 0.0
var _ground_gradient := Vector2.ZERO
var _height := 0.0
var _vertical_velocity := 0.0
var _airborne := false
var _air_time := 0.0
var _air_time_notice := 0.0
var _landing_recovery_remaining := 0.0
var _landed_this_tick := false

## Predicted ballistic height must exceed the ground ahead by this much before the car counts as
## airborne. Small enough that a car cresting at walking pace still lifts off; large enough that
## float noise on flat ground never does.
const LIFT_OFF_TOLERANCE := 0.05
## A landing can never remove more than 70% of speed.
const MIN_LANDING_SPEED_FRACTION := 0.3
```

Change `_integrate_forces` as follows. After `_sample_surface(state.transform.origin)` add `_sample_ground(state.transform.origin)`. Then apply airborne and recovery multipliers to the existing force model:

```gdscript
	var forward := -state.transform.y.normalized()
	var lateral := state.transform.x.normalized()
	var ground_authority := 0.0 if _airborne else 1.0
	var surface_engine := tuning.off_track_engine_multiplier if _surface_type == SurfaceQuery.SurfaceType.OFF_TRACK else 1.0
	var longitudinal_acceleration := tuning.engine_force * _input_state.throttle * surface_engine * ground_authority / tuning.mass_kg
	if _input_state.brake > 0.0 and not _airborne:
		# (existing brake / reverse block, unchanged)
	else:
		_reverse_hold_time = 0.0
	if not _airborne:
		# Climbing a face costs speed, descending one returns it.
		longitudinal_acceleration -= tuning.gravity * _ground_gradient.dot(forward)
	world_velocity += forward * longitudinal_acceleration * delta

	var updated_local := state.transform.basis_xform_inv(world_velocity)
	var updated_forward_speed := -updated_local.y
	var drag_rate := tuning.rolling_drag * _surface_drag * ground_authority
	var aero_drag := tuning.aerodynamic_drag * (1.0 if _airborne else _surface_drag)
	var drag_amount := (drag_rate * absf(updated_forward_speed) + aero_drag * updated_forward_speed * updated_forward_speed) * delta
	updated_forward_speed = move_toward(updated_forward_speed, 0.0, drag_amount)
	world_velocity = forward * updated_forward_speed + lateral * updated_local.x

	var progressive_grip := _progressive_grip(_slip_ratio)
	var handbrake_grip := lerpf(1.0, tuning.handbrake_grip_multiplier, _input_state.handbrake)
	var recovery_grip := tuning.landing_recovery_grip_multiplier if _landing_recovery_remaining > 0.0 else 1.0
	var lateral_response := tuning.lateral_grip * _surface_grip * progressive_grip * handbrake_grip * recovery_grip * ground_authority
	var desired_lateral_change := -lateral_speed * (1.0 - exp(-lateral_response * delta))
	var lateral_change_limit := tuning.lateral_grip_acceleration * _surface_grip * handbrake_grip * recovery_grip * ground_authority * delta
	desired_lateral_change = clampf(desired_lateral_change, -lateral_change_limit, lateral_change_limit)
	world_velocity += lateral * desired_lateral_change

	if speed < WorldScale.metres(2.0) and _input_state.throttle == 0.0 and _input_state.brake == 0.0 and not _airborne:
		world_velocity = world_velocity.move_toward(Vector2.ZERO, tuning.low_speed_stabilization * delta)

	var steering_speed_factor := clampf(absf(updated_forward_speed) / maxf(tuning.steering_full_speed, 0.01), 0.12, 1.0)
	var travel_direction := signf(updated_forward_speed) if absf(updated_forward_speed) > tuning.stop_speed else 1.0
	var rotation_multiplier := lerpf(1.0, tuning.handbrake_rotation_multiplier, _input_state.handbrake)
	var steering_authority := tuning.airborne_steering_authority if _airborne else 1.0
	var target_angular_velocity := _input_state.steer * tuning.max_steering_rate * steering_speed_factor * travel_direction * rotation_multiplier * steering_authority
```

Keep the remaining angular and clamp lines as they are. Replace the tail of the function, from `state.linear_velocity = world_velocity.limit_length(tuning.max_safe_speed)` on, with:

```gdscript
	state.linear_velocity = world_velocity.limit_length(tuning.max_safe_speed)
	_update_height_channel(state, delta)
	_peak_speed = maxf(_peak_speed, state.linear_velocity.length())
	_local_velocity = state.transform.basis_xform_inv(state.linear_velocity)
	_slip_ratio = absf(_local_velocity.x) / maxf(state.linear_velocity.length(), WorldScale.metres(1.0))
	_update_safe_pose_checkpoint(state, delta)
	_update_auto_reset(state, delta)
```

Add the channel itself:

```gdscript
func set_height_query(height_query: HeightQuery) -> void:
	_height_query = height_query


func is_airborne() -> bool:
	return _airborne


func get_height() -> float:
	return _height


func get_vertical_velocity() -> float:
	return _vertical_velocity


func get_air_time() -> float:
	return _air_time


func get_landing_recovery_remaining() -> float:
	return _landing_recovery_remaining


## Seconds of the last flight that lasted at least air_time_notice_seconds, once; then 0.0. The
## session polls this to show a status line without the car knowing about the HUD.
func consume_air_time_notice() -> float:
	var notice := _air_time_notice
	_air_time_notice = 0.0
	return notice


## True once per landing. Presentation reads it for the dust burst.
func consume_landing_event() -> bool:
	var landed := _landed_this_tick
	_landed_this_tick = false
	return landed


func _sample_ground(world_position: Vector2) -> void:
	var sample := _sample_ground_at(world_position)
	_ground_height = sample.ground_height
	_ground_gradient = sample.gradient


func _sample_ground_at(world_position: Vector2) -> HeightQuery.HeightSample:
	if _height_query == null:
		return HeightQuery.HeightSample.new()
	return _height_query.sample_at(world_position)


## The only place grounded and airborne meet. Grounded: ride the ground and predict whether the
## ballistic path clears the ground ahead. Airborne: fall, and land when the path meets the ground.
func _update_height_channel(state: PhysicsDirectBodyState2D, delta: float) -> void:
	var next_position := state.transform.origin + state.linear_velocity * delta
	var ahead := _sample_ground_at(next_position)
	if _airborne:
		_vertical_velocity -= tuning.gravity * delta
		_height += _vertical_velocity * delta
		_air_time += delta
		if _height <= ahead.ground_height:
			_land(state, ahead)
		return
	_landing_recovery_remaining = maxf(_landing_recovery_remaining - delta, 0.0)
	_vertical_velocity = state.linear_velocity.dot(_ground_gradient)
	var predicted := _height + _vertical_velocity * delta - 0.5 * tuning.gravity * delta * delta
	if predicted > ahead.ground_height + LIFT_OFF_TOLERANCE:
		_airborne = true
		_air_time = 0.0
		_height = predicted
		return
	_height = ahead.ground_height


func _land(state: PhysicsDirectBodyState2D, ground: HeightQuery.HeightSample) -> void:
	var ground_rate := state.linear_velocity.dot(ground.gradient)
	var impact := maxf(ground_rate - _vertical_velocity, 0.0)
	var kept := clampf(1.0 - tuning.landing_speed_loss * WorldScale.to_metres(impact), MIN_LANDING_SPEED_FRACTION, 1.0)
	state.linear_velocity *= kept
	_height = ground.ground_height
	_vertical_velocity = ground_rate
	_airborne = false
	_landed_this_tick = true
	if _air_time >= tuning.air_time_notice_seconds:
		_air_time_notice = _air_time
	_air_time = 0.0
	_landing_recovery_remaining = tuning.landing_recovery_seconds
```

Gate the ground-only rules. In `_update_safe_pose_checkpoint` change the first condition to:

```gdscript
	if _airborne or _ground_height > 0.0 or _landing_recovery_remaining > 0.0 or _surface_type != SurfaceQuery.SurfaceType.DIRT or _slip_ratio > tuning.safe_pose_max_slip or state.get_contact_count() > 0:
```

In `_update_auto_reset` change the first condition to:

```gdscript
	if not _auto_reset_enabled or _airborne or _surface_type != SurfaceQuery.SurfaceType.OFF_TRACK:
```

In `_apply_safe_reset` add after `_safe_pose_elapsed = 0.0`:

```gdscript
	_height = 0.0
	_vertical_velocity = 0.0
	_airborne = false
	_air_time = 0.0
	_landing_recovery_remaining = 0.0
```

Extend `get_diagnostics()` with:

```gdscript
		"height_m": WorldScale.to_metres(_height),
		"vertical_speed_mps": WorldScale.to_metres(_vertical_velocity),
		"airborne": _airborne,
		"air_time": _air_time,
```

- [ ] **Step 5: Run the vehicle test until it passes, then the existing vehicle suites**

Run: `godot --headless --path . --script res://tests/vehicle_height_channel_test.gd`
Expected: exit 0. The printed `peak_slip` line shows the recovering value above the control.

Run:
```
godot --headless --path . --script res://tests/issue_4_vehicle_maneuvers.gd
godot --headless --path . --script res://tests/open_surface_auto_reset_test.gd
godot --headless --path . --script res://tests/track_collision_physics_test.gd
```
Expected: exit 0 for all three. These cars have no height query, so `_sample_ground_at` returns flat ground and nothing lifts off; any change in their numbers means the grounded path was altered and must be fixed, not the assertions.

- [ ] **Step 6: Run the mutations**

Run: `godot --headless --path . --script res://tests/vehicle_height_channel_test.gd -- --break-gravity`
Expected: exit 1 with `FAIL: the car lands within 300 ticks`.

Run: `godot --headless --path . --script res://tests/vehicle_height_channel_test.gd -- --break-landing`
Expected: exit 1 with `FAIL: landing keeps ...` and `FAIL: reduced grip after landing produces more slip ...`.

- [ ] **Step 7: Commit**

```bash
git add vehicle/top_down_car.gd tests/height_channel_test_height_provider.gd tests/height_channel_test_height_provider.gd.uid tests/vehicle_height_channel_test.gd tests/vehicle_height_channel_test.gd.uid
git commit -m "feat: give the car a height channel with lift-off, flight, and landing"
```

---

### Task 4: Airborne obstacle levels

**Files:**
- Modify: `world/offtrack/offtrack_object_collisions.gd`, `vehicle/top_down_car.gd`, `vehicle/top_down_car.tscn`, `tests/offtrack_object_collision_test.gd:65,119`
- Test: `tests/airborne_obstacle_level_test.gd`

**Interfaces:**
- Consumes: `OfftrackObjectArchetype.obstacle_height`, `OfftrackObjectCatalog.low_obstacle_height`, `VehicleTuning.low_obstacle_clearance`, `TopDownCar.get_height()`, `HeightChannelTestHeightProvider.Mode.PLATEAU`.
- Produces: `OfftrackObjectCollisions.TALL_LAYER = 1`, `LOW_LAYER = 2`, bodies named `Chunk_<x>_<y>_tall` and `Chunk_<x>_<y>_low`, `low_collider_count() -> int`, `tall_collider_count() -> int`; `TopDownCar.TALL_LAYER = 1`, `LOW_LAYER = 2`, `get_collision_level_mask() -> int`.

- [ ] **Step 1: Write the failing obstacle test**

```gdscript
# tests/airborne_obstacle_level_test.gd
extends SceneTree

## Rocks are low obstacles on layer 2 and trees are tall obstacles on layer 1. A car above the
## clearance height drops layer 2 from its mask, so it clears a rock and still hits a tree; a car
## on the ground hits both; a car that falls through the clearance over a rock hits the rock.
## Mutation: -- --break-height-layers puts every solid on the tall layer, so the pass-over fails.

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const CATALOG_PATH := "res://data/default_offtrack_object_catalog.tres"
const HEADING_PLUS_X := PI * 0.5
const ROCK_X := 400.0
const TREE_X := 900.0
const PROBE_SPEED := 200.0
const PROBE_TICKS := 240

var _failures: Array[String] = []
var _checks := 0
var _break_layers := false


func _initialize() -> void:
	_break_layers = OS.get_cmdline_user_args().has("--break-height-layers")
	call_deferred("_run")


func _run() -> void:
	_check(_verify_layers_by_height(), "the layer assignment verification ran to completion")
	_check(await _verify_grounded_car_hits_both(), "the grounded collision verification ran to completion")
	_check(await _verify_raised_car_clears_the_rock_and_hits_the_tree(), "the raised collision verification ran to completion")
	_check(await _verify_falling_through_clearance_hits_the_rock(), "the descent collision verification ran to completion")
	_check(await _verify_mask_restores_on_the_ground(), "the mask restore verification ran to completion")
	_finish()


func _verify_layers_by_height() -> bool:
	var context := _make_field(0.0)
	var collisions: OfftrackObjectCollisions = context.collisions
	_check(collisions.low_collider_count() == 1, "the rock is a low collider")
	_check(collisions.tall_collider_count() == 1, "the tree is a tall collider")
	_check(collisions.chunk_body_count() == 2, "one chunk with both levels builds two bodies")
	var low_body := collisions.get_node_or_null("Chunk_0_0_low") as StaticBody2D
	var tall_body := collisions.get_node_or_null("Chunk_0_0_tall") as StaticBody2D
	_check(low_body != null and low_body.collision_layer == OfftrackObjectCollisions.LOW_LAYER, "the low body is on layer 2")
	_check(tall_body != null and tall_body.collision_layer == OfftrackObjectCollisions.TALL_LAYER, "the tall body is on layer 1")
	context.world.queue_free()
	return true


func _verify_grounded_car_hits_both() -> bool:
	var context := _make_field(0.0)
	var car: TopDownCar = context.car
	var reached_tree := await _probe(car)
	_check(car.get_collision_count() >= 1, "a grounded car collides with the rock")
	_check(not reached_tree, "a grounded car is stopped before the tree by the rock")
	context.world.queue_free()
	await process_frame
	return true


func _verify_raised_car_clears_the_rock_and_hits_the_tree() -> bool:
	var tuning := load(TUNING_PATH) as VehicleTuning
	var context := _make_field(tuning.low_obstacle_clearance + 5.0)
	var car: TopDownCar = context.car
	var passed_rock := await _probe(car, ROCK_X + 60.0)
	_check(passed_rock, "a car above the clearance height passes over the rock")
	_check(car.get_collision_count() == 0, "passing over the rock registers no collision")
	await _probe(car, TREE_X + 60.0)
	_check(car.get_collision_count() >= 1, "the same raised car still collides with the tree")
	_check(car.global_position.x < TREE_X, "the tree stops the raised car")
	context.world.queue_free()
	await process_frame
	return true


## Plateau ends before the rock: the car drops off the edge and falls through the clearance height
## before reaching the rock, so the low layer is back in its mask when it arrives.
func _verify_falling_through_clearance_hits_the_rock() -> bool:
	var context := _make_field(30.0, ROCK_X - 250.0)
	var car: TopDownCar = context.car
	var was_airborne := false
	for tick in range(PROBE_TICKS):
		car.linear_velocity = Vector2(PROBE_SPEED, 0.0) if not car.is_airborne() else car.linear_velocity
		await physics_frame
		if car.is_airborne():
			was_airborne = true
		if car.get_collision_count() > 0:
			break
	_check(was_airborne, "the car leaves the plateau edge")
	_check(car.get_collision_count() >= 1, "a car that has fallen below the clearance collides with the rock")
	context.world.queue_free()
	await process_frame
	return true


func _verify_mask_restores_on_the_ground() -> bool:
	var tuning := load(TUNING_PATH) as VehicleTuning
	var context := _make_field(tuning.low_obstacle_clearance + 5.0, 100.0)
	var car: TopDownCar = context.car
	await physics_frame
	await physics_frame
	_check(car.get_collision_level_mask() == TopDownCar.TALL_LAYER, "above the clearance the mask holds only the tall layer")
	car.global_position = Vector2(300.0, 0.0)
	car.linear_velocity = Vector2.ZERO
	for tick in range(90):
		await physics_frame
	_check(not car.is_airborne(), "the car is back on flat ground")
	_check(car.get_collision_level_mask() == TopDownCar.TALL_LAYER | TopDownCar.LOW_LAYER, "on the ground the mask holds both layers")
	context.world.queue_free()
	await process_frame
	return true


## Holds the car at PROBE_SPEED along +X until it collides or passes target_x.
func _probe(car: TopDownCar, target_x: float = TREE_X + 60.0) -> bool:
	var initial_collisions := car.get_collision_count()
	for tick in range(PROBE_TICKS):
		car.linear_velocity = Vector2(PROBE_SPEED, 0.0)
		await physics_frame
		if car.get_collision_count() > initial_collisions:
			return false
		if car.global_position.x >= target_x:
			return true
	return false


func _make_field(plateau_height: float, plateau_end_x: float = INF) -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var catalog := (load(CATALOG_PATH) as OfftrackObjectCatalog).duplicate(true) as OfftrackObjectCatalog
	if _break_layers:
		catalog.low_obstacle_height = -1.0
	var placements: Array[OfftrackObjectPlacement] = []
	placements.append(_solid(catalog, &"rock", Vector2(ROCK_X, 0.0)))
	placements.append(_solid(catalog, &"tree", Vector2(TREE_X, 0.0)))
	var collisions := OfftrackObjectCollisions.new()
	world.add_child(collisions)
	collisions.build(placements, catalog)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = load(TUNING_PATH) as VehicleTuning
	car.global_transform = Transform2D(HEADING_PLUS_X, Vector2(0.0, 0.0))
	var height := HeightChannelTestHeightProvider.new()
	height.mode = HeightChannelTestHeightProvider.Mode.PLATEAU
	height.plateau_height = plateau_height
	height.plateau_end_x = plateau_end_x
	car.set_height_query(height)
	car.set_surface_query(Issue4TestSurfaceProvider.new())
	world.add_child(car)
	return {"world": world, "car": car, "collisions": collisions}


func _solid(catalog: OfftrackObjectCatalog, archetype_id: StringName, origin: Vector2) -> OfftrackObjectPlacement:
	var archetype := catalog.archetype_by_id(archetype_id)
	var placement := OfftrackObjectPlacement.new()
	placement.stable_id = "v1:0:%s" % archetype_id
	placement.archetype_id = archetype_id
	placement.transform = Transform2D(0.0, origin)
	placement.scale_factor = 1.0
	placement.solid = true
	placement.visual_variant = 0
	placement.collision_profile = archetype.collision_profile
	return placement


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Airborne obstacle level checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Airborne obstacle level check failed: %s" % failure)
	quit(1)
```

- [ ] **Step 2: Run it and watch it fail**

Run: `godot --headless --path . --script res://tests/airborne_obstacle_level_test.gd`
Expected: parse errors for `low_collider_count`, `LOW_LAYER`, `get_collision_level_mask`. Exit non-zero.

- [ ] **Step 3: Split chunk bodies by level**

Replace the body-selection section of `OfftrackObjectCollisions.build()`:

```gdscript
const TALL_LAYER := 1
const LOW_LAYER := 2

var _chunk_body_count := 0
var _low_collider_count := 0
var _tall_collider_count := 0


func build(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> void:
	_clear_children()
	if catalog == null or catalog.chunk_size <= 0.0:
		push_error("Off-track collision catalog requires a positive chunk size")
		return
	var bodies: Dictionary = {}
	for placement in placements:
		if not placement.solid:
			continue
		var archetype := catalog.archetype_by_id(placement.archetype_id)
		if archetype == null or not archetype.solid or archetype.collision_radius <= 0.0:
			push_error("Invalid solid off-track placement %s" % placement.stable_id)
			continue
		var chunk := Vector2i(
			floori(placement.transform.origin.x / catalog.chunk_size),
			floori(placement.transform.origin.y / catalog.chunk_size)
		)
		# Layers belong to bodies, not shapes, so each chunk holds one body per height level.
		var is_low := archetype.obstacle_height <= catalog.low_obstacle_height
		var key := "%d_%d_%s" % [chunk.x, chunk.y, "low" if is_low else "tall"]
		var body: StaticBody2D = bodies.get(key)
		if body == null:
			body = StaticBody2D.new()
			body.name = "Chunk_" + key
			body.position = Vector2(chunk) * catalog.chunk_size
			body.collision_layer = LOW_LAYER if is_low else TALL_LAYER
			body.collision_mask = 0
			add_child(body)
			bodies[key] = body
			_chunk_body_count += 1
		var shape := CollisionShape2D.new()
		shape.name = placement.stable_id.replace(":", "_")
		shape.position = placement.transform.origin - body.position
		shape.rotation = placement.transform.get_rotation()
		var circle := CircleShape2D.new()
		circle.radius = archetype.collision_radius * placement.scale_factor
		shape.shape = circle
		body.add_child(shape)
		if is_low:
			_low_collider_count += 1
		else:
			_tall_collider_count += 1


func low_collider_count() -> int:
	return _low_collider_count


func tall_collider_count() -> int:
	return _tall_collider_count
```

Reset both counters to zero in `_clear_children()`.

- [ ] **Step 4: Toggle the car's mask by height**

In `vehicle/top_down_car.gd` add:

```gdscript
const TALL_LAYER := 1
const LOW_LAYER := 2


## The mask is a body property, not part of the integrator's state, so it is applied from
## _physics_process before the step rather than from inside _integrate_forces. It reflects the
## previous tick's height; at 60 Hz that is at most 2 px of vertical travel.
func _physics_process(_delta: float) -> void:
	if tuning == null:
		return
	collision_mask = get_collision_level_mask()


func get_collision_level_mask() -> int:
	if _height > tuning.low_obstacle_clearance:
		return TALL_LAYER
	return TALL_LAYER | LOW_LAYER
```

In `vehicle/top_down_car.tscn` add `collision_layer = 1` and `collision_mask = 3` to the `TopDownCar` node so the scene file records the same starting mask.

- [ ] **Step 5: Update the pinned chunk counts**

`tests/offtrack_object_collision_test.gd:65` and `:119` assert `chunk_body_count() == 1` for a tree and a rock in one chunk. With one body per level that is now two. Change both messages and values:

```gdscript
	_check(collisions.chunk_body_count() == 2, "nearby solid fixtures build one low and one tall chunk body")
```

- [ ] **Step 6: Run the tests and the mutation**

Run:
```
godot --headless --path . --script res://tests/airborne_obstacle_level_test.gd
godot --headless --path . --script res://tests/offtrack_object_collision_test.gd
godot --headless --path . --script res://tests/offtrack_object_runtime_test.gd
godot --headless --path . --script res://tests/height_channel_contract_test.gd
```
Expected: all exit 0.

Run: `godot --headless --path . --script res://tests/airborne_obstacle_level_test.gd -- --break-height-layers`
Expected: exit 1 with `FAIL: a car above the clearance height passes over the rock` and `FAIL: the rock is a low collider`.

- [ ] **Step 7: Commit**

```bash
git add world/offtrack/offtrack_object_collisions.gd vehicle/top_down_car.gd vehicle/top_down_car.tscn tests/offtrack_object_collision_test.gd tests/airborne_obstacle_level_test.gd tests/airborne_obstacle_level_test.gd.uid
git commit -m "feat: let an airborne car clear low obstacles"
```

---

### Task 5: Presentation

**Files:**
- Create: `world/height/jump_ramp_visuals.gd`
- Modify: `vehicle/top_down_car.tscn`, `vehicle/top_down_car.gd` (`_ready`, `_process`), `session/diagnostics_overlay.gd`
- Test: `tests/jump_ramp_visuals_test.gd`

**Interfaces:**
- Consumes: `JumpRampPlacement`, `TopDownCar.get_height()/is_airborne()/consume_landing_event()`, `VehicleTuning.lift_pixels_per_pixel/scale_per_metre`.
- Produces: `JumpRampVisuals.build(ramps: Array[JumpRampPlacement]) -> void`, `visual_count() -> int`, children named `Ramp_<stable_id with : replaced by _>`; car scene nodes `Lift` (parent of `Body`, `Windshield`, `DirectionMark`) and `Shadow`; `DiagnosticsOverlay.set_height_metrics(height_m: float, vertical_speed_mps: float, airborne: bool, air_time: float)`; `TopDownCar.SHADOW_FADE_PER_METRE = 0.15`.

- [ ] **Step 1: Write the failing visuals test**

```gdscript
# tests/jump_ramp_visuals_test.gd
extends SceneTree

## Ramps draw one wedge each, the car body lifts and scales away from its grounded shadow, an
## airborne car draws above y-sorted objects, and dust stays off in the air.

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(_verify_wedges(), "the wedge verification ran to completion")
	_check(await _verify_body_lift_and_shadow(), "the lift and shadow verification ran to completion")
	_check(await _verify_airborne_draw_order_and_dust(), "the draw order verification ran to completion")
	_check(_verify_overlay_line(), "the overlay verification ran to completion")
	_finish()


func _verify_wedges() -> bool:
	var visuals := JumpRampVisuals.new()
	root.add_child(visuals)
	var ramps: Array[JumpRampPlacement] = []
	ramps.append(_ramp("h1:0:10", Vector2(100.0, 0.0), 240.0))
	ramps.append(_ramp("h1:0:80", Vector2(900.0, 0.0), 200.0))
	var invalid := _ramp("h1:0:99", Vector2(1500.0, 0.0), 0.0)
	ramps.append(invalid)
	ramps.append(null)
	visuals.build(ramps)
	_check(visuals.visual_count() == 2, "two valid ramps build two wedges; the invalid and null records build none")
	var first := visuals.get_node_or_null("Ramp_h1_0_10") as Node2D
	_check(first != null, "wedges are named by stable id")
	if first != null:
		var wedge := first.get_node_or_null("Wedge") as Polygon2D
		_check(wedge != null and wedge.polygon.size() == 4, "each ramp draws a four-point wedge")
		if wedge != null:
			var min_y := INF
			var max_y := -INF
			for point in wedge.polygon:
				min_y = minf(min_y, point.y)
				max_y = maxf(max_y, point.y)
			_check(is_equal_approx(max_y - min_y, 240.0), "the wedge spans the placement width")
		_check(first.get_node_or_null("Crest") is Line2D, "each ramp draws a crest line")
		_check(first.get_node_or_null("ChevronIn") is Line2D and first.get_node_or_null("ChevronOut") is Line2D, "each ramp draws a chevron per face")
	visuals.build([])
	_check(visuals.visual_count() == 0 and visuals.get_child_count() == 0, "rebuilding with no ramps frees the wedges")
	visuals.queue_free()
	return true


func _verify_body_lift_and_shadow() -> bool:
	var tuning := load(TUNING_PATH) as VehicleTuning
	for metres in [0.0, 1.0, 3.0]:
		var context := _make_car(WorldScale.metres(metres))
		var car: TopDownCar = context.car
		for frame in range(4):
			await process_frame
		var lift := car.get_node("Lift") as Node2D
		var shadow := car.get_node("Shadow") as Polygon2D
		var height := WorldScale.metres(metres)
		_check(is_equal_approx(lift.position.y, -height * tuning.lift_pixels_per_pixel), "at %.0f m the body lifts %.1f px" % [metres, height * tuning.lift_pixels_per_pixel])
		_check(is_equal_approx(lift.scale.x, 1.0 + metres * tuning.scale_per_metre), "at %.0f m the body scales to %.2f" % [metres, 1.0 + metres * tuning.scale_per_metre])
		_check(is_equal_approx(shadow.position.y, 6.0), "the shadow stays on the ground at %.0f m" % metres)
		var expected_alpha := clampf(1.0 - metres * TopDownCar.SHADOW_FADE_PER_METRE, 0.25, 1.0)
		_check(is_equal_approx(shadow.modulate.a, expected_alpha), "the shadow fades to %.2f at %.0f m" % [expected_alpha, metres])
		_check(lift.get_node_or_null("Body") != null and lift.get_node_or_null("Windshield") != null and lift.get_node_or_null("DirectionMark") != null, "the body parts live under Lift")
		context.world.queue_free()
		await process_frame
	return true


func _verify_airborne_draw_order_and_dust() -> bool:
	var context := _make_car(40.0, 50.0)
	var car: TopDownCar = context.car
	var dust := car.get_node("Dust") as CPUParticles2D
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	# Off-track keeps the ordinary dust rule off, so the only way emitting can be true on the
	# landing frame is the landing burst. Without this the assertion would pass on speed alone.
	(context.surface as Issue4TestSurfaceProvider).force_off_track = true
	var seen_airborne := false
	var z_in_air := 0
	var dust_in_air := false
	var z_on_landing := -1
	var dust_on_landing := false
	for tick in range(240):
		await physics_frame
		await process_frame
		if car.is_airborne():
			seen_airborne = true
			z_in_air = car.z_index
			dust_in_air = dust_in_air or dust.emitting
		elif seen_airborne:
			z_on_landing = car.z_index
			dust_on_landing = dust.emitting
			break
	_check(seen_airborne, "the car falls off the plateau edge")
	_check(z_in_air == 1, "an airborne car draws at z_index 1")
	_check(not dust_in_air, "dust does not emit in the air")
	_check(z_on_landing == 0, "a landed car returns to z_index 0")
	_check(dust_on_landing, "landing restarts the dust as a burst")
	await process_frame
	_check(not dust.emitting, "the burst is one frame; the ordinary rule resumes")
	context.world.queue_free()
	await process_frame
	return true


func _verify_overlay_line() -> bool:
	var overlay_scene := load("res://session/main.tscn") as PackedScene
	var session := overlay_scene.instantiate()
	root.add_child(session)
	var overlay := session.get_node("%DiagnosticsOverlay") as DiagnosticsOverlay
	overlay.set_release_mode(false)
	overlay.visible = true
	overlay.set_height_metrics(1.5, -3.25, true, 0.75)
	var label := overlay.find_child("MetricsLabel", true, false) as Label
	_check(label.text.contains("height: 1.50 m"), "the overlay reports height in metres")
	_check(label.text.contains("vz: -3.25 m/s"), "the overlay reports vertical speed")
	_check(label.text.contains("air: 0.75 s"), "the overlay reports air time while airborne")
	session.queue_free()
	return true


func _ramp(id: String, origin: Vector2, width: float) -> JumpRampPlacement:
	var ramp := JumpRampPlacement.new()
	ramp.stable_id = id
	ramp.transform = Transform2D(0.0, origin)
	ramp.half_length = 150.0
	ramp.crest_height = 18.0
	ramp.width = width
	return ramp


func _make_car(plateau_height: float, plateau_end_x: float = INF) -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = load(TUNING_PATH) as VehicleTuning
	car.global_transform = Transform2D(PI * 0.5, Vector2.ZERO)
	var height := HeightChannelTestHeightProvider.new()
	height.mode = HeightChannelTestHeightProvider.Mode.PLATEAU
	height.plateau_height = plateau_height
	height.plateau_end_x = plateau_end_x
	car.set_height_query(height)
	var surface := Issue4TestSurfaceProvider.new()
	car.set_surface_query(surface)
	world.add_child(car)
	return {"world": world, "car": car, "surface": surface}


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Jump ramp visual checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Jump ramp visual check failed: %s" % failure)
	quit(1)
```

- [ ] **Step 2: Run it and watch it fail**

Run: `godot --headless --path . --script res://tests/jump_ramp_visuals_test.gd`
Expected: parse errors for `JumpRampVisuals`, `set_height_metrics`, `SHADOW_FADE_PER_METRE`. Exit non-zero.

- [ ] **Step 3: Write the wedge visuals**

```gdscript
# world/height/jump_ramp_visuals.gd
class_name JumpRampVisuals
extends Node2D

## One wedge per valid ramp: a lighter dirt quad the width of the road, a crest line, and a
## chevron on each face pointing at the crest. Pure presentation; never touches physics.

const WEDGE_COLOR := Color("9c6a33")
const CREST_COLOR := Color("e2c98a")
const CHEVRON_COLOR := Color("c7a15f")
const CREST_WIDTH := 6.0
const CHEVRON_WIDTH := 4.0

var _visual_count := 0


func build(ramps: Array[JumpRampPlacement]) -> void:
	for child in get_children():
		child.free()
	_visual_count = 0
	for ramp in ramps:
		if ramp == null or not ramp.is_valid():
			continue
		var holder := Node2D.new()
		holder.name = "Ramp_" + ramp.stable_id.replace(":", "_")
		holder.transform = ramp.transform
		add_child(holder)
		var half_width := ramp.width * 0.5
		var wedge := Polygon2D.new()
		wedge.name = "Wedge"
		wedge.polygon = PackedVector2Array([
			Vector2(-ramp.half_length, -half_width),
			Vector2(ramp.half_length, -half_width),
			Vector2(ramp.half_length, half_width),
			Vector2(-ramp.half_length, half_width),
		])
		wedge.color = WEDGE_COLOR
		holder.add_child(wedge)
		var crest := Line2D.new()
		crest.name = "Crest"
		crest.points = PackedVector2Array([Vector2(0.0, -half_width), Vector2(0.0, half_width)])
		crest.width = CREST_WIDTH
		crest.default_color = CREST_COLOR
		crest.antialiased = true
		holder.add_child(crest)
		holder.add_child(_chevron("ChevronIn", -ramp.half_length * 0.5, half_width * 0.6, 1.0))
		holder.add_child(_chevron("ChevronOut", ramp.half_length * 0.5, half_width * 0.6, -1.0))
		_visual_count += 1


func visual_count() -> int:
	return _visual_count


## A chevron at along_x whose point faces the crest (direction +1 points toward +x).
func _chevron(chevron_name: String, along_x: float, half_span: float, direction: float) -> Line2D:
	var line := Line2D.new()
	line.name = chevron_name
	var depth := half_span * 0.5 * direction
	line.points = PackedVector2Array([
		Vector2(along_x - depth, -half_span),
		Vector2(along_x + depth, 0.0),
		Vector2(along_x - depth, half_span),
	])
	line.width = CHEVRON_WIDTH
	line.default_color = CHEVRON_COLOR
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.antialiased = true
	return line
```

- [ ] **Step 4: Lift the car body**

In `vehicle/top_down_car.tscn` insert a `Lift` node and reparent the three body polygons under it (the `Shadow` node stays where it is):

```text
[node name="Lift" type="Node2D" parent="."]

[node name="Body" type="Polygon2D" parent="Lift"]
polygon = PackedVector2Array(-13, -24, 13, -24, 17, 18, 0, 27, -17, 18)
color = Color(0.88, 0.18, 0.07, 1)

[node name="Windshield" type="Polygon2D" parent="Lift"]
polygon = PackedVector2Array(-9, -13, 9, -13, 11, 2, -11, 2)
color = Color(0.08, 0.16, 0.19, 1)

[node name="DirectionMark" type="Polygon2D" parent="Lift"]
polygon = PackedVector2Array(-4, -21, 4, -21, 0, -28)
color = Color(1, 0.83, 0.35, 1)
```

In `vehicle/top_down_car.gd` add the references and constant:

```gdscript
const SHADOW_FADE_PER_METRE := 0.15

@onready var _lift: Node2D = $Lift
@onready var _shadow: Polygon2D = $Shadow
```

Replace the dust line in `_process` and append the height presentation:

```gdscript
	_dust.emitting = on_dirt and not _airborne and get_speed() > WorldScale.metres(4.0)
	if consume_landing_event():
		_dust.restart()
	var metres := WorldScale.to_metres(_height)
	_lift.position = Vector2(0.0, -_height * tuning.lift_pixels_per_pixel)
	_lift.scale = Vector2.ONE * (1.0 + metres * tuning.scale_per_metre)
	_shadow.modulate.a = clampf(1.0 - metres * SHADOW_FADE_PER_METRE, 0.25, 1.0)
	z_index = 1 if _airborne else 0
```

`_dust.restart()` sets `emitting = true` for the frame it fires in; the assignment above runs first in that frame, so the burst wins on the landing frame and the normal rule resumes on the next.

- [ ] **Step 5: Add the overlay line**

In `session/diagnostics_overlay.gd` add state and a setter:

```gdscript
var _height_m := 0.0
var _vertical_speed_mps := 0.0
var _airborne := false
var _air_time := 0.0


func set_height_metrics(height_m: float, vertical_speed_mps: float, airborne: bool, air_time: float) -> void:
	_height_m = height_m
	_vertical_speed_mps = vertical_speed_mps
	_airborne = airborne
	_air_time = air_time
	_refresh_text()
```

And extend the text in `_refresh_text` with one more line after the brake/handbrake line:

```gdscript
		+ "brake: %.2f   handbrake: %.2f\n" % [_brake, _handbrake]
		+ "height: %.2f m   vz: %.2f m/s   %s" % [_height_m, _vertical_speed_mps, ("air: %.2f s" % _air_time) if _airborne else "grounded"]
```

- [ ] **Step 6: Run the visuals test and the suites that touch the car scene**

Run:
```
godot --headless --path . --script res://tests/jump_ramp_visuals_test.gd
godot --headless --path . --script res://tests/vehicle_height_channel_test.gd
godot --headless --path . --script res://tests/issue_4_vehicle_maneuvers.gd
godot --headless --path . --script res://tests/headless_smoke.gd
godot --headless --path . --script res://tests/issue_5_main_session_test.gd
```
Expected: all exit 0. If `issue_4_vehicle_maneuvers.gd` looks up `Body` by path, update the path to `Lift/Body`.

- [ ] **Step 7: Commit**

```bash
git add world/height/jump_ramp_visuals.gd world/height/jump_ramp_visuals.gd.uid vehicle/top_down_car.tscn vehicle/top_down_car.gd session/diagnostics_overlay.gd tests/jump_ramp_visuals_test.gd tests/jump_ramp_visuals_test.gd.uid
git commit -m "feat: draw jump ramps and lift the car body away from its shadow in the air"
```

---

### Task 6: Integration

**Files:**
- Modify: `track/track_generator.gd` (`generate()`, new `_attach_jump_ramps()`), `track/track_runtime.gd` (`_ready()`, new `_build_jump_ramps()`), `session/main.gd` (`_physics_process()`, `restart_with_seed()`, `get_session_snapshot()`, `_refresh_diagnostics()`)
- Test: `tests/issue_5_main_session_test.gd` (new verification), `tests/headless_smoke.gd` (`_verify_default_resources`)

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: `TrackDefinition.jump_ramps` populated by `TrackGenerator.generate()`; `TrackRuntime` child `JumpRamps: JumpRampVisuals`; `MainSession.get_session_snapshot()["height_fingerprint"]`; status line `Air time  ·  %.2f s`.

- [ ] **Step 1: Write the failing session checks**

Add to `tests/issue_5_main_session_test.gd` a verification and call it from `_run()` through `_check(await _verify_height_channel_is_wired(session), "the height channel wiring verification ran to completion")`:

```gdscript
func _verify_height_channel_is_wired(session: Node) -> bool:
	# The file keeps `session` typed as Node like its sibling verifications, so calls go through
	# call() rather than static member access.
	session.call("restart_with_seed", 3)
	await process_frame
	var snapshot: Dictionary = session.call("get_session_snapshot")
	_check(str(snapshot.get("height_fingerprint", "")).length() == 64, "the snapshot reports a SHA-256 height fingerprint")
	var runtime := session.get_node_or_null("World/TrackMount/GeneratedTrack") as TrackRuntime
	var ramps := runtime.get_node_or_null("JumpRamps") as JumpRampVisuals if runtime != null else null
	_check(ramps != null, "the generated track mounts a JumpRamps visual layer")
	var definition: TrackDefinition = runtime.definition
	_check(ramps != null and ramps.visual_count() == definition.jump_ramps.size(), "one wedge per generated ramp")
	var first_fingerprint := str(snapshot.get("height_fingerprint", ""))

	# Seed restart replaces the ramp set entirely.
	session.call("restart_with_seed", 4)
	await process_frame
	var second: Dictionary = session.call("get_session_snapshot")
	_check(str(second.get("height_fingerprint", "")) != first_fingerprint, "restarting with another seed changes the height fingerprint")
	_check(session.get_node("World/TrackMount").get_child_count() == 1, "the previous track, including its ramps, is freed on restart")

	# A scripted fall long enough for the notice proves the car is wired to the session's status.
	var car := session.get_node("World/VehicleMount/PlayerCar") as TopDownCar
	var provider := HeightChannelTestHeightProvider.new()
	provider.mode = HeightChannelTestHeightProvider.Mode.PLATEAU
	provider.plateau_height = 40.0
	car.set_height_query(provider)
	# Two ticks on the plateau so the car snaps up to 40 px, then pull the ground away everywhere.
	await physics_frame
	await physics_frame
	provider.plateau_end_x = -INF
	var label := session.get_node("%StatusLabel") as Label
	var saw_air_time := false
	for tick in range(180):
		await physics_frame
		await process_frame
		if label.text.begins_with("Air time"):
			saw_air_time = true
			break
	_check(saw_air_time, "a flight of at least half a second shows the air time status line")
	return true
```

Dropping 40 px takes `sqrt(2 * 40 / 122.625)` = 0.81 s, above the 0.5 s notice threshold, and does not depend on the spawn heading.

Add to `tests/headless_smoke.gd` `_verify_default_resources()`:

```gdscript
	var height_catalog := load("res://data/default_height_channel_catalog.tres") as HeightChannelCatalog
	_check(height_catalog != null and height_catalog.version >= 1, "the default height channel catalog loads")
```

- [ ] **Step 2: Run them and watch them fail**

Run:
```
godot --headless --path . --script res://tests/issue_5_main_session_test.gd
godot --headless --path . --script res://tests/headless_smoke.gd
```
Expected: the session test fails on `height_fingerprint` length and the missing `JumpRamps` node; the smoke test passes already (the catalog exists since Task 1) and only confirms the check is wired.

- [ ] **Step 3: Attach ramps in the generator**

In `track/track_generator.gd` add the catalog and attach ramps before objects, so both accepted and fallback paths pass through it:

```gdscript
const DEFAULT_HEIGHT_CATALOG := preload("res://data/default_height_channel_catalog.tres")
```

Change both `return _attach_offtrack_objects(candidate)` and `return _attach_offtrack_objects(fallback)` to `return _attach_offtrack_objects(_attach_jump_ramps(candidate))` and `return _attach_offtrack_objects(_attach_jump_ramps(fallback))`, and add:

```gdscript
## Ramps come before objects. Both are domain-seeded and share nothing, but if a later catalog
## wants objects to avoid landing zones the ramps must already exist.
func _attach_jump_ramps(definition: TrackDefinition) -> TrackDefinition:
	var result := JumpRampPlacer.new().place(definition, DEFAULT_HEIGHT_CATALOG)
	definition.jump_ramps = result.placements
	definition.height_fingerprint = result.fingerprint
	definition.height_generation_usec = result.generation_usec
	definition.height_diagnostics = result.diagnostics
	return definition
```

- [ ] **Step 4: Build wedges in the runtime**

In `track/track_runtime.gd` `_ready()`, call `_build_jump_ramps()` between the `Dirt` line and the boundary lines so the edges draw over the wedge sides:

```gdscript
	_build_line("Dirt", definition.track_width, DIRT_COLOR, -2)
	_build_jump_ramps()
	_build_boundary_line("LeftEdge", definition.left_boundary)
```

```gdscript
func _build_jump_ramps() -> void:
	var visuals := JumpRampVisuals.new()
	visuals.name = "JumpRamps"
	visuals.z_index = -1
	add_child(visuals)
	visuals.build(definition.jump_ramps)
```

- [ ] **Step 5: Wire the session**

In `session/main.gd` `restart_with_seed()`, after `_vehicle.set_surface_query(...)`:

```gdscript
	_vehicle.set_height_query(TrackHeightMap.new(_track_definition))
```

In `_physics_process()`, after the auto-reset notice block and before `if reset_this_tick:`:

```gdscript
	var air_time := _vehicle.consume_air_time_notice()
	if air_time > 0.0:
		_show_status("Air time  ·  %.2f s" % air_time)
```

In `get_session_snapshot()` add `"height_fingerprint": _track_definition.height_fingerprint,`.

In `_refresh_diagnostics()` add after the `set_metrics` call:

```gdscript
	_diagnostics_overlay.call(
		"set_height_metrics",
		float(metrics.get("height_m", 0.0)),
		float(metrics.get("vertical_speed_mps", 0.0)),
		bool(metrics.get("airborne", false)),
		float(metrics.get("air_time", 0.0)),
	)
```

- [ ] **Step 6: Run the complete suite**

```
for script in harness_contract_test headless_smoke world_scale_contract_test segment_grid_test track_generator_test track_collision_physics_test issue_4_vehicle_maneuvers issue_5_input_session_test issue_5_main_session_test open_surface_auto_reset_test offtrack_object_contract_test offtrack_object_placement_test offtrack_object_visuals_test offtrack_object_collision_test offtrack_object_runtime_test offtrack_object_performance_test height_channel_contract_test jump_ramp_placement_test vehicle_height_channel_test airborne_obstacle_level_test jump_ramp_visuals_test; do
  godot --headless --path . --script res://tests/$script.gd > /tmp/claude-1000/$script.log 2>&1; echo "$script exit=$?"
done
```
Expected: every line ends `exit=0`. `track_generator_test.gd` asserts the road fingerprints for seeds 0..19 and must be untouched by the ramp pass. Run the six mutation commands from Tasks 2-4 again and confirm each exits 1.

- [ ] **Step 7: Commit**

```bash
git add track/track_generator.gd track/track_runtime.gd session/main.gd tests/issue_5_main_session_test.gd tests/headless_smoke.gd
git commit -m "feat: generate, draw, and drive jump ramps in the session"
```

---

### Task 7: Tuning, evidence, and documentation

**Files:**
- Create: `tests/capture_height_channel_evidence.gd`, `docs/height-channel.md`, `docs/evidence/height-channel/desktop-validation.md`, `docs/evidence/height-channel/desktop-trace-seeds-0-4-9.txt`, `docs/evidence/height-channel/seed-<n>-apex.png`, `seed-<n>-landing.png`, `seed-<n>-rock-cleared.png`
- Modify: `README.md`, `docs/poc-report.md`, `docs/open-surface.md` (one line), `docs/offtrack-objects.md` (one line), possibly `data/default_height_channel_catalog.tres` and `data/default_vehicle_tuning.tres` if the drive says so

**Interfaces:**
- Consumes: everything. Produces evidence only; no production interface changes unless tuning values move, in which case the contract test in Task 1 is updated with the new values in the same commit and the reason is written in `docs/height-channel.md`.

- [ ] **Step 1: Drive it**

Run `godot --path .` and drive seeds 0, 4, and 9. Note, for each ramp met: whether the approach reads as a ramp before you reach it, whether the lift-off feels tied to speed, whether the landing loss feels like a cost without feeling like a wall, and whether a rock is ever cleared in practice. Write these notes into `docs/height-channel.md` under a `Tuning notes` heading. If a value moves, change the `.tres` and the matching assertion in `tests/height_channel_contract_test.gd` together.

- [ ] **Step 2: Write the evidence capture script**

```gdscript
# tests/capture_height_channel_evidence.gd
extends SceneTree

## Graphical desktop evidence for the height channel. Runs the production MainSession in a
## 1280x720 SubViewport, records ramp counts and fingerprints for seeds 0..19, then drives the
## production car over the first ramp of three seeds and captures the apex and the landing, and
## drives it over a generated rock while airborne. Run windowed, not headless:
##   godot --path . --script res://tests/capture_height_channel_evidence.gd

const MAIN_SCENE_PATH := "res://session/main.tscn"
const OUTPUT_DIRECTORY := "res://docs/evidence/height-channel"
const TRACE_PATH := OUTPUT_DIRECTORY + "/desktop-trace-seeds-0-4-9.txt"
const LEDGER_SEEDS := 20
const CAPTURE_SEEDS := [0, 4, 9]
const APPROACH_SPEED := 560.0
const APPROACH_DISTANCE := 900.0
const MAX_TICKS := 600

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	_check(directory_error == OK, "evidence output directory exists")
	var main_scene := load(MAIN_SCENE_PATH) as PackedScene
	var lines: Array[String] = []
	lines.append("# Height channel desktop trace")
	lines.append("# renderer=graphical SubViewport=1280x720")
	_check(_record_ledger(lines), "the seed ledger completed")
	for seed in CAPTURE_SEEDS:
		_check(await _capture_jump(main_scene, seed, lines), "seed %d jump capture completed" % seed)
	_check(await _capture_rock_clearance(main_scene, lines), "rock clearance capture completed")
	var file := FileAccess.open(ProjectSettings.globalize_path(TRACE_PATH), FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(lines) + "\n")
		file.close()
	_finish()


func _record_ledger(lines: Array[String]) -> bool:
	var generator := TrackGenerator.new()
	for seed in range(LEDGER_SEEDS):
		var definition: TrackDefinition = generator.generate(seed)
		lines.append("seed=%d ramps=%d requested=%d eligible_runs=%d placement_usec=%d height=%s road=%s objects=%s" % [
			seed,
			definition.jump_ramps.size(),
			int(definition.height_diagnostics.get("requested", -1)),
			int(definition.height_diagnostics.get("eligible_runs", -1)),
			definition.height_generation_usec,
			definition.height_fingerprint,
			definition.geometry_fingerprint,
			definition.offtrack_object_fingerprint,
		])
	return true


## Teleports the production car onto the first ramp's approach at speed and captures the apex
## (highest sampled height) and the first grounded frame after it.
func _capture_jump(main_scene: PackedScene, seed: int, lines: Array[String]) -> bool:
	var viewport := _new_viewport()
	root.add_child(viewport)
	var session := main_scene.instantiate() as MainSession
	viewport.add_child(session)
	await process_frame
	session.restart_with_seed(seed)
	for frame in range(30):
		await process_frame
	var runtime := session.get_node("World/TrackMount/GeneratedTrack") as TrackRuntime
	var definition: TrackDefinition = runtime.definition
	if definition.jump_ramps.is_empty():
		lines.append("seed=%d capture=skipped reason=no_ramps" % seed)
		viewport.queue_free()
		await process_frame
		return true
	var ramp: JumpRampPlacement = definition.jump_ramps[0]
	var axis := ramp.transform.x.normalized()
	var car := session.get_node("World/VehicleMount/PlayerCar") as TopDownCar
	car.global_transform = Transform2D(axis.angle() + PI * 0.5, ramp.transform.origin - axis * APPROACH_DISTANCE)
	car.linear_velocity = axis * APPROACH_SPEED
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var apex := 0.0
	var apex_image: Image = null
	var launched := false
	var landed := false
	var air_time := 0.0
	for tick in range(MAX_TICKS):
		await physics_frame
		await RenderingServer.frame_post_draw
		if car.is_airborne():
			launched = true
			air_time = car.get_air_time()
			if car.get_height() > apex:
				apex = car.get_height()
				apex_image = viewport.get_texture().get_image()
		elif launched:
			landed = true
			var landing_image := viewport.get_texture().get_image()
			_check(landing_image.save_png(ProjectSettings.globalize_path("%s/seed-%d-landing.png" % [OUTPUT_DIRECTORY, seed])) == OK, "seed %d landing image saved" % seed)
			break
	_check(launched and landed, "seed %d production car launches and lands on ramp %s" % [seed, ramp.stable_id])
	if apex_image != null:
		_check(apex_image.save_png(ProjectSettings.globalize_path("%s/seed-%d-apex.png" % [OUTPUT_DIRECTORY, seed])) == OK, "seed %d apex image saved" % seed)
	lines.append("seed=%d ramp=%s apex_px=%.2f apex_m=%.2f air_time_s=%.3f speed_after_kph=%.1f" % [seed, ramp.stable_id, apex, WorldScale.to_metres(apex), air_time, WorldScale.to_kph(car.get_speed())])
	viewport.queue_free()
	await process_frame
	return true


## Finds a generated rock on seed 0, builds a plateau above the clearance height with the fixture
## provider, and drives the car straight over it. Collision count must stay zero.
func _capture_rock_clearance(main_scene: PackedScene, lines: Array[String]) -> bool:
	var viewport := _new_viewport()
	root.add_child(viewport)
	var session := main_scene.instantiate() as MainSession
	viewport.add_child(session)
	await process_frame
	session.restart_with_seed(0)
	for frame in range(30):
		await process_frame
	var runtime := session.get_node("World/TrackMount/GeneratedTrack") as TrackRuntime
	var definition: TrackDefinition = runtime.definition
	var rock := _rock_with_a_clear_approach(definition)
	_check(rock != null, "seed 0 has a generated rock with no tree on its +X approach")
	if rock == null:
		viewport.queue_free()
		return true
	var car := session.get_node("World/VehicleMount/PlayerCar") as TopDownCar
	var tuning: VehicleTuning = car.tuning
	var provider := HeightChannelTestHeightProvider.new()
	provider.mode = HeightChannelTestHeightProvider.Mode.PLATEAU
	provider.plateau_height = tuning.low_obstacle_clearance + 5.0
	car.set_height_query(provider)
	var start := rock.transform.origin - Vector2(300.0, 0.0)
	car.global_transform = Transform2D(PI * 0.5, start)
	var before := car.get_collision_count()
	var over_image: Image = null
	for tick in range(240):
		car.linear_velocity = Vector2(200.0, 0.0)
		await physics_frame
		if absf(car.global_position.x - rock.transform.origin.x) < 5.0:
			await RenderingServer.frame_post_draw
			over_image = viewport.get_texture().get_image()
		if car.global_position.x > rock.transform.origin.x + 100.0:
			break
	_check(car.get_collision_count() == before, "the raised production car clears the generated rock %s" % rock.stable_id)
	if over_image != null:
		_check(over_image.save_png(ProjectSettings.globalize_path("%s/seed-0-rock-cleared.png" % OUTPUT_DIRECTORY)) == OK, "rock clearance image saved")
	lines.append("seed=0 rock=%s cleared_at_height_px=%.1f collisions=%d" % [rock.stable_id, provider.plateau_height, car.get_collision_count() - before])
	viewport.queue_free()
	await process_frame
	return true


## The first rock whose straight +X approach (300 px before to 100 px after) has no tree within
## 60 px, so the only solid on the path is the rock being cleared.
func _rock_with_a_clear_approach(definition: TrackDefinition) -> OfftrackObjectPlacement:
	for candidate in definition.offtrack_objects:
		if candidate.archetype_id != &"rock":
			continue
		var origin := candidate.transform.origin
		var path_start := origin - Vector2(300.0, 0.0)
		var path_end := origin + Vector2(100.0, 0.0)
		var clear := true
		for other in definition.offtrack_objects:
			if other.archetype_id != &"tree":
				continue
			var closest := Geometry2D.get_closest_point_to_segment(other.transform.origin, path_start, path_end)
			if closest.distance_to(other.transform.origin) < 60.0:
				clear = false
				break
		if clear:
			return candidate
	return null


func _new_viewport() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	return viewport


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Height channel evidence capture passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Height channel evidence capture failed: %s" % failure)
	quit(1)
```

Compare `_new_viewport()` against the one in `tests/capture_offtrack_desktop_evidence.gd:180` and copy any extra settings it applies (world_2d sharing, physics interpolation) so both scripts capture the same way.

- [ ] **Step 3: Capture**

Run: `godot --path . --script res://tests/capture_height_channel_evidence.gd`
Expected: exit 0; `docs/evidence/height-channel/` holds the trace and at least seven PNGs. Open each PNG and confirm the apex frames show the body lifted off its shadow and the rock frame shows the car over the rock.

- [ ] **Step 4: Write the documentation**

`docs/height-channel.md` sections, in order: what the channel is (query, not trigger), ramp geometry and placement rules with the catalog table, the vehicle model (ground following, lift-off test, flight, landing formula, recovery, ground-only rules), obstacle levels and layers, presentation, determinism (domain seed, stable IDs, fingerprint), limitations (side entry pops the car up; no elevation elsewhere; no mid-air control by default; a landing on a rock is a collision), verification commands including all six mutation flags, tuning notes from Step 1, and evidence links.

`README.md`: add one sentence to the opening paragraph after the off-track sentence pointing to `docs/height-channel.md`; add the five new test commands to the Verification section.

`docs/poc-report.md`: add a `Height channel` subsection after `Architecture and catalog version` stating catalog version 1, ramp counts for seeds 0..19 from the trace, and the height fingerprint column in the seed ledger; keep #23 and #7 open and state that their reports must add ramp counts and one jump.

`docs/open-surface.md` and `docs/offtrack-objects.md`: where each says the height channel is out of scope or deferred, add `Implemented as sub-project C; see [Height channel](height-channel.md).`

- [ ] **Step 5: Run the full suite once more and commit**

Run the loop from Task 6 Step 6. Expected: every script exits 0.

```bash
git add tests/capture_height_channel_evidence.gd tests/capture_height_channel_evidence.gd.uid docs/height-channel.md docs/evidence/height-channel/ README.md docs/poc-report.md docs/open-surface.md docs/offtrack-objects.md data/
git commit -m "docs: document the height channel and record desktop evidence"
```

---

## Deferred (explicitly out of scope)

- **Continuous terrain elevation.** The `HeightQuery` seam is the boundary; a noise field or block levels can implement it later without touching the car.
- **Objects avoiding landing zones.** Ramps are placed before objects so a future catalog can exclude the landing zone; nothing does yet.
- **Mid-air control.** `airborne_steering_authority` exists as data and defaults to none. Any non-zero value is a tuning decision after the first drive.
- **Crashes, rolls, damage.** The car always lands on its wheels.
- **Retuning ramp geometry per seed.** One catalog, one shape.
