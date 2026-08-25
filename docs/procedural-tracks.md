# Procedural dirt circuits

`TrackGenerator.generate(seed)` returns a complete `TrackDefinition` without reading vehicle or input state. It uses Godot's seeded `RandomNumberGenerator` to sample a closed Catmull-Rom spline through 14 control points arranged around a circle whose base radius derives from the target lap length. Each control point's radius is independently jittered between 72% and 100% of the base radius, except three consecutive points — the first two and the last — which stay pinned to the un-jittered base radius so the loop always contains at least one gentle span; without that pin, the start-straight constraint below would be a gamble on jitter and most seeds would fall back to the stadium. The spline is scaled to hit the exact target lap length *before* uniform resampling at the target spacing — scaling a uniformly-spaced polyline after resampling would multiply its spacing too, so scaling first is what makes the final spacing correct. Curves are sampled at a fixed target spacing, their local normals produce both road edges, and millimetre-quantized geometry produces the SHA-256 fingerprint.

The resampled loop is then rotated so its longest low-curvature run starts at index 0, which becomes the start/finish straight and the spawn point. Curvature is precomputed once per sample and scanned in a single wrapped pass to find the longest run, keeping the search O(n) over the ~1,000–1,500 samples in a typical lap rather than the O(n²) that re-measuring from every index would cost.

## Accepted geometry bounds

| Property | Accepted desktop prototype bound |
| --- | --- |
| Road width | 125–175 world units |
| Lap length | 25,000–37,500 world units |
| Maximum sampled curvature | 0.005 radians per world unit |
| Start straight | At least 1,875 world units |
| Target centerline sample spacing | 25 world units |
| Deterministic validation attempts | At most 6 |

The start/spawn transform is the first centerline sample and rotates the vehicle-local `-Y` forward axis to face the first segment. Eight transforms are placed in lap order at equal sample-index intervals. The finish checkpoint is index 0; `LapProgressTracker` accepts only positive-direction crossings in the sequence `1..7, 0`, so repeated or reverse finish crossings cannot increment the lap.

Each candidate is checked against the configured bounds and for non-adjacent centerline/edge intersections and left/right edge overlap. Rejected candidates consume the next deterministic RNG values. If the bounded attempts are exhausted, generation returns a fixed, validated stadium while retaining the requested seed and reporting `retry_exhausted:<last reason>; fallback=known_valid_stadium`.

`TrackRuntime` draws grass shoulder, dirt, and edge guides and creates one static `SegmentShape2D` for every segment on both closed boundaries. With the 25-unit target spacing, the generated seeds keep boundary gaps below 30 units. The headless collision test defines ordinary prototype racing speed as 300 world units per second at 60 physics ticks per second: a real 4-unit-radius `CharacterBody2D` is swept outward through straight and curved sample joints on both edges, then driven under outward pressure across 28 consecutive contacting outer-edge joints. Seeds 0, 4, and 9 block all 24 representative sweeps without tunneling and complete the contacting traversals without a stalled joint. `TrackSurfaceMap` treats points within half the road width of the centerline as dirt (grip 1.0, drag 1.0) and all others as grass (grip 0.55, drag 2.2).

## Performance and evidence

The desktop prototype budget is 50 ms for one circuit and 1 second for the complete seeds `0..9` headless verification. The recorded Godot 4.7.1 run generated individual seeds in 11–23 ms and completed 394 checks, including a second deterministic generation of every seed, in 420 ms. Mobile timing remains intentionally deferred to the platform-specific issues.

The visual contact sheet for six seeds is in [procedural-tracks-seeds-0-5.png](evidence/procedural-tracks-seeds-0-5.png). These stadium circuits intentionally prioritize a dependable physics-test surface over production variety; elevation, branching, terrain art, racing lines, and editor tooling remain out of scope.
