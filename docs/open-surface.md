# The open surface

The circuit has no walls. This document describes what actually stops the car, what it costs to leave the dirt, why checkpoint gates still punish straying, and the opt-in automatic reset that can bring a lost car back.

## No walls, one distant boundary

`TrackRuntime._build_collision()` builds exactly one `StaticBody2D`, named `PlayAreaBounds`, made of four `SegmentShape2D` edges around a single rectangle: `TrackDefinition.play_area`. That rectangle is not the track's road edges — it is `TrackGenerator`'s combined bounds of the track's own left/right boundary polylines (`definition.bounds`), grown outward by a fixed margin:

```
PLAY_AREA_MARGIN := 2000.0  # px = 160 m at 12.5 px/m
definition.play_area = definition.bounds.grow(PLAY_AREA_MARGIN)
```

That is the only collision geometry the car can hit. The gold `LeftEdge`/`RightEdge` `Line2D` nodes drawn along the road's boundary polylines, and the grass-shoulder/dirt `Line2D` ribbons under them, are purely visual — none of them carries a `CollisionShape2D`. A car can drive straight through the painted edge line and keep going; nothing physical happens until it reaches the far rectangle, roughly a track-width's worth of circuit plus 160 m of open ground away in every direction. The code comment on `_build_collision()` puts it at "roughly 1.5 viewport widths" of recovery room before the car meets anything solid.

This also means the collision cost dropped sharply from the fenced version: four segments per track instead of one `SegmentShape2D` per centerline sample on both boundaries (previously on the order of 2,500).

## The off-track penalty is two layers stacked

Leaving the dirt costs the car in two independent places, and the two multiply together.

**`TrackSurfaceMap`** (`track/track_surface_map.gd`) classifies a world position as `DIRT` (within half the track width of the centerline) or `OFF_TRACK`, and returns a grip/drag multiplier pair for each:

| Surface | Grip multiplier | Drag multiplier |
| --- | --- | --- |
| `DIRT` | 1.0 | 1.0 |
| `OFF_TRACK` | 0.55 (`GRASS_GRIP`) | 2.2 (`GRASS_DRAG`) |

**`VehicleTuning`** (`vehicle/vehicle_tuning.gd`) applies its own multipliers on top, keyed by the same surface type, in `TopDownCar._sample_surface()`:

| Tuning field | `DIRT` value | `OFF_TRACK` value |
| --- | --- | --- |
| grip multiplier | `dirt_grip_multiplier` = 0.92 | `off_track_grip_multiplier` = 0.46 |
| drag multiplier | `dirt_drag_multiplier` = 1.0 | `off_track_drag_multiplier` = 2.6 |

The two layers multiply: `_surface_grip = sample.grip_multiplier * tuning_grip`, `_surface_drag = sample.drag_multiplier * tuning_drag`. Off the track that works out to:

- effective grip: `0.55 * 0.46 = 0.253` — roughly a quarter of on-track cornering grip
- effective drag: `2.2 * 2.6 = 5.72` — nearly six times on-track rolling/aerodynamic drag

On top of that, `VehicleTuning.off_track_engine_multiplier` (0.62) cuts engine (and reverse) force directly whenever the car is `OFF_TRACK`; this multiplier is tuning-only and does not come from the surface map, since `SurfaceSample` carries only grip and drag. So an off-track car corners on about a quarter of its normal grip, drags nearly six times as hard, and pulls with 62% of normal engine force — a car that strays off the dirt slows down fast and turns poorly while it does it.

These constants (`GRASS_GRIP`, `GRASS_DRAG`, and the three `off_track_*` tuning fields) were authored back when the track was fenced and off-track terrain was unreachable. Now that the surface is genuinely drivable, expect them to be revisited in a tuning pass once someone has actually driven it — that pass is out of scope here.

## Checkpoint gates stay strict — straying costs the lap

Nothing about lap validity got more forgiving. A checkpoint only counts as crossed within half the track width of the gate's own centre:

```gdscript
# session/checkpoint_crossing_detector.gd
if absf((crossing_point - checkpoint.origin).dot(lateral)) > _definition.track_width * 0.5:
    continue
```

With the widened 200–280 px track (16–22.4 m), that is a gate 100–140 px (8–11.2 m) wide either side of centre — generous relative to the car, but finite. And `LapProgressTracker.cross_checkpoint()` still requires checkpoints in strict order (`checkpoint_index == next_checkpoint`) in the forward direction (`forward_dot > 0.0`); a checkpoint crossed out of order, backward, or outside its lateral gate is simply ignored, not queued.

Put together: because there is no wall forcing the car back onto the road, a driver can cut wide through open ground around a corner. But if that cut carries them laterally more than half a track width past the next gate's centreline, the crossing never registers, and the car has to come back through the gate properly to keep the lap alive. The open surface is deliberately risk/reward — the space to cut is real, but the ordered, width-limited gates are what make cutting a gamble rather than a shortcut.

## Automatic reset: opt-in, off by default

`SessionSettings.auto_reset_enabled` defaults to `false`. `MainSession.restart_with_seed()` passes it straight to `TopDownCar.set_auto_reset_enabled()` on every restart, so it has to be explicitly turned on (there is no in-game toggle at time of writing; it is a resource-level setting).

When enabled, `TopDownCar._update_auto_reset()` evaluates two independent conditions, checked only while the car is `OFF_TRACK`; either is sufficient to trigger a reset:

| Condition | Threshold (`VehicleTuning` field) | Default value |
| --- | --- | --- |
| Stopped off-track | `auto_reset_stuck_speed` / `auto_reset_stuck_seconds` | speed below 25.0 px/s (2.0 m/s, 7.2 km/h) continuously for 2.0 s |
| Lost off-track | `auto_reset_lost_distance` | more than 1000.0 px (80 m) from the centerline |

The lost-distance threshold (80 m) is deliberately half of `PLAY_AREA_MARGIN` (160 m), so a "lost" reset resolves well before the car could ever reach the containment boundary. Returning to `DIRT` clears both timers immediately.

A reset that fires this way teleports the car to its last safe on-track pose (the same mechanism the manual reset uses) and shows the status message "Returned to the track". It also re-seeds the checkpoint detector at the landing pose so the teleport itself is never misread as a driven checkpoint crossing.

The manual reset — the `reset_car` input action — is unrelated to this setting and is always available regardless of `auto_reset_enabled`, on or off the track.
