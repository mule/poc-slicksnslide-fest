# Off-track objects desktop validation

## Revision, method, and environment

- **Tested content revision:** `f713cf733874d706f08fbc480c958f4f2a2d9b23`
  (`fix: harden off-track placement validation`). The captures, raw trace, impact still, and this
  documentation record are committed afterward as evidence only; they do not change the tested
  runtime tree.
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
| 0 | 1,117 | 526 / 260 / 174 / 174 / 96 | 16.636 / 17.651 / 23.600 | 40.363–40.377 |
| 4 | 1,437 | 666 / 333 / 231 / 231 / 115 | 16.646 / 17.324 / 17.820 | 41.886–41.901 |
| 9 | 1,570 | 686 / 328 / 264 / 264 / 121 | 16.685 / 17.578 / 19.840 | 42.316–42.331 |

The sampled maxima were 33.874, 20.130, and 30.258 ms respectively. These are desktop graphical
measurements, not Android or Steam Deck performance claims.

## One-time construction budgets

The independent headless performance gate swept seeds 0–19 on the tested content revision:

| Statistic | Placement generation | Runtime construction |
| --- | ---: | ---: |
| p50 | 60.512 ms | 16.590 ms |
| p95 | 73.193 ms | 19.460 ms |
| Budget | 80 ms | 100 ms |
| Result | PASS, 6.807 ms headroom | PASS, 80.540 ms headroom |

An earlier run was contaminated by concurrent Flutter, Dart, and PremierBot CPU work and was
discarded. This isolated rerun is the current result; no catalog, clearance, or budget constant was
changed.

## Graphical captures and real generated-solid impact

The standard graphical capture command refreshed the following 1280x720 RGBA PNGs; each was opened
and visually inspected after capture. They show dirt road, shoulder decoration, recovery space, and
deep solids for their deterministic seed:

| File | Road fingerprint | Object fingerprint |
| --- | --- | --- |
| [`seed-0.png`](seed-0.png) | `c473c35414d6ee31c9abada0c4d5fe4856997f137ca8d7dd6223a45da29bf55f` | `5f587a1b70ce3300729a390f555f277329c0d3e2e385891396868da5470bac88` |
| [`seed-4.png`](seed-4.png) | `4600dc93fe343e17e999276b333051a9538f51c50d02992863af9b4970779155` | `e48a8ef915e3eb316784300ad5f26189d7f157ab2c0f4bdfad733d0e676c2348` |
| [`seed-9.png`](seed-9.png) | `3fbe38ff1f6a222c0050cc004bddf93225b5da99176639d4b22f5934ece85670` | `7f5a46301fead1d1514cabb3d0b82f207e210d88a1ef1b46d246695f782aaa6b` |

[`seed-0-generated-solid-impact.png`](seed-0-generated-solid-impact.png) is a 1280x720 still
visually showing the red production `TopDownCar` at a generated tree. The harness selected stable
placement `v1:0:-10:1` (`tree`), used the mounted generated collision shape 0 in `Chunk_-3_0`, and
confirmed its pre-impact ray resolves that exact shape. The real CCD-enabled car began with zero
contacts, emitted `body_entered` for that chunk, finished with one physics contact, and was at
`x=-2360.759` versus the tree center `x=-2320.326` (speed `14.971` px/s). No synthetic
`CharacterBody2D` probe is used by this capture.

## Regression gate and result

Passed for this refreshed evidence: the evidence harness (24 checks), standard graphical seed
captures (14 checks), and independent performance gate (144 checks). The separate remediation
report records the runtime, placement, visual, collision, restart/session, mutation, graph-update,
and final-diff results for this revision.

**Result: desktop code-complete.** Epic #1, Android #23, and Steam Deck #7 remain open/blocked on
their required physical hardware, controller, lifecycle, and current-revision performance evidence.
