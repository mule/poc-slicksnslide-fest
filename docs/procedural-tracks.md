# Procedural dirt circuits

`TrackGenerator.generate(seed)` returns a complete `TrackDefinition` without reading vehicle or input state. It uses Godot's seeded `RandomNumberGenerator` to choose the dimensions and width of a sampled stadium circuit. Curves are sampled at a fixed target spacing, their local normals produce both road edges, and millimetre-quantized geometry produces the SHA-256 fingerprint.

## Accepted geometry bounds

| Property | Accepted desktop prototype bound |
| --- | --- |
| Road width | 40–56 world units |
| Lap length | 1,100–1,900 world units |
| Maximum sampled curvature | 0.02 radians per world unit |
| Start straight | At least 160 world units |
| Target centerline sample spacing | 10 world units |
| Deterministic validation attempts | At most 6 |

The start/spawn transform is the first centerline sample and faces the first segment. Eight transforms are placed in lap order at equal sample-index intervals. The finish checkpoint is index 0; `LapProgressTracker` accepts only positive-direction crossings in the sequence `1..7, 0`, so repeated or reverse finish crossings cannot increment the lap.

Each candidate is checked against the configured bounds and for non-adjacent centerline/edge intersections and left/right edge overlap. Rejected candidates consume the next deterministic RNG values. If the bounded attempts are exhausted, generation returns a fixed, validated stadium while retaining the requested seed and reporting `retry_exhausted:<last reason>; fallback=known_valid_stadium`.

`TrackRuntime` draws grass shoulder, dirt, and edge guides and creates one static `SegmentShape2D` for every segment on both closed boundaries. With the 10-unit target spacing, the generated seeds keep boundary gaps below 13.2 units. The headless collision test defines ordinary prototype racing speed as 300 world units per second at 60 physics ticks per second: a real 4-unit-radius `CharacterBody2D` is swept outward through straight and curved sample joints on both edges, then driven under outward pressure across 28 consecutive contacting outer-edge joints. Seeds 0, 4, and 9 block all 24 representative sweeps without tunneling and complete the contacting traversals without a stalled joint. `TrackSurfaceMap` treats points within half the road width of the centerline as dirt (grip 1.0, drag 1.0) and all others as grass (grip 0.55, drag 2.2).

## Performance and evidence

The desktop prototype budget is 50 ms for one circuit and 1 second for the complete seeds `0..9` headless verification. The recorded Godot 4.7.1 run generated individual seeds in 11–23 ms and completed 394 checks, including a second deterministic generation of every seed, in 420 ms. Mobile timing remains intentionally deferred to the platform-specific issues.

The visual contact sheet for six seeds is in [procedural-tracks-seeds-0-5.png](evidence/procedural-tracks-seeds-0-5.png). These stadium circuits intentionally prioritize a dependable physics-test surface over production variety; elevation, branching, terrain art, racing lines, and editor tooling remain out of scope.
