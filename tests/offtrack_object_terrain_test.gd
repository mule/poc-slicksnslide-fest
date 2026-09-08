extends SceneTree

## Off-track objects stand on the terrain. Every solid body and every decorative instance is lifted
## by the ground height the shared TrackHeightMap reports at its foot and coloured by the same
## TerrainShading function that colours the ground, so a tree on a rise draws high and bright and
## a rock in a hollow draws low and dark, from the one field the car drives on. Placement never
## sees any of it: objects are placed by seed and terrain is sampled at those positions afterwards,
## so the object fingerprint pinned below is byte for byte the one #37 recorded before terrain
## existed, and changing the terrain seed under a definition cannot move a single placement.
##
## Shading a body from the ground's own function makes the two brightnesses track each other, so
## the body's luminance ratio against the ground under it is a constant of its base colour, not of
## the hill it stands on. #50's review measured tree bodies crossing the ground's luminance at
## +20 px and +43 px of elevation -- a sign flip, invisible in between. The contrast rule here
## says every object base colour keeps at least TerrainShading.BODY_CONTRAST_FLOOR of luminance
## ratio against the ground, lighter or darker, at every height and every slope the catalog can
## produce, and the production check measures each solid against the ground grid actually drawn
## under it. A shading that tracked the ground exactly has a ratio of 1 and fails the rule; that
## falsification is performed live in the task report.
##
## The suite also re-runs #37's rock-reachability measurement on terrain: the car is launched over
## every ramp of seeds 0..19 across a heading and lateral-seat sweep, its flight is compared
## against every generated rock near the ramp while it is above the clearance height over that
## rock's own ground, and the result is pinned as an assertion whichever way it lands. Mutation:
##   -- --break-rock-corridor  removes the recovery corridor and fills every hazard cell with a rock
##                             up to the road edge, so a flight does reach one and the pin fails

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const OBJECT_CATALOG_PATH := "res://data/default_offtrack_object_catalog.tres"
const TERRAIN_CATALOG_PATH := "res://data/default_terrain_catalog.tres"
const TICK := 1.0 / 60.0
## Headless physics is wall-clock paced; ten times the tick rate at ten times the time scale keeps
## the production 1 / 60 s step and runs ten times faster. Pinned by the step check.
const PHYSICS_TICKS_PER_SECOND := 600
const TIME_SCALE := 10.0
const SEED_COUNT := 20
## The object fingerprints #37 recorded for seeds 0..19 before any terrain existed, from
## docs/evidence/height-channel/desktop-trace-seeds-0-4-9.txt. Placement does not consult terrain,
## so these must hold byte for byte.
const OBJECT_FINGERPRINTS := {
	0: "5f587a1b70ce3300729a390f555f277329c0d3e2e385891396868da5470bac88",
	1: "a6e2ba9fb9a8ac7f43b29874878529b37cb3f368bcd382e2a7346760e895a9f7",
	2: "308f0795be1df084a297b4e74971d17be10297420df51c6297fbe28606594d28",
	3: "8222001966fe85a9b0df8c1abdc5e4172586c18b702ea3891fce5309e8c2a0d9",
	4: "e48a8ef915e3eb316784300ad5f26189d7f157ab2c0f4bdfad733d0e676c2348",
	5: "23565fec72cb77b09ef01fae6966bf754460768b30697939a5273e380df4523a",
	6: "1c92f61706ca488261612277291ffbb8cfe076fec6df9d36471026adf6b2c59e",
	7: "9a3965d30d5b18ddeb963f2af4b3acfdb2ecf2d598e21ecd159037a8d9987fd2",
	8: "7ab67ac9cd411656a5799f04904d19de9bf6142212e79d063fd230274ec52a47",
	9: "7f5a46301fead1d1514cabb3d0b82f207e210d88a1ef1b46d246695f782aaa6b",
	10: "4fa89cd904ad87ea423b28f3ad382d563525354a5ff317f1bf9449e72e7dd2d5",
	11: "ce168f228e687a01bfdfc0dc5cb043a5b7555ea3f0a9877a13574de16f2b5e61",
	12: "8c9512f41ea4fcb539b6c2b5dbc1475b06cd274cbf243a8ce6272ac79df2f2e2",
	13: "765febb166d37358cf41515ecebe5ac3aa314ff0f5136b83cf31455dd1458852",
	14: "24b85a0a988cc5c7f76b9d74615e8c35d68f0d74bb323d89764b62b6a1233132",
	15: "6060ea3ec4be6e5684247648357331687cf19d318fb493c802608099d89fd622",
	16: "2c7dbb2314d629d893c06757e9c960c155be26fb7dfcc6e95dcb3ac6751a2288",
	17: "97198fba598f07593c8b9af43619979916abc23956b60e591203c57a5664e85f",
	18: "d3a77402e5dd1b77ac221b57f466b0ac1825934d022ea7318d42177b0cf3ffff",
	19: "ee5073557e8b04df7f95c075a37edc7cbd1d00b731b2760c62a84c892afc3016",
}
const PRODUCTION_SEEDS := [0, 10]
## The band #50's review found tree bodies vanishing in: the production check must include an
## object standing at least this high, or it never exercised the elevations that mattered.
const SIGN_FLIP_BAND_FLOOR := 20.0
const CONTRAST_HEIGHT_STEPS := 21
const CONTRAST_LIGHT_STEPS := 9
const COLOR_TOLERANCE := 1e-5
## The reach sweep. The car is seated just before the ramp's foot at its terminal speed on dirt
## and held at full throttle to the crest, so each pass is the fastest arrival the car can make
## and the reach is an upper envelope; the crest speed is measured and reported. Every ramp of
## every seed is swept coarsely; the ramps with the longest reach are then swept at #37's angular
## resolution, so the maximum is refined where it matters rather than everywhere at a cost of
## minutes. Sideways reach past the road edge only accrues while the car is above the clearance
## over the ground beneath it, which needs the ground to fall away under the flight; that happens
## along the ramp's axis, so steep headings drift far but never high, and the fine headings stay
## within 60 degrees of the axis.
const APPROACH_SPEED := 600.0
const APPROACH_BEFORE_FOOT := 60.0
const COARSE_HEADINGS_DEGREES := [-85, -60, -45, -30, -15, 0, 15, 30, 45, 60, 85]
const COARSE_LATERAL_FRACTIONS := [-1.0, 0.0, 1.0]
const FINE_RAMPS := 2
const FINE_HEADING_STEP := 5
const FINE_HEADING_LIMIT := 60
const FINE_LATERAL_FRACTIONS := [-1.0, -0.5, 0.0, 0.5, 1.0]
const REACH_TICKS := 240
const SETTLE_TICKS := 90
const CAR_COLLISION_RADIUS := 15.0
const ROCK_SEARCH_RADIUS := 1500.0
const CENTRELINE_SEARCH_RADIUS := 800.0

var _failures: Array[String] = []
var _checks := 0
var _break_corridor := false
var _tuning: VehicleTuning
var _object_catalog: OfftrackObjectCatalog
var _generator: TrackGenerator
var _definitions: Dictionary = {}


