# World scale: GTA2-scale circuits and a car that moves

- Date: 2026-08-24
- Status: approved design, not yet implemented
- Branch: feat/6-android-export-validation (implementation should branch fresh)

## Problem

The car crawls and the whole track fits on one screen. Both are the same
root cause: the physics is authored in SI units (metres) while Godot 2D
worlds are in pixels, and the art was drawn at roughly 12.5 px per metre.
Nothing reconciles the two.

Measured, not assumed:

- Engine acceleration is `engine_force / mass_kg` = 17000 / 1100 = 15.45 px/s².
- Drag (`vehicle/top_down_car.gd`) is `0.32·v + 0.012·v²` px/s².
- Terminal speed where those balance: `0.012v² + 0.32v − 15.45 = 0` → **24.9 px/s**.

The car sprite is 55 px long, so flat out it covers less than half a car
length per second and takes **51 s to cross the 1280 px viewport**. The
existing test at `tests/issue_4_vehicle_maneuvers.gd:71` asserts exactly
this ("full throttle reaches 20..34 world units/s after 4 s"), so the
behaviour was locked in rather than noticed.

`max_safe_speed = 48.0` has never engaged: drag caps the car at 24.9, so
the limiter is decorative.

`get_diagnostics()` returns `"speed_kph": get_speed() * 3.6` — the
metres-per-second conversion — so the HUD displays a healthy **90 km/h**
while the car creeps. The unit assumption is asserted in the readout and
nowhere in the world.

Track geometry (`track/track_generator.gd`): `half_straight` 180–240,
`radius` 100–135, `width = randi_range(20, 28) * 2` → 40–56 px. Worst-case
bounds are 806 × 326 px inside a 1280 × 720 viewport at the default camera
zoom of 1.0 (no zoom is set anywhere in the repo). At 12.5 px/m that is a
**64 m × 26 m lap** — a parking lot. The 30 px collision capsule inside a
40 px track leaves **3 px of clearance per side**.

## Decisions

1. **Target scale**: rally circuit, 2–3 km lap.
2. **Unit contract**: pixels stay the world unit, with an explicit
   `PIXELS_PER_METRE = 12.5`. Rejected: metres as the world unit, because
   Godot's 2D solver tolerances are pixel-scaled by default and a
   4.4 × 2.7 unit car would require retuning them.
3. **Layout**: replace the stadium-oval sampler with a seeded meandering
   closed loop.
4. **Conversion strategy**: bake the scale. The value in the resource file
   is the value the engine uses. Rejected: SI-in-file with derived pixel
   accessors, because a dual representation makes "read the raw field by
   mistake" a silent bug — the same failure class being fixed here.
5. **Top speed**: cut drag so the car reaches ~170 km/h and the limiter
   becomes a real safety net rather than decoration.

## 1. Scale contract

New `world/world_scale.gd`, `class_name WorldScale`:

```gdscript
const PIXELS_PER_METRE := 12.5
static func metres(m: float) -> float
static func to_kph(px_per_second: float) -> float
```

Stateless, one purpose, consumed by `track/`, `vehicle/`, and `session/`.
It does **not** go in `platform/`: that directory's README reserves it for
platform adapters and states that track generation, vehicle physics, and
session flow must not branch there.

`get_diagnostics()` switches to `WorldScale.to_kph(get_speed())` so the HUD
reading becomes true.

### Scaling rules by dimension

| Quantity class | Rule | Rationale |
| --- | --- | --- |
| Lengths, speeds, accelerations | × k | direct |
| Forces | × k | `force / mass` is an acceleration; mass is unchanged |
| Rates (1/s) | unchanged | `rolling_drag`, `lateral_grip`, `steering_response` |
| Angular (rad, rad/s) | unchanged | `max_angular_speed`, `max_steering_rate` |
| Dimensionless ratios | unchanged | slip thresholds, grip multipliers |
| `aerodynamic_drag` (c in c·v²) | ÷ k | so that `c'·(kv)² = k·(c·v²)` |
| Curvature (1/length) | ÷ k | see section 3 for why the rule is overridden |

### `data/default_vehicle_tuning.tres`

