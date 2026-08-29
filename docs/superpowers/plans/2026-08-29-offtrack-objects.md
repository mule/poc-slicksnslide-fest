# Off-track Objects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generate deterministic decorative grass/debris and solid tree/rock hazards around every circuit while preserving a 20 m collision-free recovery corridor.

**Architecture:** A versioned catalog and immutable placement records form the shared contract. A domain-separated, per-cell seeded placer produces stable placements without consuming the road generator's RNG; independent visual and collision consumers build chunked runtime nodes from fixture data before one integration task wires them into `TrackGenerator` and `TrackRuntime`.

**Tech Stack:** Godot 4.7.1 stable (`a13da4feb`), GDScript, `Resource`, `RandomNumberGenerator`, SHA-256 text hashing, `MultiMeshInstance2D`, `StaticBody2D`, GL Compatibility renderer, headless `SceneTree` test scripts.

**Spec:** `docs/superpowers/specs/2026-08-29-offtrack-objects-design.md`

## Global Constraints

- Keep the project single-viewport and controller-first; B adds no HUD panel, input action, or vehicle-specific object branch.
- Use `WorldScale.metres()` for every new scale-dependent length; the world remains 12.5 px per metre.
- Preserve `TrackDefinition.geometry_fingerprint` byte-for-byte for every existing seed.
- Object placement uses a domain-separated seed and may not consume `TrackGenerator`'s road RNG.
- Grass and debris never create physics shapes. Trees and rocks are static, circular, immovable, and indestructible.
- No solid footprint may enter the road or the 20 m recovery corridor.
- Placement is bounded by a finite 20 m grid; underfill is diagnostic and never regenerates the road.
- Every verification helper is typed `-> bool`, ends in `return true`, and is checked by its caller so a GDScript runtime error cannot exit green.
- Every mutation command named below must exit non-zero. A mutation that remains green blocks the task.
- Do not add dependencies, autoloads, local SDK paths, credentials, or generated export projects.
- Preserve untracked `.codex/` and `AGENTS.md`; do not stage them.

## Parallel Execution Boundary

Task 1 lands first and freezes all shared types. Tasks 2, 3, and 4 may then run in parallel in separate worktrees:

| Lane | Owns | Must not edit |
| --- | --- | --- |
| Task 2 placement | `offtrack_object_placer.gd`, placement tests | runtime consumers, `track_generator.gd`, `track_runtime.gd` |
| Task 3 visuals | mesh factory, visual consumer, visual tests | placer, collision consumer, shared track files |
| Task 4 collision | collision consumer, physics tests | placer, visual consumer, shared track files |

Task 5 begins only after Tasks 2-4 have passed review and combines their immutable heads. Task 6 runs after integration. Android issue #23 and Steam Deck issue #7 then run in parallel against the same Task 6 commit; Task 7 consumes both results.

## File Structure

### New production files

| File | Responsibility |
| --- | --- |
| `world/offtrack/offtrack_object_placement.gd` | Serializable data for one generated object |
| `world/offtrack/offtrack_object_archetype.gd` | Tunable definition of one object type |
| `world/offtrack/offtrack_object_catalog.gd` | Versioned placement, density, clearance, and chunk configuration |
| `world/offtrack/offtrack_object_placement_result.gd` | Typed placement output plus timing and diagnostics |
| `world/offtrack/offtrack_seed.gd` | Stable domain/cell seed derivation |
| `world/offtrack/offtrack_object_placer.gd` | Bounded deterministic placement algorithm |
| `world/offtrack/offtrack_object_mesh_factory.gd` | Procedural prototype meshes and solid-object polygons |
| `world/offtrack/offtrack_object_visuals.gd` | Decorative batches and Y-sorted solid visuals |
| `world/offtrack/offtrack_object_collisions.gd` | Chunk-local static collision bodies |
| `world/offtrack/offtrack_object_runtime.gd` | Coordinates visual and collision consumers |
| `data/default_offtrack_object_catalog.tres` | Checked-in version 1 tuning values |

### New tests and evidence

| File | Responsibility |
| --- | --- |
| `tests/offtrack_object_contract_test.gd` | Shared resource, catalog, and seed known-vector contract |
| `tests/offtrack_object_placement_test.gd` | Seeds 0-19, zones, exclusion, overlap, fingerprint, mutations |
| `tests/offtrack_object_visuals_test.gd` | Fixture-driven visual count, batching, and transform checks |
| `tests/offtrack_object_collision_test.gd` | Fixture-driven collision/non-collision and sweep checks |
| `tests/offtrack_object_runtime_test.gd` | Integrated generation/runtime/restart contract |
| `tests/offtrack_object_performance_test.gd` | Placement and construction p95 budgets |
| `tests/capture_offtrack_objects.gd` | Seed 0/4/9 graphical evidence capture |
| `docs/offtrack-objects.md` | Player-visible behavior, constants, diagnostics, and limitations |
| `docs/evidence/offtrack-objects/` | Captures and desktop measurement record |

### Existing files modified only at integration/documentation gates

| File | Change |
| --- | --- |
| `track/track_definition.gd` | Task 1 adds object placements, fingerprint, timing, and diagnostics |
| `track/track_generator.gd` | Task 5 invokes placement only after road acceptance/fallback |
| `track/track_runtime.gd` | Task 5 mounts `OfftrackObjectRuntime` |
| `session/main.gd` | Task 5 exposes object fingerprint in session snapshots |
| `tests/headless_smoke.gd` | Task 1 loads the default catalog and placement resource contract |
| `README.md` | Tasks 1, 5, and 6 list tests and document the feature |
| `docs/poc-report.md` | Task 7 records the final cross-platform result |

---

### Task 1: Shared Placement Contract and Versioned Catalog

**Files:**
- Create: `world/offtrack/offtrack_object_placement.gd`
- Create: `world/offtrack/offtrack_object_archetype.gd`
- Create: `world/offtrack/offtrack_object_catalog.gd`
- Create: `world/offtrack/offtrack_object_placement_result.gd`
- Create: `world/offtrack/offtrack_seed.gd`
- Create: `data/default_offtrack_object_catalog.tres`
- Create: `tests/offtrack_object_contract_test.gd`
- Modify: `track/track_definition.gd`
- Modify: `tests/headless_smoke.gd`
- Modify: `README.md`

**Interfaces:**
- Consumes: `WorldScale.metres(value: float) -> float` and existing `TrackDefinition` resource conventions.
- Produces: `OfftrackObjectPlacement`, `OfftrackObjectArchetype`, `OfftrackObjectCatalog`, `OfftrackObjectPlacementResult`, `OfftrackSeed.domain_seed(track_seed: int, version: int) -> int`, and `OfftrackSeed.cell_seed(domain_seed: int, cell: Vector2i) -> int`.

- [ ] **Step 1: Write the failing contract test**

Create `tests/offtrack_object_contract_test.gd` with the repository's `_initialize()`, `_check()`, and `_finish()` pattern. The central verification must be concrete:

```gdscript
func _verify_contracts() -> bool:
	var placement := OfftrackObjectPlacement.new()
	placement.stable_id = "v1:0:3:-2"
	placement.archetype_id = &"tree"
	placement.transform = Transform2D(0.25, Vector2(500.0, 750.0))
	placement.scale_factor = 1.1
	placement.visual_variant = 1
	placement.solid = true
	placement.collision_profile = &"tree_circle"
	_check(placement.stable_id == "v1:0:3:-2", "placement stores a stable ID")
	_check(placement.solid and placement.collision_profile == &"tree_circle", "placement stores its physics classification")

	var catalog := load("res://data/default_offtrack_object_catalog.tres") as OfftrackObjectCatalog
	_check(catalog != null, "default off-track object catalog loads")
	if catalog == null:
		return false
	_check(catalog.version == 1, "catalog pins placement algorithm version 1")
	_check(is_equal_approx(catalog.cell_size, WorldScale.metres(20.0)), "catalog uses a 20 m placement grid")
	_check(is_equal_approx(catalog.solid_clearance, WorldScale.metres(20.0)), "catalog preserves a 20 m solid recovery corridor")
	_check(catalog.archetype_by_id(&"grass") != null, "catalog contains grass")
	_check(catalog.archetype_by_id(&"debris") != null, "catalog contains debris")
	_check(catalog.archetype_by_id(&"tree").solid, "catalog marks trees solid")
	_check(catalog.archetype_by_id(&"rock").solid, "catalog marks rocks solid")
	return true


func _verify_seed_vectors() -> bool:
	_check(OfftrackSeed.domain_seed(0, 1) == 845162064041503952, "seed 0 domain vector is stable")
	_check(OfftrackSeed.domain_seed(42, 1) == 365479572614719053, "seed 42 domain vector is stable")
	_check(OfftrackSeed.cell_seed(845162064041503952, Vector2i(3, -2)) == 173704369122287513, "cell vector is stable")
	return true
```