func _initialize() -> void:
	Engine.physics_ticks_per_second = PHYSICS_TICKS_PER_SECOND
	Engine.time_scale = TIME_SCALE
	_break_corridor = OS.get_cmdline_user_args().has("--break-rock-corridor")
	call_deferred("_run")


func _run() -> void:
	_tuning = load(TUNING_PATH) as VehicleTuning
	_object_catalog = load(OBJECT_CATALOG_PATH) as OfftrackObjectCatalog
	_generator = TrackGenerator.new()
	_check(_verify_placement_ignores_terrain(), "the placement independence verification ran to completion")
	_check(_verify_lift_rule_matches_the_car(), "the lift rule verification ran to completion")
	_check(_verify_solids_seated_on_a_plateau(), "the solid seating verification ran to completion")
	_check(_verify_decoratives_seated_on_a_plateau(), "the decorative seating verification ran to completion")
	_check(_verify_contrast_rule_across_the_range(), "the contrast rule verification ran to completion")
	for seed in PRODUCTION_SEEDS:
		_check(_verify_production_objects(seed), "the seed %d production object verification ran to completion" % seed)
	_check(await _verify_physics_step(), "the physics step verification ran to completion")
	_check(await _verify_rock_reachability(), "the rock reachability measurement ran to completion")
	_finish()


func _definition(seed: int) -> TrackDefinition:
	if not _definitions.has(seed):
		_definitions[seed] = _generator.generate(seed)
	return _definitions[seed]


func _shading() -> TerrainShading:
	return TerrainShading.new(load(TERRAIN_CATALOG_PATH) as TerrainCatalog)


func _placement(id: String, archetype_id: StringName, position: Vector2, rotation: float, variant: int, scale_factor: float = 1.0) -> OfftrackObjectPlacement:
	var archetype := _object_catalog.archetype_by_id(archetype_id)
	var placement := OfftrackObjectPlacement.new()
	placement.stable_id = id
	placement.archetype_id = archetype_id
	placement.transform = Transform2D(rotation, position)
	placement.scale_factor = scale_factor
	placement.visual_variant = variant
	placement.solid = archetype.solid
	placement.collision_profile = archetype.collision_profile
	return placement


## A plateau of `height` for x < 1000, level ground beyond it.
func _plateau(height: float) -> HeightChannelTestHeightProvider:
	var plateau := HeightChannelTestHeightProvider.new()
	plateau.mode = HeightChannelTestHeightProvider.Mode.PLATEAU
	plateau.plateau_height = height
	plateau.plateau_end_x = 1000.0
	return plateau


func _colors_match(actual: Color, expected: Color) -> bool:
	return absf(actual.r - expected.r) <= COLOR_TOLERANCE and absf(actual.g - expected.g) <= COLOR_TOLERANCE and absf(actual.b - expected.b) <= COLOR_TOLERANCE and absf(actual.a - expected.a) <= COLOR_TOLERANCE


## Luminance ratio between two colours, always at least 1: lighter or darker counts alike.
func _contrast(first: Color, second: Color) -> float:
	var ratio := first.get_luminance() / second.get_luminance()
	return maxf(ratio, 1.0 / ratio)


## Every object base colour the factory draws, keyed by archetype and variant.
func _base_colors() -> Dictionary:
	var colors: Dictionary = {}
	for archetype in _object_catalog.archetypes:
		for variant in archetype.visual_variant_count:
			var key := "%s:%d" % [archetype.id, variant]
			if archetype.solid:
				var visual := OfftrackObjectMeshFactory.solid_visual(archetype.id, variant)
				colors[key] = (visual.get_child(1) as Polygon2D).color
				visual.free()
			else:
				var mesh := OfftrackObjectMeshFactory.decorative_mesh(archetype.id, variant)
				var vertex_colors: PackedColorArray = mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
				colors[key] = vertex_colors[0]
	return colors


## Placement is by seed alone. The pinned fingerprints predate terrain; re-placing on a definition
## whose terrain seed is replaced, or removed, reproduces them; and the generated definition's own
## fingerprint is the pinned one, so the generator's terrain step did not move anything either.
func _verify_placement_ignores_terrain() -> bool:
	var placer := OfftrackObjectPlacer.new()
	var solids := 0
	for seed in SEED_COUNT:
		var definition := _definition(seed)
		_check(definition.terrain_seed != 0, "seed %d carries a terrain seed, so the independence below is from real terrain" % seed)
		_check(definition.offtrack_object_fingerprint == OBJECT_FINGERPRINTS[seed], "seed %d object fingerprint is byte-identical to the pre-terrain ledger" % seed)
		var other_terrain := definition.duplicate() as TrackDefinition
		other_terrain.terrain_seed = definition.terrain_seed ^ 0x5bd1e995
		other_terrain.terrain_fingerprint = ""
		var no_terrain := definition.duplicate() as TrackDefinition
		no_terrain.terrain_seed = 0
		no_terrain.terrain_fingerprint = ""
		_check(placer.place(other_terrain, _object_catalog).fingerprint == OBJECT_FINGERPRINTS[seed], "seed %d places identically under a different terrain seed" % seed)
		_check(placer.place(no_terrain, _object_catalog).fingerprint == OBJECT_FINGERPRINTS[seed], "seed %d places identically with no terrain at all" % seed)
		for placement in definition.offtrack_objects:
			if placement.solid:
				solids += 1
	_check(solids > 0, "the seeds place solids (%d), so the pins above cover the objects this task seats" % solids)
	return true


## Objects lift by the car's own rate, so a car parked beside a rock on a hill draws level with it.
func _verify_lift_rule_matches_the_car() -> bool:
	_check(is_equal_approx(TerrainShading.LIFT_PIXELS_PER_PIXEL, _tuning.lift_pixels_per_pixel), "the object lift rate is the car's lift_pixels_per_pixel (%.2f)" % _tuning.lift_pixels_per_pixel)
	_check(TerrainShading.lift_offset(40.0).is_equal_approx(Vector2(0.0, -40.0 * TerrainShading.LIFT_PIXELS_PER_PIXEL)), "40 px of ground lifts a body 40 px up the screen")
	_check(TerrainShading.lift_offset(-25.0).is_equal_approx(Vector2(0.0, 25.0 * TerrainShading.LIFT_PIXELS_PER_PIXEL)), "a hollow lowers a body down the screen")
	_check(TerrainShading.lift_offset(0.0) == Vector2.ZERO, "level ground leaves a body where it stands")
	return true


