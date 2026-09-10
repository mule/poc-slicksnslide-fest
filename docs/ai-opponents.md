# AI opponents

Epic #55. This document covers what tasks #56 and #57 landed: the seam an AI drives through, the
identity that makes each driver reproducible, the camera rule that lets more than one car exist, and
what a driver knows. Judgement (#58), mistakes (#59), the field (#60) and scaling (#61) extend it.

Nothing here makes a car drive itself. It makes a field of cars possible, and gives each of them
something to react to.

## The seam

```
class_name AiDriver
extends RefCounted

func drive(delta: float) -> VehicleInputState
```

`TopDownCar.set_input_state()` already takes a `VehicleInputState`; `ControllerInput` produces one
from hardware and `AiDriver` is the other producer. `IdleDriver` is the concrete neutral driver the
field runs until reactive driving lands.

**A driver never holds a reference to the car it drives.** `_init` takes three integers and `drive`
takes a float; senses arrive from task #57 as data. A driver that can reach its own `RigidBody2D`
reads ground truth instead of its senses, and every later determinism guarantee becomes unprovable.
This is asserted structurally, not left to inspection —
`tests/ai_driver_contract_test.gd::_verify_seam_isolation` walks `get_property_list()` and rejects
any script-declared property of type `Nil`, `Object`, `NodePath`, `RID`, `Callable` or `Signal`, and
checks that `_init` takes only ints. `Nil` is there because a declared type is always reported:
`var _car: Node2D` comes back as `Object` even while it is null, so the case that would otherwise
slip through is an **untyped** `var _car`, which the engine cannot describe and which may hold a car
the moment anything assigns one. The same walk is applied to `DriverSenses` in
`tests/driver_senses_test.gd`, because a sense that carried a node would let a driver walk from its
senses back to the car, the track and the field.

## The `"ai_driver"` seed domain — persistence contract

```
domain seed   = DomainSeed.derive(version, track_seed, "ai_driver")
per-car seed  = DomainSeed.child(domain_seed, car_index, 0)
```

`DomainSeed` hashes the text `"%d|%d|%s"` and `"%d|%d|%d"` with SHA-256 and truncates to fifteen hex
digits, so the values below are stable across platforms and Godot versions.

| Field | Meaning |
| --- | --- |
| `version` | The domain's schema version. Defaults to `1` in `AiDriver._init`. |
| `track_seed` | The session seed, the same one `TrackGenerator` receives. |
| `"ai_driver"` | The domain string. It is part of the hashed text and must never be reworded. |
| `car_index` | `0` is the player's identity; rivals take `1..opponent_count`. |
| the trailing `0` | The child's second key, reserved. Task #57 may use it to fan a driver's identity out into per-subsystem seeds without disturbing the per-car seed. |

**What is fixed.** The domain string, the argument order, and `car_index` occupying the child's
first key. Changing any of them silently changes every driver's identity for every seed.

**When `version` may be bumped.** Only when the *meaning* of a driver seed changes — when the same
`(track_seed, car_index)` should deliberately produce a different driver. Bumping it is how a
behaviour change is made explicit rather than silent, and it is the only sanctioned way to move
these values.

**When it may not.** Not to shake out an unwanted personality, not to work around a bug in a
consumer of the seed, and never to make a stale expectation match. Unlike the four track
fingerprints, driver seeds are not pinned in a checked-in ledger — nothing external would notice a
drift, which makes the discipline more important here rather than less. The fixture at
`tests/ai_driver_contract_test.gd` pins `DomainSeed.child(DomainSeed.derive(1, 7, "ai_driver"), 2, 0)`
to `54569277199214867`, a value recomputed independently in Python from the algorithm; that
assertion is what a `version` bump must be seen to change.

**Cheap to record, expensive to recover.** A driver seed is only interesting once a driver's
behaviour depends on it (task #58 onward). Recording the contract now costs a paragraph; recovering
it after twenty rivals' personalities have shipped costs a re-baseline nobody can verify.

## One camera for the field

`TopDownCar` owns `$FollowCamera`. Twenty cars would mean twenty cameras competing for one viewport,
which Godot resolves by whichever became current last. The rule is an explicit per-car flag:

- `camera_enabled` is an `@export` defaulting to **false**, so a car is camera-less unless asked.
- `top_down_car.tscn` bakes `enabled = false` on the camera node.
- `_ready()` applies the flag **before** its `tuning == null` early return, so a car that fails the
  tuning guard still takes no camera.
- The setter writes through to the camera node, so assigning the flag after `_ready()` is not
  silently inert.
- `MainSession.restart_with_seed()` sets it on the player's car alone.

The scene property and the script gate are deliberately redundant. Whoever spawns the field should
simply not touch `camera_enabled` on a rival.

The follow behaviour is untouched by all of this: the lerp, lead and zoom in `_process` are
bit-for-bit what they were before the flag existed, pinned at three ticks of a 60-tick sequence in
`tests/ai_driver_contract_test.gd`.

## Settings

`SessionSettings.opponent_count` is an `@export_range(0, 20, 1)` integer defaulting to 0 and clamped
in its setter. `MainSession.restart_with_seed()` reads it into `_opponent_count` and republishes it
through `get_session_snapshot()`. As of task #56 it is **stored and observable, not wired** — no car
is spawned from it. Task #60 spawns the field.

## Sensing — what a driver knows

`DriverSenses` (`ai/driver_senses.gd`) is one car's whole view of the world for one tick, and
`SensingPass` (`ai/sensing_pass.gd`) builds it. A driver holds no car, so it cannot sense for
itself: whoever owns the field owns one pass, runs it per car, and hands the resulting
`DriverSenses` — pure data, no handles — to that car's driver.

### Which source answers which sense

Each sense comes from the cheapest source that is deterministic. "Sensor-based" is a statement about
what the driver *knows*, not about which engine call produced it.

| Sense | Source | Why |
| --- | --- | --- |
| Where the road is | `SurfaceQuery.road_frame_at` | Analytic, indexed, the same centerline the car's own rules read |
| What the surface is underneath | `SurfaceQuery.sample_at` | The car already samples exactly this |
| Whether the ground ahead falls away | the injected `HeightQuery` | Lets a driver lift for a crest it is about to launch off |
| Where the rivals are | the field's own car list | You have the list. Do not raycast for it. |
| Where the trees and rocks are | one physics ray, nearest hit | The only sense with no cheaper deterministic source |

**The ray rule is absolute.** `intersect_ray` returns a single nearest hit. `intersect_shape` returns
an array whose order Godot does not specify, and an unordered result is a determinism bug that
reproduces on one machine and not another and surfaces months later as a fingerprint that moved for
no reason. There is exactly one physics query in a pass and it is a ray.

### `road_frame_at` — why the distance query was not enough

`distance_to_centerline` answers *how far*, which is all the car's own rules ever needed. A driver
also needs which **side** it is on and which way the road **runs**, and neither is recoverable from
an unsigned distance: the field's gradient is exactly zero on the centerline, which is where a car
normally sits, so probing it with finite differences yields nothing precisely in the common case.

Both fall out of the nearest segment for free, so `SurfaceQuery.road_frame_at(position, radius)`
returns that segment's frame — `found`, `distance`, `lateral_offset`, `tangent`, `half_width` —
under the same search-radius contract. `TrackSurfaceMap` answers it from the same `SegmentGrid` and
the same geometry test as `distance_to_centerline`. The two loops are deliberately not shared:
`distance_to_centerline` sits on the car's automatic-reset path, where a refactor that is only
probably bit-identical is not worth the risk. `driver_senses_test` compares the two answers with
`==` across 535 probes on three seeds instead.

The road's direction is the centerline's own **index order**, which is the lap direction, so the
sign of `lateral_offset` is a property of the track and not of where a car's nose happens to point.
Positive is the road's **right**: with screen y growing downward, a tangent pointing east has a
right-hand normal pointing south, the same handedness as `TopDownCar`'s local +x. Note that
`TrackDefinition.left_boundary` uses the opposite naming, from `TrackGenerator._derive_boundaries`;
that name predates any car frame and was left alone.

### Frames — the rule the task exists to enforce

**No field of `DriverSenses` is a world coordinate.** A driver that receives absolute positions can
navigate by memorised map, which is the racing line this epic deliberately excluded.

Two kinds of relative live in there, invariant for different reasons:

- **Road-relative scalars** — `lateral_offset`, `heading_error`, `distance_to_left_edge`,
  `distance_to_right_edge` — are measured against the road, so no world axis enters them.
  `heading_error` near ±π is how a driver learns it is facing the wrong way.
- **Car-basis vectors** — `gradient_ahead`, `rival_offset`, `rival_relative_velocity`,
  `obstacle_offset`, `local_velocity` — are rotated out of the world by the car's own basis, in the
  convention `TopDownCar.get_local_velocity()` already uses: **+x is the car's right, forward is
  −y.**

`height_change_ahead` is a third case and the one that is easiest to get wrong. An absolute ground
height is a world-frame value wearing a scalar's clothes — it says where on the map the car is — so
what a driver gets is the *difference*: how much the ground ahead rises or falls from the ground
under it. Negative means it is about to launch.

The three `road_found` / `has_rival_ahead` / `has_obstacle_ahead` booleans gate the fields around
them. When one is false its fields are zero and mean nothing; the flags are the contract.

**What the two-placement check does not cover, which matters to whoever adds the next field.** It
builds both placements from one local layout and carries them out through a placement transform, so
every sampled point has identical *local* coordinates in both. Any sense that is a function of the
local pose alone therefore agrees in both placements **whatever the pass does with it** — the check
walks every declared field, but for such a field it is comparing two copies of one number. Today
that is the height channel, which is why `height_change_ahead` is pinned against a number, at a
fixture deliberately offset from the origin, in
`driver_senses_test.gd::_verify_ground_ahead_survives_a_shared_sample`. A later absolute altitude or
lap-progress field would inherit a green test for free. Read "every declared field is walked" as
catching every field whose value depends on *where in the world* the car is, and pin anything else
against a number of its own.

### Look-ahead is the one tunable

How far ahead a driver senses is a parameter of `sense()`, not a constant inside it, because it is
the single dial that most changes behaviour and task #59 varies it by skill. It bounds all three
forward senses: the ground probe, the rival scan and the ray. It is also the road query's search
radius, which makes it the dial that moves the cost.

### The budget

A pass costs a **fixed five queries** whatever the world contains, none of them inside a loop:

| Query | Count |
| --- | --- |
| `SurfaceQuery.road_frame_at` (under the car) | 1 |
| `SurfaceQuery.sample_at` (under the car) | 1 |
| `HeightQuery.sample_at` (under the car, and at the look-ahead point) | 2 |
| `intersect_ray` | 1 |

The rival scan issues none. `driver_senses_test` counts all five through fixtures the pass does not
own — wrapped queries for the first four, a subclass override for the ray — and pins that twenty
cars spend exactly a hundred.

**Nothing is written, nothing is moved, and no sample is held across a query.** `TrackHeightMap`
hands back one shared, re-zeroed sample on its miss path, so the ground under the car is read out
into a local before the ground ahead is asked for. The order of those lines is the contract;
`_verify_ground_ahead_survives_a_shared_sample` drives a provider that behaves the same way and
would read a flat world if the order changed.

### Cost

Measured on seed 0 with the track's real trees and rocks in the space, twenty cars spread around the
lap and across the road's width, a 400 px look-ahead. **These are wall-clock numbers and they move
with machine load — read them as a band, not a constant.** The low end of each range was measured on
an idle machine (load 1.3), the high end under a concurrent build (load 2.2–3.2):

| Case | Per car | Twenty cars | Of a 16.6 ms frame |
| --- | --- | --- | --- |
| On the racing line (ray runs full length, hits nothing) | 112–150 µs | 2.2–3.0 ms | 14–18% |
| Parked in front of a solid (ray hits) | 74–110 µs | 1.5–2.2 ms | 9–13% |

The racing-line figure is the one to quote: a ray that hits stops early, so the miss is the worst
case. It is also the normal case, because the nearest solid on a generated circuit stands 375 px
from the centerline — further than a look-ahead — so a car **on** the road never sees one. The ray
earns its place on the recovery path, where a car that has run wide is among the trees.

Roughly half the pass is the two surface queries, which walk the segment grid over the same point
twice. The look-ahead curve, printed by the suite, across the same band:

| Look-ahead | Per car | Twenty cars |
| --- | --- | --- |
| 200 px | 92–117 µs | 1.8–2.3 ms |
| 400 px | 98–147 µs | 2.0–2.9 ms |
| 600 px | 112–201 µs | 2.2–4.0 ms |

The conclusion does not depend on where in the band a machine lands: even the loaded end leaves five
times the headroom the ×20 assertion needs. Plan with the upper figure.

## Verification

```sh
godot --headless --path . --script res://tests/ai_driver_contract_test.gd
godot --headless --path . --script res://tests/driver_senses_test.gd
```

The first prints one deliberate `ERROR` line from its tuningless-car fixture; that error is the
behaviour under test. Mutations, which must fail:

```sh
godot --headless --path . --script res://tests/driver_senses_test.gd -- --break-sense-frame
```

| Flag | Suite | What it does |
| --- | --- | --- |
| `--break-sense-frame` | driver senses | Replaces the car's basis with an identity basis at the same origin, so every sense comes out in the world frame |

`--break-sense-frame` is the whole point of the frame assertion. The pass reads its car's pose
exactly once, through `SensingPass._car_frame()`; substituting an identity basis there leaves every
world position where it was and strips the rotation that turns a world vector into a car-frame one.
`_verify_senses_are_in_the_car_frame` places one layout twice — 15,000 px apart and 137 degrees
rotated — and walks every declared field of `DriverSenses` comparing the two. If that check passed
with the flag on, it would not be testing the frame.
