# Issue #6 Android validation evidence

Validation date: 2026-08-24 (Europe/Helsinki)

This report records the Android evidence collected from the issue #6 feature
branch. It deliberately separates verified results from the controller-only
criteria that could not be exercised without an external gamepad.

## Build artifact

| Field | Verified value |
| --- | --- |
| Godot | `4.7.1.stable.official.a13da4feb` |
| Preset | `Android Debug` using the matching prebuilt Android template |
| APK | `builds/android/slicksnslide-fest-debug.apk` |
| Size | 28,422,042 bytes |
| SHA-256 | `83ba6cf94dcde3be2ec750eace3640d455999df3c2c312f457ffdd6032952689` |
| Package | `com.mule.slicksnslidefest` |
| Version | code `1`, name `0.1.0-poc` |
| ABI | `arm64-v8a` only |
| Manifest SDK | minimum API 24, target/compile API 36 |
| Signature | APK Signature Scheme v2 and v3 verified |

The export completed without warnings or errors after importing ETC2/ASTC
textures and the project launcher icon. `adb install -r` returned `Success`,
and the installed package path was observed under `/data/app`.

## Device and environment

| Field | Verified value |
| --- | --- |
| Device | Samsung Galaxy Tab S9, model `SM-X710` |
| Serial | `R52Y202C7LJ` |
| Android | 16, API 36 |
| Physical display | 2560×1600 landscape validation, 340 dpi, 120 Hz |
| Renderer | Godot GL Compatibility / OpenGL ES 3 |
| External controller | Not present in Android `dumpsys input` during this run |

Samsung DeX initially opened the activity as a freeform window and ignored the
requested handheld orientation. The app was then exercised as a full-display
task with the tablet temporarily rotated to 2560×1600. The original
auto-rotation and user-rotation settings were restored after testing. DeX
freeform behavior remains a known environment limitation rather than being
presented as native handheld fullscreen evidence.

## Automated verification

The final local matrix passed:

- foundation smoke check;
- deterministic generator: 394 checks;
- generated collision physics: 59 checks;
- vehicle maneuvers: 38 checks;
- controller/input and time-trial state: 63 checks;
- integrated main session: 25 checks;
- Android lifecycle/diagnostics: 17 checks;
- editor headless import, `git diff --check`, Android export, APK signature,
  manifest, ABI, install, launch, and foreground-process checks.

The issue #6 Android test drives real Godot application notifications. It
proves that pause/focus loss suspends the time trial and immediately zeros a
held vehicle input, while resume leaves the game paused until explicit
confirmation. It also verifies the Back/View diagnostics action and visible
FPS, frame-time, memory, seed, vehicle, and normalized-input telemetry.

## Physical-device observations

- The package launched as the foreground Godot activity and remained running
  without a Godot script error, Android fatal exception, crash, or hang.
- The 2560×1600 capture shows the complete single gameplay viewport, HUD,
  diagnostics, track, and car without clipping or a second/lower panel.
- Sending Android Home and reopening the task returned to the focused pause
  menu. Diagnostics showed steering, throttle, brake, and handbrake all at
  `0.00`; the game did not auto-resume.
- Android keyboard-event injection exercised Resume, Reset, Pause, and
  Regenerate-next-seed through the real UI. Seed labels and diagnostics
  advanced from 0 through 3.
- The development overlay reported 119–120 FPS and 8.33 ms frame time while
  stationary. This is launch/session evidence, not a substitute for a
  controller-driven performance run.

### Sustained session samples

The package remained active for 10 minutes 5 seconds while the session moved
through seeds 1, 2, and 3. Android total PSS showed no upward trend.

| Time | Seed | PID | Total PSS | Battery temperature |
| --- | ---: | ---: | ---: | ---: |
| 18:53:26 | 1 | 17222 | 323,877 KiB | 28.0 °C |
| 18:56:48 | 2 | 17222 | 324,071 KiB | 28.1 °C |
| 19:00:10 | 3 | 17222 | 321,314 KiB | 28.1 °C |
| 19:03:31 | 3 | 17222 | 320,593 KiB | 28.2 °C |

Godot's in-game static-memory metric was approximately 34–36 MiB. Android PSS
includes the runtime, native libraries, graphics allocations, and platform
process overhead, so the two measurements are intentionally reported
separately.

## Captures

- [Landscape launch and diagnostics](landscape-sm-x710.png)
- [Safe paused state after Android Home/resume](resume-paused-sm-x710.png)
- [Seed 1](seed-1-sm-x710.png)
- [Seed 2](seed-2-sm-x710.png)
- [Seed 3](seed-3-sm-x710.png)

## Remaining acceptance blockers

Issue #6 must remain open until an external controller is connected and the
following physical evidence is added:

- full analog stick/trigger ranges, polarity, neutral return, and drift;
- controller-only title/session flow, one complete valid lap, pause, reset,
  and seed restart across at least three seeds;
- controller disconnect/reconnect while holding input;
- a controller-driven 10-minute run with representative frame-time and thermal
  observations;
- a short gameplay capture demonstrating controller-only operation.

Touch driving is intentionally out of scope. Automated InputMap coverage and
Android keyboard injection do not satisfy these controller hardware gates.