func _verify_solids_seated_on_a_plateau() -> bool:
	var raised_height := 40.0
	var rotation := 0.5
	var shading := _shading()
	var plateau := _plateau(raised_height)
	var placements: Array[OfftrackObjectPlacement] = [
		_placement("v1:0:1:0", &"tree", Vector2(500.0, 0.0), rotation, 0),
		_placement("v1:0:1:1", &"tree", Vector2(1500.0, 0.0), rotation, 0),
		_placement("v1:0:2:0", &"rock", Vector2(700.0, 0.0), -2.0, 1, 1.2),
	]
	var visuals := OfftrackObjectVisuals.new()
	root.add_child(visuals)
	visuals.build(placements, _object_catalog, plateau, shading)
	var raised := visuals.get_node("SolidObjects/v1_0_1_0") as Node2D
	var level := visuals.get_node("SolidObjects/v1_0_1_1") as Node2D
	var rock := visuals.get_node("SolidObjects/v1_0_2_0") as Node2D
	var raised_body := raised.get_child(1) as Polygon2D
	var level_body := level.get_child(1) as Polygon2D
	var rock_body := rock.get_child(1) as Polygon2D
	var raised_shadow := raised.get_child(0) as Polygon2D
	var expected_lift := TerrainShading.lift_offset(raised_height)
	_check(raised.position.is_equal_approx(Vector2(500.0, 0.0)), "the visual node stays at the placement, where the collider is")
	# World-space offsets through each node's own basis, so rotation and scale both count: the
	# rock is drawn at 1.2x and must still rise exactly the plateau height.
	_check(raised.transform.basis_xform(raised_body.position).is_equal_approx(expected_lift), "on the plateau the tree body is lifted %.0f px straight up the screen, whatever the tree's rotation" % -expected_lift.y)
	_check(rock.transform.basis_xform(rock_body.position).is_equal_approx(expected_lift), "the 1.2x rock beside it is lifted the same %.0f px under its own rotation and scale, not 1.2 times as far" % -expected_lift.y)
	_check(rock.scale.is_equal_approx(Vector2.ONE * 1.2) and not rock_body.position.is_equal_approx(raised_body.position.rotated(rotation - 2.0)), "the rock's local offset differs from the tree's because its scale is folded out of it")
	_check(level_body.position == Vector2.ZERO, "on level ground the body stays at its foot")
	_check(raised_body.polygon == level_body.polygon, "the lift moves the body; it does not reshape it")
	_check(raised_shadow.position.rotated(rotation).normalized().is_equal_approx(TerrainShading.SHADOW_DIRECTION), "the shadow stays at the foot, thrown along the shadow direction, so the body stands above its own shadow")
	_check(raised_shadow.position.length() > 1.0 and not raised_shadow.position.is_equal_approx(raised_body.position), "the shadow is not lifted with the body")
	# Colour: the same function the ground uses, from the same sample.
	var base := (OfftrackObjectMeshFactory.solid_visual(&"tree", 0).get_child(1) as Polygon2D).color
	var raised_sample := plateau.sample_at(Vector2(500.0, 0.0))
	_check(_colors_match(raised_body.color, shading.shade(base, raised_sample)), "the raised tree body is shade(base, sample) from the map at its foot")
	_check(_colors_match(level_body.color, base), "the level tree body is its base colour: brightness 1 on level ground")
	_check(raised_body.color.get_luminance() > level_body.color.get_luminance(), "the raised body is brighter than the level one, as the ground under each is")
	# A hollow lowers and darkens.
	plateau.plateau_height = -raised_height
	visuals.build(placements, _object_catalog, plateau, shading)
	var lowered_body := visuals.get_node("SolidObjects/v1_0_1_0").get_child(1) as Polygon2D
	_check((visuals.get_node("SolidObjects/v1_0_1_0") as Node2D).transform.basis_xform(lowered_body.position).is_equal_approx(TerrainShading.lift_offset(-raised_height)), "in a hollow the body is lowered down the screen")
	_check(lowered_body.color.get_luminance() < base.get_luminance(), "in a hollow the body is darker than its base")
	# No query, no shading: the pre-terrain fixtures draw as before.
	visuals.build(placements, _object_catalog)
	var plain_body := visuals.get_node("SolidObjects/v1_0_1_0").get_child(1) as Polygon2D
	_check(plain_body.position == Vector2.ZERO and _colors_match(plain_body.color, base), "without a height query the body is unlifted and its base colour")
	visuals.free()
	return true


func _verify_decoratives_seated_on_a_plateau() -> bool:
	var raised_height := 40.0
	var shading := _shading()
	var plateau := _plateau(raised_height)
	var placements: Array[OfftrackObjectPlacement] = [
		_placement("v1:0:1:0", &"grass", Vector2(500.0, 100.0), 0.3, 1, 0.9),
		_placement("v1:0:1:1", &"grass", Vector2(600.0, 100.0), -1.0, 1, 1.1),
		_placement("v1:0:1:2", &"debris", Vector2(1500.0, 100.0), 0.0, 2),
	]
	var visuals := OfftrackObjectVisuals.new()
	root.add_child(visuals)
	visuals.build(placements, _object_catalog, plateau, shading)
	_check(visuals.decorative_batch_count() == 2, "the grass pair and the debris form two batches")
	var expected_lift := TerrainShading.lift_offset(raised_height)
	var brightness := shading.brightness(plateau.sample_at(Vector2(500.0, 100.0)))
	_check(brightness > 1.0, "the plateau brightens (%.3f), so the colour check below is not a check against 1" % brightness)
	for index in 2:
		var placement := placements[index]
		var instance: Dictionary = visuals.decorative_instance_of(placement.stable_id)
		_check(not instance.is_empty(), "%s is findable in its batch" % placement.stable_id)
		if instance.is_empty():
			continue
		var batch: MultiMeshInstance2D = instance.batch
		var transform := _instance_transform(instance)
		var unlifted := placement.transform.scaled_local(Vector2.ONE * placement.scale_factor)
		_check(transform.origin.is_equal_approx(placement.transform.origin + expected_lift), "%s is lifted %.0f px up the screen" % [placement.stable_id, -expected_lift.y])
		_check(transform.x.is_equal_approx(unlifted.x) and transform.y.is_equal_approx(unlifted.y), "%s keeps its rotation and scale" % placement.stable_id)
		_check(batch.multimesh.use_colors, "the batch carries per-instance colours")
		_check(batch.multimesh.buffer.size() == 2 * OfftrackObjectVisuals.instance_stride(true) and instance.buffer.size() == batch.multimesh.buffer.size(), "the multimesh accepted a buffer of two coloured instances (%d floats)" % batch.multimesh.buffer.size())
		_check(_colors_match(_instance_color(instance), Color(brightness, brightness, brightness, 1.0)), "%s is tinted by the ground brightness at its foot, which the GPU multiplies into the mesh colour" % placement.stable_id)
		var bounds: AABB = batch.multimesh.custom_aabb
		_check(bounds.position.y <= transform.origin.y - WorldScale.metres(0.8) * 1.1, "the batch bounds reach above the lifted instances")
	var debris: Dictionary = visuals.decorative_instance_of("v1:0:1:2")
	_check(_instance_transform(debris).origin.is_equal_approx(Vector2(1500.0, 100.0)), "the debris on level ground is not lifted")
	_check(_colors_match(_instance_color(debris), Color.WHITE), "the debris on level ground keeps its mesh colour")
	# No query: the flat fixtures, exactly as before terrain.
	visuals.build(placements, _object_catalog)
	var plain: Dictionary = visuals.decorative_instance_of("v1:0:1:0")
	var plain_batch: MultiMeshInstance2D = plain.batch
	_check(_instance_transform(plain).origin.is_equal_approx(Vector2(500.0, 100.0)), "without a height query the instance sits at its placement")
	_check(not plain_batch.multimesh.use_colors and plain_batch.multimesh.buffer.size() == 2 * OfftrackObjectVisuals.instance_stride(false), "without shading the batch carries no instance colours (%d floats)" % plain_batch.multimesh.buffer.size())
	visuals.free()
	return true


