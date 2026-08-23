# Slicks 'n Slide Fest

A Godot proof of concept for a single-viewport, top-down dirt-racing game. The current foundation launches a placeholder circuit and establishes the contracts that runtime track generation, vehicle physics, shared input, and target-platform adapters build upon.

## Required Godot version

Use **Godot 4.7.1 stable**, official build `a13da4feb`, with its matching export templates. The project uses the GL Compatibility renderer so the same rendering baseline can target desktop Linux, Steam Deck, and Android.

## Quick start

From a clean checkout:

```sh
godot --editor --path .
```

Press **F6** in the editor or run the configured main scene directly:

```sh
godot --path .
```

The project opens one full-screen gameplay canvas containing placeholder track and vehicle geometry. Press **F3** to toggle the development diagnostics overlay. The overlay is forcibly hidden in release exports.

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

Refresh the checked-in 1280×720 placeholder-scene evidence using a graphical Godot session:

```sh
godot --path . --script res://tests/capture_foundation.gd
```

## Project boundaries

| Directory | Responsibility |
| --- | --- |
| `track/` | Generated track data and surface-query contracts; generator/rendering/collision follows in issue #3 |
| `vehicle/` | Vehicle tuning resource and future dynamics scene from issue #4 |
| `input/` | Hardware-independent normalized vehicle input; InputMap/device mapping follows in issue #5 |
| `session/` | Root scene, interchangeable mounts, session settings, and development diagnostics |
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
