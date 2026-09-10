# AI opponents

Epic #55. This document covers what tasks #56 and #60 landed: the seam an AI drives through, the
identity that makes each driver reproducible, the camera rule that lets more than one car exist,
the field of up to twenty rivals, per-car lap progress, and the standings. Sensing (#57),
judgement (#58) and mistakes (#59) extend it.

Nothing here makes a car drive itself. It makes a field of cars possible — and ranks it.

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
takes a float; senses arrive in task #57 as data. A driver that can reach its own `RigidBody2D`
reads ground truth instead of its senses, and every later determinism guarantee becomes unprovable.
This is asserted structurally, not left to inspection —
`tests/ai_driver_contract_test.gd::_verify_seam_isolation` walks `get_property_list()` and rejects
any script-declared property of type `Object`, `NodePath`, `RID`, `Callable` or `Signal`, and
checks that `_init` takes only ints.

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

## The field (#60)

`MainSession` owns the player's car plus a list of rivals. Each rival is the same
`top_down_car.tscn` with the same `VehicleTuning` as the player, differing only in its input
source: an `IdleDriver` until #58's reactive driving replaces it. Tuning and the grid transform
are assigned **before** the car enters the tree — a rival without tuning is the exact shape the
camera work above guards against, and the guards are deliberately not load-bearing here. Rivals
never touch `camera_enabled`; the scene default of false holds. All cars share the runtime's one
height query; the field shares one stateless `TrackSurfaceMap` (`sample_at` only reads), while the
player keeps its own instance exactly as before the field existed. At `opponent_count == 0` no
rival code runs at all — the session is byte-for-byte the single-car session it was.

Every car gets its own `CheckpointCrossingDetector` and its own `LapProgressTracker`. The player's
tracker lives inside its `TimeTrialState` as before; the singularity that had to go was the
session owning one of each, not the classes. A player reset skips one tick of rival sampling too,
mirroring for the field the resume-next-tick rule the player's detector already follows.

### The grid

Slot 0 is the player's and is `TrackDefinition.spawn_transform` itself, so the player's pose never
moves with the opponent count and every lap time this repo has recorded stays comparable. Rivals
take slots 1..opponent_count in two columns behind the start line: slot *s* sits in row
`(s + 1) / 2` at `WorldScale.metres(8.8)` row spacing, odd slots one side of the centreline, even
slots the other, each at a quarter of the track's width out — on the road by construction however
narrow the generated track. Rows are anchored to the centreline arc behind the start, so the grid
follows the final curve of the lap rather than ploughing a straight line through it, and each car
faces its local direction of travel. The layout is a pure function of the definition and the slot
number: no slot depends on the count, and the same seed always places the same cars in the same
slots. A car starting behind the line crosses the start/finish gate forward on launch; the
checkpoint rules already ignore it (it is not the next gate), which is exactly the standing start.

Cars keep collision layer 1 and mask 3, shared with trees and the world boundary, so car-to-car
contact works without a layer change — confirmed against the physics server in
`tests/issue_60_field_test.gd`, not assumed. No layer change was needed.

### Standings

Position is derived, never stored: `get_race_order()` ranks by **laps completed**, then
**checkpoints passed this lap**, then **progress toward the next gate** (distance to it), and
finally by **car index**. The index term is the tie-break, and it is the one decision in the
ranking that had to be invented: on the first tick rows of the grid sit at identical progress, and
an order-dependent tie-break would silently differ between runs. Identity cannot be reordered, so
ties resolve identically everywhere; the player, as index 0, wins them — pole keeps pole. The HUD
shows `POS n/size` and the snapshot publishes `player_position` and `field_size`; a full timing
table was considered for this epic and deliberately left out.

`tests/issue_60_field_test.gd` drives a scripted scenario through the session's own crossing
sampling and asserts the exact order, including a car a lap ahead sitting at an earlier checkpoint.
`-- --break-standings-order` re-ranks the session's entries without the lap term and must fail on
exactly that case; deleting the lap comparison from `MainSession._is_ahead_of` fails the same
assertion in a normal run.

### What waits for #61

Deterministic final standings over a race and a full-field race need #59's real drivers, as does
the assertion that car-to-car contact does not desync a deterministic run. The idle field cannot
race; it can only be spawned, laid out, torn down and ranked. One known property of that idle
field, not a defect: an undriven car creeps downhill, because the integrator applies gravity along
the ground gradient with no throttle. The moment drivers steer (#58), this is their problem, and
the standings code does not care either way.