## Decodes an instance's transform from the batch buffer the visuals uploaded, in the renderer's
## 2D layout: rows (x.x, y.x, 0, origin.x) and (x.y, y.y, 0, origin.y). The headless renderer
## discards instance data, so the buffer is the only readable record of what was drawn; the
## layout was confirmed against a graphical run, where get_instance_transform_2d reads it back.
func _instance_transform(instance: Dictionary) -> Transform2D:
	var buffer: PackedFloat32Array = instance.buffer
	var batch: MultiMeshInstance2D = instance.batch
	var offset: int = instance.index * OfftrackObjectVisuals.instance_stride(batch.multimesh.use_colors)
	return Transform2D(Vector2(buffer[offset], buffer[offset + 4]), Vector2(buffer[offset + 1], buffer[offset + 5]), Vector2(buffer[offset + 3], buffer[offset + 7]))


## The instance colour after the transform, or white when the batch carries none.
func _instance_color(instance: Dictionary) -> Color:
	var buffer: PackedFloat32Array = instance.buffer
	var batch: MultiMeshInstance2D = instance.batch
	if not batch.multimesh.use_colors:
		return Color.WHITE
	var offset: int = instance.index * OfftrackObjectVisuals.instance_stride(true) + 8
	return Color(buffer[offset], buffer[offset + 1], buffer[offset + 2], buffer[offset + 3])


## The rule, over the whole range the catalog can produce: every base colour keeps at least the
## floor of luminance ratio against the ground shaded from the same sample, at every height from
## minus to plus the total amplitude and every light term from fully shaded to fully lit. Because
## shading is multiplicative the ratio is flat until a channel clamps, and the sweep reaches the
## clamp corner (full height and full light together) on purpose.
func _verify_contrast_rule_across_the_range() -> bool:
	var shading := _shading()
	var terrain := load(TERRAIN_CATALOG_PATH) as TerrainCatalog
	var amplitude := terrain.total_amplitude()
	var slope := terrain.slope_bound()
	var colors := _base_colors()
	_check(colors.size() == 11, "eleven archetype and variant colours are under the rule (%d)" % colors.size())
	var ground_luminances: Array[float] = []
	var worst_key := ""
	var worst := INF
	var worst_height := 0.0
	var worst_light := 0.0
	var flat_ratio_spread := 0.0
	for key in colors.keys():
		var base: Color = colors[key]
		var low := INF
		var high := -INF
		for height_step in CONTRAST_HEIGHT_STEPS:
			var height := lerpf(-amplitude, amplitude, float(height_step) / float(CONTRAST_HEIGHT_STEPS - 1))
			for light_step in CONTRAST_LIGHT_STEPS:
				var light := lerpf(-1.0, 1.0, float(light_step) / float(CONTRAST_LIGHT_STEPS - 1))
				var sample := HeightQuery.HeightSample.new(height, -TerrainShading.LIGHT_DIRECTION * slope * light)
				var ground := shading.shade(TerrainShading.GROUND_COLOR, sample)
				var body := shading.shade(base, sample)
				var ratio := _contrast(body, ground)
				low = minf(low, ratio)
				high = maxf(high, ratio)
				if ratio < worst:
					worst = ratio
					worst_key = key
					worst_height = height
					worst_light = light
				if key == "tree:0":
					ground_luminances.append(ground.get_luminance())
		flat_ratio_spread = maxf(flat_ratio_spread, high - low)
		_check(low >= TerrainShading.BODY_CONTRAST_FLOOR, "%s keeps at least %.2f of luminance contrast against the ground everywhere (min %.3f, base ratio %.3f)" % [key, TerrainShading.BODY_CONTRAST_FLOOR, low, _contrast(base, TerrainShading.GROUND_COLOR)])
	print("contrast floor=%.2f worst=%s ratio=%.3f at height=%.1f light=%.2f colours=%d spread_over_range=%.3f" % [TerrainShading.BODY_CONTRAST_FLOOR, worst_key, worst, worst_height, worst_light, colors.size(), flat_ratio_spread])
	var darkest_ground: float = ground_luminances.min()
	var lightest_ground: float = ground_luminances.max()
	_check(lightest_ground / darkest_ground > 2.5, "the sweep spans the ground's real range (luminance %.3f to %.3f), not a sliver of it" % [darkest_ground, lightest_ground])
	# The sign never flips: every body is strictly on one side of the ground's luminance in the
	# deepest hollow and strictly on the same side on the highest rise. Strict, so a body the same
	# colour as the ground -- the invisibility #50 measured -- fails here rather than comparing
	# equal on both sides.
	var flips := 0
	for key in colors.keys():
		var base: Color = colors[key]
		var bottom := HeightQuery.HeightSample.new(-amplitude, Vector2.ZERO)
		var top := HeightQuery.HeightSample.new(amplitude, Vector2.ZERO)
		var bottom_side := signf(shading.shade(base, bottom).get_luminance() - shading.shade(TerrainShading.GROUND_COLOR, bottom).get_luminance())
		var top_side := signf(shading.shade(base, top).get_luminance() - shading.shade(TerrainShading.GROUND_COLOR, top).get_luminance())
		if bottom_side == 0.0 or top_side == 0.0 or bottom_side != top_side:
			flips += 1
	_check(flips == 0, "every body is strictly on one side of the ground's luminance in the deepest hollow and on the highest rise: no sign flip, no equality (%d offenders)" % flips)
	return true


## The drawn ground colour at a point: the four grid vertex colours around it, interpolated the way
## the GPU interpolates them across the cell. What a player sees behind an object's foot.
func _drawn_ground_color(ground: Polygon2D, area: Rect2, point: Vector2) -> Color:
	var columns := TerrainShading.ground_columns(area)
	var rows := TerrainShading.ground_rows(area)
	var cell := TerrainShading.GROUND_CELL
	var column := clampi(floori((point.x - area.position.x) / cell), 0, columns - 2)
	var row := clampi(floori((point.y - area.position.y) / cell), 0, rows - 2)
	var corner := row * columns + column
	var top_left := ground.polygon[corner]
	var bottom_right := ground.polygon[corner + columns + 1]
	var u := clampf((point.x - top_left.x) / (bottom_right.x - top_left.x), 0.0, 1.0)
	var v := clampf((point.y - top_left.y) / (bottom_right.y - top_left.y), 0.0, 1.0)
	var colors := ground.vertex_colors
	var top := colors[corner].lerp(colors[corner + 1], u)
	var bottom := colors[corner + columns].lerp(colors[corner + columns + 1], u)
	return top.lerp(bottom, v)


