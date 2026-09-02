# Off-track Objects Design Spec

**Status:** Approved in design review on 2026-08-29.

**Sub-project:** B of three. Sub-project A opened the surface; sub-project C will add a height
channel for jumping, air time, and landings.

## Goal

Populate the open surface with deterministic prototype scenery and solid hazards. Grass and debris
make the shoulder and surrounding world readable; trees and rocks make deep off-track excursions
risky. A broad recovery corridor remains free of solid objects so leaving the road is still a
viable driving choice rather than an immediate collision.

Given the same track seed, catalog, and placement algorithm version, the project must reproduce the
same object field on desktop, Android, and Steam Deck. Object-generation changes must never alter
the road geometry fingerprint.

## Scope

The first object catalog contains four archetypes:

| Archetype | Physics | Placement |
| --- | --- | --- |
| Grass tuft | Decorative | Near shoulder and hazard field |
| Small debris | Decorative | Near shoulder and hazard field |
| Tree | Static circular collider | Hazard field only |
| Rock | Static circular collider | Hazard field only |

Trees and rocks are immovable and indestructible. Visuals use the project's existing lightweight,
prototype geometry style. No external art pipeline is introduced.

## Non-goals

- Destructible, movable, or damage-dealing objects.
- Object persistence between sessions or seed restarts.
- Collectibles, pickups, spectators, buildings, or trackside gameplay systems.
- Object-specific branches in vehicle physics, input, lap tracking, or reset behavior.
- Elevation, jumps, shadows that affect gameplay, or the sub-project C height channel.
- Runtime streaming. Spatial chunks provide a future boundary, but B measures Godot's normal
  rendering and physics broadphases before adding active loading or unloading.

## Architecture

Four focused components own the feature.

### `OfftrackObjectPlacement`

A serializable `Resource` representing one generated object. It carries data only:

- stable placement ID;
- archetype ID;
- `Transform2D` and scale;
- decorative or solid classification;
- visual variant;
- collision profile.

It never holds instantiated scenes, nodes, shapes, or callbacks.

### `OfftrackObjectCatalog`

A versioned tuning resource containing the available archetypes and placement parameters. Version
1 is part of the placement fingerprint contract. The checked-in default catalog is the single
source of truth for grid size, occupancy, scale ranges,
visual weights, clearances, collision radii, and chunk size. These values do not live as scattered
literals in generation or runtime code.

### `OfftrackObjectPlacer`

A stateless generator that consumes a completed `TrackDefinition` plus an
`OfftrackObjectCatalog`. It produces placements, a SHA-256 placement fingerprint, generation time,
and an underfill diagnostic. It does not mutate the circuit and does not decide how objects render
or collide.

### `OfftrackObjectRuntime`

A `Node2D` consumer created by `TrackRuntime`. It delegates to separate visual and collision
children. Both children consume the exact same placement transforms; neither performs placement
generation.

The data flow is:

```text
TrackGenerator -> TrackDefinition
                       |
                       v
             OfftrackObjectPlacer
                       |
              placements + fingerprint
                       |
                       v
             OfftrackObjectRuntime
                 |             |
                 v             v
            visual chunks   collision chunks
```

`TrackDefinition` gains the placement array, placement fingerprint, placement-generation time, and
diagnostic. Its existing road geometry fingerprint remains unchanged and continues to cover only
the road geometry.

## Determinism and seed isolation

Object placement uses a domain-separated seed derived from:

```text
placement algorithm version + track seed + "offtrack_objects"
```

The derivation uses a checked-in, fixed integer-mixing routine with known-vector tests. It does not
use Godot's generic `hash()` as a cross-version persistence contract.

Each grid cell derives its own random stream from the object seed and integer cell coordinates.
Consequently, rejecting or adding an object in one cell cannot shift every later cell's variant or
transform. Stable placement IDs come from the algorithm version, seed, and cell coordinates rather
than accepted-array order.

The placer runs only after the circuit candidate has been accepted or the known-valid fallback has
been built. Object placement cannot consume `TrackGenerator`'s RNG, reject a road, trigger another
road attempt, or alter `geometry_fingerprint`.

Placements are sorted by stable ID before fingerprinting. The fingerprint serializes version,
archetype, transform, scale, visual variant, and collision profile with fixed decimal precision,
then hashes the result with SHA-256.

