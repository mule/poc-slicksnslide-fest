# Procedural tracks implementation and RED/GREEN record

## Outcome

Issue #3 is implemented as a vehicle/input-independent runtime generator, definition resource, surface provider, forward lap-order tracker, prototype renderer, and static edge collision builder. Seeds `0..9` are deterministic and distinct; validation retries are capped at six and an impossible validation request demonstrates the known-valid fallback and diagnostic path. Geometry limits, timings, and the six-seed contact sheet are documented in `docs/procedural-tracks.md`.

Godot version: `4.7.1.stable.official.a13da4feb`.

## RED

The behavior-focused headless suite was added before the generator and run with:

```text
godot --headless --path . --script res://tests/track_generator_test.gd
```

It exited 1 for the intended missing behavior:

```text
ERROR: Failed loading resource: res://track/track_generator.gd.
generator_test checks=1 elapsed_usec=217
ERROR: Procedural track generator check failed: runtime generator script loads
```

## GREEN

After the minimal runtime implementation, the same command exited 0:

```text
seed=0 fingerprint=0c4788666adfa225d244c8e703287a54b14147eb6cb4c4805bd58e8af943f1f3 generation_usec=12874
seed=1 fingerprint=116d44045bee31ea45f310073bb2d098a34968d6a7b7a6e7dc2f91c7589dcfcf generation_usec=11774
seed=2 fingerprint=2b2d3eb1baae07d3f1d6d224c83dfd2542f4167e4f1aa0c86f76d5a746399d05 generation_usec=11203
seed=3 fingerprint=9ef4bfcaa354b72f83abc46c8e16652196d289bfcadbf17deaf48713938a81fe generation_usec=13633
seed=4 fingerprint=a00b6667efee1ac3756046a06ead10fc3110e3dea29bda3af475ae5779ca2e1c generation_usec=12002
seed=5 fingerprint=8a00fcc75bb68970c416842ae6d731fc7bcc5d82d008a3e62c6a29895be7bde2 generation_usec=11799
seed=6 fingerprint=1d3a9ea3ad84ca13d4f255f505b397f2be8670b95617ed23c1022d50e1d002cb generation_usec=22289
seed=7 fingerprint=b727898f25e94c9a5593e67ed1fc059b94704c1ab46ead5ed4a6b7841caf7ff1 generation_usec=12656
seed=8 fingerprint=fe810e163e4d85aaeefde98937eaa733cde04526e39c4b0ff81c4e5cdbfcd1e1 generation_usec=13832
seed=9 fingerprint=c4e97c2f88ddd268fbefd93a8041713ac423d9bdb69d435367d93d19c306e3c3 generation_usec=13106
generator_test checks=394 elapsed_usec=419675
Procedural track generator checks passed
```

## Final verification

The following fresh commands completed with exit code 0:

```text
godot --headless --editor --path . --quit
godot --headless --path . --script res://tests/headless_smoke.gd
godot --headless --path . --script res://tests/track_generator_test.gd
godot --headless --path . --script res://tests/track_collision_physics_test.gd
godot --headless --path . --script res://tests/capture_procedural_tracks.gd
git diff --check
```

The final generator run reported 394 checks in 343,017 microseconds, with per-seed generation between 7,639 and 13,060 microseconds. The editor import emitted the environment's existing `cannot connect to daemon at tcp:5037` Android/ADB message but exited 0; script import, foundation smoke, and procedural tests produced no Godot errors.

## Collision physics review follow-up

The review gap was first exercised against the real generated runtime with nine consecutive right-edge collision segments deliberately removed around seed 0's curved sample/joint 40:

```text
godot --headless --path . --script res://tests/track_collision_physics_test.gd -- --break-collision
```

This mutation run exited 1 for the intended physical behavior failures, rather than a source-structure assertion:

```text
FAIL: seed 0 right edge sample/joint 40 blocks a body at 300 units/s
FAIL: seed 0 right edge sample/joint 40 does not tunnel (outside 44.00)
FAIL: seed 0 contacting joint traversal maintains ordinary racing progress (max 5 ticks/joint)
track_collision_physics speed=300 ticks_per_second=60 physics_ticks=596 checks=59 mutation=true
expected_red_exit=1
```

The unchanged production collision construction was then run intact and exited 0 with all 59 behavior checks:

```text
godot --headless --path . --script res://tests/track_collision_physics_test.gd
...
PASS: seed 0 body traverses 28 contacting edge joints without snagging (102 contacts)
PASS: seed 4 body traverses 28 contacting edge joints without snagging (69 contacts)
PASS: seed 9 body traverses 28 contacting edge joints without snagging (102 contacts)
track_collision_physics speed=300 ticks_per_second=60 physics_ticks=594 checks=59 mutation=false
Procedural track collision physics checks passed
```

The test uses the real `TrackRuntime` `StaticBody2D` and `SegmentShape2D` instances plus a 4-unit-radius `CharacterBody2D`. At the documented 300 world units per second and 60 Hz, it runs 24 outward sweeps through representative straight/curved samples and joints across both boundaries, checks the body remains on the track side, and drives a body under sustained outward pressure over 28 consecutive edge joints for each of seeds 0, 4, and 9. The deliberate segment-gap mutation proves the suite detects both tunneling and degraded joint progress; intact production required no collision-construction change.

## Exact files changed

- `docs/evidence/procedural-tracks-red-green.md`
- `docs/evidence/procedural-tracks-seeds-0-5.png`
- `docs/evidence/procedural-tracks-seeds-0-5.png.import`
- `docs/procedural-tracks.md`
- `tests/capture_procedural_tracks.gd`
- `tests/capture_procedural_tracks.gd.uid`
- `tests/track_collision_physics_test.gd`
- `tests/track_collision_physics_test.gd.uid`
- `tests/track_generator_test.gd`
- `tests/track_generator_test.gd.uid`
- `track/lap_progress_tracker.gd`
- `track/lap_progress_tracker.gd.uid`
- `track/track_definition.gd`
- `track/track_generator.gd`
- `track/track_generator.gd.uid`
- `track/track_runtime.gd`
- `track/track_runtime.gd.uid`
- `track/track_surface_map.gd`
- `track/track_surface_map.gd.uid`

No protected session, vehicle, input, project, or root README files changed.

## Limitations

- The prototype family intentionally varies stadium dimensions and width, not production-quality organic corner topology, elevation, or terrain art.
- Collision continuity is now verified with real physics at the documented prototype racing speed using a simple test body. Full vehicle-specific impact response and tire behavior remain integration concerns for issue #4.
- The contact sheet rasterizes the generated definitions and the same prototype colors without a GPU so it remains capturable under Godot's dummy headless renderer; the headless generator suite separately instantiates and checks the actual `TrackRuntime` `Line2D` and `StaticBody2D` nodes.
- Desktop timing meets the documented budget. Target-device timing remains assigned to the platform issues.