## Production objects on a generated track: every solid body and decorative instance is lifted by
## the height a car-path TrackHeightMap reports at its foot and coloured from that sample, and
## every solid keeps the contrast floor against the ground grid actually drawn under it.
func _verify_production_objects(seed: int) -> bool:
	var definition := _definition(seed)
	var runtime := TrackRuntime.new(definition)
	root.add_child(runtime)
	var car_map := TrackHeightMap.new(definition)
	var shading := runtime.get_node("TerrainShading") as TerrainShading
	var ground := shading.get_node("Ground") as Polygon2D
	var visuals := runtime.get_node("OfftrackObjects/Visuals") as OfftrackObjectVisuals
	var colors := _base_colors()
	var solids := 0
	var decoratives := 0
	var lift_mismatches := 0
	var color_mismatches := 0
	var highest := -INF
	var lowest := INF
	var min_contrast := INF
	var min_contrast_id := ""
	var min_foot_contrast := INF
	var contrast_failures := 0
	var worst_archetype_seen := false
	for placement in definition.offtrack_objects:
		var sample := car_map.sample_at(placement.transform.origin)
		var expected_lift := TerrainShading.lift_offset(sample.ground_height)
		var key := "%s:%d" % [placement.archetype_id, placement.visual_variant]
		var base: Color = colors[key]
		highest = maxf(highest, sample.ground_height)
		lowest = minf(lowest, sample.ground_height)
		# The colour on screen: a solid body's own colour; a decorative's mesh colour times its
		# instance colour, which is what the GPU multiplies and what shade() computes.
		var drawn: Color
		if placement.solid:
			solids += 1
			var visual := visuals.get_node("SolidObjects/%s" % placement.stable_id.replace(":", "_")) as Node2D
			var body := visual.get_child(1) as Polygon2D
			if not visual.transform.basis_xform(body.position).is_equal_approx(expected_lift):
				lift_mismatches += 1
			if not _colors_match(body.color, shading.shade(base, sample)):
				color_mismatches += 1
			drawn = body.color
		else:
			decoratives += 1
			var instance: Dictionary = visuals.decorative_instance_of(placement.stable_id)
			if instance.is_empty():
				lift_mismatches += 1
				color_mismatches += 1
				continue
			var batch: MultiMeshInstance2D = instance.batch
			if not _instance_transform(instance).origin.is_equal_approx(placement.transform.origin + expected_lift):
				lift_mismatches += 1
			var brightness := shading.brightness(sample)
			if not batch.multimesh.use_colors or not _colors_match(_instance_color(instance), Color(brightness, brightness, brightness, 1.0)):
				color_mismatches += 1
			var tint := _instance_color(instance)
			drawn = Color(minf(base.r * tint.r, 1.0), minf(base.g * tint.g, 1.0), minf(base.b * tint.b, 1.0), 1.0)
		if placement.archetype_id == &"debris":
			worst_archetype_seen = true
		# Against the ground the lifted body actually overlaps, not only the ground at its foot:
		# up to 52 px away, where the slope bound allows the drawn ground to differ by about 5%.
		var foot_contrast := _contrast(drawn, _drawn_ground_color(ground, definition.play_area, placement.transform.origin))
		var contrast := _contrast(drawn, _drawn_ground_color(ground, definition.play_area, placement.transform.origin + expected_lift))
		min_foot_contrast = minf(min_foot_contrast, foot_contrast)
		if contrast < min_contrast:
			min_contrast = contrast
			min_contrast_id = "%s %s h=%.1f" % [placement.stable_id, key, sample.ground_height]
		if contrast < TerrainShading.BODY_CONTRAST_FLOOR:
			contrast_failures += 1
	print("production seed=%d solids=%d decoratives=%d lift_mismatches=%d color_mismatches=%d heights=%.1f..%.1f min_contrast_at_body=%.3f at %s min_contrast_at_foot=%.3f contrast_failures=%d" % [seed, solids, decoratives, lift_mismatches, color_mismatches, lowest, highest, min_contrast, min_contrast_id, min_foot_contrast, contrast_failures])
	_check(solids > 0 and decoratives > 0, "seed %d places both solids and decoratives" % seed)
	_check(highest - lowest > 2.0 * SIGN_FLIP_BAND_FLOOR, "seed %d objects span %.1f px of ground height, so the checks cover real relief" % [seed, highest - lowest])
	_check(highest >= SIGN_FLIP_BAND_FLOOR, "seed %d has an object at +%.1f px, inside the band where unshaded trees vanished" % [seed, highest])
	_check(lift_mismatches == 0, "seed %d: every object is lifted by the car-path map's height at its foot (%d mismatches)" % [seed, lift_mismatches])
	_check(color_mismatches == 0, "seed %d: every object is coloured from the car-path map's sample at its foot (%d mismatches)" % [seed, color_mismatches])
	_check(worst_archetype_seen, "seed %d places debris, the archetype with the lowest base ratio, so the floor is tested where it is tightest" % seed)
	_check(contrast_failures == 0, "seed %d: every object, solid or decorative, keeps %.2f of contrast against the ground drawn where its lifted body sits (min %.3f at %s)" % [seed, TerrainShading.BODY_CONTRAST_FLOOR, min_contrast, min_contrast_id])
	runtime.free()
	return true


## Pins the sped-up physics to the production step, as vehicle_terrain_test does: a level-ground
## coast from the seat speed must match the integrator's longitudinal model tick for tick.
func _verify_physics_step() -> bool:
	var context := _make_car(HeightQuery.new(), Issue4TestSurfaceProvider.new(), Transform2D(PI * 0.5, Vector2.ZERO), Vector2(APPROACH_SPEED, 0.0))
	var car: TopDownCar = context.car
	var ticks := 90
	for tick in ticks:
		await physics_frame
	var speed := APPROACH_SPEED
	var distance := 0.0
	for tick in ticks:
		var drag := (_tuning.rolling_drag * absf(speed) + _tuning.aerodynamic_drag * speed * speed) * TICK
		speed = move_toward(speed, 0.0, drag)
		distance += speed * TICK
	print("physics_step ticks=%d real=%.4f model=%.4f travelled=%.1f model_distance=%.1f ticks_per_second=%d time_scale=%.1f" % [ticks, car.get_speed(), speed, car.global_position.x, distance, Engine.physics_ticks_per_second, Engine.time_scale])
	_check(absf(car.get_speed() - speed) < 0.05, "a level coast matches the integrator's model to 0.05 px/s (%.4f against %.4f), so the step is the production 1 / 60 s" % [car.get_speed(), speed])
	# The physics server moves the body by one step of its seed velocity before the integrator's
	# first tick sees it, so the distance is allowed that one step of slack.
	_check(absf(car.global_position.x - distance) < APPROACH_SPEED * TICK, "the car travelled the distance %d production ticks of the model imply (%.1f against %.1f px)" % [ticks, car.global_position.x, distance])
	context.world.queue_free()
	await process_frame
	return true


