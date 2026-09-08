# The terrain field

The ground is not flat. Since epic #46 a deterministic terrain field covers the whole play area:
the road climbs and drops with it, the off-track world has shape, the jump ramps of
[the height channel](height-channel.md) are summed onto it, and everything the track draws is
tinted and lit from the same field the car drives on. This document is the contract for that field:
what it is, how it is seeded and fingerprinted, the physics bounds that keep it driveable, how it is
drawn, what it still does not do, and how to verify all of it.

## The field

`world/terrain/terrain_field.gd` is a `HeightQuery`: seeded value noise summed over a few octaves,
evaluated analytically. Every query returns the height, the exact gradient and, when asked, the
exact Hessian; nothing is a finite difference of anything else.

- **Value noise, quintic fade.** Each octave is a square lattice of pseudo-random corner values in
  [−1, 1], interpolated with `6t⁵ − 15t⁴ + 10t³`. The fade's first and second derivatives vanish at
  the cell edges, so the gradient and the Hessian are continuous across every lattice boundary. A
  cubic fade would leave the Hessian stepping at each edge, which the car's lift-off rule reads as
  a crest.
- **Three octaves.** Octave *i* has amplitude `amplitude · persistence^i` and cell width
  `base_wavelength / lacunarity^i`. Curvature scales with amplitude over wavelength squared, so with
  `persistence = 1 / lacunarity²` every octave carries the same curvature as the one below it and
  no single octave owns the bound.
- **No allocation on the car's path.** Evaluation lands in member scalars; `sample_into` writes a
  caller's sample in place; each octave keeps the bilinear coefficients of the cell its previous
  query fell in, so a moving car's consecutive queries skip the four corner lookups per octave.
  A query costs about 4 µs in GDScript, the fade arithmetic alone about 3 µs.

## The catalog

`data/default_terrain_catalog.tres`, `TerrainCatalog` version 1:

| Field | Value | Derived |
| --- | ---: | --- |
| `amplitude` | 40 px | octave amplitudes 40, 10, 2.5 px |
| `base_wavelength` | 3000 px | octave cell widths 3000, 1500, 750 px; a hill-to-hill distance is about twice a cell |
| `octaves` | 3 | |
| `persistence` | 0.25 | `1 / lacunarity²`, so every octave carries equal curvature |
| `lacunarity` | 2.0 | |
| `total_amplitude()` | 52.5 px (4.2 m) | the field never leaves ±52.5 px |
| `slope_bound()` | 0.0875 per axis | `Σ 2 · (15/8) · aᵢ / λᵢ`; the directional slope along any heading stays under `√2 · 0.0875 = 0.1237` |
| `curvature_bound()` | 1.875 × 10⁻⁴ per px | `Σ (225/16) · aᵢ / λᵢ²`; the supremum of the field's directional second derivative |

`225/16` is the cell-centre saddle's eigenvalue for corners (−1, +1, +1, −1), which exceeds the
axis-aligned worst case of `20/√3`; `tests/terrain_field_contract_test.gd` rederives it by brute force
over 1201 × 1201 positions and all sixteen corner sign patterns.

**The road is not flattened.** Issue #47 originally asked for the field to be damped to flat on the
centreline. #49 showed that any envelope taking the field to zero across the road adds curvature of
its own, of order `total_amplitude / width²`, about seven times the lift-off threshold at any
practical width; only a flatten some 6000 px wide would fit, which would flatten most of the play
area. The premise that made flattening seem necessary is also false: the car takes only the
*forward* component of the gradient, so a laterally tilted road exerts no sideways force. The road
is summed onto the field as it is and its drivability rests on `curvature_bound()` alone.
`road_flatten_width` was removed from the catalog.

## Terrain plus ramps