Call both helpers through `_check(...)`. Ensure `_finish()` prints `offtrack_contract checks=%d` and exits 1 when `_failures` is non-empty.

- [ ] **Step 2: Run the contract test to verify it fails**

Run:

```bash
godot --headless --path . --script res://tests/offtrack_object_contract_test.gd
```

Expected: non-zero exit with missing `OfftrackObjectPlacement`, `OfftrackObjectCatalog`, and `OfftrackSeed` symbols or resources.

- [ ] **Step 3: Add the immutable placement and result resources**

Create `world/offtrack/offtrack_object_placement.gd`:

```gdscript
class_name OfftrackObjectPlacement
extends Resource

@export var stable_id: String = ""
@export var archetype_id: StringName = &""
@export var transform: Transform2D = Transform2D.IDENTITY
@export_range(0.01, 10.0, 0.01) var scale_factor: float = 1.0
@export_range(0, 31, 1) var visual_variant: int = 0
@export var solid: bool = false
@export var collision_profile: StringName = &"none"
```

Create `world/offtrack/offtrack_object_placement_result.gd`:

```gdscript
class_name OfftrackObjectPlacementResult
extends Resource

@export var placements: Array[OfftrackObjectPlacement] = []
@export var fingerprint: String = ""
@export var generation_usec: int = 0
@export var diagnostics: Dictionary = {}
```

- [ ] **Step 4: Add archetype and catalog resources**

Create `world/offtrack/offtrack_object_archetype.gd`:

```gdscript
class_name OfftrackObjectArchetype
extends Resource

@export var id: StringName = &""
@export var solid: bool = false
@export_range(0.0, 500.0, 0.1) var footprint_radius: float = 5.0
@export_range(0.0, 500.0, 0.1) var collision_radius: float = 0.0
@export_range(0.01, 10.0, 0.01) var min_scale: float = 1.0
@export_range(0.01, 10.0, 0.01) var max_scale: float = 1.0
@export_range(1, 32, 1) var visual_variant_count: int = 1
@export_range(0.0, 1.0, 0.01) var near_weight: float = 0.0
@export_range(0.0, 1.0, 0.01) var hazard_weight: float = 0.0
@export var collision_profile: StringName = &"none"
```

Create `world/offtrack/offtrack_object_catalog.gd`:

```gdscript
class_name OfftrackObjectCatalog
extends Resource

@export var version: int = 1
@export var cell_size: float = 250.0
@export var chunk_size: float = 1000.0
@export var near_max_distance: float = 150.0
@export var solid_clearance: float = 250.0
@export var hazard_max_distance: float = 1750.0
@export var containment_buffer: float = 250.0
@export var spawn_checkpoint_exclusion: float = 500.0
@export_range(0.0, 1.0, 0.01) var near_occupancy: float = 0.55
@export_range(0.0, 1.0, 0.01) var hazard_occupancy: float = 0.35
@export_range(0.0, 1.0, 0.01) var minimum_fill_ratio: float = 0.75
@export var archetypes: Array[OfftrackObjectArchetype] = []


func archetype_by_id(id: StringName) -> OfftrackObjectArchetype:
	for archetype in archetypes:
		if archetype != null and archetype.id == id:
			return archetype
	return null


func archetypes_for_zone(near_shoulder: bool) -> Array[OfftrackObjectArchetype]:
	var matching: Array[OfftrackObjectArchetype] = []
	for archetype in archetypes:
		if archetype == null:
			continue
		var weight := archetype.near_weight if near_shoulder else archetype.hazard_weight
		if weight > 0.0:
			matching.append(archetype)
	return matching
```

- [ ] **Step 5: Add stable SHA-256 seed derivation**

Create `world/offtrack/offtrack_seed.gd`:

```gdscript
class_name OfftrackSeed
extends RefCounted

const DOMAIN := "offtrack_objects"


static func domain_seed(track_seed: int, version: int) -> int:
	return _seed_from_text("%d|%d|%s" % [version, track_seed, DOMAIN])


static func cell_seed(initial_domain_seed: int, cell: Vector2i) -> int:
	return _seed_from_text("%d|%d|%d" % [initial_domain_seed, cell.x, cell.y])


static func _seed_from_text(material: String) -> int:
	# Fifteen hexadecimal digits fit in a positive signed 64-bit integer.
	return material.sha256_text().substr(0, 15).hex_to_int()
```

- [ ] **Step 6: Create the checked-in version 1 catalog**

Create `data/default_offtrack_object_catalog.tres` with this auditable version 1 resource:

```ini
[gd_resource type="Resource" script_class="OfftrackObjectCatalog" load_steps=6 format=3]

[ext_resource type="Script" path="res://world/offtrack/offtrack_object_catalog.gd" id="1_catalog"]
[ext_resource type="Script" path="res://world/offtrack/offtrack_object_archetype.gd" id="2_archetype"]

[sub_resource type="Resource" id="Archetype_grass"]
script = ExtResource("2_archetype")
id = &"grass"
footprint_radius = 5.0
min_scale = 0.7
max_scale = 1.3
visual_variant_count = 3
near_weight = 0.75
hazard_weight = 0.4

[sub_resource type="Resource" id="Archetype_debris"]
script = ExtResource("2_archetype")
id = &"debris"
footprint_radius = 7.5
min_scale = 0.8
max_scale = 1.2
visual_variant_count = 3
near_weight = 0.25
hazard_weight = 0.15

[sub_resource type="Resource" id="Archetype_tree"]
script = ExtResource("2_archetype")
id = &"tree"
solid = true
footprint_radius = 25.0
collision_radius = 15.0
min_scale = 0.8
max_scale = 1.25
visual_variant_count = 2
hazard_weight = 0.3
collision_profile = &"tree_circle"

[sub_resource type="Resource" id="Archetype_rock"]
script = ExtResource("2_archetype")
id = &"rock"
solid = true
footprint_radius = 18.75
collision_radius = 15.0
min_scale = 0.7
max_scale = 1.4
visual_variant_count = 3
hazard_weight = 0.15
collision_profile = &"rock_circle"

[resource]
script = ExtResource("1_catalog")
version = 1
cell_size = 250.0
chunk_size = 1000.0
near_max_distance = 150.0
solid_clearance = 250.0
hazard_max_distance = 1750.0
containment_buffer = 250.0
spawn_checkpoint_exclusion = 500.0
near_occupancy = 0.55
hazard_occupancy = 0.35
minimum_fill_ratio = 0.75
archetypes = Array[ExtResource("2_archetype")]([SubResource("Archetype_grass"), SubResource("Archetype_debris"), SubResource("Archetype_tree"), SubResource("Archetype_rock")])
```

- [ ] **Step 7: Extend `TrackDefinition` without changing its road fingerprint fields**

Append these exports to `track/track_definition.gd` after `diagnostic_reason`:

```gdscript
@export var offtrack_objects: Array[OfftrackObjectPlacement] = []
@export var offtrack_object_fingerprint: String = ""
@export var offtrack_object_generation_usec: int = 0
@export var offtrack_object_diagnostics: Dictionary = {}
```

Do not edit `_fingerprint()` in `track/track_generator.gd` in this task.

- [ ] **Step 8: Extend foundation resource coverage and README test commands**