func _make_car(height_query: HeightQuery, surface_query: SurfaceQuery, transform: Transform2D, velocity: Vector2 = Vector2.ZERO) -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = _tuning
	car.global_transform = transform
	car.set_surface_query(surface_query)
	car.set_height_query(height_query)
	world.add_child(car)
	car.set_auto_reset_enabled(false)
	car.linear_velocity = velocity
	return {"world": world, "car": car}


## Holds the car still at the pose until it is on the ground, then releases it at the speed.
func _seat_car(car: TopDownCar, pose: Transform2D, velocity: Vector2) -> bool:
	car.global_transform = pose
	car.linear_velocity = Vector2.ZERO
	car.angular_velocity = 0.0
	car.sleeping = false
	car.set_height_query(car.get_meta("height_map"))
	var settled := not car.is_airborne()
	for tick in SETTLE_TICKS:
		if settled:
			break
		await physics_frame
		car.global_transform = pose
		car.linear_velocity = Vector2.ZERO
		car.angular_velocity = 0.0
		settled = not car.is_airborne()
	car.global_transform = pose
	car.linear_velocity = velocity
	car.angular_velocity = 0.0
	car.sleeping = false
	return settled


## The rocks the reach is measured against: the generated ones, or under the mutation a placement
## with no recovery corridor and every hazard cell a rock, right up to the road edge.
func _rocks_for(definition: TrackDefinition) -> Array[OfftrackObjectPlacement]:
	var placements: Array[OfftrackObjectPlacement] = definition.offtrack_objects
	if _break_corridor:
		var catalog := _object_catalog.duplicate(true) as OfftrackObjectCatalog
		catalog.solid_clearance = 0.0
		catalog.near_max_distance = 0.0
		catalog.hazard_occupancy = 1.0
		for archetype in catalog.archetypes:
			archetype.hazard_weight = 1.0 if archetype.id == &"rock" else 0.0
		placements = OfftrackObjectPlacer.new().place(definition, catalog).placements
	var rocks: Array[OfftrackObjectPlacement] = []
	for placement in placements:
		if placement.solid and placement.archetype_id == &"rock":
			rocks.append(placement)
	return rocks


## One launch: the car seated before the ramp's foot on the heading, released at the seat speed,
## followed until it lands. Returns the pass record; `result` accumulates the sweep's maxima.
func _launch(car: TopDownCar, map: TrackHeightMap, surface: TrackSurfaceMap, definition: TrackDefinition, ramp: JumpRampPlacement, rocks: Array[OfftrackObjectPlacement], rock_grounds: PackedFloat64Array, degrees: float, fraction: float, result: Dictionary) -> Dictionary:
	var axis := ramp.transform.x.normalized()
	var perpendicular := Vector2(-axis.y, axis.x)
	var half_width: float = definition.track_width * 0.5
	var direction := axis.rotated(deg_to_rad(degrees))
	var seat_offset := half_width * fraction
	var seat := ramp.transform.origin - direction * (ramp.half_length + APPROACH_BEFORE_FOOT) + perpendicular * seat_offset
	var pose := Transform2D(direction.angle() + PI * 0.5, seat)
	var settled := await _seat_car(car, pose, direction * APPROACH_SPEED)
	var throttle := VehicleInputState.new()
	throttle.throttle = 1.0
	car.set_input_state(throttle)
	var rock_radius := _object_catalog.archetype_by_id(&"rock").collision_radius
	var record := {"launched": false, "settled": settled, "crest_speed": 0.0, "launch_ground": 0.0, "landing_ground": 0.0, "beyond_edge_above": 0.0, "beyond_edge_engine": 0.0, "beyond_edge_airborne": 0.0, "peak_above_ground": 0.0, "min_separation": INF, "min_separation_engine": INF, "min_separation_airborne": INF, "nearest_rock": "", "nearest_rock_engine": "", "engine_height": 0.0, "ticks_above": 0, "ticks_engine": 0, "centreline_fallbacks": 0}
	for tick in REACH_TICKS:
		await physics_frame
		var position := car.global_position
		if car.is_airborne():
			var ground := map.sample_at(position).ground_height
			var above_ground := car.get_height() - ground
			if not record.launched:
				record.launched = true
				record.crest_speed = car.get_speed()
				record.launch_ground = ground
			record.peak_above_ground = maxf(record.peak_above_ground, above_ground)
			var centreline := surface.distance_to_centerline(position, CENTRELINE_SEARCH_RADIUS)
			# A lookup that finds no centreline within the radius is counted, not silently turned
			# into a large reach; the sweep asserts the count is zero.
			var beyond_edge := CENTRELINE_SEARCH_RADIUS - half_width
			if is_finite(centreline):
				beyond_edge = maxf(centreline - half_width, 0.0)
			else:
				record.centreline_fallbacks += 1
			record.beyond_edge_airborne = maxf(record.beyond_edge_airborne, beyond_edge)
			var mask_dropped_low := car.get_collision_level_mask() == TopDownCar.TALL_LAYER
			# Reach past the edge is a field measure, taken while the car is above the clearance
			# over the ground beneath it; each rock below is scored against its own ground.
			var above_clearance := above_ground > _tuning.low_obstacle_clearance
			if mask_dropped_low:
				record.ticks_engine += 1
				record.beyond_edge_engine = maxf(record.beyond_edge_engine, beyond_edge)
			if above_clearance:
				record.ticks_above += 1
				record.beyond_edge_above = maxf(record.beyond_edge_above, beyond_edge)
			for index in rocks.size():
				var rock := rocks[index]
				var separation := position.distance_to(rock.transform.origin) - (rock_radius * rock.scale_factor + CAR_COLLISION_RADIUS)
				record.min_separation_airborne = minf(record.min_separation_airborne, separation)
				if mask_dropped_low and separation < record.min_separation_engine:
					record.min_separation_engine = separation
					record.nearest_rock_engine = rock.stable_id
					record.engine_height = above_ground
				# The physical frame: the car's height against the rock's top, which stands
				# low_obstacle_clearance above the rock's own ground.
				if car.get_height() - rock_grounds[index] > _tuning.low_obstacle_clearance and separation < record.min_separation:
					record.min_separation = separation
					record.nearest_rock = rock.stable_id
		elif record.launched:
			record.landing_ground = map.sample_at(position).ground_height
			break
	car.set_input_state(VehicleInputState.new())
	result.passes += 1
	if record.launched:
		result.launched += 1
	if record.beyond_edge_above > result.beyond_edge_above:
		result.beyond_edge_above = record.beyond_edge_above
		result.longest = {"seed": definition.seed, "ramp": ramp.stable_id, "degrees": degrees, "fraction": fraction, "crest_speed": record.crest_speed, "launch_ground": record.launch_ground, "landing_ground": record.landing_ground, "peak_above_ground": record.peak_above_ground}
	result.beyond_edge_engine = maxf(result.beyond_edge_engine, record.beyond_edge_engine)
	result.beyond_edge_airborne = maxf(result.beyond_edge_airborne, record.beyond_edge_airborne)
	result.ticks_above += record.ticks_above
	result.ticks_engine += record.ticks_engine
	result.centreline_fallbacks += record.centreline_fallbacks
	if record.min_separation_engine < result.min_separation_engine:
		result.min_separation_engine = record.min_separation_engine
		result.closest_engine = {"seed": definition.seed, "ramp": ramp.stable_id, "rock": record.nearest_rock_engine, "degrees": degrees, "fraction": fraction, "crest_speed": record.crest_speed, "height_above_ground_there": record.engine_height, "launch_ground": record.launch_ground}
	result.min_separation_airborne = minf(result.min_separation_airborne, record.min_separation_airborne)
	if record.min_separation < result.min_separation:
		result.min_separation = record.min_separation
		result.closest = {"seed": definition.seed, "ramp": ramp.stable_id, "rock": record.nearest_rock, "degrees": degrees, "fraction": fraction, "crest_speed": record.crest_speed}
	if record.beyond_edge_above > 0.0:
		result.ramp_reaches["%d:%s" % [definition.seed, ramp.stable_id]] = maxf(float(result.ramp_reaches.get("%d:%s" % [definition.seed, ramp.stable_id], 0.0)), record.beyond_edge_above)
	if record.min_separation <= 0.0:
		result.reachable.append("seed %d ramp %s rock %s heading %.0f deg seat %.1f crest %.1f px/s" % [definition.seed, ramp.stable_id, record.nearest_rock, degrees, fraction, record.crest_speed])
	if not settled:
		result.unsettled += 1
	return record


