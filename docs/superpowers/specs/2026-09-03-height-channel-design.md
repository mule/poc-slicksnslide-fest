# Height Channel Design Spec

**Status:** Approved in design review on 2026-09-03.

**Sub-project:** C of three. Sub-project A opened the surface and B populated it. C adds the
height channel: jumping, air time, and landings, layered onto the existing 2D `RigidBody2D` game
rather than rebuilding in 3D.

## Goal

Give every circuit deterministic jump ramps, give the car a vertical channel so it leaves the
ground at a crest, flies a ballistic arc, and lands with a cost, and let a car in the air clear low
obstacles it would otherwise hit. The approach is the one recorded in the open-surface spec: GTA
1/2's sprite engine over a block world with discrete height levels. The world stays 2D; height is a
scalar the car carries and the world answers queries about.

Given the same track seed and catalog version, the project must reproduce the same ramp field on
desktop, Android, and Steam Deck. Ramp placement must never alter `geometry_fingerprint` or
`offtrack_object_fingerprint`.

## Scope

- A `HeightQuery` contract beside `SurfaceQuery`, with `TrackHeightMap` as the seeded provider.
- Deterministic placement of symmetric crest-shaped humps ("jump ramps") on straight runs of the
  centerline, with a stable ID, a SHA-256 fingerprint, and diagnostics.
- A vertical channel in `TopDownCar`: ground following on slopes, lift-off at a crest, ballistic
  flight under gravity, a landing that scrubs speed and briefly reduces grip.
- Two obstacle height levels. Rocks are low and can be cleared in the air; trees are tall and
  never can. The play-area boundary is always solid.
- Presentation: ramp wedges on the dirt, the car body lifting and scaling with height above a
  grounded shadow, draw order above y-sorted objects while airborne, dust off in the air and a burst
  on landing, diagnostics and a status line for air time.

## Non-goals

- Continuous terrain elevation, banked corners, or slopes anywhere other than on a ramp.
- Off-track ramps, natural bumps, or ramps that leave the road surface.
- Rolling, flipping, damage, or a crash state. The car always lands on its wheels.
- Mid-air control beyond a single tuning value for steering authority.
- Changes to lap counting. A gate crossed in the air counts; the detector is 2D and is not touched.
- New input actions, HUD panels, or touch controls.
- Any change to the manual reset, the automatic reset rules, or the checkpoint gates.

## What already exists

Verified in the current tree before this design was written.

**A per-tick position query seam.** `TopDownCar._integrate_forces()` calls
`_surface_query.sample_at(origin)` every physics tick and folds the answer into grip, drag, and
engine multipliers. The height channel is a second query against the same position, not a trigger.

**Domain-separated seeding.** `OfftrackSeed` derives `version|seed|domain` and per-cell child seeds
through a fixed SHA-256 mixing routine with known-vector tests. Ramp placement reuses the same
routine under a new domain so it cannot consume the road RNG.

**Straight-run detection.** `TrackGenerator._curvature_at()` and `STRAIGHT_CURVATURE = 0.0005`
already identify gentle spans; the start straight is chosen with them. Ramp eligibility is the same
measurement.

**Chunked solid colliders.** `OfftrackObjectCollisions` builds one `StaticBody2D` per chunk with a
circle per solid placement on `collision_layer = 1`. Splitting low and tall objects onto two layers
is a per-shape decision inside that builder.

**A grounded shadow.** `vehicle/top_down_car.tscn` already draws a `Shadow` polygon offset from the
body. Lifting the body away from it is the classic top-down cue for height.

## Architecture

Five components own the feature. Naming follows the off-track object set.

### `HeightQuery` and `HeightSample` (`track/height_query.gd`)

The position-based height contract the vehicle consumes. `sample_at(world_position)` returns a
`HeightSample` with `ground_height` in pixels above the flat plane and `gradient`, a world-space
`Vector2` holding `dh/dx` and `dh/dy`. The base implementation returns flat ground: height `0.0` and
a zero gradient, so a provider with no notion of height keeps the car on the ground rather than
erroring. Height uses the world's pixel unit and `WorldScale` conversions like every other length.

### `JumpRampPlacement` (`world/height/jump_ramp_placement.gd`)