## Placement model

The default catalog starts with a 20 m jittered grid, an 80 m runtime chunk size, and a minimum
accepted-to-occupied ratio of 0.75 per zone. The exact values remain data and may be tuned by
evidence without changing the component boundaries.

Distances are measured from the road edge, not merely the centerline. Object footprint radius is
included when testing every boundary.

The cell center determines the deterministic zone draw before an archetype is selected. Once the
archetype and scale are known, a footprint crossing the 12 m near-shoulder boundary is rejected;
the existing center-zone `valid_cells` and `occupied_draws` diagnostics remain unchanged, while the
rejection is counted as `zone_boundary` in that candidate zone. The 20 m recovery rule continues to
exclude solid footprints only.

| Zone | Distance beyond road edge | Allowed objects |
| --- | --- | --- |
| Near shoulder | 0-12 m | Grass and small debris only |
| Recovery corridor | 0-20 m | No solid objects |
| Hazard field | 20-140 m | All four archetypes |
| Containment buffer | Final 20 m before `play_area` | No objects |

The near-shoulder and hazard-field cell occupancy defaults are 0.55 and 0.35 respectively. Initial
weighted choices are:

- near shoulder: grass 0.75, debris 0.25;
- hazard field: grass 0.40, debris 0.15, tree 0.30, rock 0.15.

These are prototype starting values, not claims of final driving quality.

### Exclusions

- A solid object's footprint must remain at least 20 m beyond the road edge.
- All object footprints must remain inside `play_area` contracted by the 20 m containment buffer.
- Solid objects are excluded within 40 m of the spawn transform and every checkpoint origin.
- Solid collision circles may not overlap each other.
- Decorative footprints may overlap lightly, but no cell produces more than one placement.
- Non-finite transforms, non-positive scale, unknown archetypes, and placement physics fields that
  disagree with the resolved catalog archetype are invalid.

Placement is bounded by the finite grid: there is no unbounded retry loop. Diagnostics record total
cells, valid-zone cells, occupied draws, accepted placements, and rejection counts by rule. A zone
is underfilled when `accepted / occupied_draws < 0.75`; zero occupied draws are reported separately
and do not divide by zero. Underfill never causes road regeneration.

## Runtime rendering and collision

### Decorative objects

Grass and debris use chunked `MultiMeshInstance2D` batches, grouped by spatial chunk, archetype,
and visual variant. Each batch sets bounds from its chunk. Batching bounds node and draw-call
growth; chunking lets CanvasItem culling discard distant portions of the several-screen circuit
instead of treating the whole field as one always-visible batch.

### Solid objects

Trees and rocks use lightweight individual prototype visual nodes under a Y-sorted container so
their relationship to the car remains readable. Their colliders are circular shapes grouped under
chunk-local `StaticBody2D` nodes.

Collision profiles are catalog data. Visual scale and collision radius are derived from the same
placement and catalog entry. Solid objects use the existing world collision layer; decorative
objects create no physics objects. The vehicle continues to rely on its existing collision mask,
continuous collision detection, bounded speed, and ordinary `RigidBody2D` response.

Changing or restarting a seed frees the old `TrackRuntime`, including all object chunks, before the
new runtime is mounted. No object state survives the rebuild.

## Failure behavior

- An empty placement set is valid and renders nothing.
- Density underfill is diagnostic and does not fail track generation.
- Unknown archetypes, invalid transforms, and catalog-mismatched `solid` or `collision_profile`
  fields are rejected by tests; runtime skips them and reports an error rather than creating partial
  physics state.
- Failure to render an object cannot modify collision placement, road geometry, lap progress, or
  reset state.
- A mismatch between placement count and visual count, or between solid-placement count and
  collider count, is a test failure.
- The recovery corridor makes on-road safe poses independent of object collision. Existing manual
  and automatic reset paths require no object-specific behavior.

## Verification

### Placement contract suite

`tests/offtrack_object_placement_test.gd` sweeps seeds `0..19` and checks:

- repeatable placements and SHA-256 fingerprints;
- unchanged road geometry fingerprints with placement enabled or disabled;
- correct near-shoulder, recovery, hazard, and containment zones;
- fully contained footprints on both sides of the 12 m boundary, with straddling candidates rejected;
- spawn and checkpoint exclusions;
- non-overlapping solid collision circles;
- finite transforms and positive scales;
- documented density or explicit underfill;
- identical rules for accepted and fallback tracks.