func _new_sweep_result() -> Dictionary:
	return {"passes": 0, "launched": 0, "unsettled": 0, "ticks_above": 0, "beyond_edge_above": 0.0, "beyond_edge_engine": 0.0, "beyond_edge_airborne": 0.0, "min_separation": INF, "min_separation_engine": INF, "min_separation_airborne": INF, "reachable": [], "longest": {}, "closest": {}, "closest_engine": {}, "ramp_reaches": {}, "rocks": 0, "ramps": 0, "ticks_engine": 0, "centreline_fallbacks": 0}


func _sweep(definition: TrackDefinition, ramps: Array[JumpRampPlacement], headings: Array, fractions: Array, result: Dictionary) -> bool:
	var map := TrackHeightMap.new(definition)
	var surface := TrackSurfaceMap.new(definition)
	var context := _make_car(map, surface, definition.spawn_transform)
	var car: TopDownCar = context.car
	car.set_meta("height_map", map)
	var all_rocks := _rocks_for(definition)
	for ramp in ramps:
		var rocks: Array[OfftrackObjectPlacement] = []
		var rock_grounds := PackedFloat64Array()
		for rock in all_rocks:
			if rock.transform.origin.distance_to(ramp.transform.origin) <= ROCK_SEARCH_RADIUS:
				rocks.append(rock)
				rock_grounds.append(map.sample_at(rock.transform.origin).ground_height)
		result.rocks += rocks.size()
		result.ramps += 1
		for degrees in headings:
			for fraction in fractions:
				await _launch(car, map, surface, definition, ramp, rocks, rock_grounds, float(degrees), float(fraction), result)
	context.world.queue_free()
	await process_frame
	return true


func _nearest_solid_beyond_edge() -> float:
	var nearest := INF
	for seed in SEED_COUNT:
		var definition := _definition(seed)
		var surface := TrackSurfaceMap.new(definition)
		var half_width: float = definition.track_width * 0.5
		for placement in definition.offtrack_objects:
			if placement.solid:
				nearest = minf(nearest, surface.distance_to_centerline(placement.transform.origin, _object_catalog.hazard_max_distance + definition.track_width) - half_width)
	return nearest