In `_verify_default_resources()` in `tests/headless_smoke.gd`, load the catalog and assert version 1 plus all four archetypes. In `README.md`, add the contract-test command directly after the world-scale checks:

```bash
godot --headless --path . --script res://tests/offtrack_object_contract_test.gd
```

- [ ] **Step 9: Import and run the focused tests**

Run:

```bash
godot --editor --headless --path . --quit
godot --headless --path . --script res://tests/offtrack_object_contract_test.gd
godot --headless --path . --script res://tests/headless_smoke.gd
godot --headless --path . --script res://tests/harness_contract_test.gd
```

Expected: import exits 0; contract and smoke tests exit 0; harness test exits 0 while printing its one intentional `SCRIPT ERROR`.

- [ ] **Step 10: Commit the frozen shared contract**

```bash
git add world/offtrack/offtrack_object_placement.gd world/offtrack/offtrack_object_archetype.gd world/offtrack/offtrack_object_catalog.gd world/offtrack/offtrack_object_placement_result.gd world/offtrack/offtrack_seed.gd data/default_offtrack_object_catalog.tres track/track_definition.gd tests/offtrack_object_contract_test.gd tests/headless_smoke.gd README.md
git commit -m "feat: define deterministic off-track object contract"
```

---

### Task 2: Deterministic Placement Engine

**Files:**
- Create: `world/offtrack/offtrack_object_placer.gd`
- Create: `tests/offtrack_object_placement_test.gd`
- Modify: `README.md`

**Interfaces:**
- Consumes: `OfftrackObjectCatalog`, `OfftrackObjectPlacement`, `OfftrackObjectPlacementResult`, `OfftrackSeed`, `TrackDefinition`, and `TrackSurfaceMap.distance_to_centerline(world_position: Vector2, search_radius: float) -> float`.
- Produces: `OfftrackObjectPlacer.place(definition: TrackDefinition, catalog: OfftrackObjectCatalog) -> OfftrackObjectPlacementResult`.

- [ ] **Step 1: Write the failing seed-sweep and mutation test**

Create `tests/offtrack_object_placement_test.gd`. Parse `--break-seed` and `--break-clearance` in `_initialize()`. The main sweep must retain the road fingerprints before placement and verify every generated result:

```gdscript
const ROAD_FINGERPRINTS := {
	0: "c473c35414d6ee31c9abada0c4d5fe4856997f137ca8d7dd6223a45da29bf55f",
	1: "b4b5a88a8be258e58c43567bb2e1ffc9364f21c98bae38ee92e0a087de9fa90e",
	2: "d1e5d0df9651e041374342582d1cccf79193fe8ecb95796baac1eb19217bd7ea",
	3: "a1e4ab9b4425050a266ac40d2bb958b99d303303192c241c02b0822912ed078d",
	4: "4600dc93fe343e17e999276b333051a9538f51c50d02992863af9b4970779155",
	5: "8d530ec157495015293c77e77d2b3f9dfb458db272c3176b1f11bc9e495716b5",
	6: "7fad0c2e88fccb083da767eba455a3b50ed248e8fea025fb43500d14e3ab04d9",
	7: "ed6a92a5ee67e6e67f147fe6382bb266afe356d1de03cdc2322fdeb1d28c2af8",
	8: "d0ff3f39294c44e16a182eabc0283b23842801ce6617c1f79a66001d93929aef",
	9: "3fbe38ff1f6a222c0050cc004bddf93225b5da99176639d4b22f5934ece85670",
	10: "56c585fc00729f4416cd459c57e7b6821b101a83374f9bb2e7443f6633546c42",
	11: "f0237efe220f89c01733e293d377a299f1c39b88843c992b5006bc0512ba51b0",
	12: "5331af0ca10b06d73cb47223caf72bebfa0c87c53df04951a395c24e2646976f",
	13: "a3b44cf2ccee2206c308f0bdc1af8324e32767e59152061a174b887ad3db97a2",
	14: "72af4a69dc7a4a8c5924348879c45258c9fd047fdcf325774a44ba025b781633",
	15: "3c2386bfa626521b3ba4996c2191cefb6902728d9c1ec80c9bd18b8a7c30fa34",
	16: "97458ea8106f57c08f45cc2f6d35611be28bd03e40dcc57431022e129a2d1bb9",
	17: "497f951e560567f3ed51b523ded8761dbad88e94fa347124e56ece7911b60cf4",
	18: "4018845b4baf9e1d3da8b49fc42d02b832771c952fb0616de956b13a150a4597",
	19: "1ccbbd249025dfc5f5d8a05f60fa43933f023bd34cfa38d66d42d66bc066bbda",
}


func _verify_seed(seed: int, catalog: OfftrackObjectCatalog) -> bool:
	var definition := TrackGenerator.new().generate(seed)
	var road_fingerprint := definition.geometry_fingerprint
	var placer := OfftrackObjectPlacer.new()
	var first := placer.place(definition, catalog)
	var second_catalog := catalog.duplicate(true) as OfftrackObjectCatalog
	if _break_seed:
		second_catalog.version += 1
	if _break_clearance:
		second_catalog.solid_clearance = 0.0
	var second := placer.place(definition, second_catalog)

	_check(first.fingerprint.length() == 64, "seed %d produces a SHA-256 object fingerprint" % seed)
	_check(first.fingerprint == second.fingerprint, "seed %d placement fingerprint repeats" % seed)
	_check(_placements_equal(first.placements, second.placements), "seed %d placements repeat exactly" % seed)
	_check(is_equal_approx(second_catalog.solid_clearance, WorldScale.metres(20.0)), "seed %d run retains the approved 20 m solid clearance" % seed)
	_check(definition.geometry_fingerprint == road_fingerprint, "seed %d road fingerprint is unchanged" % seed)
	_check(definition.geometry_fingerprint == ROAD_FINGERPRINTS[seed], "seed %d road fingerprint matches the pre-B baseline" % seed)
	_check(_verify_zones(definition, first.placements, catalog, seed), "seed %d zone verification completed" % seed)
	_check(_verify_solid_overlap(first.placements, catalog, seed), "seed %d overlap verification completed" % seed)
	_check(_verify_diagnostics(first, catalog, seed), "seed %d diagnostics verification completed" % seed)
	return true
```

Implement `_verify_zones()` to compute `edge_distance = TrackSurfaceMap.new(definition).distance_to_centerline(position, catalog.hazard_max_distance + definition.track_width) - definition.track_width * 0.5`, then assert footprint-aware road/recovery, hazard, spawn/checkpoint, and containment exclusions. Implement `_verify_solid_overlap()` as an exact pairwise oracle over solid placements. Run seeds `0..19`, then generate an impossible road with `{"max_attempts": 1, "min_lap_length": 100000.0}` and verify its fallback receives valid placements too.

- [ ] **Step 2: Run the placement test to verify it fails**

```bash
godot --headless --path . --script res://tests/offtrack_object_placement_test.gd
```

Expected: non-zero exit because `OfftrackObjectPlacer` does not exist.

- [ ] **Step 3: Implement the bounded per-cell placement loop**

Create `world/offtrack/offtrack_object_placer.gd` with this public entry point and bounded traversal:

```gdscript
class_name OfftrackObjectPlacer
extends RefCounted


func place(definition: TrackDefinition, catalog: OfftrackObjectCatalog) -> OfftrackObjectPlacementResult:
	var started_usec := Time.get_ticks_usec()
	var result := OfftrackObjectPlacementResult.new()
	if definition == null or catalog == null or definition.centerline.size() < 2:
		result.fingerprint = _fingerprint(catalog.version if catalog != null else 0, result.placements)
		result.generation_usec = Time.get_ticks_usec() - started_usec
		result.diagnostics = {"invalid_input": 1}
		return result

	var diagnostics := _new_diagnostics()
	var surface := TrackSurfaceMap.new(definition)
	var domain_seed := OfftrackSeed.domain_seed(definition.seed, catalog.version)
	var cell_min := Vector2i(
		floori(definition.play_area.position.x / catalog.cell_size),
		floori(definition.play_area.position.y / catalog.cell_size)
	)
	var cell_max := Vector2i(
		ceili(definition.play_area.end.x / catalog.cell_size) - 1,
		ceili(definition.play_area.end.y / catalog.cell_size) - 1
	)
	var solid_placements: Array[OfftrackObjectPlacement] = []
	for cell_x in range(cell_min.x, cell_max.x + 1):
		for cell_y in range(cell_min.y, cell_max.y + 1):
			_consider_cell(Vector2i(cell_x, cell_y), domain_seed, definition, catalog, surface, result.placements, solid_placements, diagnostics)

	result.placements.sort_custom(func(a, b): return a.stable_id < b.stable_id)
	result.fingerprint = _fingerprint(catalog.version, result.placements)
	result.generation_usec = Time.get_ticks_usec() - started_usec
	result.diagnostics = _finalize_diagnostics(diagnostics, catalog.minimum_fill_ratio)
	return result
```

