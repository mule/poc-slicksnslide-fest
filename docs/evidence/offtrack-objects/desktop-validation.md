# Off-track objects desktop validation

## Revision, method, and environment

- **Tested content revision:** `c52b58d9235e0a2231976e3d76a93522d0b314ae`
  (`test: capture warmed off-track desktop evidence`). It contains the evidence harness, refreshed
  captures, raw trace, and impact still. This documentation-only record is committed after that
  immutable content revision; it does not change the tested runtime tree.
- **Engine and renderer:** Godot `4.7.1.stable.official.a13da4feb`; graphical X11/OpenGL GL
  Compatibility renderer; Mesa `25.2.8-0ubuntu0.24.04.2`; Intel UHD Graphics (CML GT2).
- **Host:** Pop!_OS 24.04 LTS, Linux `7.0.11-76070011-generic`, Intel Core i7-10510U (4 cores,
  8 logical CPUs), 31 GiB RAM.
- **Graphical evidence command:**

  ```sh
  /home/japurane/.local/bin/godot --path . --script res://tests/capture_offtrack_desktop_evidence.gd
  ```

  It renders a real `MainSession` in a 1280x720 `SubViewport`, restarts each deterministic seed,
  warms for 120 process frames, then samples 240 subsequent process-frame intervals (about four
  seconds at the observed 60 Hz cadence). Frame time is the elapsed `Time.get_ticks_usec()` between
  process frames. Memory is Godot `Performance.MEMORY_STATIC`; node count is a recursive count from
  the evidence SceneTree root after the warm-up. The full raw output is
  [`desktop-trace-seeds-0-4-9.txt`](desktop-trace-seeds-0-4-9.txt).

## Warmed sustained traces

| Seed | Nodes | Visuals / batches / solid visuals / colliders / chunks | Frame p50 / p95 / p99 (ms) | Static memory range (MiB) |
| ---: | ---: | --- | --- | --- |
| 0 | 1,120 | 530 / 263 / 174 / 174 / 96 | 16.662 / 19.591 / 20.481 | 40.378–40.392 |
| 4 | 1,439 | 672 / 335 / 231 / 231 / 115 | 16.639 / 18.539 / 23.543 | 41.901–41.915 |
| 9 | 1,572 | 690 / 330 / 264 / 264 / 121 | 16.668 / 21.201 / 29.224 | 42.327–42.341 |

The sampled maxima were 30.601, 30.558, and 31.682 ms respectively. These are desktop graphical
measurements, not Android or Steam Deck performance claims.

## One-time construction budgets

The independent headless performance gate swept seeds 0–19 on the identical content revision:

| Statistic | Placement generation | Runtime construction |
| --- | ---: | ---: |
| p50 | 64.934 ms | 17.932 ms |
| p95 | 77.180 ms | 21.936 ms |
| Budget | 80 ms | 100 ms |
| Result | PASS, 2.820 ms headroom | PASS, 78.064 ms headroom |

The count range remains 507–722 placements, 236–340 decorative batches, 192–286 solid visuals and
colliders, and 88–134 collision chunks. No catalog, clearance, or budget constant was changed.

## Graphical captures and real generated-solid impact

The standard graphical capture command refreshed the following 1280x720 RGBA PNGs; each was opened
and visually inspected after capture. They show dirt road, shoulder decoration, recovery space, and
deep solids for their deterministic seed:

| File | Road fingerprint | Object fingerprint |
| --- | --- | --- |
| [`seed-0.png`](seed-0.png) | `c473c35414d6ee31c9abada0c4d5fe4856997f137ca8d7dd6223a45da29bf55f` | `04a02f965f1b5d84b6014caa57e377793a8133dfae7adc352dfde7be1dfd9bad` |
| [`seed-4.png`](seed-4.png) | `4600dc93fe343e17e999276b333051a9538f51c50d02992863af9b4970779155` | `116e6e3ea7e45226c34deb079d39e2491ae527483c803999f0e7b9e39962fa80` |
| [`seed-9.png`](seed-9.png) | `3fbe38ff1f6a222c0050cc004bddf93225b5da99176639d4b22f5934ece85670` | `1f14e7895cd92d4a92064fb738d2bdd27745ac01c3617d32245d1ebddb52d878` |

[`seed-0-generated-solid-impact.png`](seed-0-generated-solid-impact.png) is a 1280x720 still
visually showing the red production `TopDownCar` at a generated tree. The harness selected stable
placement `v1:0:-10:1` (`tree`), used the mounted generated collision shape 0 in `Chunk_-3_0`, and
confirmed its pre-impact ray resolves that exact shape. The real CCD-enabled car began with zero
contacts, emitted `body_entered` for that chunk, finished with one physics contact, and was at
`x=-2360.759` versus the tree center `x=-2320.326` (speed `14.971` px/s). No synthetic
`CharacterBody2D` probe is used by this capture.

## Regression gate and result

Passed: the evidence harness (24 checks), standard graphical seed captures (14 checks), off-track
contract, placement, visuals, collision (61 checks), runtime/restart (1,665 checks), independent
performance (144 checks), Issue 4 vehicle maneuvers (53 checks), Issue 5 integrated session (36
checks), and smoke. The pre-commit `git diff --check` passed; `graphify update .` completed.

One sequential placement-sweep attempt reported a scheduling-sensitive 80.748 ms p95 miss; an
isolated rerun passed at 73.387 ms p95 and the independent 0–19 performance gate above passed at
77.180 ms. The 80 ms limit remains unchanged; a future repeatable miss is a failure to investigate,
not permission to relax the budget.

**Result: desktop code-complete.** Epic #1, Android #23, and Steam Deck #7 remain open/blocked on
their required physical hardware, controller, lifecycle, and current-revision performance evidence.