| Field | Now | After | Note |
| --- | --- | --- | --- |
| `engine_force` | 17000 | **212500** | ×k |
| `brake_force` | 17000 | **212500** | ×k |
| `reverse_force` | 6500 | **81250** | ×k |
| `rolling_drag` | 0.32 | **0.064** | rebalanced, see below |
| `aerodynamic_drag` | 0.012 | **0.00043** | rebalanced, see below |
| `max_safe_speed` | 48.0 | **640.0** | above terminal, so it is a real limiter |
| `steering_full_speed` | 18.0 | **225.0** | ×k |
| `stop_speed` | 0.75 | **9.4** | ×k |
| `lateral_grip_acceleration` | 24.0 | **300.0** | ×k |
| `low_speed_stabilization` | 4.0 | **50.0** | ×k |
| `camera_max_lead` | 110.0 | **250.0** | screen-space budget, deliberately not ×k |
| `camera_zoom` | — | **0.8** | new field, see section 5 |

All other fields are unchanged by the rules above.

### The drag rebalance (decision 5)

Cutting `aerodynamic_drag` alone does not work. At the target 600 px/s,
`rolling_drag` at its ×k-neutral 0.32 already consumes 192 of the 193.18
px/s² acceleration budget, leaving aero at ~3.3e-6 — a tuning parameter
contributing 0.2% of drag, i.e. vestigial. That is the literal reading of
"cut aerodynamic drag" and it produces a dead knob.

**Assumption taken** (flag during review if wrong): rebalance *both* drag
terms so aero dominates at speed, as real aerodynamic drag does.

Solve `193.18 = 600r + 360000c` with aero carrying ~80% at top speed:

- `rolling_drag` r = **0.064** → 38.4 px/s² at 600
- `aerodynamic_drag` c = **0.00043** → 154.8 px/s² at 600
- Sum 193.2 = 212500/1100 ✓ → terminal speed exactly **600 px/s = 48 m/s = 172.8 km/h**

`max_safe_speed` is set to **640**, above the natural terminal speed, so it
catches abnormal energy injection from collisions without clipping normal
driving.

Derived behaviour:

- 0–100 km/h (0 → 347 px/s): **~2.2 s** — arcade-snappy, genre-appropriate
  for a top-down racer. If a longer ramp is wanted, `engine_force` is the
  knob; drag is now spoken for by the top-speed target.
- Off-track terminal (`engine ×0.62`, `drag ×2.6`): **261 px/s ≈ 75 km/h**,
  or 43% of on-track top speed — leaving the racing line is meaningfully
  punished.

### Literals that leak the contract

`vehicle/top_down_car.gd` hardcodes speeds outside the resource file. These
must scale, and become `WorldScale.metres(...)` calls so they are greppable:

- `maxf(speed, 1.0)` (slip-ratio divisor) → 12.5
- `if speed < 2.0` (low-speed stabiliser gate) → 25.0
- `get_speed() > 4.0` (dust emitter gate) → 50.0