`_consider_cell()` must seed a fresh `RandomNumberGenerator` with `OfftrackSeed.cell_seed()`, jitter once inside the cell, query centerline distance with `catalog.hazard_max_distance + definition.track_width`, classify near/hazard zone, apply occupancy, choose a weighted archetype, scale/rotate it, then apply all exclusions. It appends at most one placement per cell.

- [ ] **Step 4: Implement weighted selection and footprint-aware exclusions**

Use cumulative catalog weights without normalizing them in data:

```gdscript
func _choose_archetype(rng: RandomNumberGenerator, choices: Array[OfftrackObjectArchetype], near_shoulder: bool) -> OfftrackObjectArchetype:
	var total := 0.0
	for choice in choices:
		total += choice.near_weight if near_shoulder else choice.hazard_weight
	if total <= 0.0:
		return null
	var target := rng.randf() * total
	for choice in choices:
		target -= choice.near_weight if near_shoulder else choice.hazard_weight
		if target <= 0.0:
			return choice
	return choices[-1]
```

For a proposed placement, reject when any of these exact predicates is true:

```gdscript
var footprint := archetype.footprint_radius * scale_factor
var edge_distance := centerline_distance - definition.track_width * 0.5
var contracted_play_area := definition.play_area.grow(-(catalog.containment_buffer + footprint))
var inside_recovery := archetype.solid and edge_distance - footprint < catalog.solid_clearance
var outside_zone := edge_distance + footprint > catalog.hazard_max_distance
var outside_play_area := not contracted_play_area.has_point(position)
var blocks_spawn := archetype.solid and position.distance_to(definition.spawn_transform.origin) < catalog.spawn_checkpoint_exclusion + footprint
```

Apply the same exclusion to every checkpoint origin. Reject solid overlap when center distance is less than the sum of both scaled catalog collision radii. Store `stable_id = "v%d:%d:%d:%d" % [catalog.version, definition.seed, cell.x, cell.y]`, `transform = Transform2D(rotation, position)`, and the selected archetype's solid/profile values.

- [ ] **Step 5: Implement diagnostics and the independent fingerprint**

Track per-zone dictionaries containing `valid_cells`, `occupied_draws`, `accepted`, and rejection counts keyed by `road_or_recovery`, `containment`, `spawn_checkpoint`, and `solid_overlap`. `_finalize_diagnostics()` adds `underfilled = occupied_draws > 0 and float(accepted) / occupied_draws < minimum_fill_ratio` for each zone.

Fingerprint exact fixed-precision fields independently of road geometry:

```gdscript
func _fingerprint(version: int, placements: Array[OfftrackObjectPlacement]) -> String:
	var components := PackedStringArray(["version=%d" % version])
	for placement in placements:
		components.append("%s|%s|%.3f,%.3f|%.6f|%.3f|%d|%s|%s" % [
			placement.stable_id,
			placement.archetype_id,
			placement.transform.origin.x,
			placement.transform.origin.y,
			placement.transform.get_rotation(),
			placement.scale_factor,
			placement.visual_variant,
			str(placement.solid),
			placement.collision_profile,
		])
	return "|".join(components).sha256_text()
```

- [ ] **Step 6: Run normal and mutation tests**

```bash
godot --headless --path . --script res://tests/offtrack_object_placement_test.gd
godot --headless --path . --script res://tests/offtrack_object_placement_test.gd -- --break-seed
godot --headless --path . --script res://tests/offtrack_object_placement_test.gd -- --break-clearance
```

Expected: normal command exits 0; both mutation commands exit 1 and name the repeatability or recovery-corridor assertion they violate.

- [ ] **Step 7: Document the focused test and commit**

Add the normal placement-test command to README verification. Then commit only Task 2 files:

```bash
git add world/offtrack/offtrack_object_placer.gd tests/offtrack_object_placement_test.gd README.md
git commit -m "feat: generate deterministic off-track object placements"
```

---

### Task 3: Prototype Visuals and Chunked Rendering

**Files:**
- Create: `world/offtrack/offtrack_object_mesh_factory.gd`
- Create: `world/offtrack/offtrack_object_visuals.gd`
- Create: `tests/offtrack_object_visuals_test.gd`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1 placement/catalog resources. Tests construct fixture `OfftrackObjectPlacement` values directly and do not call Task 2.
- Produces: `OfftrackObjectVisuals.build(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> void`, `visual_count() -> int`, `decorative_batch_count() -> int`, and `solid_visual_count() -> int`.

- [ ] **Step 1: Write a failing fixture-driven visual test**

Create `tests/offtrack_object_visuals_test.gd` with four placements: grass at `(100, 100)`, debris at `(140, 100)`, tree at `(1200, 100)`, and rock at `(1300, 100)`. Give them distinct stable IDs, rotations, scales, and variants. The verification must assert:

```gdscript
func _verify_visuals(catalog: OfftrackObjectCatalog) -> bool:
	var placements := _fixture_placements()
	var visuals := OfftrackObjectVisuals.new()
	root.add_child(visuals)
	visuals.build(placements, catalog)
	_check(visuals.visual_count() == 4, "every fixture placement has a visual")
	_check(visuals.solid_visual_count() == 2, "tree and rock use solid visual nodes")
	_check(visuals.decorative_batch_count() == 2, "grass and debris create separate archetype batches")
	_check(visuals.get_node_or_null("SolidObjects/v1_0_4_0") != null, "tree stable ID names its visual node")
	_check(visuals.get_node_or_null("SolidObjects/v1_0_5_0") != null, "rock stable ID names its visual node")
	_check(_verify_solid_transform(visuals, placements[2]), "tree transform verification completed")
	visuals.queue_free()
	return true
```

Sanitize node names with `stable_id.replace(":", "_")`. `_verify_solid_transform()` must compare node position, rotation, and scale to the placement. Every helper follows the completion contract.

- [ ] **Step 2: Run the visual test to verify it fails**

```bash
godot --headless --path . --script res://tests/offtrack_object_visuals_test.gd
```

Expected: non-zero exit because `OfftrackObjectVisuals` does not exist.

- [ ] **Step 3: Implement the procedural mesh factory**

Create `world/offtrack/offtrack_object_mesh_factory.gd`. Decorative meshes are local-space triangles centered near the origin; solid visuals are `Node2D` roots containing prototype `Polygon2D` children.