Mutation modes deliberately break seed derivation and clearance enforcement. The suite follows the
repository's harness contract: a crashing test function, engine error, skipped assertion path, or
mutation that remains green is failure.

### Runtime and physics suite

`tests/offtrack_object_runtime_test.gd` uses fixed fixture placements and checks:

- every placement creates its intended visual representation;
- decorative placements create no collision shape;
- solid visuals and colliders share a transform;
- a probe collides with both a tree and a rock;
- continuous collision detection prevents tunnelling at maximum expected car speed;
- post-impact energy remains bounded;
- the recovery corridor is physically empty;
- seed restart removes the prior field before mounting the next one.
- rejected catalog-mismatched records create no visual or collider while valid siblings still build.

Mutation modes remove a solid collider and make a decorative object solid, proving both sides of
the collision contract are observed.

### Performance and evidence

Desktop evidence records placement time, runtime construction time, placement count, node count,
chunk count, collision-shape count, memory, and representative frame time for at least three seeds.
On the reference workstation, the approved budgets are placement p95 at or below 80 ms and runtime
construction p95 at or below 100 ms across seeds `0..19`. Placement runs once when a circuit is
generated; its original 50 ms target was raised to 80 ms after exact segment-safe placement measured
73.136 ms p95. This approval applies only to one-time placement generation and does not change the
separate runtime-construction budget. A miss is reported and escalated rather than hidden by further
loosening either budget. Captures show near-shoulder decoration, the open recovery corridor, deep
hazards, and a real impact.

Android issue #23 and Steam Deck issue #7 validate the same B-enabled commit in parallel. Their
reports add object and collision counts to the existing frame-time, memory, controller, and
lifecycle evidence. Desktop proof can establish code completeness but cannot substitute for these
physical-device gates.

## Delivery graph

The parent B epic contains seven delivery tasks:

1. **Shared contract and catalog.** Add placement/catalog resources, default data, seed-version
   contract, `TrackDefinition` fields, and contract tests. This lands first.
2. **Deterministic placement engine.** Implement the grid, exclusions, stable IDs, diagnostics,
   fingerprint, and placement mutation tests.
3. **Visual archetypes and rendering.** Implement prototype visuals, decorative batches, solid
   Y-sorting, chunks, and fixture-based rendering tests.
4. **Collision runtime and physics.** Implement chunk collision bodies and the collision/non-
   collision, tunnelling, response, and mutation tests.
5. **Integration.** Wire placement and runtime into the shared generator and runtime files, verify
   seed restart, and run the complete suite repeatedly.
6. **Desktop tuning and evidence.** Tune catalog data, measure budgets, capture seeds, and document
   limitations.
7. **Final reconciliation.** Consume the parallel Android #23 and Steam Deck #7 results, reconcile
   acceptance, and update the PoC report.

After task 1, tasks 2-4 run in parallel against the frozen contract and fixture data. Task 5 is the
single shared-file merge point. After task 6, Android #23 and Steam Deck #7 run in parallel against
one immutable revision. Task 7 is the final evidence gate.

Each implementation task owns its tests. A separate deferred QA task is intentionally excluded:
it would weaken test-driven delivery and make ownership of failed acceptance criteria ambiguous.

## Acceptance criteria

- Seeds `0..19` generate deterministic object placements and a stable SHA-256 object fingerprint.
- Enabling or changing object placement never changes the road geometry fingerprint.
- The road and 20 m recovery corridor contain no solid objects.
- Grass and debris are non-colliding; trees and rocks produce matching visible and physical
  placements.
- Solid placements do not overlap, block spawn/checkpoint exclusion zones, or enter the containment
  buffer.
- Real physics probes collide with trees and rocks without tunnelling or unbounded energy.
- Seed restart replaces the complete object field without retaining nodes or physics shapes.
- One-time placement-generation p95 is at most 80 ms and runtime-construction p95 is at most 100 ms across seeds
  `0..19` on the documented reference workstation, or the miss remains explicitly open.
- Desktop evidence covers at least three seeds and documents any density or performance shortfall.
- Android and Steam Deck evidence runs against the same B-enabled revision; unmet physical-device
  criteria remain open and are not represented as complete.