A serializable `Resource` for one ramp. Data only: stable ID, `transform` whose origin is the crest
and whose `x` axis points along the ramp, `half_length` in pixels, `crest_height` in pixels, and
`width` in pixels (the road width at placement time, stored so the runtime never re-derives it). It
never holds nodes or callbacks.

### `HeightChannelCatalog` (`world/height/height_channel_catalog.gd`)

Versioned tuning data, checked in as `data/default_height_channel_catalog.tres`:

| Field | Default | Meaning |
| --- | --- | --- |
| `version` | 1 | Part of the seed and the fingerprint |
| `ramps_per_lap_min` / `max` | 2 / 4 | Requested count, drawn once per track from the domain seed |
| `half_length` | 12 m | Each face of the hump |
| `slope` | 0.12 | Rise per unit run; crest height is `slope * half_length` = 1.44 m |
| `approach_clearance` | 40 m | Straight run required before the hump |
| `landing_clearance` | 80 m | Straight run required after the hump |
| `spawn_exclusion` | 80 m | No ramp face within this of the spawn origin |
| `checkpoint_exclusion` | 40 m | No ramp face within this of a gate origin |
| `minimum_spacing` | 120 m | Between crests, measured along the centerline |
| `low_obstacle_height` | 1.0 m | Obstacles at or below this are on the low layer |

The exact values are data and may be tuned by evidence without changing component boundaries.

### `JumpRampPlacer` (`world/height/jump_ramp_placer.gd`)

Runs after the road candidate is accepted or the fallback stadium is built, and before off-track
objects. It walks the centerline once, collects maximal straight runs (every sample with curvature
at or below `STRAIGHT_CURVATURE`), and keeps runs at least `approach + 2 * half_length + landing`
long. It draws the requested ramp count from the domain seed, then for each eligible run in
centerline order draws a crest position inside the run's admissible window from a run-local child
seed, rejects candidates that violate spawn, checkpoint, or spacing exclusions, and stops when the
requested count is met. Placement is bounded by the finite run list; underfill is diagnostic and
never regenerates the road. Zero ramps is a valid result.

The placer returns a `JumpRampPlacementResult` with placements sorted by stable ID, a SHA-256
fingerprint over version, ID, transform, half-length, crest height and width at fixed decimal
precision, generation time, and diagnostics: eligible runs, requested count, placed count, and
rejection counts by rule.

### `TrackHeightMap` (`track/track_height_map.gd`)

Implements `HeightQuery` from a `TrackDefinition`. For a position it finds the ramp whose local
frame contains it: along-axis distance `|a| <= half_length` and lateral distance
`|l| <= width * 0.5`. Height is `crest_height * (1 - |a| / half_length)`; the gradient is
`±crest_height / half_length` along the ramp axis, zero laterally. Outside every ramp the ground is
flat. Ramps never overlap, so the first match is the only match. With at most four ramps per track a
linear scan is cheaper than an index; the contract test bounds its cost so that stays true.

## Decisions

### Ramps are symmetric humps, not kickers

A hump rises at `slope` for `half_length`, then descends at the same slope. At the crest the car's
vertical velocity is `+v * slope`, and the ground beneath it falls at `-v * slope`. The ballistic
height minus the ground height is `2 * slope * x - g * x^2 / (2 * v^2)`, positive for every
`x < 4 * slope * v^2 / g`, so a car cresting at any speed always leaves the ground and air time
scales with speed. A hump drives correctly in both directions and needs no cliff, no direction
flag, and no special case for entering it backwards. At low speed the car lands on the downslope
and gets a short hop; at 600 px/s it lands roughly 700 px past the crest.

### Height is a query, not a trigger

The car never learns where ramps are. Every tick it samples `HeightQuery` at its origin exactly as it
samples `SurfaceQuery`, and lift-off, ground following, and landing all fall out of comparing its
ballistic height against the ground beneath it. This keeps placement deterministic and testable
with a fixture provider, keeps `TopDownCar` free of node lookups, and leaves the seam open for
continuous elevation later.

### Two obstacle levels via collision layers

