# Height channel desktop validation

## Revision, method, and environment

- **Tested content revision:** `6fbbd4021752d59f2b88c34c42f49a23a70e41e8`
  (`merge: make jump ramp density match design and keep landings on the run (task 6b)`). The
  capture script, this record, the trace, and the stills are committed afterward as evidence only;
  they do not change the tested runtime tree, and no tuning or catalog value was moved.
- **Engine and renderer:** Godot `4.7.1.stable.official.a13da4feb`; graphical X11/OpenGL GL
  Compatibility renderer; Mesa `25.2.8-0ubuntu0.24.04.2`; Intel UHD Graphics (CML GT2).
- **Host:** Pop!_OS 24.04 LTS, Linux `7.0.11-76070011-generic`, Intel Core i7-10510U (4 cores,
  8 logical CPUs), 31 GiB RAM.
- **Command:**

  ```sh
  godot --path . --script res://tests/capture_height_channel_evidence.gd
  ```

  It runs a real `MainSession` in a 1280x720 `SubViewport`. The ledger generates seeds 0-19
  through the production `TrackGenerator`. Each driven capture restarts the session on its seed,
  warms 30 process frames, then places the production `TopDownCar` 420 px before the first ramp's
  crest, on the ramp axis, at 600 px/s with the throttle held down, and renders and measures every
  physics tick until the car has launched and landed again. 600 px/s is the speed a full-throttle
  car actually settles at on dirt; `max_safe_speed` (640 px/s) is a clamp, not a reachable cruise.
  The raw output is [`desktop-trace-seeds-0-4-9.txt`](desktop-trace-seeds-0-4-9.txt).

## Ramp ledger, seeds 0-19

Every seed places at least one ramp. Mean 2.40, maximum 4, total 48.

| Seed | Ramps | Requested | Eligible runs | Placement (us) | Height fingerprint |
| ---: | ---: | ---: | ---: | ---: | --- |
| 0 | 3 | 4 | 3 | 1268 | `6831dab8217f2bd2a407a9d2caf3cb7946c1671b3b3947d6b98ebde1b8537571` |
| 1 | 3 | 3 | 5 | 1453 | `9f1c710cdeeb30dc42a32d8e1ec301f58be9773e9a6a2b17e9b9c2ebc4a31a9c` |
| 2 | 1 | 4 | 3 | 1150 | `605602a82d56acdeca82f15c3a21fb5027badf331afd279d841561dd15ab6578` |
| 3 | 3 | 3 | 4 | 1492 | `be4eeef9dc1a7bfd33a079936574ee5f9ec19bf5203b4b9a4d31580560a0adae` |
| 4 | 4 | 4 | 11 | 1548 | `bc1b6b7292003777c764d44b9cb4220992588a101ebf36c041c752d5929ef71f` |
| 5 | 2 | 2 | 7 | 1247 | `bf4188c776f2b2ae44c87f649734e69036cc23a57bf2989d02e9a300fd29d2b8` |
| 6 | 2 | 4 | 2 | 1134 | `e13abf9d5acd3f2d2f7b6712bba7512ed1d23a00214220f0728ea6068e245009` |
| 7 | 4 | 4 | 4 | 1453 | `01b34f74e5e185293c1b6111e3a53995a8eb93735b875b997f1801560d35a4f0` |
| 8 | 2 | 3 | 3 | 1233 | `b704d6f0b745f71da5a47b24c1d6d504420d4e88f60c930b18ad74fc1766c4be` |
| 9 | 4 | 4 | 7 | 1491 | `443869d91e6ff837e081ef3e50aef759946bf2bf101312e89e4a2d091ab85c9e` |
| 10 | 3 | 3 | 5 | 1504 | `ab36c60bb88410129bbe15244c0f7ea37c53b45d59ef64ee57ad7cc10f13f336` |
| 11 | 1 | 4 | 2 | 1179 | `e9ed445b2926eae68b1e57f35087c43a8eb01e617bb1db042697ce9fe50d5a6f` |
| 12 | 1 | 2 | 1 | 1451 | `db6d8bdb4cd91b54f7ea631b3d62429d2dcdec18a26c918a5b201454b8b197ef` |
| 13 | 2 | 2 | 5 | 1517 | `1b9690103b4c9e03cffa08c1d4e301edd31c79a72f8ab5c8dd5a34ab3939275c` |
| 14 | 2 | 4 | 2 | 1238 | `fee3ceaac918daf9740baba1976ca2e9d32471137f25cb714f0d90b81b5deff9` |
| 15 | 1 | 2 | 3 | 1375 | `9f18398c73c00acfe11f2ca007b629c974bb4210fb7859e431615a6a9a968818` |
| 16 | 2 | 2 | 6 | 1112 | `6352695a13800db1c3f94fa9356d7f009f9a36558314977ee07b099bc8999bc1` |
| 17 | 2 | 2 | 1 | 1072 | `6a2f187aada88834c671fd147c17de8dc93dbb0bfb9d864592600b03a35d8596` |
| 18 | 2 | 2 | 2 | 1013 | `aa3f167e270c8cbbac0eb4b6881afb84e44b6f23fd64e8c4217333c6e29f1672` |
| 19 | 4 | 4 | 5 | 1387 | `a173fe174f3a2ce3d1b93ca14827ed92af72d25f7e4e69c65357076f391d8af1` |