Missing one of these presents as a feature bug ("dust never emits", "the
car never settles at rest"), not a units bug. Nothing in the type system or
the current tests would catch it.

## 2. `world/segment_grid.gd` — one index, two consumers

A uniform grid bucketing centreline segment indices by the cells their AABB
touches. Cell size ≈ `track_width`.

```gdscript
segments_near(point: Vector2, radius: float) -> PackedInt32Array
candidate_pairs() -> Array   # only segment pairs sharing a cell
```

Two hot paths break at 2.5 km and both are fixed by the same structure:

- `TrackSurfaceMap._distance_to_centerline` scans every segment **every
  physics tick**. Today: 150 segments × 60 Hz = 9,000 distance tests/sec.
  At 2.5 km with `SAMPLE_SPACING` 25 that is 1,250 segments × 60 Hz =
  **75,000/sec per car** — an 8× increase that grows linearly with both
  lap length and car count.
- `_has_self_intersection` and `_boundaries_intersect` are brute-force
  O(n²) segment tests, run up to three times per generation attempt across
  six attempts. At 1,250 points that is ~781k pairs per check, ~14M
  segment-intersection calls per generation — seconds, not microseconds.

Building one shared index rather than two ad-hoc optimisations is what
allows `SAMPLE_SPACING` to stay fine (25 px / 2 m). The alternative —
coarsening spacing to ~100 px to buy back performance — would make corners
visibly chunky on a 150 px-wide track.

## 3. Generator rewrite (`track/track_generator.gd`)

`_sample_stadium` is replaced by a seeded perturbed-radius closed spline:

1. 12–16 control angles around a circle; radius = `base_radius ×
   rng.randf_range(0.55, 1.0)`. `base_radius` is only nominal — step 4
   does the real sizing — so `MAX_LAP_LENGTH / (2π)` ≈ 5,970 px is fine.
2. Closed Catmull-Rom through the control points, densely sampled
3. Uniform arc-length resample at `SAMPLE_SPACING`
4. Uniformly scale the loop so `lap_length` lands inside the band
5. Existing validation gates, unchanged in structure, running on
   `candidate_pairs()`
6. Existing fallback-stadium safety net, unchanged in structure, scaled up

The deterministic seed contract and the `TrackDefinition` output contract
are both unchanged. `geometry_fingerprint` values will all change, which is
expected and is what the fingerprint is for.

| Constant | Now | After | Rationale |
| --- | --- | --- | --- |
| `MIN_LAP_LENGTH` | 1100 | **25000** | 2 km |
| `MAX_LAP_LENGTH` | 1900 | **37500** | 3 km |
| `MIN_WIDTH` | 40 | **125** | 10 m ≈ 4 car widths |
| `MAX_WIDTH` | 56 | **175** | 14 m |
| `SAMPLE_SPACING` | 10 | **25** | 2 m; ~1250 points, affordable via the grid |
| `MIN_START_STRAIGHT` | 160 | **1875** | a real 150 m straight |
| `MAX_CURVATURE` | 0.02 | **0.005** | override, see below |

Resulting world: roughly **10,000 × 10,000 px ≈ 8 × 8 screens**.

### Why `MAX_CURVATURE` overrides its own rule

Curvature is 1/length, so ÷k turns 0.02 into 0.0016 — a 625 px (50 m)
minimum corner radius, far too gentle for rally. The dimensional rule
faithfully preserves *the old shape*, but the old shape was a parking-lot
oval; the constant was an accident of the old scale rather than a decision.
**0.005** (a 200 px / 16 m hairpin) expresses the intent instead. This is
the one place the mechanical rescale is deliberately not applied, and it is
worth watching for the same trap elsewhere.

## 4. Surface map on the index

`TrackSurfaceMap._distance_to_centerline` queries `segments_near(position,
track_width)` instead of scanning all segments. An empty result means no
segment is within range, which is exactly `OFF_TRACK` — so the fast path
and the slow path agree by construction rather than by coincidence.

## 5. Presentation

- **Camera zoom becomes a tuning field**, `camera_zoom`, default **0.8**.
  At the new 600 px/s top speed, zoom 1.0 would give a 2.1 s screen
  crossing, which is tight. Zoom 0.8 shows 1600 × 900 px (128 m × 72 m) and
  gives a **2.7 s** crossing. The car renders at 44 px, still clearly
  readable.
- `camera_max_lead` = 250 px. At 600 px/s the desired lead is
  `600 × 0.38 = 228 px`, so the cap sits just above normal use and only
  trims spikes. Left at 110 it would clip constantly; taken to 1375 by the
  ×k rule it would go back to being decorative.
- `TrackRuntime`: the hardcoded `track_width + 24.0` grass shoulder becomes
  proportional (`track_width * 1.4`), and boundary line width 2.0 → 6.0.
  At the new scale both currently render as hairlines.
- `top_down_car.tscn` `Dust` particles: `initial_velocity_min/max` and
  `scale_min/max` scale ×k, or the dust hangs still while the car rockets
  past.
- **Deferred (YAGNI)**: camera `limit_*` clamping to track bounds. The
  background is a screen-space `ColorRect`, so there is no visible void.

## 6. Testing and evidence

### Assertions that rescale by ×k

- `issue_4_vehicle_maneuvers.gd:83` `- 0.25` → `- 3.1`
- `issue_4_vehicle_maneuvers.gd:251` `<= 0.25` → `<= 3.1`
- `track_generator_test.gd:8-11` width and lap-length bands → section 3 values
- `issue_5_input_session_test.gd:154` `track_width = 40.0` → `150.0`

Lines 171–177 read `tuning.max_safe_speed` directly and self-scale.
Line 150 (`grass <= dirt * 0.88`) is dimensionless and is unaffected.

### Assertions that decision 5 changes structurally

The drag rebalance changes the *shape* of the acceleration curve, not just
its scale. Three assertions therefore need re-derivation, not multiplication:

1. **`:71` full throttle after 4 s.** Numeric integration of
   `dv/dt = 193.18 − 0.064v − 0.00043v²` gives ~500 px/s at t = 4 s.
   Band: **450..550**. (Note this supersedes the ×12.5-of-old-behaviour
   figure of 250..425, which assumed the unrebalanced drag curve.)
2. **`:72` half-throttle proportionality, currently `0.38..0.65` of full.**
   Half throttle gives A = 96.6 and a terminal of 405 px/s, a ratio of
   **0.675** — above the current upper bound, so this assertion would fail.
   The cause is real: with linear-dominant drag `v_terminal ∝ A`, with
   aero-dominant drag `v_terminal ∝ √A`. Rebalancing toward aero moves the
   throttle→speed transfer from near-linear toward near-square-root.
   New band: **0.55..0.80**.
3. **`:88-100` the brake maneuver.** The test accelerates for 3.0 s then
   brakes for 1.5 s and asserts a near-stop. Under the old tuning the
   approach speed was ~23 px/s and braking at 15.45 px/s² stopped it in
   almost exactly 1.5 s — the window was tuned to the old curve. Under the
   new curve the approach is ~430 px/s and braking at 193.18 px/s² needs
   ~2.2 s. **The brake window must extend from 1.5 s to 2.5 s.** Raising
   `brake_force` instead is rejected: 193.18 px/s² is already 1.6 g, beyond
   a road car on tarmac, and this is dirt.
   `approach_speed >= 17.0` → **>= 380**. `stopped_speed <= 2.5` → **<= 31**.
   For the bounded-reverse band at `:101`: the car stops ~2.2 s into the
   2.5 s window, banking 0.3 s against the 0.4 s `reverse_engage_delay`, so
   reverse engages ~0.1 s into the following 1.5 s and reaches
   `73.9 px/s² × 1.4 s ≈ 95 px/s` net of drag. The plain ×k band
   **62.5..212.5** contains this and stands.

### New tests

- **`SegmentGrid` equivalence.** The grid replaces a known-correct
  brute-force implementation, so that implementation becomes the test
  oracle: over random tracks and random query points, grid results must
  equal brute-force results exactly. This is the highest-risk change in the
  design and the cheapest one to make airtight.
- **Scale contract.** Sustained full throttle on dirt settles into
  **570..630 px/s**; at terminal speed the car traverses one viewport width
  (`1280 / camera_zoom` px) in **2.5..3.0 s**. This is the test that would
  have caught the original bug, stated in the terms the problem was
  actually noticed in.

### Evidence

`capture_procedural_tracks.gd` needs no scale changes — line 33 already
derives `scale_factor` from `definition.bounds`, so it adapts on its own.
Only its hardcoded `+ 24.0` shoulder and `2.0` edge width follow the
`TrackRuntime` change in section 5.

Regenerate `docs/evidence` and `docs/screenshots`. Re-export
`builds/android` for fresh validation evidence: unaffected by scale, but
the existing artefact predates every change here.

Update `docs/procedural-tracks.md` and `docs/vehicle/` for the new
constants, and add the px/m contract to `README.md`.

## Risks

- **A missed scale literal fails silently.** Mitigated by routing every
  scale-dependent literal through `WorldScale.metres()` and by the scale
  contract test.
- **The generator may reject more candidates.** A meandering spline can
  self-intersect where a stadium never could. The fallback stadium already
  exists and covers it; `generation_attempts` and `diagnostic_reason`
  already report it. Watch the accepted-first-attempt rate after
  implementation and widen the radial perturbation band if it drops.
- **Float precision** at ~10,000 px is comfortably inside float32 for 2D
  transforms; no action needed.

## Open items

- Decision 5 was implemented as a rebalance of both drag terms rather than
  a cut to `aerodynamic_drag` alone, because the literal reading leaves
  aero contributing 0.2% of drag. Flag during review if the literal
  reading was intended.
