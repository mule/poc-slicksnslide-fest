# Off-track objects

## Deterministic placement

Catalog version 1 is the placement contract. `OfftrackSeed.domain_seed()` hashes the algorithm
version, track seed, and the literal `offtrack_objects` domain; `cell_seed()` then hashes that
domain seed with each integer cell coordinate. Each cell therefore has an independent deterministic
stream: a rejection in one cell cannot alter the transform, variant, or archetype selected in a
later cell. Stable IDs are `v<version>:<track-seed>:<cell-x>:<cell-y>`.

`OfftrackObjectPlacer` sorts the accepted records by stable ID and SHA-256 fingerprints the
version, archetype, transform, scale, visual variant, and collision profile. The resulting object
fingerprint is distinct from `TrackDefinition.geometry_fingerprint`; object placement runs only
after the road is accepted and never consumes the road generator's random stream. That isolation is
checked for seeds 0-19.

## Placement zones

All distances are beyond the dirt-road edge and include each object's scaled footprint.

The cell's center distance selects its deterministic occupancy draw and weighted archetype list. After
the archetype and scale are chosen, an accepted footprint must be wholly on one side of the 12 m
boundary; a footprint that would straddle it is rejected. This leaves the 20 m rule unchanged:
it excludes only solid footprints, not decorative ones.

| Zone | Rule |
| --- | --- |
| Decorative band | 0-12 m: grass and debris only. |
| Solid recovery corridor | 0-20 m: trees and rocks are excluded, leaving a recoverable path after leaving the dirt. |
| Hazard field | 20-140 m: all four archetypes may occur. |
| Containment buffer | Final 20 m before `play_area`: no object footprint may enter. |
| Spawn/checkpoint exclusion | Trees and rocks stay at least 40 m plus their footprint from spawn and checkpoint origins. |

Solid collision circles also cannot overlap. The grid is finite and bounded: it does not retry
indefinitely or cause a road to regenerate.

## Prototype catalog

The default catalog uses a 20 m jittered placement grid, 80 m visual/physics chunks, occupancy
0.55 in the decorative band and 0.35 in the hazard field, and an accepted-draw fill target of 0.75.

| Archetype | Weight (near / hazard) | Scale range | Collision profile |
| --- | --- | --- | --- |
| Grass tuft | 0.75 / 0.40 | 0.70-1.30 | Decorative; no collider. |
| Small debris | 0.25 / 0.15 | 0.80-1.20 | Decorative; no collider. |
| Tree | 0.00 / 0.30 | 0.80-1.25 | `tree_circle`, 1.2 m radius before scale. |
| Rock | 0.00 / 0.15 | 0.70-1.40 | `rock_circle`, 1.2 m radius before scale. |

These are deliberately lightweight prototype shapes, not final art or a destructibility system.

## Runtime

Grass and debris are grouped into `MultiMeshInstance2D` decorative batches by spatial chunk,
archetype, and variant. Trees and rocks remain individual nodes in a Y-sorted container so their
depth relationship with the car stays readable. Solid circles are grouped beneath chunk-local
`StaticBody2D` nodes.

Before either consumer builds a record, runtime validation resolves its catalog archetype once and
requires its `solid` and `collision_profile` fields to agree with that archetype. A rejected record
reports a validation error and creates neither a visual nor a collider; valid sibling records still
build.

There is no object streaming, persistence across a restart, destructibility, damage, pickup
system, or shadow gameplay. Height and jump behaviour is no longer out of scope: it was
implemented as sub-project C, and an object's `obstacle_height` is what decides whether an
airborne car can pass over it. See [The height channel](height-channel.md).

Restarting a seed frees the old generated track and its visual and collision children before
mounting the replacement.

## Diagnostics

`OfftrackObjectPlacementResult` reports `placements`, its SHA-256 `fingerprint`,
`generation_usec`, and diagnostics. Diagnostics include the finite `total_cells` count and, for
both `near_shoulder` and `hazard`, `valid_cells`, `occupied_draws`, `accepted`, rejection counts
(`road_or_recovery`, `zone_boundary`, `containment`, `spawn_checkpoint`, and `solid_overlap`), and
`underfilled`. The zone counters remain the center-cell zone used for the deterministic draw; a
post-selection `zone_boundary` rejection therefore remains in that candidate zone. Invalid input
instead reports `invalid_input`.

An underfilled zone means its accepted/occupied-draw ratio is below the catalog's 0.75 target; it
does not change the road or retry generation. A zero-draw zone is not marked underfilled.
`OfftrackObjectRuntime.get_metrics()` reports `visuals`, `decorative_batches`, `solid_visuals`,
`colliders`, and `collision_chunks`; tests require the visual count to match placements and the
collider count to match solid placements. `collision_chunks` counts bodies, not spatial chunks:
collision layers belong to bodies rather than to shapes, so one spatial chunk holding both a low
solid and a tall one builds two `StaticBody2D` bodies, `Chunk_<x>_<y>_low` and
`Chunk_<x>_<y>_tall`. A chunk therefore contributes one or two to this count. See
[The height channel](height-channel.md) for what the two levels mean to the car.

## Verification

Run the normal contracts, placement sweep, visual/collision/runtime integration, and independent
desktop budgets:

```sh
/home/japurane/.local/bin/godot --headless --path . --script res://tests/offtrack_object_contract_test.gd
/home/japurane/.local/bin/godot --headless --path . --script res://tests/offtrack_object_placement_test.gd
/home/japurane/.local/bin/godot --headless --path . --script res://tests/offtrack_object_visuals_test.gd
/home/japurane/.local/bin/godot --headless --path . --script res://tests/offtrack_object_collision_test.gd
/home/japurane/.local/bin/godot --headless --path . --script res://tests/offtrack_object_runtime_test.gd
/home/japurane/.local/bin/godot --headless --path . --script res://tests/offtrack_object_performance_test.gd
```

The one-time placement p95 budget is 80 ms and runtime-construction p95 budget is 100 ms over
seeds 0-19. Mutation checks must fail (exit 1):

```sh
/home/japurane/.local/bin/godot --headless --path . --script res://tests/offtrack_object_placement_test.gd -- --break-seed
/home/japurane/.local/bin/godot --headless --path . --script res://tests/offtrack_object_placement_test.gd -- --break-clearance
/home/japurane/.local/bin/godot --headless --path . --script res://tests/offtrack_object_collision_test.gd -- --remove-solid-collider
/home/japurane/.local/bin/godot --headless --path . --script res://tests/offtrack_object_collision_test.gd -- --solid-decoration
```

Refresh desktop graphical evidence in a graphical Godot session, then inspect each PNG:

```sh
/home/japurane/.local/bin/godot --path . --script res://tests/capture_offtrack_objects.gd
```

Record the warmed desktop trace and the real production-car impact against a generated solid
placement (also graphical, not headless):

```sh
/home/japurane/.local/bin/godot --path . --script res://tests/capture_offtrack_desktop_evidence.gd
```

This writes the deterministic seed `0`, `4`, and `9` trace to
[`desktop-trace-seeds-0-4-9.txt`](evidence/offtrack-objects/desktop-trace-seeds-0-4-9.txt)
and the seed `0` impact still beside the standard captures. The helper warms each production
session, records frame-time, static-memory, node, and runtime-count samples, and proves a
`TopDownCar` physics contact with the selected generated solid before it saves the impact PNG.

See [desktop validation evidence](evidence/offtrack-objects/desktop-validation.md) for the recorded
desktop run. That result is code-completeness evidence only: Android #23 and Steam Deck #7 still
own their physical-device/controller and platform-performance gates.
