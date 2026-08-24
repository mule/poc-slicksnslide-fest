# Android export and device validation

The `Android Debug` preset builds a credential-free, ARM64 debug APK for the
package `com.mule.slicksnslidefest`. It uses Godot 4.7.1's matching prebuilt
Android template, GL Compatibility rendering, ETC2/ASTC texture imports,
landscape orientation, and immersive full-screen presentation.

Development-only `docs/` and `tests/` resources are excluded from the APK.

The pinned Godot 4.7.1 prebuilt template supplies the effective manifest SDK
levels. Verify those values from every produced APK; Godot only allows the
`min_sdk` and `target_sdk` preset overrides when a custom Gradle build is
enabled.

## Local prerequisites

- Godot `4.7.1.stable.official.a13da4feb` and its matching export templates.
- OpenJDK 17 configured as Godot's **Java SDK Path**.
- An Android SDK configured as Godot's **Android SDK Path**, containing
  platform-tools, build-tools 35 or newer, and Android platform 35 or newer.
- A physical Android device with USB debugging authorized.
- An external controller paired with the Android device for gameplay evidence.

SDK/JDK locations are machine-local Godot editor settings. Do not add those
paths, keystores, generated APKs, or device credentials to the repository.

## Build and inspect the debug APK

From a clean checkout:

```sh
mkdir -p builds/android
godot --editor --headless --path . --quit
godot --headless --path . \
  --export-debug "Android Debug" builds/android/slicksnslide-fest-debug.apk
```

Set `ANDROID_SDK_ROOT` to the configured Android SDK and verify the artifact:

```sh
"$ANDROID_SDK_ROOT/build-tools/35.0.0/apksigner" verify --verbose \
  builds/android/slicksnslide-fest-debug.apk
"$ANDROID_SDK_ROOT/build-tools/35.0.0/aapt" dump badging \
  builds/android/slicksnslide-fest-debug.apk
sha256sum builds/android/slicksnslide-fest-debug.apk
```

## Install and launch

```sh
adb devices -l
adb install -r builds/android/slicksnslide-fest-debug.apk
adb shell monkey -p com.mule.slicksnslidefest \
  -c android.intent.category.LAUNCHER 1
adb shell pidof com.mule.slicksnslidefest
```

For a clean launch log, clear the device buffer before starting and then filter
Godot and Android runtime failures:

```sh
adb logcat -c
adb shell monkey -p com.mule.slicksnslidefest \
  -c android.intent.category.LAUNCHER 1
adb logcat -d | grep -E 'godot|Godot|AndroidRuntime|FATAL EXCEPTION'
```

## Controller and lifecycle matrix

Use the external controller only—touch driving is intentionally out of scope.
Press Back/View to toggle the development overlay on the device. Record its
FPS, frame time, current/peak memory, seed, vehicle state, and normalized input
values during the run.

Validate all of the following on at least three seeds for a continuous
10-minute session:

- left stick and separate triggers reach their intended range and return to
  neutral without drift;
- handbrake, reset, pause/resume, and seed restart work without a pointer;
- one complete ordered lap is accepted;
- controller disconnect neutralizes the vehicle and reconnect does not inject
  held input;
- Android Home/Recent Apps pauses the game, and returning leaves it safely
  paused until **Resume** is confirmed;
- the viewport stays landscape and readable without clipping at the device's
  native aspect ratio and display cutout;
- no crash, hang, stuck input, or steadily unbounded memory trend appears.

Record device model, Android version, controller model, APK filename/SHA-256,
representative frame-time observations, thermal/throttling observations, and a
short gameplay capture in the issue #6 evidence report.

The current partial hardware results and remaining controller blocker are
recorded in [the issue #6 validation report](evidence/android/issue-6-validation.md).