A seed placing fewer ramps than it requested is not a fault: the request is drawn first and the
spawn, checkpoint, and 120 m spacing exclusions are applied afterwards, so a track with few long
straights fills what it can. The road and off-track fingerprints in the raw trace are unchanged
from the pre-height-channel baseline.

## Driven jumps

| Seed | Ramp | Crest | Apex | Air time | Speed before | Speed after | Kept | Recovery |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | `h3:0:0:2` | 9.00 px | 14.48 px (1.159 m) | 0.767 s | 143.6 km/h | 122.4 km/h | 0.852 | 0.350 s |
| 4 | `h3:4:0:4` | 9.00 px | 14.48 px (1.159 m) | 0.767 s | 143.6 km/h | 122.4 km/h | 0.852 | 0.350 s |
| 9 | `h3:9:0:0` | 9.00 px | 14.48 px (1.159 m) | 0.767 s | 143.6 km/h | 122.4 km/h | 0.852 | 0.350 s |

Each apex still was opened and inspected: the body is visibly lifted off its own shadow, the
diagnostics overlay reads a non-zero height and air time, and the ramp wedge is behind the car.
Each landing still shows the car grounded past the ramp with the air-time notice on the HUD.

## Lift-off against approach speed

The same ramp (seed 0) at five approach speeds:

| Approach (px/s) | Approach (km/h) | Apex (px) | Apex (m) | Air time (s) |
| ---: | ---: | ---: | ---: | ---: |
| 200 | 57.6 | 11.04 | 0.883 | 0.600 |
| 300 | 86.4 | 11.49 | 0.919 | 0.617 |
| 400 | 115.2 | 12.38 | 0.990 | 0.667 |
| 500 | 144.0 | 13.06 | 1.045 | 0.700 |
| 600 | 172.8 | 14.48 | 1.159 | 0.767 |

## Flight reach against the solid recovery corridor

Launch headings from 0 to 85 degrees off the ramp axis in 5-degree steps over seed 0's first
ramp, at 600 px/s, recording how far from the crest line the car ever gets sideways while
airborne and while above the 12.5 px clearance height. The arc is a property of the ramp shape
and the car, not of the seed, so one ramp is swept and the corridor is then checked against every
seed from placement data.

| Headings swept | Headings that launched | Max sideways, airborne | Max sideways, above clearance |
| ---: | ---: | ---: | ---: |
| 18 | 18 | 149.9 px | 60.2 px |

