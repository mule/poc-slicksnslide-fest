# AI opponents

Epic #55. This document covers what tasks #56, #57, #58 and #60 landed: the seam an AI drives
through, the identity that makes each driver reproducible, the camera rule that lets more than one
car exist, what a driver knows, the driver that turns it into controls, the field of up to twenty
rivals, per-car lap progress, and the standings; and what #59 added to the driver: a skill per car
and deliberate mistakes that are seeded, logged and off by default. #61 wires all of it into the game:
a field of twenty on seed 0 races the same way twice across the two spawn histories its suite varies
(scope under "Driving the field (#61)"); a driver stuck behind a stopped car goes round it, which took
the fields of 22 seeds from six meeting the stuck rule to none ("Going round a stopped car (#61)"); and
"The field at size (#61)" records what twenty cars cost, the multi-seed evidence, and what none of it
covers. Every result here is from one Linux machine.

`ReactiveDriver` (#58) is the part that makes a car drive itself. Since #61 every rival
`MainSession` spawns drives with one, sensed by the session's own `SensingPass`.

## The seam

```
class_name AiDriver
extends RefCounted

func drive(delta: float) -> VehicleInputState
```

`TopDownCar.set_input_state()` already takes a `VehicleInputState`; `ControllerInput` produces one
from hardware and `AiDriver` is the other producer. `IdleDriver` is the concrete neutral driver the
field ran until #61; fixtures still use it.

`drive` carries no senses, so #58 added the one door they come in by, and the horizon a driver wants
them built at. One tick, from whoever owns the field:

```
driver.perceive(sensing_pass.sense(field, index, driver.sensing_horizon()))
car.set_input_state(driver.drive(delta))
```

`AiDriver.perceive` is a no-op and `sensing_horizon` returns 50 m, so the neutral drivers need no
change to be driven this way. The neutral body stays in `AiDriver` rather than moving to `IdleDriver`:
#56's issue says `AiDriver` itself returns neutral controls, and `ai_driver_contract_test` pins it.

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
| the trailing `0` | The child's second key, reserved. Task #57 may use it to fan a driver's identity out into per-subsystem seeds without disturbing the per-car seed. #59 does: see the streams below. |

**The streams (#59).** The second key names a stream, and every stream is a sibling of the identity
rather than derived from it, so adding one never moves `driver_seed`:

| Key | `AiDriver` constant | Stream | Read as |
| --- | --- | --- | --- |
| `0` | `IDENTITY_STREAM` | the per-car seed, `driver_seed` | an integer |
| `1` | `SKILL_STREAM` | the car's skill | `child(domain, car_index, 1) / 16^15`, in [0, 1) |
| `2` | `MISTAKE_STREAM` | the car's mistake stream | mistake n's draw d is `child(stream, n, d) / 16^15`, d = 0 gap, 1 kind, 2 amount, 3 seconds |

The key numbers and the four draw numbers are part of the contract on the same terms as the domain
string. Mistake n is a pure function of the stream and n (`ReactiveDriver.mistake_plan`), so the
stream is random-access: nothing is consumed, and no draw's position depends on another's. A driver
reads its streams in `AiDriver._identity_fixed()`, called at the end of construction, rather than in
an `_init` of its own: the seam's structural check counts the arguments of every `_init` in the chain
and requires exactly the three identity integers.
`tests/skill_and_mistakes_test.gd` pins car 2's and car 3's skill on seed 7, and car 2's first two
plans and car 3's first, to values recomputed independently in Python.

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
through `get_session_snapshot()`. Task #60 spawns the field from it.

`SessionSettings.opponent_mistakes_enabled` (#61) is the field's one mistake switch: every rival the
session spawns takes it. It is **false in code** -- the default `ReactiveDriver` has too, and every
test builds its settings with `SessionSettings.new()`, so a test races a flawless field unless it
asks -- and **true in the shipped `data/default_session_settings.tres`**, because opponents that make
deliberate mistakes are the epic's design.

The shipped `data/default_session_settings.tres` sets `opponent_count = 10` (owner decision, #61 fix
round 1); the code default stays 0, so a test that builds `SessionSettings.new()` spawns only what it
asks for. Launched as the game, the main scene mounts eleven cars and all ten rivals drive off the grid.
A suite that loads `main.tscn` with the shipped resource gets those ten rivals, mistakes on.

## The field (#60)

`MainSession` owns the player's car plus a list of rivals. Each rival is the same
`top_down_car.tscn` with the same `VehicleTuning` as the player, differing only in its input
source: a `ReactiveDriver` since #61 (an `IdleDriver` before). Tuning and the grid transform
are assigned **before** the car enters the tree: `_ready()` sets mass from the session's tuning
and captures the grid pose for safe resets. The scene's baked tuning is only a default. Rivals
never touch `camera_enabled`; the scene default of false holds. All cars share the runtime's one
height query and one stateless `TrackSurfaceMap` (`sample_at` only reads). At
`opponent_count == 0` no rival is spawned and no rival driving or sampling runs. The snapshot
is additively extended with `field_size` and `player_position`, and the HUD displays `POS 1/1`.

Every car gets its own `CheckpointCrossingDetector` and its own `LapProgressTracker`. The player's
tracker lives inside its `TimeTrialState` as before; the singularity that had to go was the
session owning one of each, not the classes. Since #61 a player's reset no longer skips a tick of
the rivals: the field drives before the player's reset handling returns early.
A rival's own automatic reset drains its notice, reseeds its detector at the safe destination,
and skips sampling until the next tick to prevent teleport chords earning checkpoints.

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
Each rival is placed at a pose a physics step leaves unchanged, within 9.9e-5 rad of the grid's
rotation at the same origin; see "Driving the field (#61)". The player's pose is `spawn_transform`
exactly, unsnapped.

Cars keep collision layer 1 and mask 3, shared with trees and the world boundary, so car-to-car
contact works without a layer change — confirmed against the physics server in
`tests/issue_60_field_test.gd`, not assumed. No layer change was needed.

### Standings

Position is derived, never stored: `get_race_order()` ranks by **laps completed**, then
**checkpoints passed this lap**, then **progress toward the next gate** (distance to it), and
finally by **car index**. The index term is the tie-break, and it is the one decision in the
ranking that had to be invented: on the first tick rows of the grid sit at identical progress, and
an order-dependent tie-break would silently differ between runs. Identity cannot be reordered, so
exact ties are checked against `[0, 1, 2, 3]` in separate suite invocations, including reversed input.
The player, as index 0, wins them — pole keeps pole. The HUD
shows `POS n/size` and the snapshot publishes `player_position` and `field_size`; a full timing
table was considered for this epic and deliberately left out.

`tests/issue_60_field_test.gd` drives a scripted scenario through the session's own crossing
sampling and asserts the exact order, including a car a lap ahead sitting at an earlier checkpoint.
`-- --break-standings-order` re-ranks the session's entries without the lap term and must fail on
exactly that case; deleting the lap comparison from `MainSession._is_ahead_of` fails the same
assertion in a normal run.

### What #60 deferred

Deterministic final standings over a race, a full-field race, and contact not desyncing a run needed
#59's real drivers. #61 asserts all three in `tests/field_race_test.gd`; see "Driving the field (#61)".

### Driving the field (#61)

**One tick.** `MainSession._physics_process` drives the field before it handles the player's reset.
`_drive_field` builds the field as an array indexed by car index -- the player at 0, rival *n* at
*n*, a freed rival as a null the pass skips -- and walks `_rivals` in that order:

1. a rival whose own automatic reset fired drains the notice, reseeds its detector at the safe
   destination and sits the tick out (no senses, no new controls, no sampling);
2. every other rival **senses**, in index order: `sensing.sense(field, index, driver.sensing_horizon())`;
3. then each, in the same order, **perceives, drives** (`car.set_input_state(driver.drive(delta))`)
   and samples its own checkpoints.

A control set this tick moves nothing until the physics step, so every sense of a tick describes one
world. The order is the session's own list, never one a physics query or a dictionary decides. At
count 0 there are no rivals, no `SensingPass` is built and nothing runs.

**Spawn at the physics fixed point.** A physics step rebuilds a resting body's transform from its
angle in 32-bit `real_t`, which re-rounds a basis built any other way in its last digit. The #59 review
found that whether a step runs between spawn and first sense therefore decides which race the field
drives. In the session, on seed 0 with twenty rivals, a restart followed by one step before the first
sense changed 10 of 20 cars' control streams and swapped two finishers. A probe confirmed the rebuild
is exactly what the server does to a resting `RigidBody2D`, step for step. On seeds 0-19, 114 of 400 raw
grid poses are not fixed points.

*How the fixed pose is found.* The #59 review's fix rebuilt the pose until nothing changed. #61 first
capped that at 8 rounds, then 64; **neither was a fix**. The #61a review found seed 41's rivals 11-12 need
148 rounds and 13-14 need 14,670, and seed 58's 5-6 need 74; at the cap the code only logged an error and
placed them unsnapped. An exhaustive sweep then settled that no cap is safe: a C model of the rebuild
(`cosf`, `sinf`, `atan2f` from this machine's glibc, which matched the engine bit for bit on 1,000,000
angles while the double-precision variants did not) over every float32 angle in [-pi, pi] found runs of
about 3.7 million consecutive angles that a step moves.

So `_physics_fixed_pose` no longer iterates. It moves the rotation onto a lattice of 2^-16 rad -- every
point exactly representable in float32 -- and takes the nearest lattice angle the rebuild leaves
unchanged (nearest first, the higher angle first at equal distance), at the pose's own origin. Of the
411,775 lattice angles a rotation in [-pi, pi] can round to, 24,478 are moved by a step, and none is
more than `SPAWN_ANGLE_MAX_STEPS` = 6 steps from a fixed one, so a rival's rotation moves at most
6.5 x 2^-16 = 9.9e-5 rad from the grid's. The bound is exhaustive over the lattice, the C model found the
same 24,478 and the same worst case (6 steps, at 0.0337 rad), and `field_race_test` re-proves it in the
engine on every run, so it holds for whatever math library the suite runs on. Past it is a hard failure:
an assertion (a SCRIPT ERROR that aborts the spawn in any debug build or test) plus an error in release.

The player's pose is not snapped: it is `spawn_transform` exactly, which #60 pins, and on 6 of seeds
0-19 (0, 4, 7, 15, 16, 19) that is not a fixed point either. On seed 0 it did not reach the race --
both spawn phases above include it -- but that is one seed's observation, not a guarantee; the player
is a human's car in the game.

**A fresh physics space per race.** Separately, a restart into the viewport's existing space did not
reproduce the race. Measured in the session, seed 0, twenty rivals, snapped poses, each history in a
new process:

| Before the race's restart, in the same session | Cars differing from the reference race |
| --- | --- |
| nothing (the reference) | 0 |
| a full race on seed 0 itself | 20 |
| seed 1 for 600 physics frames | 18 |
| seed 1 for 5,900 physics frames | 18 (the same race as 600) |
| seed 1 for 600, then seed 2 for 600 | 0 |

These rows were measured with the iteration snap of the time. Seed 1 held for 600 or for 5,900 frames
gave the same race, so duration did not matter there; the rows show no simple rule about which tracks
were held (seed 0 itself changed all twenty, seeds 1 then 2 changed none). With `root.world_2d = World2D.new()`
before the restart, the first three histories each drove the reference race bit for bit. So
`restart_with_seed` now frees the previous race's track and cars and then gives the viewport a new
`World2D` (`_host_race_in_a_fresh_world`) before building; with that, all four histories above drive
one identical race. The persistent world nodes re-enter the new world's canvas, and a graphical
check showed the track, objects, cars, HUD and camera drawing after two restarts. **What inside a
reused space carries the history -- broadphase pairing, allocation order or anything else -- was not
measured**, and nothing here names it.

The swap is the session's viewport's (the root in the game; a `SubViewport` in the capture scripts), so
anything else living in that viewport moves into the new world with it. Measured (#61a fix round 1):
a `StaticBody2D` kept in the root beside the session was, after each of two restarts, in the new root
space -- `PhysicsServer2D.body_get_space` equal to it -- and a ray cast in a rival's world hit it 400 px
out. So the race's space is new only of what the restart freed; a body outside `World` is carried into
every race. In the game the session is the whole scene, so nothing is. `field_race_test`'s `FRESH WORLD`
assertion checks that the `World2D` object changed across the restart. That shows the swap ran; it
cannot tell a space holding nothing from before from one that carried an outside body in.

**What is asserted** (`tests/field_race_test.gd`, 43 checks, about 3.5 minutes):

- **A full-field race.** Twenty rivals on seed 0, mistakes off, the player idle at pole: every rival
  is watched driving and laps, none meets the stuck rule, none leaves the play area or gets lost. The
  longest slow streak is 62 of 120 ticks **on seed 0** since the stuck fix (91 before it); that is seed
  0's margin, not the field's. Other seeds are `capture_field_evidence`'s: see "Going round a stopped
  car (#61)" and "The field at size (#61)".
- **Deterministic final standings.** Race 1 is a new session's restart from an idle frame; race 2 is
  an in-session restart after the session has raced seed 1, called from a physics frame so one step
  runs before the first sense (0 steps against 1, counted by a probe body). Same finishing order, every
  rival on the same finishing tick, every rival's control stream identical at 64 bits.
- **Collision does not desync a run.** All twenty rivals touch another car before finishing (1,771
  contact ticks) and every one's stream is still identical.
- **The mistake switch is total**: on, all twenty drivers have mistakes on and each has drawn a mistake
  within 25 s; off, none has, none planned one and none logged one over the race.
- **Every rival spawns at a physics fixed point.** The lattice bound is re-proved over all 411,775
  angles in the engine; 200,000 random rotations (798 of which the old iteration needed more than 64
  rounds for) and every rival on seeds 0-19, 41 and 58 (one needing 14,670 rounds) are checked against
  it: fixed, at the grid origin, within 9.9e-5 rad.
- **Count 0** builds no sensing pass over 60 physics ticks; count 1 does and its rival drives.
- **A field that has to go round** (#61b fix round): twenty rivals on seed 41, the field that met the
  stuck rule on #61a's driver, race-1 protocol. All lap in 7,251 ticks, longest slow streak 85 of 120,
  none strays, 38 passes. `-- --break-go-round` fails its stuck assertion at 126 of 120.

Production mutations from the first round (when the suite had 32 checks), each run on a copy of the tree and failing by name with every check run:
the rivals back on `IdleDriver` (`FULL FIELD`, `DETERMINISTIC`, the contact guard, `SWITCH ON`: 13
failures); the switch ignored and forced off (`SWITCH ON`) or on (`SWITCH OFF`, both races); a
`SensingPass` built at count 0 (the count-0 check). The race on seed 0 cannot guard the snap's
bound -- no seed-0 pose is hard to snap -- so the pose checks are what do: see fix round 1's
falsifications in the task #61a report.

The test's probe body enters the race's space, so it is part of that space's history. On seed 0,
`capture_field_evidence`'s race A, which has no probe, finished in the same order, on the same last tick
(5,514) and with the same 1,771 contact ticks as this suite's race 1; streams were not compared between
the two files. What is asserted here is that one protocol reproduces itself across the two histories.
Scope: one seed, twenty rivals, one Linux machine, two histories varied. Cross-machine determinism of
Godot's 2D contact resolution is not established by anything here. `capture_field_evidence` repeats the
two histories on three more seeds (see "The field at size (#61)").

## The field at size (#61)

### Evidence across seeds

`tests/capture_field_evidence.gd`, run windowed (`godot --path . --script
res://tests/capture_field_evidence.gd`), races the production session on four seeds -- 0 and 41, which
the stuck fix was tuned on, and 4 and 58, which it was not -- four times each: A, a new session restarted
from an idle frame; B, a session that first races the next seed's track for 600 ticks and restarts from
a call deferred out of a physics frame; C and D, the same two with mistakes on. The player's car sits
idle at pole in every race. Then it races the game as launched and saves stills.

Asserted for every race: every rival laps; no rival meets the stuck rule at any tick (stricter than
"ends the race stuck"); none leaves the play area or its lost distance; the mistake switch is what the
race says. Asserted for each pair: A and B finish in the same order, every rival on the same tick,
every control stream identical at 64 bits; C and D log identical mistakes rival by rival -- guarded by
at least two kinds logged -- and finish the same way.

| Seed | Set | Last finisher (off / on) | Longest slow streak | Contact ticks | Passes | Reversals | Mistakes logged |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | tuned | 5,514 / 5,523 | 62 | 1,771 / 1,771 | 25 | 0 | 31, three kinds |
| 41 | tuned | 7,251 / 7,251 | 85 | 5,383 / 5,383 | 38 | 6 | 36, two kinds |
| 4 | held out | 6,489 / 6,495 | 50 | 945 / 903 | 14 | 0 | 36, three kinds |
| 58 | held out | 6,086 / 6,087 | 59 | 2,755 / 2,755 | 27 | 5 | 34, three kinds |

141 checks, 0 failures, twice; the two runs' ledgers (`docs/evidence/ai-opponents/field-ledger.txt`,
one line per race with SHA-256 digests of every stream and log) are byte-identical. On every seed the
mistakes-on streams differ from the mistakes-off ones, so the logs compared are of mistakes that acted.

**The game as launched** -- `main.tscn` on its shipped settings, nothing overridden: ten rivals, mistakes
on, seed 0. All ten lap (last on tick 5,174), longest slow streak 46, none strays, 19 mistakes logged,
8 passes. Stills: `launched-seed-0-grid.png` (the field leaving the grid past the idle player),
`launched-seed-0-under-way.png` (the leader at 20 s) and `seed-41-going-round.png` (the first tick a
rival on seed 41 is going round a stopped car, 4.3 s in, centred on it). The stills come from sessions of
their own, with the simulation all but held while a frame is drawn; they assert nothing about the race.

**The player's pose.** It is not snapped: `issue_60_field_test` pins it to `spawn_transform` exactly, and
on 6 of seeds 0-19 that is not a physics fixed point. Seeds 0 and 4 are two of those six, and on both the
two spawn histories drove the identical race, streams included. That is two seeds' observation; the pin
stands, and nothing guarantees it on the other four.

**Scope.** Four seeds reproduced across two histories, twenty-two raced once (the sweep above), one
machine, one Godot build. That the same seed races the same way on another machine, or with another
libm, is not shown by anything here.

### Cost

`tests/capture_field_cost.gd`, run windowed: the production session in the game window on seed 0, the
player idle, physics at 60 ticks a second in real time, vsync off and the frame rate uncapped so a frame
lasts as long as its work. Each count is measured over the first 3,600 ticks of its race, launch
included. Nothing else of this task ran alongside; the machine's own load average, from other programs, is
recorded in each file. Intel i7-10510U, Mesa Intel UHD Graphics (CML GT2).

Two runs back to back on the final driver; each cell is run 1 / run 2. Microseconds, per physics tick or
per frame:

| Rivals | Sensing, mean | Decisions, mean | Physics tick span, mean | Frame with a tick: mean | p95 | max |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0 / 0 | 0 / 0 | 58 / 57 | 1,973 / 1,972 | 2,614 / 2,609 | 10,556 / 6,982 |
| 1 | 275 / 278 | 57 / 59 | 394 / 399 | 2,490 / 2,504 | 3,326 / 3,295 | 6,541 / 7,838 |
| 5 | 1,176 / 1,166 | 186 / 188 | 1,455 / 1,447 | 3,950 / 3,937 | 5,380 / 5,179 | 9,071 / 8,267 |
| 10 | 2,208 / 2,213 | 318 / 322 | 2,652 / 2,663 | 5,554 / 5,575 | 7,145 / 7,271 | 11,613 / 13,224 |
| 20 | 4,319 / 4,303 | 575 / 580 | 5,070 / 5,054 | 8,820 / 8,796 | 10,910 / 10,525 | 19,051 / 15,902 |

**Per-car marginal cost** of the mean, per added rival:

| From | To | Sensing | Decisions | Physics tick span | Frame with a tick |
| --- | --- | --- | --- | --- | --- |
| 0 | 1 | 275 / 278 | 57 / 59 | 337 / 343 | 517 / 532 |
| 1 | 5 | 225 / 222 | 32 / 32 | 265 / 262 | 365 / 358 |
| 5 | 10 | 207 / 209 | 26 / 27 | 239 / 243 | 321 / 328 |
| 10 | 20 | 211 / 209 | 26 / 26 | 242 / 239 | 327 / 322 |

**The curve is linear as measured, if anything slightly less than linear.** A rival added between ten and
twenty costs what one added between five and ten does in every column, and no more than one between one
and five. Nothing proportional to the square of the field shows at this size: the sensing pass's rival
scan walks the whole field for every car, and at twenty it is not visible against the queries.

**Budget at twenty, as measured: a frame holding a physics tick averages 8.8 ms, 10.5-10.9 ms at the 95th
percentile and 15.9-19.1 ms at worst, against 16.6 ms.** Headroom is 7.8 ms on the mean and 5.7-6.1 ms at
the 95th percentile; the worst frame of one run overran. With no rivals the worst frames already reach
7.0-10.6 ms, so the tail is not the field's alone. Most of the field's cost is the sensing pass, about
210-280 us a rival; decisions are about 26-59 us. The maximum was not lowered.

**Load moves these.** The same capture run twice on the commit before the last driver change (which alters
one comparison in a reversal) with the machine's load average at 2.3-3.5 instead of 1.6-1.9 gave, at twenty
rivals, frames of 10.0-10.5 ms mean, 13.0-15.1 ms at the 95th percentile and 19.8-24.0 ms at worst, sensing
4.9-5.1 ms, and the same linear shape (`field-cost-earlier-run-1.txt`, `-2.txt`). Plan with that band.

What the columns are:

- *Sensing* and *decisions*: `MainSession._drive_field`, copied line for line into a subclass with clock
  reads between its sense loop and its perceive, drive and checkpoint loop. The capture first checks that
  copy leaves all twenty-one cars at bit-identical transforms and velocities after 1,200 ticks against the
  production session, and the query wrappers below the same.
- *Physics tick span*: from the tree's `physics_frame` signal to the next `process_frame`, on frames
  holding exactly one tick. It holds every `_physics_process`, the field's drive included, and the server's
  step. It does **not** hold the cars' `_integrate_forces`: the query pass below measures the cars' own
  queries alone -- which run inside `_integrate_forces` -- at about 820 us a tick at twenty, while the span
  leaves only about 175 us beyond the field's drive. The frame figure holds everything.
- *Frame with a tick*: wall time between consecutive `process_frame`s. Frames without a tick took
  1.8-2.4 ms at every count (the renderer and the uncapped present); the renderer's own CPU and GPU times
  were 0.6-0.7 ms and 1.1-1.5 ms at every count.

**Height and surface queries across the field** (final run 2, sped up, the first 1,200 ticks at twenty
rivals; each figure includes the timing wrapper's own 1.1-1.4 us per call):

| Asked by | Query | Calls a tick | us a tick | us a call |
| --- | --- | --- | --- | --- |
| cars' own physics | `HeightQuery.sample_at` | 42 | 319 | 7.6 |
| cars' own physics | `SurfaceQuery.sample_at` | 21 | 503 | 24.0 |
| sensing | `SurfaceQuery.road_frame_at` | 40 | 2,504 | 62.7 |
| sensing | `HeightQuery.sample_at` | 40 | 450 | 11.3 |
| sensing | `SurfaceQuery.sample_at` | 20 | 431 | 21.6 |

The two road frames a car senses are more than half the sensing pass. The cars' calls include the idle
player's.

**Against the calibration figures.** #57 measured twenty cars sensing at 2.26 ms and #58's sixth query
raised it to about 4 ms (`driver_senses_test`, twenty cars placed around the lap, one pass each). In the
running session twenty rivals sense in 4.3 ms a tick on the mean (4.9-5.1 ms at the higher load). The
conditions differ -- a real race from its launch, cars bunched and off the racing line, clock reads inside
the loop -- and which of them accounts for any difference was not measured.

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
| Where the road is, under the car and at the look-ahead point | `SurfaceQuery.road_frame_at` | Analytic, indexed, the same centerline the car's own rules read |
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

The four `road_found` / `road_ahead_found` / `has_rival_ahead` / `has_obstacle_ahead` booleans gate
the fields around them. When one is false its fields are zero and mean nothing; the flags are the
contract.

### The road ahead (#58)

`road_ahead_found`, `road_ahead_lateral_offset` and `road_ahead_heading_error` are the road at the
look-ahead point -- where the ground probe and the ray already end -- read exactly as the road under
the car is. They are the one sense #58 added, and it was needed rather than convenient: the car
brakes at 15.5 m/s², so shedding top speed for a tight corner takes most of a look-ahead, and nothing
under the car says a corner is coming until the car is in it. That physics is the case for the sense.
The measurement agrees without settling it: with the three fields blanked, the committed driver still
finishes seeds 0-2 but spends 7.0-10.8% of each lap on the grass, three excursions each; with them,
none (`tests/reactive_driver_test.gd -- --blind-to-road-ahead` reproduces it). The suite's 5% off-road
bound, which the blind driver fails, was set after both figures were seen, so it is not independent
evidence.

`heading_error - road_ahead_heading_error` is how far the road turns between the two points, and the
car's own heading cancels out of it. The reading comes from the nearest centreline segment to the
point, which on a winding circuit can be a different stretch of the lap; the fields say so rather
than pretend otherwise. `_verify_the_road_is_read_ahead_of_the_car` pins both values beyond a
30-degree bend, both ways round, against the fixture's geometry; answering "ahead" from the road
under the car fails four named assertions.

`rival_relative_velocity`'s comment said negative y is closing. It is the rival's velocity minus this
car's, so a rival ahead gets closer as y grows; the comment is corrected and the value never moved.

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
the single dial that most changes behaviour and task #59 varies it by skill. It bounds all four
forward senses: the road ahead, the ground probe, the rival scan and the ray. It is also both road
queries' search radius, which makes it the dial that moves the cost. A driver states the horizon it
wants through `sensing_horizon()`.

### The budget

A pass costs a **fixed six queries** whatever the world contains, none of them inside a loop. #58's
road ahead is the sixth:

| Query | Count |
| --- | --- |
| `SurfaceQuery.road_frame_at` (under the car, and at the look-ahead point) | 2 |
| `SurfaceQuery.sample_at` (under the car) | 1 |
| `HeightQuery.sample_at` (under the car, and at the look-ahead point) | 2 |
| `intersect_ray` | 1 |

The rival scan issues none. `driver_senses_test` counts all six through fixtures the pass does not
own — wrapped queries for the surface and height calls, a subclass override for the ray — and pins
that twenty cars spend exactly a hundred and twenty.

**Nothing is written, nothing is moved, and no sample is held across a query.** `TrackHeightMap`
hands back one shared, re-zeroed sample on its miss path, so the ground under the car is read out
into a local before the ground ahead is asked for. The order of those lines is the contract;
`_verify_ground_ahead_survives_a_shared_sample` drives a provider that behaves the same way and
would read a flat world if the order changed.

### Cost

Measured on seed 0 with the track's real trees and rocks in the space, twenty cars spread around the
lap and across the road's width, a 400 px look-ahead. **These are wall-clock numbers and they move
with machine load — read them as a band, not a constant.** Each range spans the extremes actually
observed across every measured run, from an idle machine (load 1.3) to one under a concurrent build
(load 3.2):

| Case | Per car | Twenty cars | Of a 16.6 ms frame |
| --- | --- | --- | --- |
| On the racing line (ray runs full length, hits nothing) | 104–161 µs | 2.1–3.2 ms | 12–19% |
| Parked in front of a solid (ray hits) | 74–113 µs | 1.5–2.3 ms | 9–14% |

The racing-line figure is the one to quote: a ray that hits stops early, so the miss is the worst
case. It is also the normal case, because the nearest solid on a generated circuit stands 375 px
from the centerline — further than a look-ahead — so a car **on** the road never sees one. The ray
earns its place on the recovery path, where a car that has run wide is among the trees.

Roughly half the pass is the two surface queries, which walk the segment grid over the same point
twice. The look-ahead curve, printed by the suite, across the same band:

| Look-ahead | Per car | Twenty cars |
| --- | --- | --- |
| 200 px | 92–124 µs | 1.8–2.5 ms |
| 400 px | 98–147 µs | 2.0–2.9 ms |
| 600 px | 112–201 µs | 2.2–4.0 ms |

The conclusion does not depend on where in the band a machine lands: even the loaded end leaves five
times the headroom the ×20 assertion needs. Plan with the upper figure.

**After #58's sixth query.** The tables above are the five-query pass. Re-measured with the road ahead
added -- three runs back to back at load 1.3-1.5, so a narrower band than the one above and not
directly comparable to it:

| Case | Per car | Twenty cars | Of a 16.6 ms frame |
| --- | --- | --- | --- |
| On the racing line, 400 px | 165–189 µs | 3.3–3.8 ms | 20–23% |
| Parked in front of a solid, 400 px | 96–98 µs | 1.9–2.0 ms | 12% |
| Look-ahead 200 px | 120–124 µs | 2.4–2.5 ms | |
| Look-ahead 600 px | 198–203 µs | 4.0–4.1 ms | 24% |

`ReactiveDriver` senses at 600 px, so the last row is the one a field of reactive drivers pays: about
4 ms of every frame for twenty, before their physics. #61 measures the whole thing at size.

## Reactive driving (#58)

`ReactiveDriver` (`ai/reactive_driver.gd`) turns one tick's `DriverSenses` into a `VehicleInputState`.
It has no route, no waypoint list and no memory of the lap. Between ticks it keeps only what a driver
keeps: whether it is backing out of something and for how long, which way it chose to turn round, the
last tick's `height_change_ahead` (lift reads a rate), and its recovery counts. Nothing it holds says
where on the circuit it is.

### Four jobs

**Steer**, as a yaw rate asked for and divided by what full lock gives at this speed:

```
yaw = -2.4 * course_error - 2.4 * clamp(1.44 * offset / (2.4 * v), +-0.6) + 0.8 * v * turn / look_ahead
```

Two terms, because the lateral offset then obeys `offset'' + 2.4 offset' + 1.44 offset = 0` at every
speed: critically damped at 1.2 rad/s. The heading term *is* the damping; without it the offset term
is an undamped spring. The heading term reads the **course** -- heading error plus the slip angle
from `local_velocity` -- because near the grip limit the nose points down the road while the car
slides off it; damping the nose alone left seed 2 sliding wide through a long right-hander at the
corner speed it had judged correctly. The feed-forward is the road's own turn across the look-ahead,
from which the car's heading cancels, so it adds no heading information of its own.

**Slow down.** Every reason is a distance and a speed the car must be down to by then, and all of them
go through one braking distance, `(v² - v_req²) / (2 · 12 m/s²) + (v - v_req) · 0.15 s`:

| Reason | Distance | Down to |
| --- | --- | --- |
| What it cannot see | the look-ahead, less 2 m | the speed for the tightest corner it expects (16 m at 13.6 m/s²) |
| A corner ahead | where the bend starts | that bend's corner speed |
| A road edge closing across the nose | where the nose would cross it on a straight road | 14 m/s, a speed it can turn away at |
| A rival in its path | the gap, less 6 m | the rival's speed; inside the 6 m and not closing, it drops back |
| An obstacle on the ray | its distance, less 4 m | a stop |

The corner is read from the two road-ahead readings as a straight that becomes an arc: an arc of
length b and radius R turns b/R and pushes a point on the straight's line b²/2R outside it, so the turn
and the look-ahead point's unexplained offset give both. "In its path" is judged across the road, not
off the nose line: the rival's offset is turned into the road's frame and the road's bend is taken off,
or a car stopped mid-bend reads as beside the path. On top sit speed caps for the car's state now: 12
m/s on grass, easing from 20 to 10 m/s as the heading error grows from 0.35 to 0.9 rad, 5 m/s wrong way
round.

**Lift** when the ground ahead falls away relative to the ground under the car faster than 0.03 per
pixel travelled, above 20 m/s. A rate, not a level: across a 600 px horizon a plain downhill drops
further than a ramp's 9 px crest, and a ramp on rising ground can read level. Measured on tuning laps,
climbing a ramp face reads 0.043-0.073; terrain rarely reaches 0.03. The level rule it replaced lifted
for 22-29% of the lap on the three tuning seeds measured and still missed launches.

**Recover.** Slower than 1 m/s for 0.5 s while racing: reverse for 1.6 s with the nose swinging the way
the road steering wanted, then 1 s of grace; a reversal not rolling backwards at 0.25 m/s by 0.8 s ends there (#61).
Stalled behind a rival in its lane: go round it instead (#61, below). Wrong way round (heading error
past 90 degrees): full lock in one committed direction, held across the ±π seam. Off the road: the
steering already heads back, at up to 0.6 rad, under the grass cap. Road not found at all: ask to sense
at 120 m until it is.

### What it believes about its car

A driver holds no car and no tuning, so its model of its own car is written in the driver as beliefs,
pessimistic on purpose against `default_vehicle_tuning.tres`:

| Belief | Driver | The car |
| --- | --- | --- |
| Braking | 12 m/s² | 15.5 m/s² |
| Cornering it will ask for | 13.6 m/s² | about 22 m/s² before the lateral limit |
| Full-lock yaw rate | 1.75 rad/s above 18 m/s | the same (`max_steering_rate`, `steering_full_speed`) |
| Tightest corner | 16 m | the generator's `MAX_CURVATURE`, 0.005 /px |

A session that tunes the car differently leaves the driver's beliefs where they are. That is the
price of a seam that refuses a tuning handle.

### Look-ahead is the skill dial

48 m (600 px) by default -- skill 1.0 since #59, whose skill dial runs it from 36 m to 48 m. Every
one of the fifteen proof seeds laps cleanly from 30 m to 60 m, and the time moves smoothly with it,
which is what #59 needs from it:

| Look-ahead | Clean laps | Lap times |
| --- | --- | --- |
| 30 m | 15 / 15 | 76.6-106.1 s |
| 38 m | 15 / 15 | 69.9-96.6 s |
| 48 m | 15 / 15 | 64.0-87.9 s |
| 60 m | 15 / 15 | 59.4-80.5 s |

At 48 m the "what it cannot see" rule caps the car at 437 px/s. That is where most of the lap time
between the rows goes.

### What braking distance does and does not carry

`--break-brake-distance` makes the braking distance a constant: the production answer from half of
`max_safe_speed` to rest, 389 px. **It still completes every lap, cleanly and 15-20% faster**, and it
does not trip the stuck rule. Nothing that drives in the suite can tell the speed-dependent term from a
well-chosen constant on this generator's circuits. The review of #58 went further: a constant of 450 or
500 px passes the whole suite -- every lap, recovery, parked-rival stop and the field -- except one unit
check.

**The one guard is a unit check.** `_verify_braking_distance_grows_with_speed` pairs an obstacle 300 px
ahead at 150 and 400 px/s. It fails for *any* constant, because 250 px of room separates its two speeds:
a constant of 250 px or more brakes the slow case, and one under 250 px lets the fast case drive on.
That is a genuine guard for the formulation, but it is not the lap test or the stuck rule the issue
names.

Why laps do not need the term, measured across all fifteen seeds by the review:

- **The driver's beliefs are pessimistic, and that is the main reason.** With rolling and aerodynamic
  drag added to the brakes, the car's real stop from its capped 437 px/s is about 380-390 px; the driver
  believes 702 px. From 595 px/s it is about 620 px against a belief of 1269. The 389 px constant is
  almost exactly the car's real stop from its capped speed. Cornering is believed at 13.6 m/s² against
  about 22. A car that stops roughly twice as hard as its driver thinks makes almost any constant in a
  broad band work. A driver whose beliefs matched its car -- one lever #59 has -- would lose this slack.
- **Generated corners arrive gradually.** The corner rule binds on 0-326 ticks a lap, never at all on
  seeds 3 and 7, at most 208 px out and with at most 267 px of braking distance when it does -- all under
  the constant, which therefore brakes earlier there, not later.
- **The visibility cap is the speed governor**, the tightest margin on 2,788-4,583 ticks of every lap,
  and it only ever trims the throttle. The constant switches it off. With the cap removed from production
  instead, the car still laps every seed cleanly at about 595 px/s.

The parked-rival stop is a test of the **rival rule**: remove `_rival_margin` and the car hits the
parked rival at 411-437 px/s. It is not a guard for speed-dependent braking. The production driver comes
to rest with its centre about 65 px from the rival's -- a 13 px gap between bumpers -- on all three seeds,
two of them on bends. The 389 px constant, braking from about 478 px/s, hits the rival on all three at
122-131 px/s (about 10 m/s), measured on the tick before contact. It fails there only because 389 px is
close to the car's real stop; every constant from about 450 px passes. A contact count says nothing about
how hard a car hit a frozen body -- two ticks for the 10 m/s hit, and two for a 430 px/s one with the
rival rule removed. The field of twenty also passes under the constant (worst contact 2.3%).

### Proof

`tests/reactive_driver_test.gd`, against the production world -- `TrackRuntime` with its trees, rocks and
play-area boundary in the physics space, the production surface and height maps, a production
`SensingPass` -- with the car's **automatic reset off**, so nothing but the driver gets it home.

- **Laps** on fifteen seeds: tuned on 0-4, and 5-14 run for the first time only once tuning was frozen.
  Every lap completes, is never outside the play area or beyond the car's own lost distance, never
  meets the stuck rule, spends at most 5% of its ticks off the dirt (every seed: 0.00%), and leaves the
  ground on every flight with the throttle released. No lap needed a recovery.
- **Stuck** is the car's own rule, the one its automatic reset fires on -- slower than
  `auto_reset_stuck_speed` (2 m/s) for `auto_reset_stuck_seconds` (2 s) -- applied everywhere, not only
  off the road. Fixed before anything was measured against it.
- **Recovery** from three placed starts per seed on 0, 1, 2, 5, 6 and 7 -- wrong way round, off the road
  facing away from it, and pinned nose-first against a rock -- each back to racing (two consecutive
  checkpoints crossed forward) in 19-27 s without meeting the stuck rule. Each start carries a guard
  that it really was what it claims -- a guard on the start, not the recovery; the rock guard is the ray
  reading the rock at the 28 px it was placed at. The off-road start faces straight away from the road,
  90 degrees off its direction, which reads as wrong-way on five of the six seeds, so it mostly
  exercises the turn-around from off the road. Removing the stall reversal leaves every pinned start
  sitting there until the stuck rule trips.
- **A field of twenty** on seed 0, every car a `ReactiveDriver` on the session's grid (restated in
  the suite, since the session's own method is private): all twenty lap, none meets the stuck rule
  (longest slow spell 45 of 120 ticks since #61's stuck fix, 85 before), none strays, and no car touches
  another for more than 5% of its lap (worst 2.0%; 3.3% before). A baseline for #61, which owns the field. The 5% was set after the fact: the
  first exploratory fields spent 20-40% of their laps in contact, because the rival rule only acted
  while closing and a car that crept inside the gap at equal speed rode the bumper in front.
- **Determinism**: two cars from the same pose on the same seed produce identical control streams, all
  four values kept at the 64 bits `VehicleInputState` holds them at, over a whole lap (4692 ticks on
  seed 3). A start 1 px to the side differs from tick 0, which is what shows the comparison can see a
  difference.
- **Senses only**: every field the driver declares is plain data, and the only object any of its
  methods, own or inherited, accepts is `perceive()`'s `DriverSenses`. `ai_driver_contract_test` walks
  `ReactiveDriver` alongside the neutral drivers. The walks cannot see a global reached by name; by
  inspection the driver names nothing outside itself but `WorldScale`'s pure conversions, the
  `SurfaceQuery.SurfaceType` enum, and the `VehicleInputState` it returns -- no autoload, no static
  state, no clock and no random number. (#59 adds `DomainSeed`'s pure hash, the same one `AiDriver`
  already derived its identity with; the draws it makes are the seeded mistakes, not a random number.)

| Seed | Set | Lap | | Seed | Set | Lap |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | tuned | 66.32 s | | 8 | held out | 64.87 s |
| 1 | tuned | 84.17 s | | 9 | held out | 85.75 s |
| 2 | tuned | 64.02 s | | 10 | held out | 84.65 s |
| 3 | tuned | 78.20 s | | 11 | held out | 65.32 s |
| 4 | tuned | 84.13 s | | 12 | held out | 81.23 s |
| 5 | held out | 80.27 s | | 13 | held out | 87.85 s |
| 6 | held out | 72.52 s | | 14 | held out | 69.07 s |
| 7 | held out | 76.77 s | | | | |

The map-following `LapDriver` the terrain suites lap with does 69.6-86.8 s on seeds 0, 4 and 9.

### Limits worth knowing

- **Rocks on raised ground are not there for a grounded car.** `TopDownCar` picks its collision mask
  from its absolute height, so on terrain above the 12.5 px low-obstacle clearance it neither hits nor
  senses rocks. That is the limitation the terrain epic deferred; the pinned-rock starts pick rocks a
  grounded car can hit, and two first attempts that did not showed a car "pinned" beside a rock its
  ray could not see.
- **No overtaking, and nothing alongside.** The senses carry only the nearest rival *ahead*; a car
  beside or behind is invisible, and every car's offset term pulls it to the centreline, so where the
  grid's two columns merge the cars rub. A car catching a moving rival follows it; nothing steers round
  it. A rival stopped in the road is followed to a halt, and since #61 the car then goes round it (see
  "Going round a stopped car (#61)"); that is not overtaking, and a slow car is still followed.
- **The visibility cap costs time on these circuits** (see above) without buying a lap. It is kept for
  circuits whose corners arrive faster than this generator's.
- **One field, one seed, in this suite.** The rival rules are asserted on synthetic senses, against one
  parked rival and in one field of twenty on seed 0. How the session's field behaves across seeds is
  #61's capture: see "Going round a stopped car (#61)".

### Going round a stopped car (#61)

With twenty rivals on seed 41 the session's field met the stuck rule. The fix is in the driver; the
stuck threshold did not move and no car is exempt from it.

**Diagnosis, from measurement.** Everything below was run in the session, seed 41, twenty rivals,
mistakes off, the player idle at pole, restarted from an idle frame (race A of the capture), on the
driver as #61a left it.

- *Which cars, and how badly.* Longest slow streaks 144, 128, 125 and 121 ticks against the rule's 120
  (rivals 19, 18, 20, 13); rivals 4-20 finished 1,800-3,300 ticks behind rivals 1-3, whose worst streak
  was 7. The #61a review measured 177 on the same seed under the snap of its time.
- *Where.* A snapshot of the whole field every two seconds showed the idle player's car shoved down the
  road by the grid's launch -- 273 px from pole at 4 s, 898 px at 20 s -- where it came to rest 22 px off
  the centreline, with seventeen rivals behind it along the lap.
- *What the slow cars were behind.* For every rival-tick in a slow streak of 30 ticks or more, a probe
  walked the chain of "the car in my lane within 150 px ahead" to its head, and labelled the head still or
  moving against the stuck rule's 25 px/s. Of 4,698 such ticks, the player's car headed 1,549 -- 913 while
  moving, 636 at rest -- more than any single rival. Rivals headed the other 3,149, 2,148 of them while
  moving and 1,001 at rest. The probe does not group cars into queues.
- *The variable, varied alone.* The same race with the player's car moved out of reach before the first
  step: longest streak 89, no rival over the rule, 829 slow rival-ticks, the field home by tick 6,690
  instead of 8,882.
- *Why it cycled.* A rival reaching the stopped car held its 6 m following gap, stalled, reversed for
  1.6 s, and drove up to the same car again; the field logged 126 reversals. A per-tick trace of the
  four worst streaks after a first attempt at a fix (below) showed the arithmetic: in three of them,
  88-97 ticks were a reversal spent in contact with other cars and not rolling backwards (rival 13's
  trace shows it creeping forwards at 7-9 px/s with reverse held), in a queue whose cars behind the driver cannot see. A 0.5 s
  stall plus a blocked 1.6 s reversal is 126 ticks under the rule's speed, so a blocked reversal meets
  the rule by construction.

The #58 review's lead -- a car stopped behind a stationary rival reverses after 0.5 s and can cycle --
was the right one. On seed 41, what put a stopped car at the head of the slow field was the idle player's
car; that counterfactual was run on seed 41 and nowhere else by this task. **It is not the cause
everywhere.** The #61b review repeated it on #61a's driver on three other seeds that met the stuck rule:
with the player's car out of reach, seeds 10 and 17 cleared (longest streaks 84 and 72) but seed 5 still met
the rule: longest streaks 152 (rival 18) and 146 (rival 16), 18 reversals, 729 slow rival-ticks. This task
re-ran that probe on seed 5 and got the same figures; with the player in place the same field reached 206. What stalls seed 5's field without the player was not diagnosed.

**The fix.** A stall with a rival in the lane within `PASS_BLOCKED_GAP_M` (8 m) at any tick of the stall
is a blocked stall, and the driver goes round rather than backing out:

- it aims `PASS_CLEARANCE_M` (4 m) to the side of the nearest rival ahead with more road, never nearer an
  edge than 1.5 m, at no more than 8 m/s, judging rivals against the line it aims for rather than the
  one it is on (the rival it is passing is beside that line by construction);
- it lets go once no rival has been within 12 m ahead for 1 s, or after 6 s; mistakes do not begin
  while it is passing;
- a second blocked stall while passing reverses, the nose swinging toward the other side;
- a reversal that is not rolling backwards at 0.25 m/s by 0.8 s ends -- a car backing into a queue it
  cannot see stands still or is pushed forwards.

The last bound was first 1 m/s. Running every mutation flag afterwards showed it cutting short a
legitimate reversal: on grass, begun from a creep forwards, a traced reversal was rolling back at about
10 px/s by 0.8 s, and `reactive_driver_test`'s seed-0 off-road start under `--break-brake-distance` met
the stuck rule (141 of 120 ticks), a failure that suite never had before. At 0.25 m/s that start is
back to exactly #61a's result (109 ticks, 21.10 s), and seeds 0 and 41's fields race exactly as they did
at 1 m/s. The change was made after the held-out seeds had been raced once, from a solo trace rather
than a field. The sweep below was raced again on the final driver: every seed's ledger line came out
identical but seed 6's, where seven rivals finished 6-15 ticks sooner (the table's figures for it did
not change).

What stopped the car is remembered across the stall because, in a knot of cars, the nearest one ahead
changes from tick to tick and the car that stopped this one may be beside it by the stall's last tick.
Nothing here reads a rival's identity; the senses carry none.

**How it was reached, on the tuned seeds 0 and 41.** Each step was measured before the next:

| Driver | Seed 41 longest streak | Rivals over the rule | Seed 0 |
| --- | --- | --- | --- |
| #61a | 144 | 4 | 91 (the suite's race) |
| reverse toward a passing side, then pass | 148 | 4 | 65 |
| pass forwards first, reverse on a second stall | 110 | 0 | 62 |
| and end a reversal that is not reversing | 109 | 0 | 62 |
| and remember what stopped the car across the stall | 85 | 0 | 62 |

Solo driving is untouched: with no rival nothing new runs, and `reactive_driver_test` reproduces #58's
fifteen lap times to the hundredth with no recovery and 0.00% off road. The parked-rival stop still comes
to rest 65 px behind the rival without touching it, because the pass begins only after the stall. In the
suite's own field of twenty on seed 0 the longest slow streak went from 85 to 45 and the worst contact
from 3.3% to 2.0%.

**Unit checks** (`_verify_it_goes_round_a_stopped_car`, synthetic senses): a stall behind a rival in the
lane starts a pass, not a reversal, and drives off to the roomier side without braking for that rival,
both ways round; a second stall reverses toward the other side; a stall with the rival 100 px beside the
path is an ordinary reversal; a rival in the lane for the stall's first ticks and beside the path by its
last still starts a pass; a reversal not rolling back 0.8 s in ends, one rolling back at only 10 px/s
does not. `-- --break-go-round` (no stall is ever caused by a rival) fails seven of them by name; the two it
should not touch pass.

**Widened, tuned versus held out.** Tuned on seeds 0 and 41 only. `tests/capture_field_evidence.gd
-- --sweep` raced one field of twenty on each of seeds 0-19, 41 and 58 -- the twenty held-out seeds first
raced at `ba10ad0`, and all 22 re-raced on the final driver -- on the fixed driver, and on a copy of the tree with #61a's driver restored. Race A of the capture:
a new session restarted from an idle frame, mistakes off, the player idle at pole. Run headless: the
sweep asserts and saves no stills.

| Seed | Set | Before: longest streak | Reversals | After: longest streak | Passes | Reversals |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | tuned | 91 | 36 | 62 | 25 | 0 |
| 41 | tuned | **144** | 126 | 85 | 38 | 6 |
| 1 | held out | 81 | 17 | 45 | 14 | 0 |
| 2 | held out | 66 | 26 | 49 | 25 | 0 |
| 3 | held out | 118 | 52 | 59 | 43 | 5 |
| 4 | held out | 87 | 22 | 50 | 14 | 0 |
| 5 | held out | **206** | 163 | 81 | 43 | 1 |
| 6 | held out | 89 | 24 | 61 | 22 | 7 |
| 7 | held out | 110 | 66 | 72 | 30 | 0 |
| 8 | held out | 103 | 17 | 75 | 13 | 0 |
| 9 | held out | 78 | 20 | 49 | 17 | 0 |
| 10 | held out | **175**, 10 of 20 lapped in 240 s | 444 | 104 | 30 | 2 |
| 11 | held out | **122** | 32 | 86 | 26 | 6 |
| 12 | held out | 88 | 33 | 47 | 23 | 0 |
| 13 | held out | 87 | 23 | 62 | 23 | 0 |
| 14 | held out | 99 | 53 | 88 | 39 | 7 |
| 15 | held out | **127** | 47 | 80 | 35 | 2 |
| 16 | held out | 98 | 52 | 87 | 35 | 2 |
| 17 | held out | **144** | 236 | 75 | 42 | 3 |
| 18 | held out | 81 | 37 | 93 | 38 | 8 |
| 19 | held out | 114 | 22 | 45 | 18 | 0 |
| 58 | held out | 86 | 30 | 59 | 27 | 5 |

Before the fix, 6 of the 22 fields met the stuck rule -- one of the two tuned seeds and five of the twenty
held out -- and on seed 10 half the field had not lapped after four minutes. After it, all 22 lap with
nobody stuck and nobody out of the play area: longest streak 85 of 120 on the tuned seeds, 104 on the
held-out ones (seed 10). Seed 18 is the one seed slower after the fix than before (93 against 81). The
margin is not large everywhere: 16 ticks on seed 10. These are 22 seeds, one race each, one machine.

**The fix bites.** The "before" column is the falsification: the same capture on the tree with #61a's
`ai/reactive_driver.gd` restored exits 1 with `FAIL: STUCK: seed 41 (tuned) A(mistakes off, new session,
idle frame): all 20 rivals were watched driving and none meets the stuck rule (20 watched, longest slow
streak 144 of 120 ticks, by rival 19)`, beside the same failure on seeds 5, 10, 11, 15 and 17 and a LAP
failure on seed 10. On the committed tree the same seeds pass. Of the nine unit checks above, the restored driver fails
eight; the ninth, the ordinary stall beside the path, passes as it should.

## Skill and deliberate mistakes (#59)

A deliberate mistake and a bug look identical from outside, and this project's review culture rests
on telling them apart. So nothing here is emergent: skill and every mistake come from the car's own
seed streams (see the contract above), every mistake is typed and logged, and mistakes are **off
unless someone turns them on**. A `ReactiveDriver` built the ordinary way is flawless.

### Skill: one dial

`ReactiveDriver.skill` is one number per car in [0, 1), from `SKILL_STREAM`. It turns three things
together, linearly, and nothing else:

| Skill | Look-ahead | Cornering it will ask for | A mistake every |
| --- | --- | --- | --- |
| 0.0 | 36 m | 12.0 m/s² | 10 s of clean racing, on average |
| 0.5 | 42 m | 12.8 m/s² | 20 s |
| 1.0 | 48 m | 13.6 m/s² | 30 s |

**Skill 1.0 is #58's driver exactly.** Each dial is its 1.0 value less `(1 - skill)` times its span,
so at 1.0 nothing is computed that could round, and `tests/reactive_driver_test.gd` -- which pins
every one of its drivers to 1.0 -- reproduces all fifteen of #58's lap times to the hundredth.

**Why 36-48 m.** The top is the reviewed driver, so nothing new has to be proved about the fast end.
The bottom sits inside the band #58 already showed laps cleanly on all fifteen seeds (30-60 m), and
lower skill only ever looks less far and corners more gently -- both slower, neither less safe.
Measured on seeds 0-4 with mistakes off, skill 0.0 laps 12.8-13.8% slower than 1.0 (seed 0: 74.83,
70.05, 66.32 s at 0.0, 0.5, 1.0): wide enough to see, and the slowest car in the table is still
nowhere near the stuck rule. `set_skill` pins it, clamped to [0, 1].

### Mistakes: three kinds

| Kind | What the driver does | Bounded by |
| --- | --- | --- |
| `LATE_BRAKE` | where a corner asks for braking, withholds **the corner's** brake for 4-12 m of travel | never the brake for a rival, an obstacle, an edge or the limit of vision |
| `WIDE_LINE` | through a bend, aims 2-5 m to the outside of the centreline for 1.5-3 s | the **aim** is capped 6 m from the edge, and the mistake cannot begin, and ends that tick, with the **car's** centre within 6 m of either edge. What the car keeps is measured, below |
| `NEEDLESS_LIFT` | on a clear straight above 18 m/s, takes the throttle off for 0.4-1.2 s | throttle only: no brake, the same steering |

Mistake n's kind, amount and seconds are drawn from the stream alone; its **gap** -- clean racing
before it is armed -- is the stream's draw times the skill's mean. Once armed, it waits for the road
to offer it a moment: a corner that asks for braking (and is what asks), a bend, a clear straight.
The stream decides what and how much; the road decides where. A mistake is begun only while the car
is racing cleanly -- on the road, aligned, above 12 m/s, not recovering -- the gap counts down only
then, and leaving that state ends a mistake that tick. An armed mistake the road offers nothing to in
15 s lapses and the next is drawn: this generator's circuits are gentle, and some (seeds 3 and 7)
never ask a driver of any skill to brake for a corner, so without it one late brake would silence a
driver for the whole race.

**Logged.** `active_mistake` says what the driver is doing this tick; `mistake_log()` returns every
mistake committed, oldest first: `n` (its plan number), `kind`, `tick` (the driver's own tick count --
never a frame count), `amount`, `seconds`, and `until`, the first tick it no longer acted on.
`mistakes_planned` and `mistakes_lapsed` count the rest. A reviewer reading a run sees the decision
rather than inferring it.

**Suppressed.** `mistakes_enabled` is false unless set. Off, the driver makes no draw, runs no clock
and touches no control: the gate (`_mistakes_on()`) is read in three places -- deciding, acting, and
the `active_mistake` getter. Switched off in the middle of a mistake, the mistake ends that tick and is
logged as ended; switched back on, it does not resume.

**The field-level switch (#61).** One switch for a whole field needed a field owner, which #59 did not
have. `SessionSettings.opponent_mistakes_enabled` is that switch; `MainSession` applies it to every
rival it spawns, and `tests/field_race_test.gd` asserts over a field of twenty that it is total both
ways (see "Settings" and "Driving the field (#61)").

**Survivable.** Forced to one kind at its largest, a second of clean racing apart, at skill 0.0 and
1.0, a car laps cleanly on seeds 0, 2, 5, 6 and 8, with no recovery and its body never off the dirt.
Seeds 0 and 6 are the two narrowest roads of the fifteen (205 px). The wide line's first bound, 3 m,
held only for its aim: the car overshoots its aim by about 3 m through a bend, and forced wide lines
put the car's centre 0.6-1.7 px from the edge there. The keep is now the 3 m plus that overshoot, and
the suite asserts on every lap that the car's centre stays at least its own 15 px radius from the edge;
forced at every chance, a second apart, the car's centre then keeps 28.4-60.2 px from the edge across
those five seeds, thinnest on seed 6. A wide line so forced costs 0.25-0.76 s a lap at skill 1.0.
Putting the keep back to 3 m fails the new assertion on seeds 0, 2 and 6 (0.6, 8.9 and 6.6 px).

**A late brake is a mistake in the log, not in its effect.** It **saves** 0.10-0.20 s a lap
at skill 1.0. The 4-12 m it withholds sit inside the slack #58's review measured (see "What braking
distance does and does not carry"): the car stops in about half the distance its driver believes and
corners on about 22 m/s² where the driver asks for 13.6. It is typed, logged and visible in the
controls, but a viewer would not see it, and it makes the car faster. Making it bite means sizing it
against the real slack -- far beyond 12 m, or shrinking the beliefs -- and that is a decision for the
epic, not something #59 can make alone. Skill only ever makes the beliefs more pessimistic, so it
never eats into that slack.

### Proof

`tests/skill_and_mistakes_test.gd`:

- **Seeded.** Skill and the first plans are pinned against Python; the same (seed, index) gives the
  same skill and plan, and a different seed, index or version a different one.
- **Chosen.** For each kind, a driver primed to commit it is fed the same synthetic senses as a
  flawless driver. They agree tick for tick until the mistake is logged, then differ exactly as the
  kind says: the corner's brake withheld for 23 ticks (12 m at 400 px/s), the steering aimed at a line
  exactly 25 px out on a road where the edge caps the aim there, the throttle off for 72 ticks. A rival
  caught in the path is still braked for through a late brake; a wide line ends the tick the car's
  centre comes within 6 m of an edge, and cannot begin inside it.
- **The same car repeats its mistakes.** Seed 1's least skilled rival laps twice with mistakes on and
  logs the same sequence -- plan number, kind, tick, amount, seconds and end of every mistake -- and
  the same control stream, with guards that the log holds at least three mistakes of two kinds and
  that every entry is the stream's plan for its number.
- **Different cars make different mistakes.** No pair of twenty rivals plans the same first three
  mistakes on any of three seeds. In a real field of twenty with mistakes on, every pair that committed
  the same plan number committed a different mistake under it.
- **Suppression is total.** Two rivals that differ **only** in their mistake streams -- different
  indices, skill pinned equal, the same start -- drive identical control streams over a whole lap with
  mistakes off. With mistakes on, the same twins agree until the first tick either logs a mistake, and
  differ on that tick. The issue's own wording, two identical cars with mistakes off, is checked too,
  and is not relied on: identical cars make identical mistakes, so it passes with a switch that hides
  only the log (`--leak-mistakes` shows exactly that).
- **Skill spreads the field.** On seeds 0-2 the least and most skilled of twenty rivals, by derived
  skill, differ by at least 5% in lap time; pinned 0.0, 0.5 and 1.0 lap in order, and 1.0 is #58's lap
  to the tick.
- **The lowest skill finishes**: skill 0.0 with mistakes on laps all fifteen seeds cleanly.
- **Every kind is survivable** (above), on seeds 0, 2, 5, 6 and 8 -- chosen because they have corners
  a late brake can happen in, and including both of the narrowest roads. On every lap the suite
  drives, the car's centre stays at least its 15 px radius inside the edge.
- **A field** of twenty with derived skills and mistakes on laps whole, none stuck, none strayed.

### What it does not settle

- **Which race a field of twenty drives depends on how and where it was spawned.** It predates #59:
  #58's driver at skill 1.0 with mistakes off shows it too. Run in a fresh process, the suite's field
  is identical run after run; spawned after other sections it was not, 6 of 20 cars differing after
  one section and 13 after a whole suite. #59's first explanation, car-to-car contact order decided by
  the server's history, was wrong. The #59 review measured the mechanism and demonstrated it bit for
  bit:
  - **The spawn phase.** What decides the race is whether a physics step runs between placing the cars
    and their first sense. Integrating a body rebuilds its transform from its angle in 32-bit `real_t`,
    which re-rounds the basis the grid built. At the first driving tick the two spawn phases agree on
    every position, height and velocity, and differ only in some cars' `global_rotation`, in the last
    digit. No car touches another at spawn. The driver amplifies that ulp and contact spreads it.
    Snapping each grid pose to its own fixed point before placing it -- rebuild it from its rotation
    and origin until it stops changing -- made every spawn phase the review tried drive the identical
    race.
  - **A reused space.** Separately, a physics space that has held a different track changed 18 of 20
    cars even with snapped poses; a fresh `World2D` after the same history did not.

  `skill_and_mistakes_test` runs its field first, so it spawns in the phase and the space
  `--only=field` has: a measurement fix, not a cure. #61 did the cure in `MainSession` -- see "Driving
  the field (#61)" -- and the hand-built fields in the driver suites still have neither. What the
  review asked of #61, kept for the record:
  1. give every race a spawn whose first sensed state does not depend on the main-loop phase -- snap
     each grid pose to its fixed point, or run a fixed number of steps before the first sense *and*
     snap. A fresh process is neither necessary nor sufficient;
  2. host each race in its own `World2D`, or prove the session's real restart path does not reuse a
     space that held another track;
  3. assert it where it can fail: the same seed and count twice in one process, with different
     histories between (another track, an idle-frame spawn, a physics-frame spawn), control streams
     compared at 64 bits. Remove the snap and that test must fail;
  4. scope the claim: this was shown on seed 0, twenty cars, one Linux machine. Cross-machine
     determinism of Godot's 2D contact resolution is a separate claim nothing here establishes.

  Solo laps spawned the same way did not differ between histories in #59's runs; with the mechanism
  above, that is an observation about how they were spawned, not a guarantee.
- **No overtaking.** A spread field on a road where nothing overtakes strings out behind its slowest
  cars rather than by skill. That is the field's shape to judge (#61), not a mistake's.
- **The rates are a choice.** A mistake every 10-30 s of clean racing on average; measured, skill
  0.0 commits 1-6 a lap across the fifteen seeds and a field of twenty 0-4 a car, with late brakes
  lapsing most often. They are constants in one place; nothing else depends on them.

## What is not covered

Said once, in one place, so nobody has to assemble it from the sections above.

- **Other machines.** Every race, every reproduction and every cost here ran on one Linux laptop with one
  Godot build. Nothing shows the same seed racing the same way elsewhere: Godot's 2D contact resolution
  across machines, and the spawn snap's bound under another libm (Android's, say), are unestablished.
- **Reproduction, as far as it goes.** Four seeds (0, 4, 41, 58) raced the same way across two spawn
  histories, with mistakes off and on; seed 0 also inside `field_race_test`. Twenty-two seeds were raced
  once each, **with mistakes off**; the shipped game runs mistakes on, and with mistakes on twenty rivals
  were raced on four seeds and the launched ten on seed 0 only. A race with the player driving -- a human's inputs -- is not reproducible by construction and
  is not what any of this compares.
- **The player's pose** is unsnapped and #60 pins it; on seeds 0 and 4 it did not desync a race. The
  other four seeds of 0-19 where it is not a fixed point (7, 15, 16, 19) were raced only once.
- **The stuck rule's margin.** 104 of 120 ticks on the worst of the 20 held-out seeds. Nothing bounds it
  on a seed not raced. A car stuck where no rival is in its lane -- against a tree beside a queue, say --
  still has only the stall reversal.
- **Overtaking.** A driver goes round a car stopped in its lane; it still follows a slow moving one, and
  sees nothing beside or behind it. Contact is common in a full field: 903-5,383 contact ticks a race
  across the four evidence seeds, summed over twenty rivals.
- **Every field raced has the player idle at pole.** How twenty rivals race a player who drives was not
  measured. On seed 41 the idle player's car was what the field got stuck behind; on seed 5, before the
  fix, the field met the stuck rule without it, for a reason not diagnosed.
- **Wrong-way driving** is not asserted at field level. Neither `capture_field_evidence` nor
  `field_race_test` bounds turn-arounds or wrong-way ticks; a lap counts only forward, in-order checkpoint
  crossings, which rules out a lap driven backwards but not a wrong-way excursion within one. (The seed-41
  suite field prints its turn-arounds: 1.)
- **The budget's tail.** At twenty rivals the worst frame overran 16.6 ms in three of the four cost runs
  (15.9-24.0 ms); with no rivals the worst frames already reach 7-11 ms. How often a player would see a dropped frame was
  not measured, nor was anything on a phone, a slower GPU, or any other track seed than 0.
- **The late brake does not bite** (see "Skill and deliberate mistakes"), and the driver's beliefs about
  its car are constants a differently tuned session would leave stale.
- **Rocks on raised ground** are invisible to a grounded car's ray and mask, as the terrain epic left them.

## Verification

```sh
godot --headless --path . --script res://tests/ai_driver_contract_test.gd
godot --headless --path . --script res://tests/driver_senses_test.gd
godot --headless --path . --script res://tests/reactive_driver_test.gd
godot --headless --path . --script res://tests/skill_and_mistakes_test.gd
godot --headless --path . --script res://tests/field_race_test.gd
```

The first prints one deliberate `ERROR` line from its tuningless-car fixture; that error is the
behaviour under test. The reactive driver suite takes about four minutes, skill and mistakes about nine.

The captures, windowed (a display, not `--headless`); each writes to `docs/evidence/ai-opponents/`:

```sh
godot --path . --script res://tests/capture_field_evidence.gd              # about 18 min; field-ledger.txt, stills
godot --headless --path . --script res://tests/capture_field_evidence.gd -- --sweep   # 22 seeds, about 21 min
godot --path . --script res://tests/capture_field_cost.gd                  # about 6-12 min; field-cost.txt
```

The sweep asserts without drawing, so it runs headless. The checked-in `field-cost-run-1.txt` and
`-run-2.txt` are two runs of the cost capture renamed; `field-sweep-ledger-before-fix.txt` is the sweep on
#61a's driver, raw capture output apart from its first line, a hand-written header saying so. Run nothing alongside the cost capture.

Mutations, which must fail:

```sh
godot --headless --path . --script res://tests/driver_senses_test.gd -- --break-sense-frame
godot --headless --path . --script res://tests/reactive_driver_test.gd -- --break-steer-heading
godot --headless --path . --script res://tests/reactive_driver_test.gd -- --break-brake-distance
godot --headless --path . --script res://tests/reactive_driver_test.gd -- --break-go-round
godot --headless --path . --script res://tests/skill_and_mistakes_test.gd -- --break-mistake-seed
godot --headless --path . --script res://tests/skill_and_mistakes_test.gd -- --break-skill-spread
godot --headless --path . --script res://tests/skill_and_mistakes_test.gd -- --leak-mistakes
godot --headless --path . --script res://tests/field_race_test.gd -- --break-spawn-snap
godot --headless --path . --script res://tests/field_race_test.gd -- --break-fresh-world
godot --headless --path . --script res://tests/field_race_test.gd -- --break-contact-replay
godot --headless --path . --script res://tests/field_race_test.gd -- --break-go-round
```

| Flag | Suite | What it does |
| --- | --- | --- |
| `--break-sense-frame` | driver senses | Replaces the car's basis with an identity basis at the same origin, so every sense comes out in the world frame |
| `--break-steer-heading` | reactive driver | Drops the heading term from steering. No seed completes a lap -- each spends 49-66% of five minutes on the grass -- and no recovery start gets back to racing |
| `--break-brake-distance` | reactive driver | Makes the braking distance a constant. Laps still complete and the stuck rule never trips; the unit pair fails, and so does the parked-rival stop, only because 389 px is close to the car's real stop (see above) |
| `--break-mistake-seed` | skill and mistakes | Derives the mistake stream without the car index. Every different-cars assertion fails: 190 of 190 plan pairs the same on each seed, every comparable field pair the same, and the twins log the same mistakes and drive the same lap |
| `--break-skill-spread` | skill and mistakes | Collapses every derived skill to 0.5. The lap-time spread fails on all three seeds at exactly 0.0%, as do the derived-skill range checks, and the repeat car -- no longer the least skilled -- commits too few mistakes for its guard |
| `--leak-mistakes` | skill and mistakes | Evidence, not an issue flag: the switch hides the log and nothing else. The twins' suppression check fails (they part on the first mistake's tick) and so do the primed-but-off unit checks; the issue's literal "two identical cars" wording **passes** |
| `--break-go-round` | reactive driver | No stall counts as caused by a rival, so a car stuck behind a stopped one reverses as before #61. Seven of the going-round unit checks fail; the ordinary-stall and reversal-progress checks pass, as they should. The suite's own field, on seed 0, passes under it -- exactly #58's numbers (longest slow streak 85, worst contact 3.3%) |
| `--break-go-round` | field race | The same substitution for every rival of the seed-41 field, before its first tick. `GO ROUND ... none meets the stuck rule` fails (126 of 120 ticks, by rival 7; 131 reversals) and so does its guard (0 passes); every other check passes. The field-level guard for the fix |
| `--break-spawn-snap` | field race | Rivals spawn at the raw grid pose. Both `FIXED POSE` checks fail (11,813 of 200,000 seedless; 128 of 440 on the swept seeds), and so do the stream and `COLLISION` checks (15 of 20). **Since the stuck fix the finishing order and ticks on seed 0 no longer change under it**, so those two `DETERMINISTIC` checks pass; at #61a they failed too |
| `--break-fresh-world` | field race | A restart reuses the space it has (the old race is still freed first). Both `FRESH WORLD` checks fail, and every `DETERMINISTIC` one: 0 of 20 streams identical |
| `--break-contact-replay` | field race | Evidence, not a production mutation: race 2 moves the first rival to touch another car 0.05 px on that tick. `COLLISION` fails (0 of 20), with the `DETERMINISTIC` assertions it depends on |

`--break-sense-frame` is the whole point of the frame assertion. The pass reads its car's pose
exactly once, through `SensingPass._car_frame()`; substituting an identity basis there leaves every
world position where it was and strips the rotation that turns a world vector into a car-frame one.
`_verify_senses_are_in_the_car_frame` places one layout twice — 15,000 px apart and 137 degrees
rotated — and walks every declared field of `DriverSenses` comparing the two. If that check passed
with the flag on, it would not be testing the frame.

### The whole suite (#61)

Every script under `tests/` that extends `SceneTree`, less the twelve graphical `capture_*` scripts and the
two fixtures (`height_channel_test_height_provider.gd`, `issue_4_test_surface_provider.gd`): **33 suites,
run one after another on the final driver, 33 exit 0.** `reactive_driver_test` now has 277 checks,
`skill_and_mistakes_test` 362, `field_race_test` 37 (43 since #61b's fix round, exit 0, re-run on `8d830f0`). The two captures this task added were run as
described above (evidence twice, cost twice, the sweep once on each driver).

### Every mutation flag in the project (#61)

Enumerated from the code, not from a ledger: every `OS.get_cmdline_user_args()` flag under `tests/`
that breaks production or the evidence -- thirty `--break-*` names, `--break-clearance` read by two
suites and `--break-go-round` by two, so thirty-two `--break-*` runs, `--leak-mistakes`, and
`offtrack_object_collision_test`'s `--remove-solid-collider` and `--solid-decoration`. Exploration
switches (`--seeds=`, `--laps-only`, `--recovery-only`, `--trace`, `--blind-to-road-ahead`, `--only=`,
`--proof-seed-only`, the `issue_4` `--*-only` switches, the captures' `--sweep` and `--no-launched`)
are not mutations and were not run as such. Each flag below was run once, sequentially, on the final
driver (`e1aa53e`, whose later commits touch only docs and evidence): **35 run, 35 exit 1** (the 35th, `field_race_test -- --break-go-round`, added in #61b's fix round and run on
`8d830f0`), every one
with the suite running to its end, named `FAIL` lines, and no `SCRIPT ERROR`. The first failing
assertion is the first `FAIL` line the suite printed; for some flags the assertion the flag targets comes
later in the same run.

| Flag | Suite | Exit | FAIL lines | First failing assertion |
| --- | --- | --- | --- | --- |
| `--break-height-layers` | `airborne_obstacle_level_test` | 1 | 6 | the rock is a low collider |
| `--break-sense-frame` | `driver_senses_test` | 1 | 38 | a car yawed +0 degrees off the road reads -1.570796 rad (expected +0.000000) |
| `--break-spawn-snap` | `field_race_test` | 1 | 4 | DETERMINISTIC: every rival's control stream is non-empty and identical at 64 bits (15 of 20; diverged: car 16 at tick 1279 (first contact tick 94), car 17 at tick 27 (first contact tick 94), car 18 at tick 101 (first contact ti... |
| `--break-fresh-world` | `field_race_test` | 1 | 6 | FRESH WORLD: race 1 (new session, spawned in an idle frame): the restart replaced the viewport's World2D (it shows the swap ran, not that nothing outside World came along) |
| `--break-contact-replay` | `field_race_test` | 1 | 4 | DETERMINISTIC: the same seed and count finish, all twenty, in the same order in both races ([2, 1, 3, 4, 5, 7, 9, 6, 8, 10, 12, 11, 14, 13, 16, 15, 18, 17, 20, 19] against [2, 1, 3, 4, 5, 7, 9, 6, 8, 10, 11, 14, 12, 13, 16, 15,... |
| `--break-go-round` | `field_race_test` | 1 | 2 | GO ROUND: seed 41, twenty rivals, the player idle at pole: all 20 rivals were watched driving and none meets the stuck rule (20 watched, longest slow streak 126 of 120 ticks, by rival 7) |
| `--break-proportional-steering` | `issue_4_vehicle_maneuvers` | 1 | 1 | half steering produces proportional rotation (half 1.10, full 1.10 rad) |
| `--break-countersteer` | `issue_4_vehicle_maneuvers` | 1 | 1 | counter-steer meaningfully reduces slip (0.56 -> 0.99) |
| `--break-surface-recovery` | `issue_4_vehicle_maneuvers` | 1 | 1 | reduced off-track grip takes at least 15 more ticks to recover (dirt 30, off-track 30) |
| `--break-standings-order` | `issue_60_field_test` | 1 | 1 | MUTATION --break-standings-order: ranking without lap counts still puts the car a lap ahead (at an earlier checkpoint) first — expected order [3, 1, 0, 2], lap-blind order [1, 0, 2, 3] |
| `--break-height-seed` | `jump_ramp_placement_test` | 1 | 60 | seed 0 height fingerprint repeats |
| `--break-clearance` | `jump_ramp_placement_test` | 1 | 32 | seed 1 height fingerprint repeats |
| `--break-density` | `jump_ramp_placement_test` | 1 | 3 | seed 0 places at least one ramp |
| `--remove-solid-collider` | `offtrack_object_collision_test` | 1 | 6 | only tree and rock produce colliders |
| `--solid-decoration` | `offtrack_object_collision_test` | 1 | 4 | v1:0:0:0 solid flag matches its catalog archetype |
| `--break-runtime-integrity` | `offtrack_object_performance_test` | 1 | 100 | seed 0 runtime visual count matches generated placements |
| `--break-seed` | `offtrack_object_placement_test` | 1 | 40 | seed 0 placement fingerprint repeats |
| `--break-clearance` | `offtrack_object_placement_test` | 1 | 304 | seed 0 placement fingerprint repeats |
| `--break-rock-corridor` | `offtrack_object_terrain_test` | 1 | 2 | no generated rock in seeds 0..19 is reachable from a flight above the clearance over that rock's own ground (21 reachable) |
| `--break-steer-heading` | `reactive_driver_test` | 1 | 72 | on the centreline with the nose +0.2 rad off the road, it steers back (steer +0.000) |
| `--break-brake-distance` | `reactive_driver_test` | 1 | 4 | at 150 px/s the same obstacle is not: it keeps driving (throttle 0.00, brake 1.00) |
| `--break-go-round` | `reactive_driver_test` | 1 | 7 | stalled behind a stopped rival 52 px ahead and 10 px right of its line, it starts a pass rather than a reversal (reversals 1, passing false, passes 0) |
| `--break-mistake-seed` | `skill_and_mistakes_test` | 1 | 6 | seed 0: no two of twenty rivals plan the same first three mistakes (190 of 190 pairs the same) |
| `--break-skill-spread` | `skill_and_mistakes_test` | 1 | 10 | seed 0: twenty rivals draw twenty different skills (1 distinct) |
| `--leak-mistakes` | `skill_and_mistakes_test` | 1 | 15 | primed for late brake but switched off, it drives 150 ticks exactly as a flawless driver |
| `--break-terrain-version` | `terrain_field_contract_test` | 1 | 21 | two fields from the same seed and version agree bit for bit at every position |
| `--break-terrain-seed` | `terrain_field_contract_test` | 1 | 21 | two fields from the same seed and version agree bit for bit at every position |
| `--break-terrain-curvature` | `terrain_field_contract_test` | 1 | 2 | the catalog's curvature bound (0.0007500000) stays under the lift-off curvature at max_safe_speed (0.0002993774) |
| `--break-side-wall` | `terrain_height_map_test` | 1 | 16 | on a flat base: the car's ride height tracks the map under it on every tick (worst gap 9.0000 px) |
| `--break-flank-curvature` | `terrain_height_map_test` | 1 | 12 | terrain plus flank curvature (0.015289650) stays under the lift-off curvature at the off-track terminal speed (0.004883371) |
| `--break-collision` | `track_collision_physics_test` | 1 | 24 | seed 0 probe driven right stays inside the play area (at 7024.9,2344.6) |
| `--break-gravity` | `vehicle_height_channel_test` | 1 | 7 | slope 0.120: the car lands within 300 ticks |
| `--break-landing` | `vehicle_height_channel_test` | 1 | 3 | slope 0.120: the landing is hard enough that the loss assertion is live |
| `--break-terrain-lift-off` | `vehicle_terrain_test` | 1 | 2 | bare terrain never lifts the car off at max_safe_speed in the real integrator (44 airborne of 36709 ticks over 24 lines) |
| `--break-speed-clamp` | `vehicle_terrain_test` | 1 | 1 | on the synthetic descent the car never exceeds the shipped max_safe_speed (peak 683.215 of 640.0 px/s) |