Godot 2D has no per-shape height, so height levels are collision layers, the discrete-levels model
from the recorded engine path. `OfftrackObjectArchetype` gains `obstacle_height`; rocks are 1.0 m,
trees 6.0 m. `OfftrackObjectCollisions` puts a shape on layer 2 when its archetype's
`obstacle_height` is at or below the catalog's `low_obstacle_height`, otherwise layer 1. The play
area boundary stays on layer 1. The car's mask is layers 1 and 2 while its height is below
`VehicleTuning.low_obstacle_clearance`, and layer 1 alone above it. A car descending through the
clearance height over a rock regains the rock and lands on it; that is a collision, not a bug.

`low_obstacle_clearance` and the catalog's `low_obstacle_height` must agree. The contract test
asserts equality, the same way `auto_reset_lost_distance < PLAY_AREA_MARGIN` is asserted today.

### Landing costs speed and grip, nothing else

Impact is the vertical speed relative to the ground at touchdown,
`velocity . gradient - vertical_velocity`, so landing on a downslope is gentler than landing flat.
Speed is multiplied by `1 - landing_speed_loss * impact_mps`, clamped to no less than 0.3, and a
recovery window of `landing_recovery_seconds` applies `landing_recovery_grip_multiplier` to lateral
grip. No damage, no crash, no roll. The window is also a period in which no safe pose is captured.

### The ground is followed, gravity acts along the slope

While grounded the car's height equals the ground height and its vertical velocity is the ground's
rate of change under it, `velocity . gradient`. Longitudinal acceleration gains
`-gravity * gradient . forward`, so climbing a face slows the car and descending one speeds it up.
Gravity is `WorldScale.metres(9.81)`, 122.6 px/s^2.

Each tick the car predicts its ballistic height at the next position and compares it with the
ground there. If the prediction is above the ground by more than a half-pixel tolerance the car is
airborne; otherwise it stays on the ground. This single test produces lift-off at a crest, keeps a
slow car on a downslope, and is the only place the grounded and airborne states meet.

### Airborne physics

No engine, brake, or reverse force. No rolling drag; aerodynamic drag still applies so the air is
never faster than the road. No lateral grip correction, so the car keeps whatever sideways velocity
it launched with. Steering authority is `airborne_steering_authority` times the ground value,
default 0.0. `max_safe_speed` still clamps. Surface sampling continues so the surface type under
the car is reported, but grip, drag, and engine multipliers are ignored in the air.

### Safe pose and automatic reset are ground-only

A safe pose is captured only while grounded, on flat ground, outside a landing recovery window, and
under the existing dirt, slip, and contact rules, so a reset never lands the car on a ramp face. The
automatic reset does not evaluate while the car is airborne and its stopped timer is cleared, so a
car in the air can never count as stuck or lost. A reset sets height and vertical velocity to zero.

### Gates count in the air

`CheckpointCrossingDetector` samples the car's 2D position and is not changed. A gate crossed
mid-flight is a legal crossing. Ramps are excluded from within 40 m of every gate origin so a gate
never sits on a ramp face, which keeps the lateral gate rule and the ramp's flat approach separate.

### Presentation

`TrackRuntime` draws one wedge per ramp between the dirt and the edge lines: a lighter dirt quad the
width of the road, a crest line, and a chevron on each face pointing at the crest. The vehicle scene
groups `Body`, `Windshield`, and `DirectionMark` under a `Lift` node; each frame `Lift.position.y`
is `-height * lift_pixels_per_pixel` and `Lift.scale` is `1 + height * scale_per_metre`, while
`Shadow` stays at its ground offset and fades with height. The car's `z_index` is raised to 1 while
airborne so it draws above y-sorted trees and rocks. Dust stops in the air; `Dust.restart()` fires
on landing. The diagnostics overlay adds one line: height in metres, vertical speed, airborne flag,
and air time. On landing after at least 0.5 s in the air the session shows `Air time  ·  1.32 s`
through the existing status panel, read from a consumable notice like the auto-reset one.

## Vehicle tuning additions

A new `Height channel` export group on `VehicleTuning`, baked in pixels like every other value:

