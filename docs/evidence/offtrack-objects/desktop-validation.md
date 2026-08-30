# Off-track objects desktop validation

## Revision and environment

- **Tested content revision:** `12a9198519aaa8cee0d7c1e7089f962b303a6456`
  (`docs: validate off-track objects on desktop`). This commit contains the catalog, integrated
  runtime, measurement script, capture script, documentation, and captured PNGs used below.
- **Evidence-record method:** this document is committed immediately after that content revision so
  it can cite an immutable SHA without claiming that a yet-to-be-created commit was measured. It
  changes documentation only; the product/runtime tree tested here is the revision above.
- **Engine:** Godot `4.7.1.stable.official.a13da4feb`, GL Compatibility renderer.
- **Reference workstation:** Pop!_OS 24.04 LTS; Intel Core i7-10510U (8 logical CPUs); Intel UHD
  Graphics (CML GT2), Mesa 25.2.8; 31 GiB RAM.
- **Command:** `/home/japurane/.local/bin/godot --headless --path . --script res://tests/offtrack_object_performance_test.gd`

## Raw budget measurements

Timing measures the already-recorded one-time placement generation and separate
`OfftrackObjectRuntime` construction for each deterministic seed. Values are microseconds.

| Seed | Placement | Runtime | Placements | Decorative batches | Solid visuals | Colliders | Collision chunks |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 52648 | 11326 | 530 | 263 | 174 | 174 | 96 |
| 1 | 65930 | 14352 | 698 | 340 | 248 | 248 | 128 |
| 2 | 49983 | 10950 | 510 | 240 | 193 | 193 | 96 |
| 3 | 66316 | 13375 | 647 | 287 | 267 | 267 | 122 |
| 4 | 70760 | 15605 | 672 | 335 | 231 | 231 | 115 |
| 5 | 65284 | 14640 | 684 | 324 | 246 | 246 | 120 |
| 6 | 56122 | 12180 | 595 | 271 | 239 | 239 | 108 |
| 7 | 61597 | 12808 | 630 | 310 | 219 | 219 | 117 |
| 8 | 50977 | 10937 | 507 | 236 | 196 | 196 | 98 |
| 9 | 78050 | 15002 | 690 | 330 | 264 | 264 | 121 |
| 10 | 70785 | 14380 | 713 | 336 | 265 | 265 | 118 |
| 11 | 52620 | 12288 | 539 | 269 | 198 | 198 | 88 |
| 12 | 63970 | 13272 | 642 | 315 | 235 | 235 | 117 |
| 13 | 68704 | 15387 | 722 | 317 | 286 | 286 | 134 |
| 14 | 55681 | 11770 | 584 | 280 | 224 | 224 | 102 |
| 15 | 55924 | 11242 | 622 | 310 | 212 | 212 | 105 |
| 16 | 59153 | 12241 | 608 | 295 | 202 | 202 | 101 |
| 17 | 44582 | 11207 | 626 | 306 | 225 | 225 | 106 |
| 18 | 51871 | 11219 | 522 | 254 | 192 | 192 | 99 |
| 19 | 55210 | 11979 | 686 | 338 | 224 | 224 | 116 |

| Statistic | Placement generation | Runtime construction |
| --- | ---: | ---: |
| p50 | 56122 us (56.122 ms) | 12241 us (12.241 ms) |
| p95 | 70785 us (70.785 ms) | 15387 us (15.387 ms) |
| Budget | 80000 us (80 ms) | 100000 us (100 ms) |
| Result | PASS, 9.215 ms headroom | PASS, 84.613 ms headroom |

| Count statistic | Placements | Decorative batches | Solid visuals | Colliders | Collision chunks |
| --- | ---: | ---: | ---: | ---: | ---: |
| Min | 507 | 236 | 192 | 192 | 88 |
| Median | 628 | 308 | 224.5 | 224.5 | 111.5 |
| Max | 722 | 340 | 286 | 286 | 134 |

No catalog tuning was attempted: both approved budgets passed on the first measurement. In
particular, the 20 m solid clearance, 40 m spawn/checkpoint exclusion, containment buffer, and
runtime construction budget were not weakened.

## Graphical captures

The graphical command was run against the real X11/OpenGL renderer, not headless rendering:

```sh
/home/japurane/.local/bin/godot --path . --script res://tests/capture_offtrack_objects.gd
```

The capture script uses a 1280x720 `SubViewport`, waits three process frames and one physics frame,
then uses a capture-only camera centred between the spawn and nearest deterministic solid object.
Manual inspection confirmed the dirt road, near-shoulder decorations, readable solid recovery
corridor, and at least one deeper tree or rock in every frame.

| File | Dimensions | Road fingerprint | Object fingerprint |
| --- | --- | --- | --- |
| [`seed-0.png`](seed-0.png) | 1280x720 | `c473c35414d6ee31c9abada0c4d5fe4856997f137ca8d7dd6223a45da29bf55f` | `04a02f965f1b5d84b6014caa57e377793a8133dfae7adc352dfde7be1dfd9bad` |
| [`seed-4.png`](seed-4.png) | 1280x720 | `4600dc93fe343e17e999276b333051a9538f51c50d02992863af9b4970779155` | `116e6e3ea7e45226c34deb079d39e2491ae527483c803999f0e7b9e39962fa80` |
| [`seed-9.png`](seed-9.png) | 1280x720 | `3fbe38ff1f6a222c0050cc004bddf93225b5da99176639d4b22f5934ece85670` | `1f14e7895cd92d4a92064fb738d2bdd27745ac01c3617d32245d1ebddb52d878` |

`file` verified each image as a readable 8-bit RGBA PNG at the listed dimensions.

## Regression gate and result

The Task 5 focused suites all passed: contract, placement, visuals, collision, and generated
runtime/restart. The four mutation modes all exited 1 as intended: `--break-seed`,
`--break-clearance`, `--remove-solid-collider`, and `--solid-decoration`. Every CI-relevant Godot
suite passed twice, including the 17,918-physics-tick containment sweep for seeds 0, 4, and 9 and
the Issue 4 vehicle maneuvers. `git diff --check` was clean before commit.

**Result: desktop code-complete.** This is not physical-platform acceptance. Android #23 and Steam
Deck #7 still require their own current-revision build, controller, frame-time, collision, recovery,
and lifecycle evidence; Task 7 reconciles those physical gates.
