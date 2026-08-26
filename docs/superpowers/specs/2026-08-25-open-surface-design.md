# Open Surface Design Spec

**Goal:** The circuit stops being a walled corridor and becomes a preferred line across an open
surface. The car can leave the track, pays for it in grip and drag, and can be returned to the
racing line automatically if the player opts in.

**Sub-project:** A of three. B (sideline objects) and C (height channel) are out of scope here and
specified separately.

**Engine path:** This work assumes the project stays a 2D `RigidBody2D` game. Jumping and air time
will later be added as a height channel layered onto 2D — GTA 1/2's actual approach, a sprite
engine over a block world with discrete height levels — not by rebuilding in 3D. That decision is
recorded here because it is what makes this sub-project groundwork rather than throwaway work: an
open surface is where a jump lands.

## What already exists

Three capabilities this design consumes rather than builds. Each was verified in the current tree
before the design was written.

**Off-track physics.** `TrackSurfaceMap.sample_at()` already returns `SurfaceType.OFF_TRACK` with
`GRASS_GRIP = 0.55` and `GRASS_DRAG = 2.2` for any position beyond `track_width * 0.5` from the
centerline. The surface is unreachable today only because `TrackEdges` walls it off. Removing the
walls is what makes the existing model reachable; no new surface code is required.

**Safe-pose capture.** `TopDownCar._update_safe_pose_checkpoint()` records a pose only while the car
is on `DIRT`, below `tuning.safe_pose_max_slip`, and reporting zero contacts. `_safe_reset_pose` is
therefore already guaranteed to be a clean on-track pose, and the automatic reset needs no
destination logic of its own.

**Lap integrity.** `LapProgressTracker.cross_checkpoint()` requires strictly ordered checkpoint
indices and a positive forward dot, and `CheckpointCrossingDetector` only counts a crossing that
falls within `track_width * 0.5` of the gate centre. Cutting across the infield misses gates and
banks no lap. Lap validity survives fence removal unchanged.

## Decisions

### The fence is replaced by a distant containment rectangle, not softened

`_add_boundary_collision()` is deleted from `track_runtime.gd`. `_build_boundary_line()` is kept, so
the track edge stays visible while ceasing to be solid.

A single `StaticBody2D` named `PlayAreaBounds` carries four `SegmentShape2D` around
`definition.play_area`. The alternative of an offset polygon following the circuit was rejected: it
costs a generator pass and hundreds of shapes to express a boundary the player should rarely meet.

Rejected alternative: no containment at all. The background is a screen-space `ColorRect`, so an
unbounded world lets the car drive into featureless green with no cue to turn back and no
guarantee of recoverability.

Consequence worth naming: collision shapes per track fall from roughly 2,500 to 4. This retires the
performance caveat deferred by the world-scale plan, which flagged the per-track `SegmentShape2D`
count as the first thing to attack if track load time became noticeable.

### Containment is part of the track contract

`TrackDefinition` gains `play_area: Rect2`, computed by the generator as `bounds` grown by
`PLAY_AREA_MARGIN = WorldScale.metres(160.0)` (2,000 px, roughly 1.5 viewport widths of runoff).

Placing it in the definition rather than recomputing it in `TrackRuntime` keeps the containment
region assertable in generator tests and keeps consumers from each deriving their own margin.

### Checkpoint gates stay strict

Gates remain `track_width * 0.5` wide and widen automatically with the track. They are not widened
to accommodate off-track driving.

This is the risk/reward loop, and it needs no new code: leaving the track costs grip and drag, and
straying past a gate costs the lap. Without it, an open surface has no downside and the racing line
carries no meaning.

### Automatic reset fires on stuck or lost, whichever comes first

Two conditions, evaluated only while off-track, either sufficient:

```
while off_track:
  speed < auto_reset_stuck_speed for auto_reset_stuck_seconds  -> reset
  distance_to_centerline > auto_reset_lost_distance            -> reset
on returning to dirt: clear both timers
```

A single time-off-track rule was rejected for interrupting a deliberate wide line taken under full
control. A distance-only rule was rejected for failing to rescue a car wedged against the outer
boundary a few metres from the track.

Thresholds live in `VehicleTuning`, not as literals in the car, per the epic's architecture
boundary that seeds and physics tuning are data rather than scattered constants. Starting values,
expected to be tuned by play:

| Field | Value | Rationale |
| --- | --- | --- |
| `auto_reset_stuck_speed` | `WorldScale.metres(2.0)` = 25 px/s (7.2 km/h) | Slow enough that it cannot trigger during any controlled off-track run; terminal speed is 600 px/s. |
| `auto_reset_stuck_seconds` | 2.0 | Long enough to ride out a slow corner exit, short enough not to strand the player. |
| `auto_reset_lost_distance` | `WorldScale.metres(80.0)` = 1,000 px | Half the play-area margin, so "lost" resolves well before the car can reach the containment wall. |

`auto_reset_lost_distance < PLAY_AREA_MARGIN` is a required invariant, not a coincidence: if the
lost threshold exceeded the margin, a player with auto-reset enabled could be pinned against the
outer wall with only the stuck timer able to recover them. The invariant is asserted in tests.

The feature is opt-in via `SessionSettings.auto_reset_enabled`, defaulting to `false`. The existing
manual reset on `reset_car` is unchanged and remains available regardless.

## Changes by file

| File | Change |
| --- | --- |
| `track/track_definition.gd` | Add `@export var play_area: Rect2`. |
| `track/track_generator.gd` | `MIN_WIDTH` 125 → 200, `MAX_WIDTH` 175 → 280. Add `PLAY_AREA_MARGIN`; populate `play_area`. |
| `track/track_runtime.gd` | Delete `_add_boundary_collision()`. Replace `_build_collision()` body with a four-segment `PlayAreaBounds`. Keep boundary line rendering. |
| `track/surface_query.gd` | Add `distance_to_centerline(position: Vector2) -> float` to the interface. |
| `track/track_surface_map.gd` | Expose the existing private `_distance_to_centerline()` through the new interface method. |
| `vehicle/vehicle_tuning.gd` | Add `auto_reset_stuck_speed`, `auto_reset_stuck_seconds`, `auto_reset_lost_distance`. |
| `vehicle/top_down_car.gd` | Add `set_auto_reset_enabled()`; evaluate both conditions in `_integrate_forces` while off-track; set `_reset_requested`. |
| `session/session_settings.gd` | Add `auto_reset_enabled: bool = false`. |
| `session/main.gd` | Pass the setting to the car; surface an auto-reset status message. |

## Testing

Existing coverage that changes:

- `tests/track_collision_physics_test.gd` is repurposed. Its joint-traversal sweep and boundary
  tunnelling checks exist to prove the track walls stop a body without snagging it; with no walls
  they test nothing. The file becomes containment coverage: a car driven hard at the play-area edge
  is stopped and stays inside. `SegmentGrid` and surface coverage elsewhere are unaffected.

New coverage:

- Generator: `play_area` contains `bounds` with the expected margin, for every tested seed.
- Generator: fallback rate reported at the new width across 20 seeds.
- Surface: `distance_to_centerline()` agrees with `sample_at()` at the track-width boundary.
- Auto-reset: fires on the stuck condition; fires on the lost condition; does not fire when
  disabled; does not fire while off-track at speed near the racing line.
- Containment: a body driven at the play-area edge is stopped and remains inside.

## Risks

**Widening eats the generator's self-intersection clearance.** This is the one substantive risk. The
generator validates that the circuit does not overlap itself, and a wider ribbon needs more room to
satisfy that at the same `MIN_LAP_LENGTH` and `MAX_CURVATURE`. The current test bounds fallbacks at
2 of 20 seeds.

Mitigation is measurement, not assumption: record the fallback rate at the current width, apply the
widening, record it again, and report both. If it degrades, the levers are the retry budget and
`MIN_LAP_LENGTH`. The bound is not to be loosened silently to make a test pass.

**Off-track handling constants are unvalidated by play.** `GRASS_GRIP = 0.55` and `GRASS_DRAG = 2.2`
were authored for a surface no car could reach. They are provisional and should be expected to need
retuning once the surface is drivable. Treat the first drive as the tuning pass, not as acceptance.

## Out of scope

Sideline objects, the height channel, off-track visual treatment, camera limit changes, new surface
types, and any change to the manual reset. Elevation is deliberately deferred: it is specified as
sub-project C against the height-channel approach recorded above.