| Field | Default | Note |
| --- | --- | --- |
| `gravity` | 122.6 px/s^2 | `WorldScale.metres(9.81)` |
| `airborne_steering_authority` | 0.0 | Fraction of ground steering rate |
| `landing_speed_loss` | 0.03 per m/s | Fraction of speed lost per metre-per-second of impact |
| `landing_recovery_seconds` | 0.35 | Reduced grip after landing |
| `landing_recovery_grip_multiplier` | 0.5 | Applied to `lateral_grip` during recovery |
| `low_obstacle_clearance` | 12.5 px | Must equal the catalog's `low_obstacle_height` |
| `air_time_notice_seconds` | 0.5 | Minimum flight before the status line shows |
| `lift_pixels_per_pixel` | 1.0 | Body lift per pixel of height |
| `scale_per_metre` | 0.04 | Body scale gain per metre of height |

## Determinism and seed isolation

Ramp placement uses a domain-separated seed derived from `version|track_seed|"height_channel"`
through the same mixing routine as off-track objects. That routine is extracted from `OfftrackSeed`
into a shared `DomainSeed` helper with the domain as a parameter; `OfftrackSeed` keeps its API and
its known-vector tests as a thin wrapper. Each eligible run derives a child seed from the domain
seed and the run's start sample index, so rejecting a candidate in one run cannot shift another
run's draw. Stable IDs are `h<version>:<track-seed>:<run-start-index>`.

The placer runs only after road acceptance and consumes nothing from the road RNG. It runs before
the off-track object placer and shares nothing with it. Adding, removing, or changing ramps cannot
alter `geometry_fingerprint` or `offtrack_object_fingerprint`.

## Failure behavior

- An empty ramp set is valid: the car never leaves the ground and every test that asserts flat
  behaviour still passes.
- A track with no eligible straight run reports zero ramps and the underfill reason; generation
  does not fail and the road is not regenerated.
- A `JumpRampPlacement` with a non-finite transform, non-positive half-length, crest height, or
  width is rejected by runtime validation and creates no wedge and no height; valid siblings still
  build. The height map skips invalid records.
- A car that enters a ramp from the side pops up to the ramp's height in one tick. This is accepted
  for the PoC and documented as a limitation.
- Failure to draw a wedge cannot change the height map, physics, lap progress, or reset state.

## Verification

Every verification function is typed `-> bool`, ends in `return true`, and is checked by its
caller, per `tests/harness_contract_test.gd`. Every mutation flag named below must exit non-zero.

### Contract suite (`tests/height_channel_contract_test.gd`)

- `HeightQuery` base returns flat ground and a zero gradient.
- `DomainSeed` known vectors, and `OfftrackSeed` still produces its existing vectors.
- `TrackHeightMap` against a fixture definition: zero before a ramp, linear rise, exact crest,
  linear fall, zero after, zero beside the road, and the gradient sign on each face.
- `VehicleTuning.low_obstacle_clearance` equals the catalog's `low_obstacle_height`.
- Ten thousand height queries against a four-ramp fixture complete under 20 ms.

### Placement suite (`tests/jump_ramp_placement_test.gd`)

Sweeps seeds `0..19` and checks repeatable placements and fingerprints; unchanged
`geometry_fingerprint` and `offtrack_object_fingerprint` against a definition generated with the
placer disabled; every crest on a sample whose curvature is at or below `STRAIGHT_CURVATURE`;
approach and landing clearances inside the same straight run; spawn, checkpoint, and spacing
exclusions; count within the catalog range or explicit underfill; identical rules on the fallback
stadium; placement p95 at or below 5 ms. Mutations `--break-height-seed` (draw from the road RNG,
which must change `geometry_fingerprint`) and `--break-clearance` (skip the checkpoint exclusion).

### Vehicle suite (`tests/vehicle_height_channel_test.gd`)

Uses a scripted `HeightQuery` fixture holding one hump at a known place, the way
`issue_4_test_surface_provider.gd` scripts surfaces. Checks: a car driven over the crest leaves the
ground with vertical speed within 5% of `speed * slope`; flight time matches the analytic
`(vz + sqrt(vz^2 + 2 g h)) / g` within one physics tick; landing distance matches the closed-form
aerodynamic-drag integral within 5%; speed after landing matches the loss formula; the recovery
window reduces lateral grip and then restores it; throttle in the air adds no speed; steering in the
air does not rotate the car at authority 0.0; a slow car on the downslope stays grounded; no safe
pose is captured in the air or on a ramp face; auto-reset does not fire in the air; a reset zeroes
height. Mutations `--break-gravity` (gravity 0, the car never lands) and `--break-landing` (no speed
loss).

