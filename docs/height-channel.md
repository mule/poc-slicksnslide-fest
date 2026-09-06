# The height channel

The circuit is flat everywhere except where a generated jump ramp says otherwise. This document
describes the one vertical axis the game has: how ground height is asked for rather than triggered,
how ramps are placed, what the car does with a crest, what an airborne car can and cannot hit, and
what the drive and the captures actually measured.

## A query, not a trigger

`track/height_query.gd` is the whole seam:

```gdscript
class_name HeightQuery
func sample_at(world_position: Vector2) -> HeightSample   # { ground_height, gradient, on_feature }
```

The base class answers zero height and a zero gradient everywhere, so a car with no height source
behaves exactly as it did before the channel existed. `on_feature` (#48) says whether the position
lies inside a placed feature — anywhere on a ramp or its flank — as opposed to bare ground however
high or steep. It exists for one consumer, the car's safe-pose rule, which needs "on a ramp" and can
no longer read that off the total height. It is a boolean rather than the feature's height on
purpose: the consumer needs membership, and a height would invite "raised means feature", which a
dip carved into the road would falsify. `TrackHeightMap` is the production
implementation: it is constructed from a `TrackDefinition` and answers the terrain field built
from that definition's `terrain_seed` plus that definition's `jump_ramps`, summed (#47). A
definition without a terrain seed, such as a hand-built fixture, gets a flat base.

Nothing about a ramp reaches the car. There is no ramp node in the physics world, no `Area2D`, no
`body_entered`, no signal, and no per-ramp state on the vehicle. `TopDownCar` asks two questions
per physics tick — the ground under it, and the ground under the position it is about to move to —
and decides everything else from those two samples. That is what makes the seam replaceable: a
noise field, a set of block levels, or a hand-authored track could implement `HeightQuery` and
drive crests, drops, and flight without a line changing in `vehicle/`.

`TrackHeightMap` keeps per-ramp bounds in scalar packed arrays and rejects most queries with a
conservative reach test before doing any transform work. Its off-ramp answer is one shared
`HeightSample` instance, rewritten with the terrain sample on every return: read it freely, but
never write through it — a mutation corrupts only what is read before the next off-ramp query
rewrites it. The terrain sample itself allocates nothing: `TerrainField.sample_into` writes the
shared sample in place, and each octave keeps the coefficients of the cell its previous query fell
in, so a moving car's queries skip the corner lookups almost always.

**Query cost, and a deviation from #47's scope.** Issue #47 asked for the query cost to stay within
the existing budget of ten thousand queries in 20 ms. **That is not met.** A three-octave field costs
about 4 µs a query in GDScript even with no allocation and no lookups (the fade arithmetic alone is
about 3 µs), so ten thousand terrain-bearing queries cost about 40 ms; `tests/terrain_height_map_test.gd`
asserts the median of three runs under 60 ms, which is the assertion that covers the shipped map. The
20 ms assertion in `tests/jump_ramp_placement_test.gd` still passes, but its fixture has no terrain
seed, so it covers a ramp-only map and not the shipped path; the comment on that assertion says so.
Per tick the car's two queries cost about 8 µs, under a tenth of a percent of a 60 Hz tick.

## Ramp geometry and placement

A ramp is a symmetric hump. Its crest is the placement transform's origin, its faces run along the
transform's x axis, and it spans the full road width. Height falls linearly from the crest to zero
at each foot, so the gradient is a constant `slope` pointing at the crest from either side.

Beyond each road edge the hump fades to nothing over `flank_width` (250 px, 20 m, the off-track
catalog's `solid_clearance`, so no solid ever sits on a flank), along the quintic fade
`6t^5 - 15t^4 + 10t^3`. Both of its derivatives vanish at the road edge and at the flank's outer
edge, so the total height is continuous everywhere and its second derivative has no step for the
lift-off rule to read as a crest. The flank adds curvature of its own, bounded by
`crest * (|w''|max / flank^2 + |w'|max / (flank * half_length))` = 1.28e-3 per px, which together
with the terrain bound (1.875e-4) stays under the lift-off curvature at the off-track terminal
speed of 158.5 px/s (4.88e-3); the summed field launches a car crossing a flank only above
289 px/s (83 km/h). In a slide racer that is ordinary play, not an edge case: a car that crosses a
ramp edge sideways at 600 px/s hops, and the hop is bounded below. The flank is not part of the
height fingerprint, so the pinned fingerprints below hold.

**Ruling on the threshold (#47 fix round 1).** #49 bounded the terrain's curvature against
`max_safe_speed` (2.994e-4 per px); the flank is bounded against the off-track terminal speed
(4.883e-3), sixteen times looser, because no flank narrower than about 1350 px could meet the tighter
one and any flank that wide puts solids on flanks. The relaxation is kept, and its consequence is
bounded by assertion instead of by argument: the flank's whole relief is the crest height, so the
hop a fast crossing produces is bounded by geometry whatever the speed. `tests/terrain_height_map_test.gd`
drives a lateral crossing at `max_safe_speed` and asserts the peak height of the car above the map
under it stays under the ballistic apex of the fade's peak slope at that speed,
`(max_safe_speed * crest * 15/8 / flank)^2 / 2g` = 7.61 px, and under the crest height, 9 px.
Measured: lift-off at 601 px/s on the near flank with 41 px/s of vertical speed, 35 ticks in the air,
a 3.8 px peak hop, landing on the road. The #48 acceptance line covers terrain with no ramp present;
this is the check for the ramp-and-flank case at `max_safe_speed`.

`data/default_height_channel_catalog.tres`, catalog version 3:

| Field | Value | In metres |
| --- | ---: | --- |
| `half_length` | 150 px | 12 m per face |
| `slope` | 0.06 | 6 cm of rise per 1 m along the face |
| `crest_height()` | 9 px | 0.72 m, derived as `slope * half_length` |
| `approach_clearance` | 350 px | 28 m of straight before the near foot |
| `landing_clearance` | 400 px | 32 m of straight after the far foot |
| `minimum_run_length()` | 1050 px | 84 m, derived as approach + both faces + landing |
| `spawn_exclusion` | 1000 px | 80 m from the spawn origin |
| `checkpoint_exclusion` | 500 px | 40 m from any checkpoint origin |
| `minimum_spacing` | 1500 px | 120 m between two crests |
| `ramps_per_lap_min` / `max` | 2 / 4 | the count drawn per lap |

`JumpRampPlacer` runs after the road is accepted, on the accepted centerline:

1. It finds maximal runs of consecutive samples whose curvature is at most
   `TrackGenerator.STRAIGHT_CURVATURE` (0.0005) and keeps the runs at least `minimum_run_length()`
   long.
2. It draws a requested ramp count in `[ramps_per_lap_min, ramps_per_lap_max]` from the height
   domain seed.
3. Each run gets its own child seed and its own without-replacement shuffle of the crest positions
   that leave room for a whole approach and a whole landing zone inside that run. A rejection in
   one run therefore cannot shift the candidate stream of another, and no legal crest is tried
   twice.
4. A candidate is rejected if it is inside the spawn exclusion, inside a checkpoint exclusion, or
   closer than `minimum_spacing` to a crest already placed. Rejections are counted in
   `height_diagnostics` as `rejected_spawn_candidates`, `rejected_checkpoint_candidates`, and
   `rejected_spacing_candidates`.
5. Accepted placements are sorted by stable ID, so the record order does not depend on the order
   the runs happened to be visited in.

A stable ID is `h<catalog-version>:<track-seed>:<run-start-index>:<attempt-index>`.

Measured over seeds 0–19 with this catalog: every seed places at least one ramp, the mean is
**2.40** ramps per track, the maximum is 4, and seed 0 places 3. The full per-seed ledger, with
requested counts, eligible run counts, placement time, and all three fingerprints, is in
[`desktop-trace-seeds-0-4-9.txt`](evidence/height-channel/desktop-trace-seeds-0-4-9.txt).

## The vehicle model

`TopDownCar` keeps a single scalar `_height` and a single scalar `_vertical_velocity`. The car's
2D position is never affected by them: height is a separate channel that changes what the car may
collide with and how it is drawn, not where it is.

`_update_height_channel()` is the only place the grounded and airborne halves meet.

**Ground following.** While grounded, `_vertical_velocity` is the rate the ground under the car is
rising or falling — `linear_velocity.dot(gradient)`. The car follows the ground down as far as it
goes, but rises only as fast as the ground itself rises:

```gdscript
var rise_limit := maxf(maxf(_vertical_velocity, ground_rate_ahead) * delta, 0.0)
_height = minf(ahead.ground_height, _height + rise_limit)
```

On a continuous face those are the same number, so a face is ridden exactly. At a vertical step —
which every ramp has at its lateral boundary — the rise is refused, so the car cannot be carried up
onto a wall for free. Climbing a face also costs speed and descending one returns it, through
`longitudinal_acceleration -= gravity * gradient.dot(forward)`.

**The lift-off test.** There are two ways to leave the ground, because a one-tick lookahead sees a
drop-off and a crest differently:

```gdscript
var predicted := _height + _vertical_velocity * delta - 0.5 * gravity * delta * delta
var clears_the_ground_ahead := predicted > ahead.ground_height + LIFT_OFF_TOLERANCE
var ground_falls_away := ground_rate_ahead < _vertical_velocity - gravity * delta \
        and predicted > ahead.ground_height - LIFT_OFF_TOLERANCE
```

Over a drop-off the ballistic path clears the ground ahead outright. A crest is a break in the
gradient that the path straddles, and that margin shrinks to `-0.5 * gravity * delta^2` when a tick
lands exactly on the crest; there the question is whether the ground ahead falls away faster than
one tick of gravity can pull the car onto it. The second conjunct of `ground_falls_away` is what
rejects a vertical wall: driving into one, the car is on flat ground (rate 0) while the face behind
the wall reads as falling away, which would otherwise open a flight onto ground *above* the car.
`LIFT_OFF_TOLERANCE` is 0.05 px — small enough that a car cresting at walking pace still lifts off,
large enough that float noise on flat ground never does.

**Flight.** Lift-off vertical speed is `slope * speed` along the ramp axis, so how far the car flies
is a direct function of how fast it hit the ramp. In the air, gravity (122.625 px/s², which is
9.81 m/s² at 12.5 px per metre) is integrated into `_vertical_velocity` and then into `_height`;
engine force, braking, rolling drag and lateral grip are all multiplied by a zero ground authority,
and steering is multiplied by `airborne_steering_authority`, which is **0.0** by default. Only
aerodynamic drag still acts. An airborne car therefore keeps the heading and the trajectory it left
the crest with, and the throttle does nothing until it lands.

**Landing.** The impact is the closing rate between the car and the ground it meets:

```gdscript
var impact := maxf(ground_rate - _vertical_velocity, 0.0)
var kept := clampf(1.0 - landing_speed_loss * WorldScale.to_metres(impact), MIN_LANDING_SPEED_FRACTION, 1.0)
state.linear_velocity *= kept
```

`landing_speed_loss` is 0.03, so the car loses 3% of its speed per metre-per-second of impact, and
`MIN_LANDING_SPEED_FRACTION` (0.3) means no single landing can ever take more than 70% of it.

**Recovery.** A landing opens a `landing_recovery_seconds` (0.35 s) window in which lateral grip is
multiplied by `landing_recovery_grip_multiplier` (0.5). The car lands on its wheels, pointing where
it was pointing; the cost is that it slides for a third of a second afterwards. A flight of at
least `air_time_notice_seconds` (0.5 s) also leaves an air-time notice the session shows once.

**Ground-only rules.** The safety behaviours are deliberately blind to the air:

- `_update_safe_pose_checkpoint()` refuses to record a safe pose while `_airborne`, while the
  ground under the car is part of a placed feature (`on_feature`: anywhere on a ramp or its
  flank), during the landing recovery window, off dirt, above the slip limit, or while touching
  anything. A reset therefore never puts the car back onto a ramp face or into mid-air. Until #48
  the gate read the total height (`_ground_height > 0`), which meant the same thing while ramps
  were the only raised ground; see "Slopes" below for why that had to change.
- `_update_auto_reset()` does not run at all while `_airborne`, so a long jump over off-track
  ground can never be mistaken for a car that is stuck or lost. The same lost condition fires
  normally once the car has landed.
- `_apply_safe_reset()` re-seats `_height` from the height query at the reset pose and zeroes
  `_vertical_velocity`, `_airborne`, `_air_time`, and the recovery window.

## Obstacle levels and collision layers

Height decides what the car can hit, through two collision layers rather than through geometry.

| Layer | Bit | Holds |
| --- | ---: | --- |
| `TALL_LAYER` | 1 | solids taller than the catalog's `low_obstacle_height` — trees, at 75 px (6 m) |
| `LOW_LAYER` | 2 | solids at or below it — rocks, at 12.5 px (1 m) |

`OfftrackObjectCollisions.build()` puts each solid on the layer its archetype's `obstacle_height`
earns. Layers belong to bodies, not shapes, so a chunk that holds both a rock and a tree builds
**two** `StaticBody2D` bodies, one per height level, named `Chunk_<x>_<y>_low` and
`Chunk_<x>_<y>_tall`.

The car's side is one method:

```gdscript
func get_collision_level_mask() -> int:
	if _height > tuning.low_obstacle_clearance:
		return TALL_LAYER
	return TALL_LAYER | LOW_LAYER
```

`VehicleTuning.low_obstacle_clearance` (12.5 px) and `OfftrackObjectCatalog.low_obstacle_height`
(12.5 px) are pinned equal by `tests/height_channel_contract_test.gd`: the height at which the car
stops colliding with low obstacles is by definition the height of the tallest low obstacle. The
mask is a body property rather than integrator state, so it is applied from `_physics_process`
before the step and reflects the previous tick's height — at 60 Hz, at most 2 px of vertical travel
of staleness.

## Presentation

Ramps and airborne cars are drawn, not simulated, by `world/height/jump_ramp_visuals.gd` and
`TopDownCar._process()`:

- Each ramp is a lighter dirt quad the width of the road, a crest line across it, and a chevron on
  each face pointing at the crest, all under `TrackRuntime/JumpRamps` at `z_index = -1`.
- The car's `Lift` node is offset by `-_height * lift_pixels_per_pixel` (1 px per px of height) and
  scaled by `1 + metres * scale_per_metre` (+4% per metre), so the body rises off its own shadow
  and grows slightly. The offset is a child position, so it is in the car's own frame: the body
  separates from its shadow along the car's heading rather than toward the top of the screen. The
  cue is the gap, not its direction, and the shadow's own offset is in the same frame, so the two
  stay consistent — but it does mean a car pointing right reads as being *ahead* of its shadow.
- The shadow fades with height (`SHADOW_FADE_PER_METRE` 0.15, clamped to a 0.25 floor) and stays
  where the car actually is, so the gap between body and shadow is the readable cue.
- `z_index` becomes 1 while airborne, so a flying car draws over scenery it is passing.
- Dust stops while airborne; a landing restarts the one-shot landing burst.

## Determinism

Ramp placement is a separate deterministic domain from the road and from off-track objects.

- `DomainSeed.derive(catalog.version, definition.seed, "height_channel")` is the domain seed. The
  literal domain string and the `"%d|%d|%s"` text layout are a persistence contract: changing
  either changes every fingerprint on every platform.
- Each straight run draws from `DomainSeed.child(domain_seed, run_start, run_count)`.
- The placer never touches the road generator's RNG, and runs after road acceptance, so a change to
  the ramp catalog cannot move a road. `tests/jump_ramp_placement_test.gd` checks that the road and
  off-track fingerprints are unchanged across seeds while the height fingerprint responds.
- `TrackDefinition.height_fingerprint` is a SHA-256 over `version=<n>` and, per placement, its
  stable ID, origin to three decimals, rotation to six, half length, crest height, and width.
- Catalog version 3 is the current contract. Versions 1 and 2 were the pre-density-fix geometry;
  the version is part of both the domain seed and the fingerprint, so a bump necessarily
  invalidates both.

**The height fingerprint is downstream of road tuning, and no catalog version bump announces it.**
The bullets above document one direction only — a catalog change moves the height hashes. The
reverse coupling also exists and is unversioned:

- `JumpRampPlacer._straight_runs` reads `TrackGenerator.STRAIGHT_CURVATURE`
  (`world/height/jump_ramp_placer.gd:116`) to decide which samples are gentle, so retuning that
  threshold changes which runs are eligible, and therefore which crests are chosen.
- The placer derives `spacing` from `definition.lap_length` over the sample count
  (`world/height/jump_ramp_placer.gd:44`), which `TrackGenerator.SAMPLE_SPACING` sets. Changing it
  changes the sample count, the clearance-to-sample conversions, and the crest indices.

So a change to either road constant moves **every** height fingerprint on **every** seed while
`HeightChannelCatalog.version` stays at 3. The coupling runs one way and in the correct direction —
the placer runs after road acceptance and never touches the road RNG, so no ramp change can move a
road — but a reader who assumes "same catalog version, same height hash" will be wrong after a
road-tuning commit. `tests/jump_ramp_placement_test.gd` pins the road fingerprints against a
baseline, so a road-tuning change is caught there first; treat that failure as the signal that the
recorded height fingerprints need regenerating too.

## Slopes

#37 handled gradients through one line, `longitudinal_acceleration -= gravity * gradient.dot(forward)`,
and only ever exercised it on a 12 m ramp face. #48 measured what that line does on the whole
terrain field, and made the one design decision the field forced. `tests/vehicle_terrain_test.gd`
holds every number below as an assertion.

**The safe-pose gate.** The pre-terrain gate refused a pose wherever `_ground_height > 0`. That
was "not on a ramp" while ramps were the only raised ground; on a terrain field it is a different
rule entirely. Over seeds 0–19 the road sits above zero for between 24.9 % and 100 % of its length
(seed 13: all of it), and the gate zeroes its half-second timer on every refused tick, so on the
three seeds the suite drives it captured 58 %, 45 % and 34 % of the poses the rest of its own
conditions allow — and it captured a pose *on a ramp* on two of them, because a wedge summed onto
ground below zero reads as "not raised". Two replacements were weighed:

- *A flatness test* — capture only where the gradient is below some limit. Rejected. No limit
  separates ramp from terrain: a ramp face is a constant 0.06 plus whatever the terrain under it
  contributes (−0.049 to +0.049 across the roads surveyed), so any threshold either admits ramp faces
  where the terrain cancels the wedge's slope or refuses terrain that is provably driveable. And
  flatness is not what a safe pose is for: the car can drive away from any slope the catalog allows
  (the stall margin below is 12.7×), and `low_speed_stabilization` (50 px/s²) exceeds gravity on the
  steepest possible slope (15.2 px/s²), so a car reset onto a slope sits still.
- *"Not on a ramp"* — the original intent, read from the feature's own contribution rather than the
  total. **Chosen.** The height sample now carries `on_feature`, the map sets it on every ramp hit
  (flank included), the scripted test provider reports its hump, plateau and wall as features, and
  the gate reads `_on_feature`. On flat fixtures the two conditions are identical,
  and the three flat regression suites report the same 53, 12 and 44 assertion lines to the byte.

The rate is asserted, not the existence of a pose. During each lap the suite rebuilds the gate's
own eligibility from the car's public state (grounded, no recovery window, on dirt, under the slip
limit, not inside a ramp's footprint) and counts one expected capture per 30 consecutive eligible
ticks; the observed captures must reach 90 % of that and must include poses on ground above zero.
With the new gate the count matches exactly on every lap driven (128 of 128, 157 of 157, 160 of
160, with 54, 84 and 102 of them above zero); with the old gate reverted in code the same drives
report 74, 71 and 54 and the suite exits 1.

**Uphill.** The relationship is `gravity * gradient` against `engine_force / mass_kg`. From rest,
where drag is zero, the car stalls only when `g · s > engine / mass`, i.e. `s > 193.18 / 122.625 =
1.575` (a 57.6° slope). The catalog bounds each gradient component at 0.0875, so the directional
slope along any heading is under `√2 · 0.0875 = 0.1237`, a 12.7× margin. The twenty seeds' roads
reach 0.0488 (the steepest climb along a road is 0.0486, seed 3). Balancing engine, slope and drag,
the terminal speed on level ground is 600.0 px/s and on the steepest slope the catalog allows
573.3 px/s: the worst climb costs 4.4 % of top speed. Driven: full throttle from rest on seed 3's
steepest climb reaches 421.5 px/s in three seconds, above the 403.9 px/s the slope bound allows and
below the 432.4 px/s of the same run on level ground, with speed and progress monotone on every
tick.

**Downhill.** Coasting, drag balances gravity at 127.6 px/s on the steepest slope the catalog
allows; on seed 18's steepest road descent (−0.0465) a car released at 30 px/s reaches 36 px/s after
two seconds and peaks at 40.7. Under full throttle the drag balance on the steepest possible slope
is 625.6 px/s, **under the 640 px/s clamp**: on shipped terrain drag is what holds every descent
and the clamp is a backstop with 2.3 % of margin. Driven, a full-throttle descent from 550 px/s
reaches 579.7 px/s against 576.8 on level ground. So a terrain drive cannot show the clamp working;
the suite proves it on a synthetic 0.5 plane, six times the catalog's bound, where engine plus
gravity would balance drag at 698.5 px/s and the car instead sits at 640.000 for the whole last
second. Under `--break-speed-clamp` (clamp raised to 2000) the same drive peaks at 683.2.

**No spurious lift-off, in the integrator.** #49 asserts `|h″| < g / max_safe_speed²` in the field's
arithmetic. The suite pins a production car at 640 px/s and drives 24 straight lines through three
seeds' play areas on bare terrain (ramps stripped: a ramp launches by design, and #47 sanctioned the
flank hop), 36 709 ticks in all, never airborne, riding the terrain within 0.003 px, across
curvature up to 1.10e-4 per px (58 % of the bound, 37 % of the lift-off threshold). Under
`--break-terrain-lift-off` (amplitude ×4, curvature 4.38e-4) the same drive is airborne on 44 ticks.

**A lap.** A pure-pursuit driver with a curvature governor drives seeds 0, 4 and 9 on terrain and
on the flat base with the same ramps:

| Seed | Terrain lap | Flat lap | Top speed (terrain) | Top uphill | Top downhill | Slowest |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 69.0 s | 69.1 s | 560.8 px/s | 560.8 | 515.0 | 182.5 |
| 4 | 84.5 s | 84.5 s | 582.5 px/s | 576.0 | 561.0 | 182.3 |
| 9 | 86.2 s | 86.2 s | 570.3 px/s | 557.9 | 550.9 | 181.6 |

No lap fired an automatic reset, none held the car under the stuck speed for a second, and terrain
moved no lap time by more than three ticks. After the terrain lap a manual reset lands the car on
its last pose at the terrain's own height (−0.4 to −15.7 px on the poses hit), on dirt, off any
ramp, and it drives away under throttle; a car stranded off-track beside seed 3's steepest climb is
reset by the automatic rule onto the climb, sits still on it for two seconds, then climbs away.

**Two things a fixture must know.** `_integrate_forces` runs at the start of an iteration on the
transform the previous step produced, so (1) a car *seeded* with a velocity is moved one step by
the server before its first tick sees it; seated where it was placed, its ride height is stale by
one tick of vertical travel, and on a descent steeper than the lift-off tolerance per tick (0.43 px
at 550 px/s on seed 18) it lifts off and pays a landing. The suite seats a seeded car on the ground
one step along its velocity. (2) After a tick, `get_height()` is the height the car computed for
the ground *one step ahead*, so it must be compared with the ground at `position + velocity * step`;
compared with the ground under the car it reads one tick of vertical travel off, which is what the
0.17 px "gap" in #47's crossing figures is. Neither affects the game, whose car only ever gains
velocity by driving.

## Limitations

- **Crossing a ramp's lateral edge passes the car under the ramp — closed in #47.** The height map
  gave every ramp a vertical wall at its lateral boundary, so a car entering from the side drove
  under the wedge. The wedge now fades over a flank beyond each road edge, and
  `tests/terrain_height_map_test.gd` drives a production car across it at the off-track terminal
  speed: its ride height tracks the map within 0.18 px on every tick and it arrives on the crest
  line at the crest height. Under `--break-side-wall`, or with the falloff reverted to the hard
  cut in code, the same drive reads a 9.0 px gap and a zero wedge height.
- **A fast lateral flank crossing hops.** The flank replaced the wall with a real slope, and above
  289 px/s sideways its curvature exceeds the lift-off rule's threshold, so a car crossing a ramp
  edge at speed leaves the ground: at 601 px/s, 41 px/s of vertical speed, 0.58 s in the air, a
  3.8 px (0.3 m) peak above the ground, landing on the road. Bounded by assertion at 7.61 px (the
  ballistic apex of the fade's peak slope at `max_safe_speed`) and by the 9 px crest height; see the
  ruling above. It is a hop, not a launch, but it is new behaviour and the #52 drive should say how
  it reads.
- **No rock can be cleared from a generated ramp.** The behaviour works — a car above the clearance
  height passes over a rock and still hits a tree — but ramp placement and object placement never
  bring the two within reach of each other, so it is a capability rather than something that
  happens in play. See the tuning notes below for the measurement.
- **No elevation anywhere else — closed in #47.** The ground is now the terrain field of #49
  under the whole play area, with the ramps summed onto it, so the road climbs and drops with it.
  Nothing renders that yet; #50 makes it legible.
- **No mid-air control.** `airborne_steering_authority` is data and defaults to 0.0. Any non-zero
  value is a tuning decision no drive has justified yet.
- **A landing on a solid is a collision.** Nothing keeps objects out of a landing zone; ramps are
  placed before objects, so a future catalog could exclude the zone, but none does.
- **No crashes, rolls, or damage.** The car always lands on its wheels.
- **One catalog, one shape.** Ramp geometry is not retuned per seed.

## Verification

```sh
godot --headless --path . --script res://tests/height_channel_contract_test.gd
godot --headless --path . --script res://tests/jump_ramp_placement_test.gd
godot --headless --path . --script res://tests/vehicle_height_channel_test.gd
godot --headless --path . --script res://tests/airborne_obstacle_level_test.gd
godot --headless --path . --script res://tests/jump_ramp_visuals_test.gd
godot --headless --path . --script res://tests/issue_5_main_session_test.gd
godot --headless --path . --script res://tests/track_collision_physics_test.gd
godot --headless --path . --script res://tests/vehicle_terrain_test.gd
```

`tests/vehicle_terrain_test.gd` steps physics at 600 ticks a second under a time scale of 10, which
keeps the production 1 / 60 s step (it pins that against the integrator's model to 0.05 px/s) and
runs its 70 000-odd ticks in about two minutes.

`tests/vehicle_height_channel_test.gd` runs its analytic-arc case twice, once on the suite's own
0.12 hump and once on the catalog's shipped 0.06 slope, and every assertion in that case is prefixed
with the slope it came from. The suite's other cases use the steeper hump only; it is a harsher test
of the same model, not the shape the game ships.

The graphical evidence capture is not headless:

```sh
godot --path . --script res://tests/capture_height_channel_evidence.gd
```

Eleven mutation flags exist to prove those suites are load-bearing. Each must exit non-zero, and each
must do so on its own assertion rather than on a load error — check the first `FAIL:` line, not
just the exit code:

```sh
godot --headless --path . --script res://tests/jump_ramp_placement_test.gd -- --break-height-seed
godot --headless --path . --script res://tests/jump_ramp_placement_test.gd -- --break-clearance
godot --headless --path . --script res://tests/jump_ramp_placement_test.gd -- --break-density
godot --headless --path . --script res://tests/vehicle_height_channel_test.gd -- --break-gravity
godot --headless --path . --script res://tests/vehicle_height_channel_test.gd -- --break-landing
godot --headless --path . --script res://tests/airborne_obstacle_level_test.gd -- --break-height-layers
godot --headless --path . --script res://tests/track_collision_physics_test.gd -- --break-collision
godot --headless --path . --script res://tests/terrain_height_map_test.gd -- --break-side-wall
godot --headless --path . --script res://tests/terrain_height_map_test.gd -- --break-flank-curvature
godot --headless --path . --script res://tests/vehicle_terrain_test.gd -- --break-terrain-lift-off
godot --headless --path . --script res://tests/vehicle_terrain_test.gd -- --break-speed-clamp
```

| Flag | Breaks | First failing assertion |
| --- | --- | --- |
| `--break-height-seed` | reuses the road seed for the height domain | `seed 0 height fingerprint repeats` |
| `--break-clearance` | zeroes the checkpoint exclusion only; the spawn and spacing exclusions are untouched | `seed 1 height fingerprint repeats` |
| `--break-density` | restores a pre-fix landing clearance (2000 px, so `minimum_run_length` goes 1050 → 2650) and starves placement: counts fall from 3 / 20 non-empty / mean 2.40 to 0 / 5 / mean 0.35 | `seed 0 places at least one ramp` |
| `--break-gravity` | zeroes gravity, so nothing ever lands | `slope 0.120: the car lands within 300 ticks` |
| `--break-landing` | zeroes the landing speed loss and recovery | `slope 0.120: the landing is hard enough that the loss assertion is live` |
| `--break-height-layers` | puts every solid on the tall layer | `the rock is a low collider` |
| `--break-collision` | removes the containment boundary | `seed 0 probe driven right stays inside the play area` |
| `--break-side-wall` | zeroes the fixture ramp's flank width, restoring the hard lateral cut | `on a flat base: the car's ride height tracks the map under it on every tick (worst gap 9.0000 px)` |
| `--break-flank-curvature` | quarters the flank width, so its curvature breaks the crossing-speed bound | `terrain plus flank curvature (0.015289650) stays under the lift-off curvature at the off-track terminal speed (0.004883371)` |
| `--break-terrain-lift-off` | quadruples the terrain amplitude under the lift-off drive | `bare terrain never lifts the car off at max_safe_speed in the real integrator (44 airborne of 36709 ticks over 24 lines)` |
| `--break-speed-clamp` | raises max_safe_speed to 2000 under the clamp drive | `on the synthetic descent the car never exceeds the shipped max_safe_speed (peak 683.215 of 640.0 px/s)` |

The safe-pose capture-rate assertion has no flag: it is demonstrated by reverting the gate in
`vehicle/top_down_car.gd` to `_ground_height > 0.0`, which fails the rate on all three driven seeds
(74 of 128, 71 of 157, 54 of 160) and records a pose on a ramp on two of them.

## Tuning notes

These come from driving the production session on seeds 0, 4, and 9 in a graphical run: the car
placed on each ramp's approach 420 px out at 600 px/s — the speed a full-throttle car actually
holds on dirt, not the 640 px/s `max_safe_speed` clamp — with the throttle down, and every frame
of the approach, the flight, and the landing rendered and measured. The stills below are the
frames the numbers were read from. **No tuning value was moved by this pass**; the reasoning for
the one value that was questioned is at the end of this section.

Two measurement frames are used deliberately and should not be mixed:

- **Speeds attached to a jump are crest speeds**, measured on the first airborne tick, not the
  speed the car was seated at. The car is under throttle over the approach, so the two differ by
  a lot — a 200 px/s seat crosses the crest at 383.8 px/s.
- **Sideways distances are measured outward from the road edge.** That is the frame the
  off-track catalog's `solid_clearance` is expressed in. A distance measured from the crest
  would double-count the road's half width when compared against it, because a ramp spans the
  full road width and a car can launch anywhere across it.

### Does the approach read as a ramp before you reach it?

Yes, comfortably. At 250 px (20 m) out — about a third of a second at speed — the wedge, its
crest line, and the chevron pointing at the crest are all on screen well ahead of the car, and
the lighter dirt separates cleanly from the road. See
[`seed-0-approach.png`](evidence/height-channel/seed-0-approach.png). The ramp spans the whole
road width, so there is no line to choose around it; the only decision the approach offers is how
fast to take it, which is the right decision for this shape.

### Is lift-off tied to speed?

Directly. Lift-off vertical speed is `slope * speed_at_the_crest`, so the apex is quadratic in
the crest speed. The same ramp on seed 0, seated at nine speeds and measured at the crest:

| Seat | Crest speed | Apex | Air time | Above the 12.5 px clearance? |
| ---: | ---: | ---: | ---: | --- |
| 200 px/s | 383.8 px/s (110.5 km/h) | 11.04 px (0.883 m) | 0.600 s | no |
| 250 px/s | 400.9 px/s (115.5 km/h) | 11.17 px (0.893 m) | 0.600 s | no |
| 300 px/s | 422.6 px/s (121.7 km/h) | 11.49 px (0.919 m) | 0.617 s | no |
| 350 px/s | 447.0 px/s (128.7 km/h) | 11.86 px (0.949 m) | 0.650 s | no |
| 400 px/s | 473.8 px/s (136.5 km/h) | 12.38 px (0.990 m) | 0.667 s | no |
| 450 px/s | 502.1 px/s (144.6 km/h) | 12.60 px (1.008 m) | 0.683 s | yes |
| 500 px/s | 532.4 px/s (153.3 km/h) | 13.06 px (1.045 m) | 0.700 s | yes |
| 550 px/s | 564.4 px/s (162.5 km/h) | 13.86 px (1.109 m) | 0.733 s | yes |
| 600 px/s | 597.2 px/s (172.0 km/h) | 14.48 px (1.159 m) | 0.767 s | yes |

A crawl still leaves the ground — that is deliberate, and `LIFT_OFF_TOLERANCE` is tuned for it —
but it is a bounce. What grows with speed is mostly distance: the car keeps its speed in the air,
so the slowest row covers roughly 230 px of ground and the fastest roughly 458 px.

### Does the landing feel like a cost rather than a wall?

A cost. Across the three driven seeds:

| Seed | Ramp | Crest speed | Apex | Air time | Speed before | Speed after | Kept |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | `h3:0:0:2` | 172.0 km/h | 14.48 px (1.159 m) | 0.767 s | 143.6 km/h | 122.4 km/h | 0.852 |
| 4 | `h3:4:0:4` | 172.0 km/h | 14.48 px (1.159 m) | 0.767 s | 143.6 km/h | 122.4 km/h | 0.852 |
| 9 | `h3:9:0:0` | 172.0 km/h | 14.48 px (1.159 m) | 0.767 s | 143.6 km/h | 122.4 km/h | 0.852 |

The impact term takes a slice, not a stop: the 30% floor is nowhere near being approached, and
most of the drop between the crest and the landing is the aerodynamic drag of the flight rather
than the impact. What is actually paid is the 0.35 s of halved grip afterwards — the car lands
pointing where it was pointing and then slides for a third of a second, so a jump taken into a
corner costs a line. The dust burst and the air-time notice both fire, so the landing reads as
having been paid for. Driving away under power on the far side is the normal outcome.

### Is a rock ever cleared in practice?

**No — and not for the reason it looked like.** This is the finding of the drive, so the numbers
are here in full.

The vertical half of the behaviour is sound. A production car crossing a generated crest at the
speed it can actually hold on dirt peaks at **14.48 px (1.159 m)** against a `low_obstacle_clearance`
of 12.5 px, and its mask does drop the low layer up there. Slower crossings do not: the sweep
above brackets the floor between a crest speed of **473.8 px/s** (apex below the clearance) and
**502.1 px/s** (apex above it), so roughly 136-145 km/h at the crest is what it takes, against the
172.0 km/h a full-throttle approach reaches. The floor sits at about 79% of that ceiling, so only
the top fifth of the speed range clears — a fair price for a stunt, and not the problem.

The horizontal half is what makes it unreachable. A flight lasts about 0.767 s, cannot be steered
(`airborne_steering_authority` is 0), and a ramp always sits on a straight run, so the car comes
down on the road it took off from. The sweep covers every launch heading from 0° to 85° in 5°
steps at five lateral seats across the road — a ramp spans the full road width, so a car crossing
it near the edge launches that far off the centreline and carries the offset through the flight.
68 of 90 passes left the ground. Measured outward from the road edge:

| Measurement | Value |
| --- | ---: |
| Furthest past the road edge while airborne at any height | 192.2 px |
| Furthest past the road edge while above the 12.5 px clearance | 95.4 px |
| Nearest an off-track solid may sit to the road edge (`solid_clearance`) | 250 px |
| Nearest one actually sits, measured over seeds 0-19 | 267.8 px |

The same sweep in the frame-independent form: a flight drifts at most 95.4 px sideways from the
line it launched on while above the clearance height, and 192.2 px over the whole flight.

So: **a solid sits at least 250 px outside the road edge; a flight carries the car at most
95.4 px past that edge while it is high enough to clear a rock; the gap is about 155 px.**
Even ignoring height entirely, the whole flight envelope reaches 192.2 px past the edge against the
267.8 px where the nearest solid actually sits, so the margin survives that reading too.

**Why `low_obstacle_clearance` was not lowered.** The obvious remedy is to lower the clearance so
the car counts as "up" sooner. It cannot work, because the clearance is a vertical threshold and
the missing distance is horizontal: even a clearance of zero would only extend the reach past the
edge to 192.2 px, the whole-envelope figure above, which is still short of the corridor.
Lowering it would also force the rock archetype's `obstacle_height` down with it — otherwise
rocks leave the low layer entirely and become permanently unclearable — which redefines a 1 m
boulder as a pebble that still stops a car dead on the ground. That is a cost with no benefit, so
the catalog and the tuning were left alone, and `tests/height_channel_contract_test.gd` still pins
`VehicleTuning.low_obstacle_clearance` equal to `OfftrackObjectCatalog.low_obstacle_height` at
12.5 px, with the rock at exactly that height and the tree at 75 px.

The constant that actually governs this is `OfftrackObjectCatalog.solid_clearance` (250 px), the
recovery corridor that deliberately keeps trees and rocks away from the road. Bringing a rock
within reach of a jump means either admitting a low solid into that corridor near a landing zone —
a placement change that would move every seed's off-track fingerprint — or giving ramps a steeper
geometry, which was just rebalanced against the landing guarantee. Both are placement decisions,
not tuning, and neither belongs in an evidence pass.

`tests/capture_height_channel_evidence.gd` asserts the gap rather than merely reporting it, in two
directions and in one frame: the above-clearance reach past the edge against the catalog rule, and
the whole-envelope reach past the edge against the nearest solid seeds 0-19 actually place. A
later placement change that brings a solid within reach of a flight fails that check and sends
whoever made it back to this section.

### What the rock-clearance still actually shows

The layer behaviour itself is proven against a real generated rock, with a scripted height source
rather than a ramp. The capture takes rock `v1:0:-10:12` from seed 0 — a generated placement with a
real chunked static collider on the low layer — holds the production car at **14.48 px (1.159 m)**,
the apex a real ramp produced in the runs above, and drives it over the rock at 57.6 km/h. The
height comes from `HeightChannelTestHeightProvider` in plateau mode, not from a ramp, because as
measured above no generated ramp is near enough to a rock to supply it. The car's mask holds only
the tall layer on every one of the 17 physics ticks on which the two collision circles overlap, and
the collision count does not move. The still is taken only once the car is clear of that window:
waiting for a frame to be drawn lets several physics ticks pass, so taking it inside the window
would skip ticks the check is meant to cover. The car drives through the rock's centre rather than
grazing it — closest approach 0.01 px. See
[`seed-0-rock-cleared.png`](evidence/height-channel/seed-0-rock-cleared.png).
`tests/airborne_obstacle_level_test.gd` proves the other half of the same rule: the same raised
car still collides with a tree, and a car that has fallen back through the clearance hits the rock.

### One thing the capture had to work around

`ApplicationLifecycle` pauses the whole `SceneTree` on `NOTIFICATION_APPLICATION_FOCUS_OUT`, which
is correct for a game and fatal for an unattended capture: a paused tree still emits
`physics_frame`, so a drive loop keeps counting ticks while the car sits still and the run
silently measures nothing. The capture disconnects that one signal for the life of each session it
opens and asserts the tree is running before it measures anything. Nothing else about the session
is modified.

## Evidence

Everything below is under [`docs/evidence/height-channel/`](evidence/height-channel/) and is
regenerated by one graphical command; see
[`desktop-validation.md`](evidence/height-channel/desktop-validation.md) for the environment,
method, and the complete per-seed tables.

| File | Shows |
| --- | --- |
| [`desktop-trace-seeds-0-4-9.txt`](evidence/height-channel/desktop-trace-seeds-0-4-9.txt) | the seeds 0-19 ramp ledger with all three fingerprints, the three driven jumps, the crest-speed sweep, the flight-reach and corridor measurements, and the rock pass |
| [`seed-0-approach.png`](evidence/height-channel/seed-0-approach.png) | the ramp 250 px out, car grounded at speed |
| [`seed-0-apex.png`](evidence/height-channel/seed-0-apex.png) | the apex, body lifted clear of its own shadow, height and air time on the overlay |
| [`seed-0-landing.png`](evidence/height-channel/seed-0-landing.png) | the first grounded frame, air-time notice showing |
| [`seed-4-approach.png`](evidence/height-channel/seed-4-approach.png) | the ramp 250 px out, car grounded at speed |
| [`seed-4-apex.png`](evidence/height-channel/seed-4-apex.png) | the apex, body lifted clear of its own shadow, height and air time on the overlay |
| [`seed-4-landing.png`](evidence/height-channel/seed-4-landing.png) | the first grounded frame, air-time notice showing |
| [`seed-9-approach.png`](evidence/height-channel/seed-9-approach.png) | the ramp 250 px out, car grounded at speed |
| [`seed-9-apex.png`](evidence/height-channel/seed-9-apex.png) | the apex, body lifted clear of its own shadow, height and air time on the overlay |
| [`seed-9-landing.png`](evidence/height-channel/seed-9-landing.png) | the first grounded frame, air-time notice showing |
| [`seed-0-rock-cleared.png`](evidence/height-channel/seed-0-rock-cleared.png) | the production car over generated rock `v1:0:-10:12` with the low layer out of its mask |