```gdscript
class_name OfftrackObjectMeshFactory
extends RefCounted


static func decorative_mesh(archetype_id: StringName, variant: int) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	match archetype_id:
		&"grass":
			vertices = PackedVector3Array([
				Vector3(-4, 5, 0), Vector3(0, -9 - variant, 0), Vector3(1, 5, 0),
				Vector3(-1, 5, 0), Vector3(5, -6 - variant, 0), Vector3(4, 6, 0),
			])
			colors.resize(vertices.size())
			colors.fill(Color("6f8f3d"))
		&"debris":
			vertices = PackedVector3Array([
				Vector3(-6, -3, 0), Vector3(5 + variant, -2, 0), Vector3(3, 4, 0),
				Vector3(-6, -3, 0), Vector3(3, 4, 0), Vector3(-4, 5, 0),
			])
			colors.resize(vertices.size())
			colors.fill(Color("765235"))
		_:
			return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func solid_visual(archetype_id: StringName, variant: int) -> Node2D:
	var root_node := Node2D.new()
	var shadow := Polygon2D.new()
	shadow.position = Vector2(4, 6)
	shadow.color = Color(0.02, 0.03, 0.02, 0.35)
	var body := Polygon2D.new()
	if archetype_id == &"tree":
		shadow.polygon = PackedVector2Array([Vector2(-20, 0), Vector2(0, -22), Vector2(20, 0), Vector2(0, 22)])
		body.polygon = PackedVector2Array([Vector2(-18, 4), Vector2(-10, -15), Vector2(0, -25 - variant * 3), Vector2(12, -13), Vector2(20, 5), Vector2(0, 22)])
		body.color = Color("315b2f") if variant == 0 else Color("3e6b35")
	elif archetype_id == &"rock":
		shadow.polygon = PackedVector2Array([Vector2(-18, 8), Vector2(-12, -10), Vector2(8, -16), Vector2(19, 3), Vector2(8, 15)])
		body.polygon = shadow.polygon
		body.color = [Color("777269"), Color("696963"), Color("857b6e")][variant % 3]
	else:
		return null
	root_node.add_child(shadow)
	root_node.add_child(body)
	return root_node
```

- [ ] **Step 4: Implement decorative batches and solid Y-sorted visuals**

Create `world/offtrack/offtrack_object_visuals.gd`:

```gdscript
class_name OfftrackObjectVisuals
extends Node2D

var _visual_count := 0
var _decorative_batch_count := 0
var _solid_visual_count := 0


func build(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> void:
	_clear_children()
	var decorative := Node2D.new()
	decorative.name = "DecorativeBatches"
	add_child(decorative)
	var solids := Node2D.new()
	solids.name = "SolidObjects"
	solids.y_sort_enabled = true
	add_child(solids)
	_build_decorative(placements, catalog, decorative)
	_build_solids(placements, catalog, solids)
```

Group decorative placements by `Vector2i(floori(position.x / chunk_size), floori(position.y / chunk_size))`, archetype ID, and variant. For each group, call this builder:

```gdscript
func _add_batch(parent: Node2D, key: String, group: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> void:
	var first := group[0]
	var mesh := OfftrackObjectMeshFactory.decorative_mesh(first.archetype_id, first.visual_variant)
	if mesh == null:
		push_error("Unknown decorative archetype %s" % first.archetype_id)
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.mesh = mesh
	multimesh.instance_count = group.size()
	for index in range(group.size()):
		var placement := group[index]
		var instance_transform := placement.transform.scaled_local(Vector2.ONE * placement.scale_factor)
		multimesh.set_instance_transform_2d(index, instance_transform)
	var chunk := Vector2i(floori(first.transform.origin.x / catalog.chunk_size), floori(first.transform.origin.y / catalog.chunk_size))
	multimesh.custom_aabb = AABB(
		Vector3(chunk.x * catalog.chunk_size, chunk.y * catalog.chunk_size, -1.0),
		Vector3(catalog.chunk_size, catalog.chunk_size, 2.0)
	)
	var instance := MultiMeshInstance2D.new()
	instance.name = key
	instance.multimesh = multimesh
	instance.z_index = -1
	parent.add_child(instance)
	_decorative_batch_count += 1
	_visual_count += group.size()
```

For solid placements, instantiate the factory node, sanitize the stable ID into its name, and copy `position`, `rotation`, and uniform `scale`. Skip an unknown archetype with `push_error()` and do not increment counts. Add these exact lifecycle/getter methods; immediate `free()` makes seed replacement observable in the same call:

```gdscript
func visual_count() -> int:
	return _visual_count


func decorative_batch_count() -> int:
	return _decorative_batch_count


func solid_visual_count() -> int:
	return _solid_visual_count


func _clear_children() -> void:
	for child in get_children():
		child.free()
	_visual_count = 0
	_decorative_batch_count = 0
	_solid_visual_count = 0
```

- [ ] **Step 5: Run the visual test twice after a clean import**

```bash
godot --editor --headless --path . --quit
godot --headless --path . --script res://tests/offtrack_object_visuals_test.gd
godot --headless --path . --script res://tests/offtrack_object_visuals_test.gd
```

Expected: both runs exit 0 with four visuals, two decorative batches, and two solid visuals.

- [ ] **Step 6: Document the test and commit the visual lane**

Add the visual-test command to README, then:

```bash
git add world/offtrack/offtrack_object_mesh_factory.gd world/offtrack/offtrack_object_visuals.gd tests/offtrack_object_visuals_test.gd README.md
git commit -m "feat: render chunked off-track object visuals"
```

---

### Task 4: Static Collision Runtime and Physics Coverage

**Files:**
- Create: `world/offtrack/offtrack_object_collisions.gd`
- Create: `tests/offtrack_object_collision_test.gd`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1 placement/catalog resources. Tests use fixture placements and do not call Task 2 or Task 3.
- Produces: `OfftrackObjectCollisions.build(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> void`, `collider_count() -> int`, and `chunk_body_count() -> int`.

- [ ] **Step 1: Write the failing collision and mutation test**

Create `tests/offtrack_object_collision_test.gd`. Use fixtures at grass `(50, 0)`, debris `(75, 0)`, tree `(200, 0)`, and rock `(400, 0)`. Parse `--remove-solid-collider` and `--solid-decoration`.

```gdscript
func _verify_contract(catalog: OfftrackObjectCatalog) -> bool:
	var placements := _fixture_placements()
	if _solid_decoration:
		placements[0].solid = true
		placements[0].collision_profile = &"tree_circle"
	var collisions := OfftrackObjectCollisions.new()
	root.add_child(collisions)
	collisions.build(placements, catalog)
	if _remove_solid_collider:
		_remove_first_shape(collisions)
	_check(_verify_catalog_alignment(placements, catalog), "placement/catalog physics alignment completed")
	_check(collisions.collider_count() == 2, "only tree and rock produce colliders")
	_check(collisions.chunk_body_count() == 1, "nearby solid fixtures share one chunk body")
	_check(await _verify_sweep(collisions, Vector2.ZERO, Vector2(300, 0), "tree"), "tree sweep verification completed")
	_check(await _verify_sweep(collisions, Vector2(260, 0), Vector2(240, 0), "rock"), "rock sweep verification completed")
	_check(await _verify_car_impact(collisions), "real car impact verification completed")
	collisions.queue_free()
	return true
```

`_verify_sweep()` creates a `CharacterBody2D` on layer 2/mask 1 with a 4 px `CircleShape2D`, calls `move_and_collide(motion)`, and asserts a non-null collision plus a final position before the target center. This is an exact swept collision rather than an endpoint-overlap test. `_verify_car_impact()` instantiates `vehicle/top_down_car.tscn`, starts at `(0, 0)` with `linear_velocity = Vector2.RIGHT * car.tuning.max_safe_speed`, awaits up to 120 physics frames, and asserts `get_collision_count() >= 1`, final speed at most `max_safe_speed * 1.05`, and position short of the tree center. This uses the real CCD-enabled `RigidBody2D` and proves bounded post-impact energy.

`_verify_catalog_alignment(placements, catalog) -> bool` checks every placement's `solid` and `collision_profile` exactly match its catalog archetype, calls `_check()` for both fields, and returns true. This makes `--solid-decoration` fail even though production correctly refuses to instantiate the invalid grass collider.

- [ ] **Step 2: Run the collision test to verify it fails**

```bash
godot --headless --path . --script res://tests/offtrack_object_collision_test.gd
```

Expected: non-zero exit because `OfftrackObjectCollisions` does not exist.

- [ ] **Step 3: Implement chunk-local static bodies**

Create `world/offtrack/offtrack_object_collisions.gd`:

```gdscript
class_name OfftrackObjectCollisions
extends Node2D

var _collider_count := 0
var _chunk_body_count := 0


func build(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> void:
	_clear_children()
	var bodies: Dictionary = {}
	for placement in placements:
		if not placement.solid:
			continue
		var archetype := catalog.archetype_by_id(placement.archetype_id)
		if archetype == null or not archetype.solid or archetype.collision_radius <= 0.0:
			push_error("Invalid solid off-track placement %s" % placement.stable_id)
			continue
		var chunk := Vector2i(
			floori(placement.transform.origin.x / catalog.chunk_size),
			floori(placement.transform.origin.y / catalog.chunk_size)
		)
		var body: StaticBody2D = bodies.get(chunk)
		if body == null:
			body = StaticBody2D.new()
			body.name = "Chunk_%d_%d" % [chunk.x, chunk.y]
			body.collision_layer = 1
			body.collision_mask = 0
			add_child(body)
			bodies[chunk] = body
			_chunk_body_count += 1
		var shape := CollisionShape2D.new()
		shape.name = placement.stable_id.replace(":", "_")
		shape.position = placement.transform.origin
		var circle := CircleShape2D.new()
		circle.radius = archetype.collision_radius * placement.scale_factor
		shape.shape = circle
		body.add_child(shape)
		_collider_count += 1
```

Add exact getters and lifecycle reset:

```gdscript
func collider_count() -> int:
	return _collider_count


func chunk_body_count() -> int:
	return _chunk_body_count


func _clear_children() -> void:
	for child in get_children():
		child.free()
	_collider_count = 0
	_chunk_body_count = 0
```

- [ ] **Step 4: Run normal and mutation tests**

```bash
godot --headless --path . --script res://tests/offtrack_object_collision_test.gd
godot --headless --path . --script res://tests/offtrack_object_collision_test.gd -- --remove-solid-collider
godot --headless --path . --script res://tests/offtrack_object_collision_test.gd -- --solid-decoration
```

Expected: normal exits 0; collider-removal exits 1 on count/sweep; solid-decoration exits 1 because the decorative placement violates the expected collider count.

- [ ] **Step 5: Run existing vehicle collision regression**

```bash
godot --headless --path . --script res://tests/issue_4_vehicle_maneuvers.gd -- --collision-only
godot --headless --path . --script res://tests/track_collision_physics_test.gd
```

Expected: both exit 0; the new collision component has not changed the car or containment paths.

- [ ] **Step 6: Document the test and commit the collision lane**

Add the normal collision-test command to README, then:

```bash
git add world/offtrack/offtrack_object_collisions.gd tests/offtrack_object_collision_test.gd README.md
git commit -m "feat: add solid off-track object collisions"
```

---

### Task 5: Generator, Runtime, and Seed-Restart Integration

**Files:**
- Create: `world/offtrack/offtrack_object_runtime.gd`
- Create: `tests/offtrack_object_runtime_test.gd`
- Modify: `track/track_generator.gd`
- Modify: `track/track_runtime.gd`
- Modify: `session/main.gd`
- Modify: `README.md`

**Interfaces:**
- Consumes: `OfftrackObjectPlacer.place()`, `OfftrackObjectVisuals.build()`, and `OfftrackObjectCollisions.build()` from Tasks 2-4.
- Produces: generated `TrackDefinition.offtrack_objects`, mounted `TrackRuntime/OfftrackObjects`, `OfftrackObjectRuntime.get_metrics() -> Dictionary`, and session snapshot field `offtrack_object_fingerprint`.

- [ ] **Step 1: Write the failing integrated runtime/restart test**

Create `tests/offtrack_object_runtime_test.gd`. Verify one generated definition and then the real session restart path:

```gdscript
func _verify_generated_runtime() -> bool:
	var definition := TrackGenerator.new().generate(0)
	_check(not definition.offtrack_objects.is_empty(), "seed 0 carries generated off-track objects")
	_check(definition.offtrack_object_fingerprint.length() == 64, "seed 0 carries an object fingerprint")
	var runtime := TrackRuntime.new(definition)
	root.add_child(runtime)
	var objects := runtime.get_node_or_null("OfftrackObjects") as OfftrackObjectRuntime
	_check(objects != null, "track runtime mounts off-track objects")
	if objects == null:
		return false
	var metrics := objects.get_metrics()
	_check(int(metrics.get("visuals", -1)) == definition.offtrack_objects.size(), "every placement is visualized")
	_check(int(metrics.get("colliders", -1)) == _solid_count(definition.offtrack_objects), "every solid placement has one collider")
	var catalog := load("res://data/default_offtrack_object_catalog.tres") as OfftrackObjectCatalog
	_check(_verify_solid_transforms(objects, definition.offtrack_objects, catalog), "solid visual/collider transform verification completed")
	runtime.free()
	return true


func _verify_seed_restart(main_scene: PackedScene) -> bool:
	var session := main_scene.instantiate() as MainSession
	root.add_child(session)
	await process_frame
	var first_runtime := session.get_node("World/TrackMount/GeneratedTrack") as TrackRuntime
	var first_fingerprint: String = session.get_session_snapshot().get("offtrack_object_fingerprint", "")
	session.restart_with_seed(1)
	var second_runtime := session.get_node("World/TrackMount/GeneratedTrack") as TrackRuntime
	var second_fingerprint: String = session.get_session_snapshot().get("offtrack_object_fingerprint", "")
	_check(not is_instance_valid(first_runtime), "seed restart frees the previous runtime immediately")
	_check(second_runtime != first_runtime, "seed restart mounts a new runtime")
	_check(first_fingerprint != second_fingerprint, "different seeds produce different object fingerprints")
	session.free()
	return true
```

Call the async restart helper with `await` and then `_check(completed, ...)` so a runtime error is observable.

Implement `_verify_solid_transforms(objects, placements, catalog) -> bool` by indexing every solid placement by sanitized stable ID, finding the matching node under `Visuals/SolidObjects`, recursively finding the same-named `CollisionShape2D` under `Collisions`, and asserting visual position and collider position both equal `placement.transform.origin`, visual rotation equals `placement.transform.get_rotation()`, and circle radius equals `catalog.archetype_by_id(id).collision_radius * placement.scale_factor`. End with `return true` and check the helper's completion as shown above.

- [ ] **Step 2: Run the integration test to verify it fails**

```bash
godot --headless --path . --script res://tests/offtrack_object_runtime_test.gd
```

Expected: non-zero exit because generation does not populate placements and runtime has no `OfftrackObjects` node.

- [ ] **Step 3: Add the runtime coordinator**

Create `world/offtrack/offtrack_object_runtime.gd`:

```gdscript
class_name OfftrackObjectRuntime
extends Node2D

var _visuals: OfftrackObjectVisuals
var _collisions: OfftrackObjectCollisions


func _init(placements: Array[OfftrackObjectPlacement] = [], catalog: OfftrackObjectCatalog = null) -> void:
	name = "OfftrackObjects"
	_visuals = OfftrackObjectVisuals.new()
	_visuals.name = "Visuals"
	add_child(_visuals)
	_collisions = OfftrackObjectCollisions.new()
	_collisions.name = "Collisions"
	add_child(_collisions)
	if catalog != null:
		_visuals.build(placements, catalog)
		_collisions.build(placements, catalog)


func get_metrics() -> Dictionary:
	return {
		"visuals": _visuals.visual_count(),
		"decorative_batches": _visuals.decorative_batch_count(),
		"solid_visuals": _visuals.solid_visual_count(),
		"colliders": _collisions.collider_count(),
		"collision_chunks": _collisions.chunk_body_count(),
	}
```

- [ ] **Step 4: Populate objects only after accepting the road**

In `track/track_generator.gd`, preload the default catalog and add `_attach_offtrack_objects()`:

```gdscript
const DEFAULT_OFFTRACK_CATALOG := preload("res://data/default_offtrack_object_catalog.tres")


func _attach_offtrack_objects(definition: TrackDefinition) -> TrackDefinition:
	var result := OfftrackObjectPlacer.new().place(definition, DEFAULT_OFFTRACK_CATALOG)
	definition.offtrack_objects = result.placements
	definition.offtrack_object_fingerprint = result.fingerprint
	definition.offtrack_object_generation_usec = result.generation_usec
	definition.offtrack_object_diagnostics = result.diagnostics
	return definition
```