| Seed | Ramps | Solids | Nearest solid to the centreline (px) | Nearest a solid may sit (px) |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 3 | 174 | 375.1 | 352.5 |
| 1 | 3 | 248 | 398.9 | 360.0 |
| 2 | 1 | 193 | 389.1 | 355.0 |
| 3 | 3 | 267 | 413.3 | 382.5 |
| 4 | 4 | 231 | 389.4 | 355.0 |
| 5 | 2 | 246 | 407.8 | 390.0 |
| 6 | 2 | 239 | 372.9 | 352.5 |
| 7 | 4 | 219 | 419.7 | 382.5 |
| 8 | 2 | 196 | 382.2 | 360.0 |
| 9 | 4 | 264 | 388.6 | 365.0 |
| 10 | 3 | 265 | 416.4 | 387.5 |
| 11 | 1 | 198 | 406.7 | 380.0 |
| 12 | 1 | 235 | 401.0 | 362.5 |
| 13 | 2 | 286 | 405.9 | 375.0 |
| 14 | 2 | 224 | 414.3 | 385.0 |
| 15 | 1 | 212 | 415.0 | 385.0 |
| 16 | 2 | 202 | 394.8 | 375.0 |
| 17 | 2 | 225 | 396.5 | 370.0 |
| 18 | 2 | 192 | 420.5 | 375.0 |
| 19 | 4 | 224 | 381.8 | 355.0 |

The last column is half the road width plus the off-track catalog's 250 px `solid_clearance`: no
generated solid can ever be nearer the centreline than that. Across seeds 0-19 the nearest a
solid actually sits to the centreline is 372.9 px, against a sideways reach above the
clearance height of 60.2 px. That gap is why no rock can be cleared from a generated ramp, and the capture asserts
it in both directions rather than only reporting it.

## Rock clearance

| Rock | Scale | Held height | Clearance threshold | Contact distance | Overlapping ticks | Speed | Collisions |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v1:0:-10:12` | 0.89 | 14.48 px (1.159 m) | 12.50 px | 28.3 px | 17 | 57.6 km/h | 0 |

The mask is checked on every tick the two collision circles overlap, each of which is a tick a
grounded car would have been stopped on. The still keeps the last of them, because the raised
body is drawn offset along the car's heading and the rock is only visible once it is behind.

The rock is a generated placement from seed 0 with a real chunked static collider on the low
layer, and the car is the production `TopDownCar` with its real mask logic. The height is
supplied by `HeightChannelTestHeightProvider` in plateau mode at the apex the driven ramps above
actually produced, because no generated ramp is near enough to a rock to supply it. The still is
[`seed-0-rock-cleared.png`](seed-0-rock-cleared.png).

## Captures

All 1280x720 RGBA PNGs, each opened and inspected after capture.

| File | Shows |
| --- | --- |
| [`seed-0-approach.png`](seed-0-approach.png) | the ramp 250 px ahead, car grounded at speed |
| [`seed-0-apex.png`](seed-0-apex.png) | the apex, body lifted off its shadow |
| [`seed-0-landing.png`](seed-0-landing.png) | the first grounded frame after the flight |
| [`seed-4-approach.png`](seed-4-approach.png) | the ramp 250 px ahead, car grounded at speed |
| [`seed-4-apex.png`](seed-4-apex.png) | the apex, body lifted off its shadow |
| [`seed-4-landing.png`](seed-4-landing.png) | the first grounded frame after the flight |
| [`seed-9-approach.png`](seed-9-approach.png) | the ramp 250 px ahead, car grounded at speed |
| [`seed-9-apex.png`](seed-9-apex.png) | the apex, body lifted off its shadow |
| [`seed-9-landing.png`](seed-9-landing.png) | the first grounded frame after the flight |
| [`seed-0-rock-cleared.png`](seed-0-rock-cleared.png) | the raised production car over a generated rock |

These are desktop graphical measurements. No Android or Steam Deck height-channel observation
exists; see the [cross-platform PoC report](../../poc-report.md).