### Obstacle level suite (`tests/airborne_obstacle_level_test.gd`)

Fixture placements with one rock and one tree. A probe at ground level collides with both; a probe
held above the clearance height passes over the rock and still collides with the tree; a probe
descending through the clearance over the rock collides; the mask is restored after landing; rock
shapes are on layer 2 and tree shapes on layer 1; the play-area bounds are on layer 1. Mutation
`--break-height-layers` (every solid on layer 1).

### Visual suite (`tests/jump_ramp_visuals_test.gd`)

One wedge per valid ramp, none for a rejected record; wedge width equals the placement width; body
lift, scale, and shadow alpha at heights 0, 1 m, and 3 m match the tuning formulas; `z_index` is 1
while airborne and 0 on the ground; dust is not emitting in the air.

### Session and smoke

`tests/issue_5_main_session_test.gd` gains: the snapshot reports `height_fingerprint`, seed restart
replaces the ramp set, and the air-time status line appears after a scripted flight.
`tests/headless_smoke.gd` loads the default height catalog.

### Evidence

Desktop evidence records ramp counts and fingerprints for seeds `0..19`, placement time, height
query cost, and captures of a car mid-air with a separated shadow, a landing, and a rock cleared in
the air, for at least three seeds. Android #23 and Steam Deck #7 validate the same commit and add
ramp counts and a jump to their reports. Desktop proof establishes completeness; it does not
substitute for the physical gates.

## Delivery graph

The parent C epic contains seven delivery tasks:

1. **Shared contract and data.** `HeightQuery`, `JumpRampPlacement`, `HeightChannelCatalog`,
   `DomainSeed`, `TrackDefinition` fields, `VehicleTuning` fields, `obstacle_height` on archetypes,
   default catalog data, and the contract suite. Lands first.
2. **Deterministic ramp placement and height map.** `JumpRampPlacer`, `TrackHeightMap`, and the
   placement suite with mutations.
3. **Vehicle height channel.** Ground following, lift-off, flight, landing, recovery, ground-only
   safe pose and auto-reset, diagnostics, and the vehicle suite with mutations.
4. **Airborne obstacle levels.** Layer split in the collision builder, mask toggle in the car, and
   the obstacle suite with its mutation.
5. **Presentation.** Ramp wedges, body lift and shadow, draw order, dust, overlay line, air-time
   notice, and the visual suite.
6. **Integration.** Generator, runtime, and session wiring; seed restart; session and smoke tests;
   full suite run.
7. **Tuning, evidence, and documentation.** Tune catalog and vehicle data, capture evidence,
   write `docs/height-channel.md`, update the README and PoC report.

After task 1, tasks 2 and 3 run in parallel against the frozen contract. Tasks 4 and 5 follow
task 3 because both edit the vehicle. Task 6 is the shared-file merge point. Task 7 closes.

Each implementation task owns its tests. There is no separate QA task.

## Acceptance criteria

- Seeds `0..19` generate deterministic ramp placements and a stable SHA-256 height fingerprint.
- Enabling, disabling, or changing ramp placement never changes the road or object fingerprints.
- Every ramp sits on a straight run with its approach and landing clearances, outside the spawn,
  gate, and spacing exclusions, on accepted and fallback tracks alike.
- A car cresting a ramp leaves the ground, flies an arc that matches the analytic model, and lands
  with the documented speed loss and recovery window.
- In the air the car clears rocks and never trees; on the ground it collides with both.
- No safe pose is captured and no automatic reset fires while the car is airborne.
- Gates crossed in the air count; ramps sit at least 40 m from every gate.
- Seed restart replaces the ramp set without retaining nodes or height state.
- Placement p95 is at most 5 ms and ten thousand height queries cost under 20 ms on the reference
  workstation, or the miss remains explicitly open.
- Every mutation flag named above exits non-zero.