Change only the two final returns in `generate()`:

```gdscript
return _attach_offtrack_objects(candidate)
```

for the accepted candidate, and:

```gdscript
return _attach_offtrack_objects(fallback)
```

for retry exhaustion. Do not invoke placement inside `_build_definition()`: rejected road candidates must not pay object-generation cost or perturb diagnostics.

- [ ] **Step 5: Mount objects from `TrackRuntime` and expose the snapshot fingerprint**

In `TrackRuntime._ready()`, after `_build_collision()`, add:

```gdscript
var object_runtime := OfftrackObjectRuntime.new(
	definition.offtrack_objects,
	preload("res://data/default_offtrack_object_catalog.tres"),
)
add_child(object_runtime)
```

In `MainSession.get_session_snapshot()`, add:

```gdscript
"offtrack_object_fingerprint": _track_definition.offtrack_object_fingerprint,
```

No other session or vehicle behavior changes.

- [ ] **Step 6: Run the focused and mutation suites**

```bash
godot --editor --headless --path . --quit
godot --headless --path . --script res://tests/offtrack_object_contract_test.gd
godot --headless --path . --script res://tests/offtrack_object_placement_test.gd
godot --headless --path . --script res://tests/offtrack_object_visuals_test.gd
godot --headless --path . --script res://tests/offtrack_object_collision_test.gd
godot --headless --path . --script res://tests/offtrack_object_runtime_test.gd
godot --headless --path . --script res://tests/offtrack_object_placement_test.gd -- --break-seed
godot --headless --path . --script res://tests/offtrack_object_placement_test.gd -- --break-clearance
godot --headless --path . --script res://tests/offtrack_object_collision_test.gd -- --remove-solid-collider
godot --headless --path . --script res://tests/offtrack_object_collision_test.gd -- --solid-decoration
```

Expected: five normal commands exit 0; all four mutation commands exit 1.

- [ ] **Step 7: Run every existing CI-relevant Godot suite twice**

Run this exact list twice, preserving the output from both batches:

```bash
godot --headless --path . --script res://tests/harness_contract_test.gd
godot --headless --path . --script res://tests/headless_smoke.gd
godot --headless --path . --script res://tests/world_scale_contract_test.gd
godot --headless --path . --script res://tests/segment_grid_test.gd
godot --headless --path . --script res://tests/track_generator_test.gd
godot --headless --path . --script res://tests/track_collision_physics_test.gd
godot --headless --path . --script res://tests/issue_4_vehicle_maneuvers.gd
godot --headless --path . --script res://tests/issue_5_input_session_test.gd
godot --headless --path . --script res://tests/issue_5_main_session_test.gd
godot --headless --path . --script res://tests/issue_6_android_test.gd
godot --headless --path . --script res://tests/open_surface_auto_reset_test.gd
```

Expected: every command exits 0 in both batches. The harness suite prints one intentional `SCRIPT ERROR`; no other suite prints `SCRIPT ERROR`, `ERROR:`, parser errors, or orphan-node warnings.

- [ ] **Step 8: Document integration and commit**

Add the integrated runtime-test command to README. Then:

```bash
git add world/offtrack/offtrack_object_runtime.gd track/track_generator.gd track/track_runtime.gd session/main.gd tests/offtrack_object_runtime_test.gd README.md
git commit -m "feat: integrate off-track objects into generated sessions"
```

---

### Task 6: Desktop Performance, Documentation, and Captures

**Files:**
- Create: `tests/offtrack_object_performance_test.gd`
- Create: `tests/capture_offtrack_objects.gd`
- Create: `docs/offtrack-objects.md`
- Create: `docs/evidence/offtrack-objects/desktop-validation.md`
- Create: `docs/evidence/offtrack-objects/seed-0.png`
- Create: `docs/evidence/offtrack-objects/seed-4.png`
- Create: `docs/evidence/offtrack-objects/seed-9.png`
- Modify: `README.md`

**Interfaces:**
- Consumes: integrated `TrackGenerator`, `OfftrackObjectRuntime.get_metrics()`, catalog version 1, and the configured main scene.
- Produces: reproducible desktop budgets and visual evidence used by Android #23, Steam Deck #7, and Task 7.

- [ ] **Step 1: Write the failing performance-budget test**

Create `tests/offtrack_object_performance_test.gd`. The test records placement timing already stored on each definition, measures object-runtime construction separately, prints counts, and asserts p95 budgets:

```gdscript
const PLACEMENT_P95_BUDGET_USEC := 50_000
const RUNTIME_P95_BUDGET_USEC := 100_000


func _verify_budgets(catalog: OfftrackObjectCatalog) -> bool:
	var placement_times: Array[int] = []
	var runtime_times: Array[int] = []
	for seed in range(20):
		var definition := TrackGenerator.new().generate(seed)
		placement_times.append(definition.offtrack_object_generation_usec)
		var started := Time.get_ticks_usec()
		var runtime := OfftrackObjectRuntime.new(definition.offtrack_objects, catalog)
		root.add_child(runtime)
		var construction_usec := Time.get_ticks_usec() - started
		runtime_times.append(construction_usec)
		var metrics := runtime.get_metrics()
		print("offtrack_perf seed=%d placement_usec=%d runtime_usec=%d placements=%d batches=%d colliders=%d" % [
			seed,
			definition.offtrack_object_generation_usec,
			construction_usec,
			definition.offtrack_objects.size(),
			int(metrics.get("decorative_batches", 0)),
			int(metrics.get("colliders", 0)),
		])
		runtime.free()
	var placement_p95 := _percentile(placement_times, 0.95)
	var runtime_p95 := _percentile(runtime_times, 0.95)
	_check(placement_p95 <= PLACEMENT_P95_BUDGET_USEC, "placement p95 is <= 50 ms (got %.2f ms)" % (placement_p95 / 1000.0))
	_check(runtime_p95 <= RUNTIME_P95_BUDGET_USEC, "runtime p95 is <= 100 ms (got %.2f ms)" % (runtime_p95 / 1000.0))
	print("offtrack_perf placement_p95_usec=%d runtime_p95_usec=%d" % [placement_p95, runtime_p95])
	return true


func _percentile(values: Array[int], ratio: float) -> int:
	var ordered := values.duplicate()
	ordered.sort()
	var index := clampi(ceili(ratio * ordered.size()) - 1, 0, ordered.size() - 1)
	return ordered[index]
```

Use the completion-observable harness pattern for `_verify_budgets()` and `_finish()`.

- [ ] **Step 2: Run the budget test before tuning**

```bash
godot --headless --path . --script res://tests/offtrack_object_performance_test.gd
```

Expected: either exit 0 within both approved budgets, or exit 1 naming the measured miss. Preserve the full seed-by-seed output in `docs/evidence/offtrack-objects/desktop-validation.md`; do not change a budget to obtain green.

- [ ] **Step 3: Tune catalog data only if a budget or playability criterion fails**

Tune in this order, changing one checked-in catalog value at a time and rerunning placement, runtime, and performance tests after each change:

1. reduce `near_occupancy` while keeping it above 0.35;
2. reduce `hazard_occupancy` while keeping it above 0.20;
3. increase `cell_size` no higher than `WorldScale.metres(25.0)`;
4. increase `chunk_size` no higher than `WorldScale.metres(120.0)` if node count, rather than instance count, is the measured problem.

Do not shrink the 20 m solid clearance, spawn/checkpoint exclusion, or containment buffer. Record every attempted value and its result in the desktop validation document. If the lowest allowed densities still miss the budget, leave the test red and escalate the finding instead of weakening acceptance.

- [ ] **Step 4: Create the deterministic graphical capture script**

Create `tests/capture_offtrack_objects.gd`. For seeds 0, 4, and 9, instantiate the configured main scene, call `restart_with_seed(seed)`, wait three process frames plus one physics frame, and save a viewport image:

