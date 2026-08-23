# Slicks 'n Slide Fest

A Godot proof of concept for a single-viewport, top-down dirt-racing game. It now launches directly into a deterministic generated circuit with a force-based car, controller-first input, ordered lap timing, safe reset, pause, and seed restart.

## Required Godot version

Use **Godot 4.7.1 stable**, official build `a13da4feb`, with its matching export templates. The project uses the GL Compatibility renderer so the same rendering baseline can target desktop Linux, Steam Deck, and Android.

## Quick start

From a clean checkout:

```sh
godot --editor --path .
```

Press **F5** (**Run Project**) in the editor or run the configured main scene directly:

```sh
godot --path .
```

The project opens one full-screen gameplay canvas. Drive with a left stick and triggers or WASD/arrow keys, use the handbrake with a face button or Space, reset with a separate face button or R, and pause with Menu/Start or Esc. The pause menu can resume, restart the same seed, or generate the next seed without a mouse.

Press **F3** to toggle the development diagnostics overlay. The overlay is forcibly hidden in release exports. See [Controller-first time trial](docs/controller-time-trial.md) for the complete mapping and tuning contract.

## Verification

Import the project and exit after all resources are parsed:

```sh
godot --editor --headless --path . --quit
```

Run the foundation smoke check:

```sh
godot --headless --path . --script res://tests/headless_smoke.gd
```

The smoke check loads and instantiates the configured main scene, exercises its interchangeable track/vehicle mount points, verifies normalized vehicle input behavior, checks release diagnostics visibility, and loads the default seed and vehicle-tuning resources.

Run the issue #5 input/session and integrated-scene checks:

```sh
godot --headless --path . --script res://tests/issue_5_input_session_test.gd
godot --headless --path . --script res://tests/issue_5_main_session_test.gd
```

Refresh the checked-in 1280×720 gameplay and 1280×800 pause-menu evidence using a graphical Godot session:

```sh
godot --path . --script res://tests/capture_issue_5_session.gd
```

## Project boundaries

| Directory | Responsibility |
| --- | --- |
| `track/` | Deterministic generated track data, runtime geometry/collision, lap order, and surface queries |
| `vehicle/` | Tunable force-based car dynamics, reset safety, feedback, and diagnostics |
| `input/` | InputMap polling, deadzone processing, and hardware-independent normalized vehicle input |
| `session/` | Integrated time trial, checkpoint crossing, pause/restart flow, HUD, and diagnostics |
| `platform/` | Small Android or Linux/Steam Deck adapters only |
| `data/` | Versioned/default seed and physics tuning resources |
| `tests/` | Headless project, contract, and future deterministic behavior checks |

`TrackDefinition` carries the generated centerline, width, bounds, spawn transform, ordered checkpoints, seed, and geometry fingerprint. `SurfaceQuery` maps a world position to surface type, grip, and drag. `VehicleInputState` carries normalized steering, throttle, brake, and handbrake values without referencing hardware.

The session owns `TrackMount` and `VehicleMount` integration points. Track and vehicle scenes are installed as opaque scene roots, so neither side needs hard-coded paths into the other's internals.

## Export placeholders

`export_presets.cfg` contains shared, credential-free placeholders for:

- `Android Debug`, producing `builds/android/slicksnslide-fest-debug.apk` once issue #6 supplies and validates the Android toolchain;
- `Linux x86_64`, producing `builds/linux/slicksnslide-fest.x86_64` once issue #7 validates the Steam Deck package.

No SDK paths, signing material, generated binaries, or local credentials belong in the repository. Platform-specific build and physical-device validation are intentionally deferred to issues #6 and #7.