`TrackHeightMap` (`track/track_height_map.gd`) is the production `HeightQuery`: the terrain sample is
taken at every query and a ramp's wedge is summed onto it when the position is inside that ramp.
Heights add and gradients add. Across the road the wedge is the linear hump of #37 at full height;
beyond each road edge it fades to nothing over the placement's `flank_width` (250 px) along the same
quintic fade, so the total height is continuous everywhere and its second derivative has no step at
either edge of the flank.

That flank closed the side-wall defect of #37: the old map cut the wedge off at the road edge,
leaving a vertical wall a car crossing from the side drove *under*. A car now rides the flank onto
the wedge — `tests/terrain_height_map_test.gd` drives the production car across it at the off-track
terminal speed and its ride height tracks the map within 0.18 px on every tick. The flank's own
curvature stays under the lift-off threshold at the speed a car can carry onto it from off-track
(289 px/s sideways); above that a crossing hops, and the hop is bounded by assertion at 7.61 px
(the ballistic apex of the fade's peak slope at `max_safe_speed`) and by the 9 px crest height. At
601 px/s sideways the measured hop is 3.8 px (0.3 m), 0.58 s in the air, landing on the road. A
placement with a zero flank width is the old hard cut, and `--break-side-wall` restores it.

A definition without a terrain seed (a hand-built fixture) gets a flat base, so every pre-terrain
fixture reads exactly as it did.

## Determinism

Terrain is its own domain, seeded by the project's one scheme and never touching the road
generator's RNG stream:

- The field's seed is `DomainSeed.derive(catalog.version, track_seed, "terrain")`. Each octave's
  lattice seed is a `DomainSeed.child` of that; each lattice corner's value is a `DomainSeed.child`
  of the octave seed keyed by the corner's integer coordinates. No `RandomNumberGenerator` is
  involved, so the same seed and version reproduce the same field on every platform.
- `TrackGenerator` attaches the terrain after road acceptance and after ramp placement, on both the
  accepted and the fallback exit paths. `TrackDefinition` carries `terrain_seed`,
  `terrain_fingerprint`, `terrain_generation_usec` and `terrain_diagnostics`.
- The **terrain fingerprint** is a SHA-256 over a header (`version`, `seed`, the play area, the
  spacing) and the field's height to three decimals at every point of a 250 px grid over the play
  area — the same pitch as the off-track placement cell and the ground grid. The field is never
  serialised; the fingerprint stands in for it. The contract test rebuilds it independently from
  `height_at` over the documented grid.
- **The three older fingerprints did not move.** Terrain draws only from `DomainSeed`, so the
  object placer downstream sees an untouched RNG stream, and ramps are fingerprinted before terrain
  exists; `tests/terrain_height_map_test.gd` pins the road, object and height fingerprints of seeds
  0–19 byte for byte against a dump taken before terrain was attached, and
  `tests/capture_terrain_evidence.gd` checks them again against the checked-in height-channel
  ledger every time it runs. A changed fingerprint is a blocker, never a re-baseline.

### Seeds 0–19

From [`docs/evidence/terrain/terrain-ledger-seeds-0-19.txt`](evidence/terrain/terrain-ledger-seeds-0-19.txt),
generated twice per seed (every fingerprint repeats, all twenty are distinct). Statistics are over
the fingerprint grid of each seed's play area (2 550 to 4 012 samples); road figures are along the
centreline.

| Seed | Terrain fingerprint | Min | Max | RMS | Road min | Road max | Road climb per lap |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | `03f45d13053809507e6cfac470a1ff4b3d7ddf8a4d18eef7bd380599ccbf8885` | −45.7 | 44.5 | 18.4 | −38.0 | 40.8 | 133 px |
| 1 | `971e18b00e98a00d6b4628dff2896f193ce5d86e586c7a19e2970d99c8a87e87` | −42.4 | 36.0 | 17.9 | −38.4 | 20.6 | 165 px |
| 2 | `ea0c7206675f60c2115bc10a2bf599acef83114b9f5b9e5193fe0a2962f48243` | −46.0 | 45.3 | 19.3 | −35.5 | 29.3 | 140 px |
| 3 | `472aa1213308ccee37eb1366b1a3f672a7efc7360a151fa3372e6363f4df2225` | −41.6 | 43.9 | 21.4 | −41.8 | 29.0 | 229 px |
| 4 | `e000021cdd90f6952df414f798133aacfea90f7416ab1f7edb8271ccd7328e6a` | −48.4 | 34.2 | 16.1 | −45.2 | 21.4 | 185 px |
| 5 | `1b8865bf3c79745bae5d159c63d87091dbe919c90167293d4df71a285ca9c212` | −37.8 | 41.3 | 17.0 | −32.5 | 34.0 | 169 px |
| 6 | `4e71c736f8b90a4b1418acf055762bda319efaca5e4e4ab608abb0e1e6c6e685` | −31.1 | 42.9 | 14.6 | −29.3 | 34.1 | 128 px |
| 7 | `1816bc94310f44acf695f3bfec53751b52e9b1bc6dad56adefb029fc6cd47f31` | −42.9 | 44.8 | 18.2 | −29.2 | 24.0 | 141 px |
| 8 | `e1c293d2fe8be5d8628508b9b2a40bfa8b9fc13127344ee1aba2573b8f68af26` | −47.7 | 38.1 | 18.0 | −32.3 | 32.0 | 153 px |
| 9 | `cc0b9c84f96d4c344caa130c974ee878ff6c7878cb1a4532cf4b63b42e9b3b90` | −46.2 | 45.6 | 17.2 | −26.1 | 34.4 | 175 px |
| 10 | `80924d2e243d73d17bc7e8cce67d5acb58e7685d72e1726fd4b6a338d256d910` | −46.0 | 32.2 | 18.2 | −36.1 | 24.6 | 191 px |
| 11 | `f108b02e930453b350e4622d7d695712e62bc4d5c5372b03d53146d075f0f4bb` | −31.8 | 43.0 | 18.2 | −30.2 | 28.3 | 138 px |
| 12 | `3d2d5a550bef4709121b6eb5a7fd443b89e776018343263962658df63b88a7f5` | −45.2 | 47.9 | 17.2 | −7.2 | 36.5 | 117 px |
| 13 | `481b26e5b6316bb0a2ad98e43f65b6f9cbfae28d202026a9e386109a51171177` | −42.6 | 40.5 | 20.1 | 1.0 | 40.6 | 123 px |
| 14 | `8792bc236c46a3611360cad3fcb1cfd4acda4e59c0bd65384c0f87184d1c7a95` | −37.3 | 39.4 | 17.3 | −35.4 | 25.9 | 123 px |
| 15 | `ef12242db0b25a061999098cf19bcd5289a02b4f9fc3377bd8e499d418e00ab9` | −36.4 | 45.4 | 19.2 | −35.3 | 39.3 | 203 px |
| 16 | `93dc52a69b19f896646c1f31e3a5b45172fb6bcbf1de90d2d6e490c9d6e2b556` | −45.3 | 44.5 | 16.8 | −43.5 | 44.4 | 176 px |
| 17 | `82cbc5ec4f3d167a205eede1d76a4d7bf0bc4c912f558e9664f5fa226fb94bb1` | −36.3 | 38.2 | 16.9 | −31.9 | 36.5 | 172 px |
| 18 | `38aaf85dd1eb9ea591a4ee8de3f6108fa9c087e0c143de39b10f3edafa539a52` | −46.2 | 45.6 | 21.1 | −23.8 | 41.5 | 133 px |
| 19 | `8b13fca574d45984d30191593b81a11c9dcd44c2cf44ee031afb989a5b261d9b` | −45.8 | 40.2 | 18.2 | −45.8 | 12.5 | 127 px |

Heights are px; 12.5 px is a metre. Every seed stays inside ±52.5 px (the widest is seed 4's −48.4
to seed 12's +47.9), the steepest sampled gradient component is 0.0551 (seed 18) against the 0.0875
bound, the least relief in any play area is 74 px, and seed 13's road never dips below zero, which
is why the pre-terrain safe-pose gate would have refused the whole of that lap (see below).

**The fingerprint is downstream of road tuning.** The play area is the track's bounds grown by
2000 px, so any road-generator change that moves a track's bounds moves that seed's terrain
fingerprint even though the field itself is unchanged; the same unversioned coupling the height
fingerprint has to `STRAIGHT_CURVATURE` and `SAMPLE_SPACING`. Treat a road-fingerprint failure as
the signal that the recorded terrain fingerprints need regenerating too.

## The physics bounds

Sustained slopes are a physics change, not a rendering change. Every bound below is an assertion
in `tests/terrain_field_contract_test.gd`, `tests/terrain_height_map_test.gd` or
`tests/vehicle_terrain_test.gd`, derived from the vehicle's own tuning and the catalog rather than
from a hardcoded number; [The height channel](height-channel.md#slopes) has the full derivations
and the driven figures.

- **Lift-off is a bound on curvature, not slope.** The car's lift-off rule fires when the ground
  ahead falls away faster than one tick of gravity can pull the car onto it, which on a smooth
  surface reduces to `v² · |h″| > g`. At `max_safe_speed` = 640 px/s and `gravity` = 122.625 px/s²
  the threshold is `2.9938 × 10⁻⁴` per px; the catalog's bound is `1.875 × 10⁻⁴` (a 1.60× margin
  analytically, 2.74× on the sampled field, and a driven maximum of `1.10 × 10⁻⁴` over 36 709 ticks
  of straight lines at 640 px/s on three seeds, never airborne). `g / v²` is the *conservative*
  form of the discrete rule. `--break-terrain-curvature` quadruples the amplitude and breaks it;
  `--break-terrain-lift-off` does the same under the real integrator and launches the car on 44 ticks.
- **Uphill cannot stall.** From rest the car stalls only on a slope above
  `(engine_force / mass) / g = 1.575` (57.6°); the steepest directional slope the catalog allows is
  0.1237, a 12.7× margin, and the steepest climb any seed's road produces is 0.0486. The worst climb
  costs 4.4 % of level top speed (573.3 against 600.0 px/s).
- **Downhill is held by drag, the clamp is a backstop.** Full throttle on the steepest slope the
  catalog allows balances drag at 625.6 px/s, under the 640 px/s clamp by 2.3 %; a released car on
  the steepest road descent peaks at 40.7 px/s. The clamp is proven on a synthetic 0.5 slope, six
  times the bound, where the car sits at exactly 640 for a second (`--break-speed-clamp` raises the
  clamp and the same drive peaks at 683.2).
- **The safe-pose gate reads feature membership, not height.** The pre-terrain gate refused a pose
  wherever the ground was above zero, which on a terrain field is between a quarter and the whole
  of a lap. `HeightSample.on_feature` now says whether a position is on a ramp or its flank; the gate
  reads that, and the capture *rate* is asserted against an eligibility trace built from the car's
  public state (128 of 128, 157 of 157, 160 of 160 on the three driven seeds).
- **Query cost — a deviation from #47's scope.** Issue #47 asked the query cost to stay within the
  existing 20 ms per ten thousand queries budget. It does not: a three-octave field costs about 4 µs
  a query, so ten thousand terrain-bearing queries cost about 40 ms, and the assertion that covers
  the shipped map is a median-of-three under 60 ms in the height map suite. The 20 ms assertion in
  the ramp placement suite still passes but its fixture has no terrain seed. Per tick the car's two
  queries cost about 8 µs, under a tenth of a percent of a 60 Hz tick.

## Presentation

Elevation reads as tint, light and shadow. Nothing here samples a field of its own:
`TrackRuntime` builds one `TrackHeightMap` from the definition — the same class, catalog and seed
the session gives the car — and every cue is computed from that map, so the tint under the car and
the car's own ride height cannot disagree. `tests/terrain_visuals_test.gd` asserts the agreement
per vertex against a freshly built car-path map.

- **Ground and road (#50).** `TerrainShading.shade(base, sample)` multiplies a base colour by
  `1 + 0.45 · clamp(height / 52.5) + 0.35 · light_term`, where the light term is the Lambert term
  of the height field against a light in the screen's top-left, scaled by the slope bound. The
  ground is one `Polygon2D` with a vertex every 250 px over the play area; the road ribbons, the
  boundary lines and the ramp wedges take gradients or vertex colours from the same function. The
  ground base colour is `#2b4b29`, lightened from `#203a1e` so a 45 % swing is a visible step, and
  the suite asserts an absolute luminance spread of at least 0.15 across the seed 0 grid.
- **Objects (#51).** Every off-track body is lifted up the screen by the ground height at its foot
  at `LIFT_PIXELS_PER_PIXEL` = 1.0, the car's own rate, and coloured by `shade()` from the same
  sample. Because the shading is multiplicative, a body's luminance ratio against the ground is a
  constant of its base colour, and `BODY_CONTRAST_FLOOR` = 1.4 is the rule every base colour must
  satisfy; #50's unshaded trees crossed the ground's luminance at +20 and +43 px and vanished in
  between. Colliders stay flat circles. Placement never sees terrain, so the object fingerprint is
  unchanged.
- **Shadows are anchored to the lift (#52).** #51 left every shadow at the foot while the body rose,
  and its stills showed a tree on a +42 px rise floating 20 px clear of a detached shadow, and a
  tree in a hollow with its shortened shadow above and left of the body — on the lit side, sunk under
  its own shadow. That reversal was new: before bodies moved vertically, shadows only varied in
  length. The user's decision was to anchor the shadow to the body's lift. A solid's shadow is now
  cast *from the lifted body* along the shadow direction, at the factory offset times the length
  factor (`1 + 0.15 · metres` of ground height, clamped 0.5–2.0), so it stays under the body on a
  rise and cannot cross to the lit side in a hollow. The car follows the same split: the ground
  height lifts its body and its shadow together, straight up the screen whatever the heading (until
  #52 the lift was along the heading, so a car pointing right drew ahead of its shadow), and only
  the height *above* the ground opens a gap, grows the body and fades the shadow. Height then reads
  through the lift, the tint and the shadow's length, not through a gap. What the before-and-after
  stills show is in [the height channel](height-channel.md#what-the-object-stills-show).
- **Still unshaded.** The ramp crest line and chevrons, the checkpoint gates and start/finish line,
  and the car are flat-coloured furniture drawn over shaded ground. They are not reading the wrong
  height; they are not reading any. The claim "nothing the track draws can disagree with the ground
  it sits on" is therefore true of the ground grid, the ribbons, the boundary lines, the wedges and
  the object bodies, and of nothing else.

### How it drives (#52)

`tests/capture_terrain_evidence.gd` laps seeds 0, 4 and 9 through the production session with the
pure-pursuit driver of the vehicle terrain suite, at the production 1 / 60 s step (300 ticks a second
under a time scale of 5, pinned against the integrator's model to 0.002 px/s), auto-reset on, and
records every flight and landing. From
[`drive-trace-seeds-0-4-9.txt`](evidence/terrain/drive-trace-seeds-0-4-9.txt):

| Seed | Lap | Top | Mean on climbs | Slowest on a climb | Mean on descents | Fastest descent | Flights | Landings on the road | Resets |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 69.6 s | 161.5 km/h | 116.0 km/h | 67.4 km/h | 108.2 km/h | 148.3 km/h | 3 of 3 from ramps | 3 of 3 | 0 |
| 4 | 85.2 s | 167.7 km/h | 119.0 km/h | 56.8 km/h | 133.6 km/h | 161.6 km/h | 4 of 4 from ramps | 4 of 4 | 0 |
| 9 | 86.8 s | 164.3 km/h | 132.4 km/h | 91.4 km/h | 119.1 km/h | 158.7 km/h | 4 of 4 from ramps | 4 of 4 | 0 |

The lap times match the vehicle terrain suite's headless laps within a second (69.0, 84.5, 86.2 s).
The slowest climb speeds are corner exits that happen to be uphill, not stalls: the mean speed on
climbs is within 3 km/h of the level mean on seeds 0 and 4 and above it on seed 9, and no lap held
the car under the stuck speed for more than seven ticks. No descent came within 20 km/h of the
clamp. No flight left from bare terrain; every landing came down on the road, at apexes of 13.3 to
13.9 px over the ground (the flat-plane figure was 14.5 px at a faster crest). Ramps on shaped
ground land as they did on the plane — the wedge is summed onto the terrain, so the far side is the
terrain's own slope and the driver's speed governor never noticed. Stills:
[`seed-0-hill.png`](evidence/terrain/seed-0-hill.png) (the car on seed 0's highest road sample,
+40.8 px), [`seed-4-slope.png`](evidence/terrain/seed-4-slope.png) (its most lit stretch, light
term 0.38), [`seed-0-ramp-on-terrain.png`](evidence/terrain/seed-0-ramp-on-terrain.png) (a ramp
in a −38 px hollow, wedge as dark as the hollow), [`seed-9-ramp-on-terrain.png`](evidence/terrain/seed-9-ramp-on-terrain.png)
(a ramp on a +14.5 px rise) and the drive apex and landing stills per seed.

How the hills read, honestly: on the road, well — the ribbon's tint swings from 0.67× in a hollow
to 1.41× on a crest and a lit slope brightens visibly along its length. Off the road, moderately —
the ground grid's tint is a 45 % swing on a mid-green base and reads as lighter or darker ground
rather than as a hill in relief; the shadow length on the solids is the only off-road cue with a
direction. The drive was scripted, not by hand: the numbers above are what a full-throttle driver
measured, and whether the climbs *feel* fair on a controller is a judgment this capture cannot make.

## Limitations

- **A shadow in a hollow nearly disappears.** Anchoring the shadow to the lift removes the gap that
  said "raised", and in a hollow the shadow is shortened (0.56× at −36 px) and cast 4.4 px from a
  body the same size, over the darkest ground there is. In `seed-0-object-low.png` the lowered tree
  reads as a flat shape on dark ground with almost no shadow, not as sunk under one. The failure
  mode the fix invited — a shadow that reads as painted on rather than cast — shows on the low
  sites, not on the high ones, where the lengthened shadow reads as cast.
- **Off-road relief is legible mainly through the road and the shadows.** See above.
- **The car's low-layer mask compares its absolute height, not its height over the ground.**
  `TopDownCar.get_collision_level_mask()` drops the low layer when `_height` exceeds the 12.5 px
  clearance, and since #47 `_height` is the terrain height while grounded: a car driving on any rise
  above 12.5 px passes through rocks without leaving the ground (412 of the 1 511 rocks in seeds
  0–19 stand on such ground). Deferred in #52, deliberately: the fix is one comparison in the
  vehicle, but `tests/airborne_obstacle_level_test.gd` proves the layer rule by holding a *grounded*
  car on a raised plateau as a stand-in for flight, so the fixture has to be redesigned around a
  genuinely airborne car, the engine-frame figures of the rock-reachability table change, and the
  rule is a collision decision the epic never made. The object suite prints both frames so the fix
  can be measured when it is taken.
- **A fast lateral flank crossing hops** (above 289 px/s sideways; bounded at 7.61 px).
- **No rock can be cleared from a generated ramp.** Re-measured on terrain over every ramp of seeds
  0–19: the gap narrowed from about 155 px to 137 px and remains. See the height channel's
  *Re-measured on terrain*.
- **The ground grid creases.** `Polygon2D` interpolates linearly within each triangle, so a cell whose
  tint is not planar shows a faint diagonal crease; alternating the split direction turns the streaks
  into a lattice the eye does not follow. A shader would remove it; the epic ruled a shader out.
- **Cross-road camber is drawn but not felt.** The road is summed onto the field without damping, so
  a road running along a slope is tilted across its width; the car takes only the forward gradient,
  so the tilt costs nothing. No drive has found it odd; none has looked for it.
- **The car's shadow does not lengthen with the ground** the way the solids' do; it fades and
  separates only with height above the ground.
- **The query budget of #47 is not met**; see *The physics bounds*.

## Verification

Suites (headless):

```sh
godot --headless --path . --script res://tests/terrain_field_contract_test.gd
godot --headless --path . --script res://tests/terrain_height_map_test.gd
godot --headless --path . --script res://tests/vehicle_terrain_test.gd
godot --headless --path . --script res://tests/terrain_visuals_test.gd
godot --headless --path . --script res://tests/offtrack_object_terrain_test.gd
godot --headless --path . --script res://tests/jump_ramp_visuals_test.gd
```

The contract suite pins the catalog derivations, the seed vectors, determinism, the fingerprint
(rebuilt independently from the public height query), the central-difference gradient and the
curvature bound with its brute-forced constant. The height map suite pins the three older
fingerprints byte for byte for seeds 0–19, the terrain-plus-wedge sum, the flank crossing and its
hop bound, and the query cost that covers the shipped path. The vehicle terrain suite drives the
bounds above and three whole laps, about two minutes. The visuals suite pins the shading, the
agreement with the car's own map, the object shadow cast from the lifted body on raised, level and
lowered ground, and the build cost. The object terrain suite pins the seating, the contrast rule,
every production solid's shadow anchor on two seeds, the object fingerprints and the
rock-reachability measurement, about four minutes. The ramp visuals suite pins the car's
presentation split: body and shadow lifted together on the ground, the gap only in the air.

Graphical evidence (not `--headless`; needs a display):

```sh
godot --path . --script res://tests/capture_terrain_evidence.gd
godot --path . --script res://tests/capture_terrain_visuals.gd
godot --path . --script res://tests/capture_offtrack_object_terrain.gd
```

The first writes the seeds 0–19 terrain ledger, the three-seed drive trace and the hill, slope,
ramp-on-terrain, drive-apex and drive-landing stills under
[`docs/evidence/terrain/`](evidence/terrain/), and checks a seed restart replaces the track, its
terrain shading, its ground grid, its objects and the car without retaining a node. The other two
write the elevation and object stills there. It takes about a minute; the three laps run five times
faster than real time.

### Every mutation flag

Each must exit non-zero on its own assertion, not on a load error: check the first `FAIL:` line.
The terrain flags are the first seven; the rest belong to the height channel, the off-track objects,
the open surface and the vehicle, and are listed so one run covers the whole project.

```sh
godot --headless --path . --script res://tests/terrain_field_contract_test.gd -- --break-terrain-version
godot --headless --path . --script res://tests/terrain_field_contract_test.gd -- --break-terrain-seed
godot --headless --path . --script res://tests/terrain_field_contract_test.gd -- --break-terrain-curvature
godot --headless --path . --script res://tests/terrain_height_map_test.gd -- --break-side-wall
godot --headless --path . --script res://tests/terrain_height_map_test.gd -- --break-flank-curvature
godot --headless --path . --script res://tests/vehicle_terrain_test.gd -- --break-terrain-lift-off
godot --headless --path . --script res://tests/vehicle_terrain_test.gd -- --break-speed-clamp
godot --headless --path . --script res://tests/offtrack_object_terrain_test.gd -- --break-rock-corridor
godot --headless --path . --script res://tests/jump_ramp_placement_test.gd -- --break-height-seed
godot --headless --path . --script res://tests/jump_ramp_placement_test.gd -- --break-clearance
godot --headless --path . --script res://tests/jump_ramp_placement_test.gd -- --break-density
godot --headless --path . --script res://tests/vehicle_height_channel_test.gd -- --break-gravity
godot --headless --path . --script res://tests/vehicle_height_channel_test.gd -- --break-landing
godot --headless --path . --script res://tests/airborne_obstacle_level_test.gd -- --break-height-layers
godot --headless --path . --script res://tests/offtrack_object_placement_test.gd -- --break-seed
godot --headless --path . --script res://tests/offtrack_object_placement_test.gd -- --break-clearance
godot --headless --path . --script res://tests/offtrack_object_collision_test.gd -- --remove-solid-collider
godot --headless --path . --script res://tests/offtrack_object_collision_test.gd -- --solid-decoration
godot --headless --path . --script res://tests/offtrack_object_performance_test.gd -- --break-runtime-integrity
godot --headless --path . --script res://tests/track_collision_physics_test.gd -- --break-collision
godot --headless --path . --script res://tests/issue_4_vehicle_maneuvers.gd -- --break-countersteer
godot --headless --path . --script res://tests/issue_4_vehicle_maneuvers.gd -- --break-proportional-steering
godot --headless --path . --script res://tests/issue_4_vehicle_maneuvers.gd -- --break-surface-recovery
```

| Flag | Suite | Breaks |
| --- | --- | --- |
| `--break-terrain-version` | field contract | bumps the catalog version on every second build, so repeat samples and fingerprints stop agreeing |
| `--break-terrain-seed` | field contract | derives every second build's seed from the wrong domain, so repeats stop agreeing |
| `--break-terrain-curvature` | field contract | quadruples the amplitude, so the field breaks the lift-off bound |
| `--break-side-wall` | height map | zeroes the fixture ramp's flank width, restoring the hard lateral cut of #37 |
| `--break-flank-curvature` | height map | quarters the flank width, so its curvature breaks the crossing-speed bound |
| `--break-terrain-lift-off` | vehicle terrain | quadruples the terrain amplitude under the lift-off drive |
| `--break-speed-clamp` | vehicle terrain | raises `max_safe_speed` to 2000 under the clamp drive |
| `--break-rock-corridor` | object terrain | removes the recovery corridor and fills every hazard cell with a rock up to the road edge |
| `--break-height-seed`, `--break-clearance`, `--break-density` | ramp placement | see [the height channel](height-channel.md#verification) |
| `--break-gravity`, `--break-landing` | vehicle height channel | see [the height channel](height-channel.md#verification) |
| `--break-height-layers` | airborne obstacle level | puts every solid on the tall layer |
| `--break-seed`, `--break-clearance` | object placement | see [off-track objects](offtrack-objects.md) |
| `--remove-solid-collider`, `--solid-decoration` | object collision | see [off-track objects](offtrack-objects.md) |
| `--break-runtime-integrity` | object performance | builds the runtime from an empty placement list, so its counts disagree with the placed set |
| `--break-collision` | track collision physics | removes the containment boundary |
| `--break-countersteer`, `--break-proportional-steering`, `--break-surface-recovery` | vehicle manoeuvres | steers with the slide instead of against it; doubles the half-steer input; gives off-track the dirt's grip and drag |

Three assertions have no flag and are demonstrated in code instead, all recorded in the task
reports: the safe-pose capture rate (revert the gate to `_ground_height > 0.0`), the shading
agreement (make `TrackRuntime` reconstruct the field from the track seed, or without the ramps), and
the object shadow anchor (with the anchor at the foot, both the visuals suite and the object terrain
suite fail — five fixture assertions and 174 and 265 production mismatches on seeds 0 and 10).

Two off-track suites, `offtrack_object_placement_test` and `offtrack_object_performance_test`, miss
an 80 ms p95 budget under machine load between a third and two thirds of the time, at `main` as
well as on any branch. Re-run either alone on an idle machine before reading a red result.