```gdscript
func _capture_seed(main_scene: PackedScene, seed: int) -> bool:
	var session := main_scene.instantiate() as MainSession
	root.add_child(session)
	await process_frame
	session.restart_with_seed(seed)
	await process_frame
	await process_frame
	await physics_frame
	var image := root.get_viewport().get_texture().get_image()
	var path := "res://docs/evidence/offtrack-objects/seed-%d.png" % seed
	var error := image.save_png(ProjectSettings.globalize_path(path))
	_check(error == OK, "seed %d capture saves" % seed)
	var snapshot := session.get_session_snapshot()
	print("capture seed=%d road=%s objects=%s" % [seed, snapshot.get("geometry_fingerprint", ""), snapshot.get("offtrack_object_fingerprint", "")])
	session.free()
	await process_frame
	return true
```

Ensure the output directory exists through `DirAccess.make_dir_recursive_absolute()` before the loop. The script exits 1 if any image fails to save.

- [ ] **Step 5: Capture seeds and inspect all three images**

Run in a graphical session:

```bash
godot --path . --script res://tests/capture_offtrack_objects.gd
```

Inspect `seed-0.png`, `seed-4.png`, and `seed-9.png`. Each must visibly show the dirt road, near-shoulder decorative objects, a readable open recovery corridor, and at least one deeper tree or rock. If a selected seed does not show all four layers within the initial camera view, move only the capture camera to the nearest deterministic hazard cluster; do not alter placements for the screenshot.

- [ ] **Step 6: Write feature documentation and desktop evidence**

Create `docs/offtrack-objects.md` with these exact sections:

- `Deterministic placement`: catalog version, domain/cell seed rules, object fingerprint, and road-fingerprint isolation.
- `Placement zones`: the 0-12 m decorative band, 20 m solid clearance, 20-140 m hazard field, final 20 m containment buffer, and 40 m spawn/checkpoint exclusions.
- `Prototype catalog`: the four archetypes, weights, scale ranges, and collision profiles.
- `Runtime`: decorative batches, Y-sorted solid visuals, chunk bodies, and non-goals.
- `Diagnostics`: every placement/result/runtime metric and what underfill means.
- `Verification`: normal commands, mutation commands, performance budgets, and physical-device boundary.

Create `docs/evidence/offtrack-objects/desktop-validation.md` containing:

- exact commit SHA and Godot build string;
- reference workstation OS/CPU/GPU;
- all seed 0-19 placement/runtime measurements;
- p50 and p95 placement/runtime values;
- min/max/median placements, batches, solid visuals, and colliders;
- capture filenames and fingerprints for seeds 0/4/9;
- any tuning attempts and remaining limitations;
- an explicit `desktop code-complete`, `conditional`, or `failed` result.

Update README's gameplay paragraph, project-boundary table, and verification commands to link the document and performance/capture scripts.

- [ ] **Step 7: Run the final desktop gate**

Run the Task 5 focused and full suites, then:

```bash
godot --headless --path . --script res://tests/offtrack_object_performance_test.gd
git diff --check
```

Expected: every normal suite exits 0, every mutation suite exits 1, the performance suite meets both budgets, and `git diff --check` prints nothing. If the graphical command or image inspection is unavailable, Task 6 remains incomplete rather than substituting headless SVG evidence.

- [ ] **Step 8: Commit desktop evidence**

```bash
git add data/default_offtrack_object_catalog.tres tests/offtrack_object_performance_test.gd tests/capture_offtrack_objects.gd docs/offtrack-objects.md docs/evidence/offtrack-objects README.md
git commit -m "docs: validate off-track objects on desktop"
```

---

### Task 7: Physical-Platform Gates and Final Reconciliation

**Files:**
- Modify: `docs/evidence/android/issue-6-validation.md`
- Create or modify: `docs/poc-report.md`
- Modify: `README.md`
- Platform issue #7 owns its Steam Deck package guide, capture, and device record.
- Android issue #23 owns its rebuilt APK and replacement device captures.

**Interfaces:**
- Consumes: one immutable Task 6 commit, Android issue #23 evidence, Steam Deck issue #7 evidence, and the desktop validation document.
- Produces: reconciled B acceptance and the cross-platform PoC recommendation. No application code is changed in this task.

- [ ] **Step 1: Pin the one revision both platform lanes must test**

Run:

```bash
git rev-parse HEAD
git status --short --branch
```

Record the full SHA in both #23 and #7 before either build starts. The status must contain no tracked modifications. Do not accept evidence from different SHAs.

- [ ] **Step 2: Run Android #23 against the pinned revision**

Follow `docs/android-export.md` exactly:

```bash
godot --headless --path . --export-debug "Android Debug" builds/android/slicksnslide-fest-debug.apk
/home/japurane/Android/Sdk/platform-tools/adb install -r builds/android/slicksnslide-fest-debug.apk
```

On the physical SM-X710 with an external controller, drive at least three seeds for at least ten minutes total. Record APK SHA-256, commit, Godot version, device/build, placement and collider counts, representative frame time and spikes, memory, controller-only operation, lifecycle pause/resume, collision with tree and rock, recovery-corridor usability, and updated captures. Update `docs/evidence/android/issue-6-validation.md` and complete issue #23's world-rescale step only if this current object-enabled build passes.

- [ ] **Step 3: Run Steam Deck #7 concurrently against the same revision**

Build the native Linux package:

```bash
godot --headless --path . --export-release "Linux x86_64" builds/linux/slicksnslide-fest.x86_64
sha256sum builds/linux/slicksnslide-fest.x86_64
```

Add it as a non-Steam game and validate in Gaming Mode at 1280x800 using built-in controls. Drive at least three seeds for at least ten minutes total. Record package hash, commit, Godot and SteamOS versions, shortcut settings, Deck performance/TDP profile, placement/collider counts, frame time and spikes, memory, focus, pause/back, suspend/resume, collision with both solid archetypes, recovery-corridor usability, and a short capture. Issue #7 remains open if any required physical evidence is unavailable.

- [ ] **Step 4: Reconcile the reports without averaging away platform failures**

Create or update `docs/poc-report.md` with these sections:

- `Revision and reproducible builds`;
- `Architecture and catalog version`;
- `Seeds 0-19 and fingerprints`;
- `Desktop, Android, and Steam Deck matrix`;
- `Generation, construction, frame-time, memory, and object counts`;
- `Driving observations`;
- `Captures`;
- `Known limitations and open defects`;
- `Go, conditional go, or no-go recommendation`.

Report each platform independently. A 60 FPS miss, missing controller evidence, missing capture, or unavailable device remains visible and keeps its issue open; desktop results do not replace it.

- [ ] **Step 5: Run the documentation and repository integrity gate**

```bash
git diff --check
git status --short --branch
```

Verify that every referenced capture exists, both platform reports name the identical commit, all object fingerprints are 64 characters, and no APK, Linux binary, SDK path, key, or credential is staged.

- [ ] **Step 6: Commit the reconciled evidence**

```bash
git add docs/evidence/android/issue-6-validation.md docs/poc-report.md README.md
git commit -m "docs: reconcile off-track object platform evidence"
```

If issue #7 contributes additional checked-in documentation or captures, stage those exact reviewed paths in the same commit. Do not use `git add .`.

- [ ] **Step 7: Close only evidence-backed work**

Reconcile the B epic checklist from the committed reports. Close Android #23, Steam Deck #7, the B final-reconciliation task, and the B epic only when their own acceptance criteria are evidenced. If either platform gate remains incomplete, leave B open with a concise blocker and retain the desktop result as conditional.

---

## Plan Completion Gate

Before claiming the implementation complete:

- Tasks 1-7 each have a reviewed commit.
- Task 1 preceded the parallel Task 2-4 branches.
- Task 5 integrated exact reviewed Task 2-4 heads and passed two full suite batches.
- All four mutation commands failed for the intended assertion.
- Road fingerprints for seeds `0..19` match the pre-B baseline.
- Object fingerprints repeat for seeds `0..19` and differ across the selected capture seeds.
- Desktop p95 meets 50 ms placement and 100 ms runtime-construction budgets, or the miss remains open.
- Android and Steam Deck used one immutable revision and neither is represented by desktop-only proof.
- `git diff --check` is clean and only reviewed task files are staged in every commit.