## #37's measurement, re-run on terrain. Sideways reach past the road edge is measured while the
## car is above the clearance height over the ground beneath it, and, separately, while the car's
## own mask has dropped the low layer, which today compares its absolute height. Every generated
## rock near each ramp is checked against the flight directly, each in the frame its top is in:
## the car's height against the rock's own ground plus the clearance. So the verdict does not rest
## on the corridor rule alone. Whichever way the numbers land, they are pinned here.
func _verify_rock_reachability() -> bool:
	var rocks_total := 0
	var rocks_above_clearance := 0
	for seed in SEED_COUNT:
		var definition := _definition(seed)
		var map := TrackHeightMap.new(definition)
		for placement in definition.offtrack_objects:
			if placement.solid and placement.archetype_id == &"rock":
				rocks_total += 1
				if map.sample_at(placement.transform.origin).ground_height > _tuning.low_obstacle_clearance:
					rocks_above_clearance += 1
	print("rocks seeds=%d total=%d standing_above_clearance_height=%d clearance_px=%.1f" % [SEED_COUNT, rocks_total, rocks_above_clearance, _tuning.low_obstacle_clearance])
	var coarse := _new_sweep_result()
	var started := Time.get_ticks_usec()
	for seed in SEED_COUNT:
		var definition := _definition(seed)
		_check(not definition.jump_ramps.is_empty(), "seed %d has a ramp to launch from" % seed)
		await _sweep(definition, definition.jump_ramps, COARSE_HEADINGS_DEGREES, COARSE_LATERAL_FRACTIONS, coarse)
	var coarse_seconds := (Time.get_ticks_usec() - started) / 1e6
	_print_sweep("coarse", coarse, coarse_seconds)
	_check(coarse.ramps == 48, "every ramp of seeds 0..19 was swept (%d)" % coarse.ramps)
	_check(coarse.rocks > 0, "rocks near the ramps were checked against the flights (%d)" % coarse.rocks)
	_check(coarse.unsettled == 0, "every pass started from a grounded car (%d did not)" % coarse.unsettled)
	_check(coarse.launched >= coarse.passes / 2, "at least half the sweep left the ground (%d of %d), so the maximum is taken over the envelope" % [coarse.launched, coarse.passes])
	_check(coarse.ticks_above > 0 and coarse.beyond_edge_above > 0.0, "the sweep observed flight past the road edge above the clearance, so the reach is measured rather than vacuous")
	_check(coarse.ticks_engine > 0 and coarse.beyond_edge_engine > 0.0, "the sweep observed flight past the road edge with the low layer dropped from the car's mask (%d ticks), so the engine-frame figures are measured rather than vacuous" % coarse.ticks_engine)
	_check(coarse.ramp_reaches.size() >= FINE_RAMPS, "at least %d ramps produced flight above the clearance past the edge (%d), so the refinement below has real candidates" % [FINE_RAMPS, coarse.ramp_reaches.size()])
	# Refine at #37's angular resolution on the ramps the coarse sweep found reaching furthest.
	var ranked: Array = coarse.ramp_reaches.keys()
	ranked.sort_custom(func(a, b): return coarse.ramp_reaches[a] > coarse.ramp_reaches[b])
	var fine_headings: Array = []
	for degrees in range(-FINE_HEADING_LIMIT, FINE_HEADING_LIMIT + 1, FINE_HEADING_STEP):
		fine_headings.append(degrees)
	var fine := _new_sweep_result()
	started = Time.get_ticks_usec()
	var fine_ramps: Array = []
	for rank in mini(FINE_RAMPS, ranked.size()):
		var key: String = ranked[rank]
		var seed := int(key.get_slice(":", 0))
		var ramp_id := key.substr(key.find(":") + 1)
		var single: Array[JumpRampPlacement] = []
		for ramp in _definition(seed).jump_ramps:
			if ramp.stable_id == ramp_id:
				single.append(ramp)
		_check(single.size() == 1, "refined ramp %s is a placed ramp of seed %d" % [ramp_id, seed])
		fine_ramps.append({"seed": seed, "ramps": single})
		await _sweep(_definition(seed), single, fine_headings, FINE_LATERAL_FRACTIONS, fine)
	_print_sweep("fine", fine, (Time.get_ticks_usec() - started) / 1e6)
	# Attribution, not a bound: the longest-reach ramp swept again on a flat base, so the share of
	# the reach that is terrain rather than the full-throttle crest is visible in the trace.
	var flat := _new_sweep_result()
	if not fine_ramps.is_empty():
		var flat_definition := _definition(fine_ramps[0].seed).duplicate() as TrackDefinition
		flat_definition.terrain_seed = 0
		await _sweep(flat_definition, fine_ramps[0].ramps, fine_headings, FINE_LATERAL_FRACTIONS, flat)
	_print_sweep("flat", flat, 0.0)
	_check(flat.launched > 0 and flat.beyond_edge_above > 0.0, "the flat-base sweep of the same ramp launched and reached past the edge, so the terrain's share of the reach is measured against something")
	var reach_above := maxf(coarse.beyond_edge_above, fine.beyond_edge_above)
	var reach_engine := maxf(coarse.beyond_edge_engine, fine.beyond_edge_engine)
	var reach_airborne := maxf(coarse.beyond_edge_airborne, fine.beyond_edge_airborne)
	var min_separation := minf(coarse.min_separation, fine.min_separation)
	var min_separation_engine := minf(coarse.min_separation_engine, fine.min_separation_engine)
	var min_separation_airborne := minf(coarse.min_separation_airborne, fine.min_separation_airborne)
	var reachable: Array = coarse.reachable + fine.reachable
	var nearest_solid := _nearest_solid_beyond_edge()
	var longest: Dictionary = fine.longest if fine.beyond_edge_above >= coarse.beyond_edge_above else coarse.longest
	var closest_engine: Dictionary = fine.closest_engine if fine.min_separation_engine <= coarse.min_separation_engine else coarse.closest_engine
	print("reach summary seeds=%d max_beyond_edge_above_local_clearance_px=%.1f max_beyond_edge_engine_mask_px=%.1f max_beyond_edge_airborne_px=%.1f nearest_solid_beyond_edge_px=%.1f rule_min_beyond_edge_px=%.1f gap_px=%.1f engine_gap_px=%.1f min_rock_separation_above_clearance_px=%.1f min_rock_separation_engine_mask_px=%.1f min_rock_separation_airborne_px=%.1f reachable=%d" % [
		SEED_COUNT, reach_above, reach_engine, reach_airborne, nearest_solid, _object_catalog.solid_clearance, nearest_solid - reach_above, nearest_solid - reach_engine, min_separation, min_separation_engine, min_separation_airborne, reachable.size()
	])
	print("reach summary longest=%s" % [longest])
	print("reach summary closest_engine=%s" % [closest_engine])
	for line in reachable:
		print("reach reachable %s" % line)
	# The finding. No generated rock is within reach of any flight above the clearance in seeds
	# 0..19, by direct comparison against every rock near every ramp; the corridor rule still holds
	# the above-clearance reach off; but the whole envelope, at any height, now reaches past the
	# rule, so #37's envelope-versus-nearest-solid bound is retired and the per-rock separations
	# stand in its place. If a later change moves any of this, the lines below say so.
	_check(coarse.centreline_fallbacks + fine.centreline_fallbacks + flat.centreline_fallbacks == 0, "every airborne tick found the centreline within %.0f px (%d fallbacks), so no reach figure was manufactured by a failed lookup" % [CENTRELINE_SEARCH_RADIUS, coarse.centreline_fallbacks + fine.centreline_fallbacks + flat.centreline_fallbacks])
	_check(is_finite(min_separation) and is_finite(min_separation_engine), "both separations were measured against real rocks (physical %.1f px, engine %.1f px), neither left at its initial infinity" % [min_separation, min_separation_engine])
	_check(reachable.is_empty(), "no generated rock in seeds 0..19 is reachable from a flight above the clearance over that rock's own ground (%d reachable)" % reachable.size())
	_check(min_separation > 0.0, "the closest a flight above a rock's clearance came to that rock's contact distance is %.1f px, on the far side of it" % min_separation)
	_check(min_separation_engine > 0.0, "the closest a flight with the low layer dropped from the car's mask came to a rock's contact distance is %.1f px, on the far side of it" % min_separation_engine)
	_check(reach_above < _object_catalog.solid_clearance, "a flight drifts at most %.1f px past the road edge while above the clearance, against the catalog's %.1f px corridor" % [reach_above, _object_catalog.solid_clearance])
	_check(reach_airborne >= _object_catalog.solid_clearance, "the whole flight envelope (%.1f px past the road edge) now exceeds the %.1f px corridor rule, so the rule alone no longer proves a rock out of reach and the per-rock checks above carry the finding; if this fails, the envelope has shrunk and docs/height-channel.md must say so" % [reach_airborne, _object_catalog.solid_clearance])
	return true


func _print_sweep(label: String, result: Dictionary, seconds: float) -> void:
	print("reach %s ramps=%d rocks_near_ramps=%d passes=%d launched=%d unsettled=%d ticks_above_clearance=%d max_beyond_edge_airborne_px=%.1f max_beyond_edge_above_local_clearance_px=%.1f max_beyond_edge_engine_mask_px=%.1f min_rock_separation_above_clearance_px=%.1f min_rock_separation_engine_mask_px=%.1f min_rock_separation_airborne_px=%.1f ramps_with_reach=%d ticks_engine_mask=%d centreline_fallbacks=%d seconds=%.1f" % [
		label, result.ramps, result.rocks, result.passes, result.launched, result.unsettled, result.ticks_above, result.beyond_edge_airborne, result.beyond_edge_above, result.beyond_edge_engine, result.min_separation, result.min_separation_engine, result.min_separation_airborne, result.ramp_reaches.size(), result.ticks_engine, result.centreline_fallbacks, seconds
	])
	print("reach %s longest=%s" % [label, result.longest])
	print("reach %s closest=%s" % [label, result.closest])
	print("reach %s closest_engine=%s" % [label, result.closest_engine])


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Off-track object terrain checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Off-track object terrain check failed: %s" % failure)
	quit(1)
