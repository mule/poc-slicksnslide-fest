# Procedural dirt circuits

`TrackGenerator.generate(seed)` returns a complete `TrackDefinition` without reading vehicle or input state. It uses Godot's seeded `RandomNumberGenerator` to sample a closed Catmull-Rom spline through 14 control points arranged around a circle whose base radius derives from the target lap length. Each control point's radius is independently jittered between 55% and 100% of the base radius, except three consecutive points — the first two and the last — which stay pinned to the un-jittered base radius so the loop always contains at least one gentle span; without that pin, the start-straight constraint below would be a gamble on jitter and most seeds would fall back to the stadium. The spline is scaled to hit the exact target lap length *before* uniform resampling at the target spacing — scaling a uniformly-spaced polyline after resampling would multiply its spacing too, so scaling first is what makes the final spacing correct. Curves are sampled at a fixed target spacing, their local normals produce both road edges, and millimetre-quantized geometry produces the SHA-256 fingerprint.

The resampled loop is then rotated so its longest low-curvature run starts at index 0, which becomes the start/finish straight and the spawn point. Curvature is precomputed once per sample and scanned in a single wrapped pass to find the longest run, keeping the search O(n) over the ~1,000–1,500 samples in a typical lap rather than the O(n²) that re-measuring from every index would cost.

## Accepted geometry bounds

| Property | Accepted desktop prototype bound |
| --- | --- |
| Road width | 200–280 world units |
| Lap length | 25,000–37,500 world units |
| Maximum sampled curvature | 0.005 radians per world unit |
| Start straight | At least 1,875 world units |
| Target centerline sample spacing | 25 world units |
| Deterministic validation attempts | At most 30 |

The start/spawn transform is the first centerline sample and rotates the vehicle-local `-Y` forward axis to face the first segment. Eight transforms are placed in lap order at equal sample-index intervals. The finish checkpoint is index 0; `LapProgressTracker` accepts only positive-direction crossings in the sequence `1..7, 0`, so repeated or reverse finish crossings cannot increment the lap.

Each candidate is checked against the configured bounds and for non-adjacent centerline/edge intersections and left/right edge overlap. Rejected candidates consume the next deterministic RNG values. If the bounded attempts are exhausted, generation returns a fixed, validated stadium while retaining the requested seed and reporting `retry_exhausted:<last reason>; fallback=known_valid_stadium`. The higher, 30-attempt retry budget (raised from an earlier cap of 6) is what makes the wider circuit variety possible: several seeds only pass validation on a later attempt, and seed 17 currently exhausts all 30 attempts before falling back to the stadium.

`TrackRuntime` draws grass shoulder, dirt, and edge-guide `Line2D`s along the centerline and both boundary polylines, but none of them carries collision — the circuit itself has no walls. The only collision geometry is a single four-segment `StaticBody2D` far outside the road, built around the track's own bounds grown by a fixed margin. See [The open surface](open-surface.md) for that contract in full, including the off-track penalty and the opt-in automatic reset. `tests/track_collision_physics_test.gd` now verifies containment directly: for seeds 0, 4, and 9 it drives a probe outward from the centerline toward each side of the play area and checks it stays inside a tolerance-grown play-area rectangle, plus a `--break-collision` mode that strips the containment shapes and expects the probe to escape instead. `TrackSurfaceMap` treats points within half the road width of the centerline as dirt (grip 1.0, drag 1.0) and all others as off-track/grass (grip 0.55, drag 2.2).

## Performance and evidence

The desktop prototype budget is nominally 50 ms for one circuit, but at HEAD the 30-attempt retry budget routinely exceeds it: a recorded Godot 4.7.1 run of `tests/track_generator_test.gd` measured individual seeds (`0..19`) at 26.1–372.8 ms of `generation_usec`, with a median around 126 ms, and 17 of the 20 seeds over the stated 50 ms budget (seed 17 was the slowest, exhausting all 30 attempts before falling back). This is the deliberate cost of retrying up to 30 times per circuit rather than 6 — the same budget increase that buys the wider circuit variety described above. The generator test sweeps seeds `0..19` and observably completes **764 checks** (verified against the current `tests/track_generator_test.gd` run). Mobile timing remains intentionally deferred to the platform-specific issues.

The visual contact sheet for six seeds is in [procedural-tracks-seeds-0-5.png](evidence/procedural-tracks-seeds-0-5.png). These Catmull-Rom spline circuits (the fixed stadium is only used as the retry-exhausted fallback, see above) intentionally prioritize a dependable physics-test surface over production variety; elevation, branching, terrain art, racing lines, and editor tooling remain out of scope.
