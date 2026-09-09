extends SceneTree

## TrackHeightMap answers terrain plus ramps summed. The generator attaches the terrain seed and
## fingerprint on both exit paths without moving any of the three fingerprints the earlier epics
## pinned; inside a ramp the sample is terrain plus wedge and outside every ramp it is terrain
## alone; the ramp's lateral edge, which was a vertical wall, is now a smooth flank the car rides
## onto; the flank's own curvature stays under the lift-off threshold at the speed a car can carry
## onto it from off-track; and above that speed the hop a crossing produces is bounded by the
## flank's geometry, measured at max_safe_speed. Mutations:
##   -- --break-side-wall        zeroes the fixture ramp's flank width, restoring the hard lateral
##                               cut of #37, so the crossing car passes under the wedge again
##   -- --break-flank-curvature  quarters the flank width, so the flank's curvature breaks the
##                               crossing-speed bound, launches the slow crossing car, and throws
##                               the fast one higher than the crest

const TERRAIN_CATALOG_PATH := "res://data/default_terrain_catalog.tres"
const HEIGHT_CATALOG_PATH := "res://data/default_height_channel_catalog.tres"
const OBJECT_CATALOG_PATH := "res://data/default_offtrack_object_catalog.tres"
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const SEED_COUNT := 20
const BROKEN_FLANK_FACTOR := 0.25
## Geometry, off-track object and height fingerprints for seeds 0-19, dumped from the generator
## at 19015e4, before terrain was attached. Every one must survive byte for byte.
const FINGERPRINTS := {
	0: ["c473c35414d6ee31c9abada0c4d5fe4856997f137ca8d7dd6223a45da29bf55f", "5f587a1b70ce3300729a390f555f277329c0d3e2e385891396868da5470bac88", "6831dab8217f2bd2a407a9d2caf3cb7946c1671b3b3947d6b98ebde1b8537571"],
	1: ["b4b5a88a8be258e58c43567bb2e1ffc9364f21c98bae38ee92e0a087de9fa90e", "a6e2ba9fb9a8ac7f43b29874878529b37cb3f368bcd382e2a7346760e895a9f7", "9f1c710cdeeb30dc42a32d8e1ec301f58be9773e9a6a2b17e9b9c2ebc4a31a9c"],
	2: ["d1e5d0df9651e041374342582d1cccf79193fe8ecb95796baac1eb19217bd7ea", "308f0795be1df084a297b4e74971d17be10297420df51c6297fbe28606594d28", "605602a82d56acdeca82f15c3a21fb5027badf331afd279d841561dd15ab6578"],
	3: ["a1e4ab9b4425050a266ac40d2bb958b99d303303192c241c02b0822912ed078d", "8222001966fe85a9b0df8c1abdc5e4172586c18b702ea3891fce5309e8c2a0d9", "be4eeef9dc1a7bfd33a079936574ee5f9ec19bf5203b4b9a4d31580560a0adae"],
	4: ["4600dc93fe343e17e999276b333051a9538f51c50d02992863af9b4970779155", "e48a8ef915e3eb316784300ad5f26189d7f157ab2c0f4bdfad733d0e676c2348", "bc1b6b7292003777c764d44b9cb4220992588a101ebf36c041c752d5929ef71f"],
	5: ["8d530ec157495015293c77e77d2b3f9dfb458db272c3176b1f11bc9e495716b5", "23565fec72cb77b09ef01fae6966bf754460768b30697939a5273e380df4523a", "bf4188c776f2b2ae44c87f649734e69036cc23a57bf2989d02e9a300fd29d2b8"],
	6: ["7fad0c2e88fccb083da767eba455a3b50ed248e8fea025fb43500d14e3ab04d9", "1c92f61706ca488261612277291ffbb8cfe076fec6df9d36471026adf6b2c59e", "e13abf9d5acd3f2d2f7b6712bba7512ed1d23a00214220f0728ea6068e245009"],
	7: ["ed6a92a5ee67e6e67f147fe6382bb266afe356d1de03cdc2322fdeb1d28c2af8", "9a3965d30d5b18ddeb963f2af4b3acfdb2ecf2d598e21ecd159037a8d9987fd2", "01b34f74e5e185293c1b6111e3a53995a8eb93735b875b997f1801560d35a4f0"],
	8: ["d0ff3f39294c44e16a182eabc0283b23842801ce6617c1f79a66001d93929aef", "7ab67ac9cd411656a5799f04904d19de9bf6142212e79d063fd230274ec52a47", "b704d6f0b745f71da5a47b24c1d6d504420d4e88f60c930b18ad74fc1766c4be"],
	9: ["3fbe38ff1f6a222c0050cc004bddf93225b5da99176639d4b22f5934ece85670", "7f5a46301fead1d1514cabb3d0b82f207e210d88a1ef1b46d246695f782aaa6b", "443869d91e6ff837e081ef3e50aef759946bf2bf101312e89e4a2d091ab85c9e"],
	10: ["56c585fc00729f4416cd459c57e7b6821b101a83374f9bb2e7443f6633546c42", "4fa89cd904ad87ea423b28f3ad382d563525354a5ff317f1bf9449e72e7dd2d5", "ab36c60bb88410129bbe15244c0f7ea37c53b45d59ef64ee57ad7cc10f13f336"],
	11: ["f0237efe220f89c01733e293d377a299f1c39b88843c992b5006bc0512ba51b0", "ce168f228e687a01bfdfc0dc5cb043a5b7555ea3f0a9877a13574de16f2b5e61", "e9ed445b2926eae68b1e57f35087c43a8eb01e617bb1db042697ce9fe50d5a6f"],
	12: ["5331af0ca10b06d73cb47223caf72bebfa0c87c53df04951a395c24e2646976f", "8c9512f41ea4fcb539b6c2b5dbc1475b06cd274cbf243a8ce6272ac79df2f2e2", "db6d8bdb4cd91b54f7ea631b3d62429d2dcdec18a26c918a5b201454b8b197ef"],
	13: ["a3b44cf2ccee2206c308f0bdc1af8324e32767e59152061a174b887ad3db97a2", "765febb166d37358cf41515ecebe5ac3aa314ff0f5136b83cf31455dd1458852", "1b9690103b4c9e03cffa08c1d4e301edd31c79a72f8ab5c8dd5a34ab3939275c"],
	14: ["72af4a69dc7a4a8c5924348879c45258c9fd047fdcf325774a44ba025b781633", "24b85a0a988cc5c7f76b9d74615e8c35d68f0d74bb323d89764b62b6a1233132", "fee3ceaac918daf9740baba1976ca2e9d32471137f25cb714f0d90b81b5deff9"],
	15: ["3c2386bfa626521b3ba4996c2191cefb6902728d9c1ec80c9bd18b8a7c30fa34", "6060ea3ec4be6e5684247648357331687cf19d318fb493c802608099d89fd622", "9f18398c73c00acfe11f2ca007b629c974bb4210fb7859e431615a6a9a968818"],
	16: ["97458ea8106f57c08f45cc2f6d35611be28bd03e40dcc57431022e129a2d1bb9", "2c7dbb2314d629d893c06757e9c960c155be26fb7dfcc6e95dcb3ac6751a2288", "6352695a13800db1c3f94fa9356d7f009f9a36558314977ee07b099bc8999bc1"],
	17: ["497f951e560567f3ed51b523ded8761dbad88e94fa347124e56ece7911b60cf4", "97198fba598f07593c8b9af43619979916abc23956b60e591203c57a5664e85f", "6a2f187aada88834c671fd147c17de8dc93dbb0bfb9d864592600b03a35d8596"],
	18: ["4018845b4baf9e1d3da8b49fc42d02b832771c952fb0616de956b13a150a4597", "d3a77402e5dd1b77ac221b57f466b0ac1825934d022ea7318d42177b0cf3ffff", "aa3f167e270c8cbbac0eb4b6881afb84e44b6f23fd64e8c4217333c6e29f1672"],
	19: ["1ccbbd249025dfc5f5d8a05f60fa43933f023bd34cfa38d66d42d66bc066bbda", "ee5073557e8b04df7f95c075a37edc7cbd1d00b731b2760c62a84c892afc3016", "a173fe174f3a2ce3d1b93ca14827ed92af72d25f7e4e69c65357076f391d8af1"],
}
## Seed 17 limited to one attempt takes the fallback stadium: the generator's second exit path.
const FALLBACK_SEED := 17
const FALLBACK_FINGERPRINTS := ["497f951e560567f3ed51b523ded8761dbad88e94fa347124e56ece7911b60cf4", "97198fba598f07593c8b9af43619979916abc23956b60e591203c57a5664e85f", "6a2f187aada88834c671fd147c17de8dc93dbb0bfb9d864592600b03a35d8596"]
const TRANSECT_STEP := 0.5
const CURVATURE_STEP := 1.0
## Vector2 is float32, so a seat computed as "halfway up the face" lands within a few 1e-4 px of
## it; at the wedge's 0.06 slope that is a few 1e-5 px of height. The sum itself is float64.
const SEAT_TOLERANCE := 1e-3
## jump_ramp_placement_test budgets the ramp-only map at ten thousand queries in 20 ms and still
## holds it. With terrain on every query the field's three octaves cost about 4 us a query in
## GDScript after #47's allocation-free evaluation and cell cache (about 9 us before them), so
## the terrain-bearing budget is 60 ms: 6 us a query, or 12 us for the car's two queries a tick,
## under a tenth of a percent of a 60 Hz tick. The pre-#47 field measured over 90 ms here, so the
## budget separates the optimised path from the unoptimised one. Each pattern is timed three times
## and the median is asserted, so one descheduled slice on a busy host does not fail the suite the
## way the off-track performance budgets are documented to.
const QUERY_COUNT := 10000
const QUERY_BUDGET_USEC := 60000
const TIMING_RUNS := 3
## The driven path circles at this turn rate: 10 px a tick at 0.03 rad a tick is a loop about
## 330 px across, so the whole path stays inside cells the warm-up lap has already touched and
## the measurement is the steady per-tick cost rather than first-touch corner hashing.
const PATH_TURN_RATE := 0.03
const CROSSING_TICKS := 400
## The crossing car starts this far outside the flank's outer edge.
const CROSSING_RUN_UP := 60.0
const TICK := 1.0 / 60.0

var _failures: Array[String] = []
var _checks := 0
var _sections := 0
var _break_side_wall := false
var _break_flank := false


func _initialize() -> void:
	_break_side_wall = OS.get_cmdline_user_args().has("--break-side-wall")
	_break_flank = OS.get_cmdline_user_args().has("--break-flank-curvature")
	call_deferred("_run")


func _run() -> void:
	_section(_verify_generator_attaches_terrain(), "the generator attachment verification ran to completion")
	_section(_verify_fingerprints_unchanged(), "the fingerprint verification ran to completion")
	_section(_verify_sum_inside_and_outside_ramps(), "the sum verification ran to completion")
	_section(_verify_continuity_across_the_lateral_edge(), "the continuity verification ran to completion")
	_section(_verify_flank_curvature_is_bounded(), "the flank curvature verification ran to completion")
	_section(await _verify_car_rides_onto_the_flank(false), "the flat-base flank crossing verification ran to completion")
	_section(await _verify_car_rides_onto_the_flank(true), "the terrain-base flank crossing verification ran to completion")
	_section(await _verify_fast_flank_crossing_hop_is_bounded(false), "the flat-base fast crossing verification ran to completion")
	_section(await _verify_fast_flank_crossing_hop_is_bounded(true), "the terrain-base fast crossing verification ran to completion")
	_section(_verify_shared_sample_discipline_with_terrain(), "the shared sample verification ran to completion")
	_section(_verify_query_cost(), "the query cost verification ran to completion")
	_section(_verify_road_flatten_width_is_gone(), "the dead field verification ran to completion")
	_finish()


func _height_catalog() -> HeightChannelCatalog:
	var catalog := load(HEIGHT_CATALOG_PATH) as HeightChannelCatalog
	if _break_flank:
		var narrow := catalog.duplicate(true) as HeightChannelCatalog
		narrow.flank_width *= BROKEN_FLANK_FACTOR
		print("break_flank_curvature flank_width=%.1f" % narrow.flank_width)
		return narrow
	return catalog


## Counts the documented grid by walking it: a sample at the origin and one every spacing until the
## far edge is passed, on each axis. Built differently from the field's own arithmetic on purpose.
func _fingerprint_samples(area: Rect2) -> int:
	var spacing: float = TerrainField.FINGERPRINT_SPACING
	var columns := 0
	var x := area.position.x
	while x <= area.end.x:
		columns += 1
		x += spacing
	var rows := 0
	var y := area.position.y
	while y <= area.end.y:
		rows += 1
		y += spacing
	return columns * rows


func _verify_generator_attaches_terrain() -> bool:
	var catalog := load(TERRAIN_CATALOG_PATH) as TerrainCatalog
	var generator := TrackGenerator.new()
	var accepted: TrackDefinition = generator.generate(0)
	var fallback: TrackDefinition = generator.generate(FALLBACK_SEED, {"max_attempts": 1})
	_check(not accepted.used_fallback, "seed 0 is an accepted candidate, the generator's first exit path")
	_check(fallback.used_fallback, "seed %d with one attempt is the fallback stadium, the generator's second exit path" % FALLBACK_SEED)
	for definition: TrackDefinition in [accepted, fallback]:
		var label := "seed %d%s" % [definition.seed, " (fallback)" if definition.used_fallback else ""]
		_check(definition.terrain_seed == DomainSeed.derive(catalog.version, definition.seed, "terrain"), "%s carries the terrain domain seed" % label)
		# Rebuilt from the attached seed and the shipped catalog, over the area the definition
		# documents, so the fingerprint is tied to the definition and not merely non-empty.
		var independent := TerrainField.new(definition.terrain_seed, catalog)
		_check(definition.terrain_fingerprint == independent.fingerprint(definition.play_area), "%s terrain fingerprint is the field's fingerprint over the play area" % label)
		_check(definition.terrain_generation_usec > 0, "%s records terrain generation time (%d us)" % [label, definition.terrain_generation_usec])
		for key in ["octaves", "fingerprint_samples", "total_amplitude", "curvature_bound"]:
			_check(definition.terrain_diagnostics.has(key), "%s terrain diagnostics report %s" % [label, key])
		_check(int(definition.terrain_diagnostics.get("fingerprint_samples", -1)) == _fingerprint_samples(definition.play_area), "%s diagnostics count the fingerprint grid over the play area" % label)
		_check(int(definition.terrain_diagnostics.get("octaves", -1)) == catalog.octaves, "%s diagnostics carry the catalog octave count" % label)
		print("%s terrain_seed=%d fingerprint=%s samples=%d usec=%d" % [label, definition.terrain_seed, definition.terrain_fingerprint, int(definition.terrain_diagnostics.get("fingerprint_samples", -1)), definition.terrain_generation_usec])
	var other: TrackDefinition = generator.generate(1)
	_check(other.terrain_fingerprint != accepted.terrain_fingerprint, "seeds 0 and 1 carry different terrain fingerprints")
	_check(other.terrain_seed != accepted.terrain_seed, "seeds 0 and 1 carry different terrain seeds")
	return true


func _verify_fingerprints_unchanged() -> bool:
	var generator := TrackGenerator.new()
	for seed in range(SEED_COUNT):
		var definition: TrackDefinition = generator.generate(seed)
		var pinned: Array = FINGERPRINTS[seed]
		_check(definition.geometry_fingerprint == pinned[0], "seed %d geometry fingerprint is byte-identical to the pre-terrain pin" % seed)
		_check(definition.offtrack_object_fingerprint == pinned[1], "seed %d off-track object fingerprint is byte-identical to the pre-terrain pin" % seed)
		_check(definition.height_fingerprint == pinned[2], "seed %d height fingerprint is byte-identical to the pre-terrain pin" % seed)
		_check(definition.terrain_fingerprint != "", "seed %d carries a terrain fingerprint while the other three held" % seed)
	var fallback: TrackDefinition = generator.generate(FALLBACK_SEED, {"max_attempts": 1})
	_check(fallback.geometry_fingerprint == FALLBACK_FINGERPRINTS[0], "fallback geometry fingerprint is byte-identical to the pre-terrain pin")
	_check(fallback.offtrack_object_fingerprint == FALLBACK_FINGERPRINTS[1], "fallback off-track object fingerprint is byte-identical to the pre-terrain pin")
	_check(fallback.height_fingerprint == FALLBACK_FINGERPRINTS[2], "fallback height fingerprint is byte-identical to the pre-terrain pin")
	return true


## Inside a ramp the sample is the terrain sample plus the wedge; outside every ramp it is the
## terrain sample, bit for bit. The terrain side comes from an independent field built from the
## definition's own seed, never from the map.
func _verify_sum_inside_and_outside_ramps() -> bool:
	var catalog := load(TERRAIN_CATALOG_PATH) as TerrainCatalog
	var definition: TrackDefinition = TrackGenerator.new().generate(0)
	var field := TerrainField.new(definition.terrain_seed, catalog)
	var map := TrackHeightMap.new(definition)
	_check(map.has_terrain(), "a map built from a generated definition carries terrain")
	_check(definition.jump_ramps.size() >= 1, "seed 0 places at least one ramp to sum onto terrain (%d)" % definition.jump_ramps.size())
	var half_width: float = definition.track_width * 0.5
	for ramp: JumpRampPlacement in definition.jump_ramps:
		var axis := ramp.transform.x.normalized()
		var lateral := ramp.transform.y.normalized()
		var slope := ramp.crest_height / ramp.half_length
		var crest := ramp.transform.origin
		# The crest, and halfway up the rising face at the centreline and a pixel inside both road
		# edges: the on-road wedge is unchanged by the flank.
		var seats := [
			[crest, ramp.crest_height, Vector2.ZERO],
			[crest - axis * ramp.half_length * 0.5, ramp.crest_height * 0.5, axis * slope],
			[crest - axis * ramp.half_length * 0.5 + lateral * (half_width - 1.0), ramp.crest_height * 0.5, axis * slope],
			[crest - axis * ramp.half_length * 0.5 - lateral * (half_width - 1.0), ramp.crest_height * 0.5, axis * slope],
			[crest + axis * ramp.half_length * 0.5, ramp.crest_height * 0.5, -axis * slope],
		]
		for seat: Array in seats:
			var position: Vector2 = seat[0]
			var terrain := field.sample_at(position)
			var sample := map.sample_at(position)
			_check(absf(sample.ground_height - (terrain.ground_height + float(seat[1]))) < SEAT_TOLERANCE, "ramp %s: height at (%.1f, %.1f) is terrain plus %.2f" % [ramp.stable_id, position.x, position.y, float(seat[1])])
			_check(sample.gradient.is_equal_approx(terrain.gradient + Vector2(seat[2])), "ramp %s: gradient at (%.1f, %.1f) is terrain plus the wedge gradient" % [ramp.stable_id, position.x, position.y])
			_check(terrain.ground_height != 0.0, "ramp %s: terrain under (%.1f, %.1f) is not flat, so the sum is not a sum with zero" % [ramp.stable_id, position.x, position.y])
	var outside := 0
	for position in _positions_outside_every_ramp(definition, 12):
		var terrain := field.sample_at(position)
		var sample := map.sample_at(position)
		outside += 1
		_check(sample.ground_height == terrain.ground_height, "outside every ramp, height at (%.1f, %.1f) is the terrain height bit for bit" % [position.x, position.y])
		_check(sample.gradient == terrain.gradient, "outside every ramp, gradient at (%.1f, %.1f) is the terrain gradient bit for bit" % [position.x, position.y])
	_check(outside == 12, "twelve positions outside every ramp were found (%d)" % outside)
	var flat := TrackHeightMap.new(TrackDefinition.new())
	_check(not flat.has_terrain(), "a definition without a terrain seed builds a map without terrain")
	_check(flat.sample_at(Vector2(123.0, 456.0)).ground_height == 0.0, "a map without terrain is flat")
	return true


## Deterministic scatter across the play area, keeping only positions clear of every ramp's reach.
func _positions_outside_every_ramp(definition: TrackDefinition, count: int) -> Array[Vector2]:
	var positions: Array[Vector2] = []
	var area := definition.play_area
	var golden := 0.7548776662466927
	var golden_2 := 0.5698402909980532
	var index := 0
	while positions.size() < count and index < 1000:
		var candidate := area.position + Vector2(fmod(0.5 + float(index) * golden, 1.0) * area.size.x, fmod(0.5 + float(index) * golden_2, 1.0) * area.size.y)
		index += 1
		var clear := true
		for ramp: JumpRampPlacement in definition.jump_ramps:
			var reach := ramp.half_length + definition.track_width + ramp.flank_width
			if candidate.distance_to(ramp.transform.origin) <= reach:
				clear = false
		if clear:
			positions.append(candidate)
	return positions


## A lateral transect through the crest of a generated ramp on real terrain: from beyond one flank
## across the road to beyond the other. The total height must be continuous everywhere, with the
## old wall's position no different from anywhere else; and its second difference must stay
## inside the analytic bound, so the flank meets the terrain without a step in the second
## derivative either. With the hard cut of #37 the first difference at the road edge is the whole
## crest height and the second difference is thousands of times the bound.
func _verify_continuity_across_the_lateral_edge() -> bool:
	var terrain_catalog := load(TERRAIN_CATALOG_PATH) as TerrainCatalog
	var height_catalog := _height_catalog()
	var definition: TrackDefinition = TrackGenerator.new().generate(0)
	var ramp: JumpRampPlacement = definition.jump_ramps[0].duplicate() as JumpRampPlacement
	ramp.flank_width = height_catalog.flank_width
	var fixture := TrackDefinition.new()
	fixture.track_width = definition.track_width
	fixture.terrain_seed = definition.terrain_seed
	fixture.jump_ramps.append(ramp)
	var map := TrackHeightMap.new(fixture)
	var field := TerrainField.new(fixture.terrain_seed, terrain_catalog)
	var half_width := ramp.width * 0.5
	var flank := ramp.flank_width
	var lateral := ramp.transform.y.normalized()
	var crest := ramp.transform.origin
	var extent := half_width + flank + 50.0
	var steps := int(round(2.0 * extent / TRANSECT_STEP))
	var heights := PackedFloat64Array()
	for step in range(steps + 1):
		var offset := -extent + float(step) * TRANSECT_STEP
		heights.append(map.sample_at(crest + lateral * offset).ground_height)
	var slope_bound := sqrt(2.0) * terrain_catalog.slope_bound() + ramp.crest_height * TerrainCatalog.FADE_PEAK_SLOPE / maxf(flank, 1e-9)
	var largest_jump := 0.0
	var largest_jump_at := 0.0
	for step in range(1, heights.size()):
		var jump := absf(heights[step] - heights[step - 1])
		if jump > largest_jump:
			largest_jump = jump
			largest_jump_at = -extent + float(step) * TRANSECT_STEP
	print("transect largest_jump=%.6f at=%.1f allowed=%.6f crest=%.2f" % [largest_jump, largest_jump_at, slope_bound * TRANSECT_STEP, ramp.crest_height])
	_check(largest_jump <= slope_bound * TRANSECT_STEP + 1e-9, "no two samples %.1f px apart across the ramp differ by more than the slope bound allows (%.6f)" % [TRANSECT_STEP, largest_jump])
	_check(largest_jump > 0.1 * slope_bound * TRANSECT_STEP, "the transect has real slope in it (%.6f), so the jump bound is not passing on flat ground" % largest_jump)
	for side: float in [-1.0, 1.0]:
		for edge_name: String in ["road edge", "flank edge"]:
			var edge := half_width if edge_name == "road edge" else half_width + flank
			var inside := map.sample_at(crest + lateral * side * (edge - 0.5 * TRANSECT_STEP)).ground_height
			var beyond := map.sample_at(crest + lateral * side * (edge + 0.5 * TRANSECT_STEP)).ground_height
			_check(absf(beyond - inside) <= slope_bound * TRANSECT_STEP + 1e-9, "the %s on side %+.0f is no step: %.6f px across %.1f px" % [edge_name, side, absf(beyond - inside), TRANSECT_STEP])
	# Second differences at 1 px against the analytic bound on the summed field's curvature.
	var curvature_bound := terrain_catalog.curvature_bound() + height_catalog.flank_curvature_bound()
	var largest_second := 0.0
	var largest_second_at := 0.0
	var second_steps := int(round(2.0 * extent / CURVATURE_STEP))
	for step in range(1, second_steps):
		var offset := -extent + float(step) * CURVATURE_STEP
		# The crest line itself is the wedge's own kink; every other position along the transect
		# is inside a flank, on the road, or on terrain.
		var left := map.sample_at(crest + lateral * (offset - CURVATURE_STEP)).ground_height
		var centre := map.sample_at(crest + lateral * offset).ground_height
		var right := map.sample_at(crest + lateral * (offset + CURVATURE_STEP)).ground_height
		var second := absf(left - 2.0 * centre + right) / (CURVATURE_STEP * CURVATURE_STEP)
		if second > largest_second:
			largest_second = second
			largest_second_at = offset
	print("transect largest_second_difference=%.9f at=%.1f bound=%.9f" % [largest_second, largest_second_at, curvature_bound])
	_check(largest_second <= curvature_bound + 1e-7, "the second difference across the transect stays inside the summed curvature bound (%.9f of %.9f)" % [largest_second, curvature_bound])
	_check(largest_second > 0.25 * height_catalog.flank_curvature_bound(), "the second difference reaches a real fraction of the flank bound (%.9f), so the flank's curvature is being measured" % largest_second)
	# The wedge on the road is the wedge, the flank halfway across is half of it, and beyond the
	# flank there is only terrain.
	var on_road := map.sample_at(crest + lateral * (half_width - 1.0)).ground_height - field.height_at(crest + lateral * (half_width - 1.0))
	var mid_flank := map.sample_at(crest + lateral * (half_width + 0.5 * flank)).ground_height - field.height_at(crest + lateral * (half_width + 0.5 * flank))
	var beyond_flank := map.sample_at(crest + lateral * (half_width + flank + 1.0)).ground_height
	_check(absf(on_road - ramp.crest_height) < SEAT_TOLERANCE, "a pixel inside the road edge the wedge is at full crest height on terrain (%.6f)" % on_road)
	_check(absf(mid_flank - 0.5 * ramp.crest_height) < SEAT_TOLERANCE, "halfway across the flank the wedge is at half crest height (%.6f)" % mid_flank)
	_check(beyond_flank == field.height_at(crest + lateral * (half_width + flank + 1.0)), "a pixel beyond the flank is terrain alone, bit for bit")
	return true


## The flank adds curvature the terrain bound does not cover. Its analytic bound is checked
## against a brute-force sweep of the map's own gradient over a ramp on real terrain, and the
## summed bound must stay under the lift-off curvature at the speed a car can carry onto a flank:
## the off-track terminal speed, derived from the tuning and the surface map rather than pinned.
## A car can cross a flank faster only by leaving the road, and then it is leaving anyway.
func _verify_flank_curvature_is_bounded() -> bool:
	var terrain_catalog := load(TERRAIN_CATALOG_PATH) as TerrainCatalog
	var height_catalog := _height_catalog()
	var object_catalog := load(OBJECT_CATALOG_PATH) as OfftrackObjectCatalog
	var tuning := load(TUNING_PATH) as VehicleTuning
	# Worked from the pinned numbers, never from the catalog's own derivation.
	var expected_bound := 9.0 * (10.0 / sqrt(3.0) / (250.0 * 250.0) + 15.0 / 8.0 / (250.0 * 150.0))
	if not _break_flank:
		_check(is_equal_approx(height_catalog.flank_width, WorldScale.metres(20.0)), "flank width is 20 m")
		_check(absf(height_catalog.flank_curvature_bound() - expected_bound) < 1e-12, "flank curvature bound is crest times (peak fade curvature over flank squared plus peak fade slope over flank times half length)")
		_check(absf(height_catalog.flank_curvature_bound() - 1.281384e-3) < 1e-9, "flank curvature bound is 1.281384e-3 per px")
	_check(height_catalog.flank_width <= object_catalog.solid_clearance, "the flank (%.1f px) ends where solids may begin (%.1f px), so no solid ever sits on one" % [height_catalog.flank_width, object_catalog.solid_clearance])
	_check(height_catalog.flank_width > 0.0, "the shipped flank has width, so the lateral edge is not the hard cut")
	# Off-track terminal speed: engine at the off-track multiplier balances rolling and aerodynamic
	# drag at the surface map's grass factor times the tuning's off-track factor.
	var acceleration := tuning.engine_force * tuning.off_track_engine_multiplier / tuning.mass_kg
	var drag_factor := TrackSurfaceMap.GRASS_DRAG * tuning.off_track_drag_multiplier
	var quadratic := tuning.aerodynamic_drag * drag_factor
	var linear := tuning.rolling_drag * drag_factor
	var terminal_speed := (-linear + sqrt(linear * linear + 4.0 * quadratic * acceleration)) / (2.0 * quadratic)
	var lift_off_curvature := tuning.gravity / (terminal_speed * terminal_speed)
	var summed_bound := terrain_catalog.curvature_bound() + height_catalog.flank_curvature_bound()
	var launch_speed := sqrt(tuning.gravity / summed_bound)
	print("offtrack_terminal_speed=%.1f px/s (%.1f km/h) lift_off_curvature=%.9f terrain_bound=%.9f flank_bound=%.9f summed=%.9f flank_launch_speed=%.1f px/s (%.1f km/h)" % [terminal_speed, WorldScale.to_kph(terminal_speed), lift_off_curvature, terrain_catalog.curvature_bound(), height_catalog.flank_curvature_bound(), summed_bound, launch_speed, WorldScale.to_kph(launch_speed)])
	_check(absf(terminal_speed - 158.5) < 0.5, "the off-track terminal speed derives to 158.5 px/s (%.1f)" % terminal_speed)
	_check(summed_bound < lift_off_curvature, "terrain plus flank curvature (%.9f) stays under the lift-off curvature at the off-track terminal speed (%.9f)" % [summed_bound, lift_off_curvature])
	_check(launch_speed < tuning.max_safe_speed, "the flank can still launch a car below max_safe_speed (%.1f < %.1f px/s), so the bound is a bound and not a vacuous one" % [launch_speed, tuning.max_safe_speed])
	# Brute force: the map's gradient, finite-differenced over a generated ramp's flanks on real
	# terrain, must never exceed the analytic sum, and must come close enough to it that the sweep
	# is measuring the flank and not empty ground.
	var definition: TrackDefinition = TrackGenerator.new().generate(0)
	var ramp: JumpRampPlacement = definition.jump_ramps[0].duplicate() as JumpRampPlacement
	ramp.flank_width = height_catalog.flank_width
	var fixture := TrackDefinition.new()
	fixture.track_width = definition.track_width
	fixture.terrain_seed = definition.terrain_seed
	fixture.jump_ramps.append(ramp)
	var map := TrackHeightMap.new(fixture)
	var half_width := ramp.width * 0.5
	var axis := ramp.transform.x.normalized()
	var lateral := ramp.transform.y.normalized()
	var sampled_max := 0.0
	var sampled_max_at := Vector2.ZERO
	var evaluations := 0
	var along := -ramp.half_length + 2.0
	while along <= ramp.half_length - 2.0:
		# Skip the wedge's own kink at the crest line: the stencil must not straddle it.
		if absf(along) > CURVATURE_STEP:
			for side: float in [-1.0, 1.0]:
				var across := half_width + 1.0
				while across <= half_width + ramp.flank_width - 1.0:
					var position := ramp.transform.origin + axis * along + lateral * side * across
					var radius := _sampled_curvature(map, position)
					evaluations += 1
					if radius > sampled_max:
						sampled_max = radius
						sampled_max_at = Vector2(along, side * across)
					across += 2.0
		along += 4.0
	print("flank_sweep sampled_max=%.9f at_local=(%.1f, %.1f) summed_bound=%.9f evaluations=%d" % [sampled_max, sampled_max_at.x, sampled_max_at.y, summed_bound, evaluations])
	_check(sampled_max <= summed_bound + 1e-7, "the sampled curvature on the flanks (%.9f) never exceeds the summed analytic bound (%.9f)" % [sampled_max, summed_bound])
	_check(sampled_max > 0.5 * height_catalog.flank_curvature_bound(), "the sampled curvature reaches half the flank bound (%.9f), so the sweep is measuring the flank" % sampled_max)
	_check(sampled_max < lift_off_curvature, "the sampled flank curvature stays under the lift-off curvature at the off-track terminal speed")
	return true


## Spectral radius of the Hessian finite-differenced from the map's gradient.
func _sampled_curvature(map: TrackHeightMap, position: Vector2) -> float:
	var right := map.sample_at(position + Vector2(CURVATURE_STEP, 0.0)).gradient
	var left := map.sample_at(position - Vector2(CURVATURE_STEP, 0.0)).gradient
	var up := map.sample_at(position + Vector2(0.0, CURVATURE_STEP)).gradient
	var down := map.sample_at(position - Vector2(0.0, CURVATURE_STEP)).gradient
	var hxx := (right.x - left.x) / (2.0 * CURVATURE_STEP)
	var hyy := (up.y - down.y) / (2.0 * CURVATURE_STEP)
	var hxy := 0.5 * ((right.y - left.y) + (up.x - down.x)) / (2.0 * CURVATURE_STEP)
	var mean := 0.5 * (hxx + hyy)
	var half_difference := 0.5 * (hxx - hyy)
	return absf(mean) + sqrt(half_difference * half_difference + hxy * hxy)


## The defect #37 deferred, driven live. A production car crosses a ramp's lateral edge at the
## off-track terminal speed, coming from outside the flank. It must ride the ground the whole way
## -- its ride height within half a pixel of the map under it on every tick -- never lift off, and
## arrive on the crest line at the crest height. Under --break-side-wall the flank is the hard
## cut again and the car stays at ground level under the wedge.
func _verify_car_rides_onto_the_flank(on_terrain: bool) -> bool:
	var label := "on terrain" if on_terrain else "on a flat base"
	var tuning := load(TUNING_PATH) as VehicleTuning
	var crossing_speed := _offtrack_terminal_speed(tuning)
	# Enough throttle on the test's dirt to hold the crossing speed against drag.
	var throttle := (tuning.rolling_drag * crossing_speed + tuning.aerodynamic_drag * crossing_speed * crossing_speed) * tuning.mass_kg / tuning.engine_force
	var trace := await _drive_flank_crossing(on_terrain, crossing_speed, throttle)
	var crest_height: float = trace.crest_height
	print("crossing %s: ticks=%d speed_at_road_edge=%.1f speed_at_crest=%.1f worst_gap=%.4f at=(%.1f, %.1f) peak_wedge=%.3f crest=%.3f launched=%s" % [label, trace.ticks, trace.speed_at_road_edge, trace.speed_at_crest, trace.worst_gap, trace.worst_gap_at.x, trace.worst_gap_at.y, trace.peak_wedge, crest_height, trace.launched])
	_check(trace.has_terrain == on_terrain, "%s: the crossing map carries terrain as intended" % label)
	_check(trace.reached_crest_line, "%s: the car reaches the crest line within %d ticks" % [label, CROSSING_TICKS])
	_check(trace.speed_at_road_edge > 0.8 * crossing_speed, "%s: the car crosses the road edge near the off-track terminal speed (%.1f of %.1f px/s)" % [label, trace.speed_at_road_edge, crossing_speed])
	_check(not trace.launched, "%s: the car never leaves the ground crossing the flank" % label)
	_check(trace.worst_gap < 0.5, "%s: the car's ride height tracks the map under it on every tick (worst gap %.4f px)" % [label, trace.worst_gap])
	_check(trace.peak_wedge >= crest_height - 0.5, "%s: the car arrives on the crest line at the crest height above terrain (%.3f of %.3f px), riding onto the wedge instead of under it" % [label, trace.peak_wedge, crest_height])
	if on_terrain:
		_check(trace.terrain_under_crest != 0.0, "%s: the terrain under the crest line is not flat (%.3f px)" % [label, trace.terrain_under_crest])
		_check(absf(trace.crest_ground - trace.terrain_under_crest - crest_height) < 1e-6, "%s: the crest line is terrain plus the crest height" % label)
	return true


## The flank is bounded against the off-track terminal speed, sixteen times looser than #49's
## max_safe_speed bound on the terrain, so above 289 px/s a lateral crossing launches the car. The
## controller's ruling (#47 fix round 1) keeps that threshold and bounds the consequence instead:
## the flank's whole relief is the crest height, so the hop is bounded by geometry whatever the
## speed. Measured here at max_safe_speed: the car leaves the ground, and the peak of its height
## above the map under it stays under the ballistic apex of the fade's peak slope at that speed,
## (max_safe_speed * crest * FADE_PEAK_SLOPE / flank)^2 / 2g, and under the crest height. Under
## --break-flank-curvature the quartered flank throws the car well above the crest.
func _verify_fast_flank_crossing_hop_is_bounded(on_terrain: bool) -> bool:
	var label := "fast crossing on terrain" if on_terrain else "fast crossing on a flat base"
	var tuning := load(TUNING_PATH) as VehicleTuning
	var trace := await _drive_flank_crossing(on_terrain, tuning.max_safe_speed, 1.0)
	var crest_height: float = trace.crest_height
	var flank: float = trace.flank_width
	var peak_slope := crest_height * TerrainCatalog.FADE_PEAK_SLOPE / maxf(flank, 1e-9)
	var apex_bound := pow(tuning.max_safe_speed * peak_slope, 2.0) / (2.0 * tuning.gravity)
	print("%s: ticks=%d speed_at_road_edge=%.1f launched=%s launch_y=%.1f launch_vz=%.2f landing_y=%.1f air_ticks=%d peak_hop=%.3f at=(%.1f, %.1f) apex_bound=%.3f crest=%.3f flank=%.1f" % [label, trace.ticks, trace.speed_at_road_edge, trace.launched, trace.launch_y, trace.launch_vz, trace.landing_y, trace.air_ticks, trace.peak_hop, trace.peak_hop_at.x, trace.peak_hop_at.y, apex_bound, crest_height, flank])
	_check(trace.speed_at_road_edge >= 0.9 * tuning.max_safe_speed, "%s: the car reaches the road edge near max_safe_speed (%.1f of %.1f px/s)" % [label, trace.speed_at_road_edge, tuning.max_safe_speed])
	_check(trace.launched, "%s: the crossing leaves the ground, so the hop bound below is measured on a real hop" % label)
	_check(trace.launch_y != INF and trace.launch_y < 0.0 and trace.launch_y > -(0.5 * trace.width + flank), "%s: lift-off happens on the near flank (y=%.1f)" % [label, trace.launch_y])
	_check(trace.landing_y != INF, "%s: the car lands again within the crossing (y=%.1f)" % [label, trace.landing_y])
	_check(trace.peak_hop > 1.0, "%s: the hop is real (%.3f px), so the bound is not passing on a grounded crossing" % [label, trace.peak_hop])
	_check(trace.peak_hop <= apex_bound, "%s: the peak hop above the map (%.3f px) stays under the ballistic apex of the fade's peak slope at max_safe_speed (%.3f px)" % [label, trace.peak_hop, apex_bound])
	_check(apex_bound < crest_height, "%s: the analytic apex bound (%.3f px) is itself under the crest height, so the geometric bound is the binding one" % [label, apex_bound])
	_check(is_equal_approx(flank, 250.0), "%s: the crossed flank is the shipped 20 m, 250 px (%.1f)" % [label, flank])
	return true


## Off-track terminal speed: engine at the off-track multiplier balances rolling and aerodynamic
## drag at the surface map's grass factor times the tuning's off-track factor.
func _offtrack_terminal_speed(tuning: VehicleTuning) -> float:
	var acceleration := tuning.engine_force * tuning.off_track_engine_multiplier / tuning.mass_kg
	var drag_factor := TrackSurfaceMap.GRASS_DRAG * tuning.off_track_drag_multiplier
	var quadratic := tuning.aerodynamic_drag * drag_factor
	var linear := tuning.rolling_drag * drag_factor
	return (-linear + sqrt(linear * linear + 4.0 * quadratic * acceleration)) / (2.0 * quadratic)


## Drives a production car straight across a catalog ramp's flank, from CROSSING_RUN_UP outside it
## toward the crest line, at the given initial speed with the given throttle held, until it is on
## or past the crest line and grounded, or past the far flank, or out of ticks. Returns the trace
## the crossing verifications assert on; frees the scene before returning.
func _drive_flank_crossing(on_terrain: bool, speed: float, throttle: float) -> Dictionary:
	var terrain_catalog := load(TERRAIN_CATALOG_PATH) as TerrainCatalog
	var height_catalog := _height_catalog()
	var tuning := load(TUNING_PATH) as VehicleTuning
	var ramp := JumpRampPlacement.new()
	ramp.stable_id = "h3:0:0:0"
	ramp.transform = Transform2D(0.0, Vector2.ZERO)
	ramp.half_length = height_catalog.half_length
	ramp.crest_height = height_catalog.crest_height()
	ramp.width = 240.0
	ramp.flank_width = 0.0 if _break_side_wall else height_catalog.flank_width
	if _break_side_wall:
		print("break_side_wall flank_width=%.1f" % ramp.flank_width)
	var definition := TrackDefinition.new()
	definition.track_width = ramp.width
	if on_terrain:
		definition.terrain_seed = DomainSeed.derive(terrain_catalog.version, 0, "terrain")
	definition.jump_ramps.append(ramp)
	var map := TrackHeightMap.new(definition)
	# Only a terrain base has a field under it; TerrainField.new(0, ...) would be a real field.
	var field := TerrainField.new(definition.terrain_seed, terrain_catalog) if on_terrain else null
	var half_width := ramp.width * 0.5
	var far_edge := half_width + height_catalog.flank_width + CROSSING_RUN_UP
	var start_y := -far_edge

	var world := Node2D.new()
	root.add_child(world)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = tuning
	# Rotation PI points the car's forward axis along +Y, straight across the ramp.
	car.global_transform = Transform2D(PI, Vector2(0.0, start_y))
	car.set_surface_query(Issue4TestSurfaceProvider.new())
	car.set_height_query(map)
	world.add_child(car)
	car.set_safe_reset_pose(car.global_transform)
	car.linear_velocity = Vector2(0.0, speed)
	var controls := VehicleInputState.new()
	controls.throttle = throttle
	car.set_input_state(controls)
	var trace := {
		"has_terrain": map.has_terrain(),
		"crest_height": ramp.crest_height,
		"width": ramp.width,
		"flank_width": ramp.flank_width,
		"ticks": 0, "launched": false, "reached_crest_line": false,
		"worst_gap": 0.0, "worst_gap_at": Vector2.ZERO,
		"peak_wedge": 0.0, "peak_hop": 0.0, "peak_hop_at": Vector2.ZERO,
		"speed_at_road_edge": 0.0, "speed_at_crest": 0.0,
		"launch_y": INF, "launch_vz": 0.0, "landing_y": INF, "air_ticks": 0,
		"crest_ground": map.sample_at(Vector2.ZERO).ground_height,
		"terrain_under_crest": field.height_at(Vector2.ZERO) if on_terrain else 0.0,
	}
	var was_airborne := false
	for tick in range(CROSSING_TICKS):
		await physics_frame
		trace.ticks += 1
		var position := car.global_position
		var ground := map.sample_at(position).ground_height
		var above := car.get_height() - ground
		if absf(above) > trace.worst_gap:
			trace.worst_gap = absf(above)
			trace.worst_gap_at = position
		if above > trace.peak_hop:
			trace.peak_hop = above
			trace.peak_hop_at = position
		var airborne := car.is_airborne()
		if airborne:
			trace.air_ticks += 1
			if not was_airborne and trace.launch_y == INF:
				trace.launch_y = position.y
				trace.launch_vz = car.get_vertical_velocity()
		elif was_airborne and trace.landing_y == INF:
			trace.landing_y = position.y
		was_airborne = airborne
		trace.launched = trace.launched or airborne
		trace.peak_wedge = maxf(trace.peak_wedge, car.get_height() - (field.height_at(position) if on_terrain else 0.0))
		if trace.speed_at_road_edge == 0.0 and position.y >= -half_width:
			trace.speed_at_road_edge = car.get_speed()
		if position.y >= 0.0 and not trace.reached_crest_line:
			trace.speed_at_crest = car.get_speed()
			trace.reached_crest_line = true
		if (trace.reached_crest_line and not airborne) or position.y >= far_edge:
			break
	world.queue_free()
	await process_frame
	return trace


## The miss path hands back one shared sample, now carrying terrain rather than zeros, rewritten on
## every return. A consumer writing through it must not corrupt the next query, and the next query
## must be the terrain sample of its own position, not the poisoned values or the previous ones.
func _verify_shared_sample_discipline_with_terrain() -> bool:
	var catalog := load(TERRAIN_CATALOG_PATH) as TerrainCatalog
	var definition: TrackDefinition = TrackGenerator.new().generate(0)
	var field := TerrainField.new(definition.terrain_seed, catalog)
	var map := TrackHeightMap.new(definition)
	var positions := _positions_outside_every_ramp(definition, 2)
	_check(positions.size() == 2, "two positions outside every ramp were found for the discipline check")
	if positions.size() < 2:
		return false
	var poisoned := map.sample_at(positions[0])
	poisoned.ground_height = 123.0
	poisoned.gradient = Vector2(7.0, 9.0)
	var next := map.sample_at(positions[1])
	_check(next == poisoned, "the miss path returns the same shared sample object, so the discipline is exercised and not bypassed by an allocation")
	_check(next.ground_height == field.height_at(positions[1]), "a miss query after a consumer writes to the shared sample reads its own terrain height")
	_check(next.gradient == field.sample_at(positions[1]).gradient, "a miss query after a consumer writes to the shared sample reads its own terrain gradient")
	_check(next.ground_height != 123.0 and next.gradient != Vector2(7.0, 9.0), "the poison did not survive")
	return true


## Terrain now runs on every query. Two patterns: the placement suite's line of queries through
## the ramps, and the car's own pattern of two samples a tick along a wandering path.
func _verify_query_cost() -> bool:
	var definition: TrackDefinition = TrackGenerator.new().generate(0)
	var map := TrackHeightMap.new(definition)
	_check(map.has_terrain(), "the query cost is measured with terrain on")
	var origin: Vector2 = definition.jump_ramps[0].transform.origin
	var axis: Vector2 = definition.jump_ramps[0].transform.x.normalized()
	# Warm the lattice cells both patterns touch, as the game does on its first frames.
	_time_line_queries(map, origin, axis)
	_time_path_queries(map, origin, axis)
	var line_times: Array[int] = []
	var path_times: Array[int] = []
	for run in range(TIMING_RUNS):
		line_times.append(_time_line_queries(map, origin, axis))
		path_times.append(_time_path_queries(map, origin, axis))
	line_times.sort()
	path_times.sort()
	var line_usec: int = line_times[TIMING_RUNS / 2]
	var path_usec: int = path_times[TIMING_RUNS / 2]
	print("terrain_height_query_usec_per_10k line_median=%d path_median=%d line_runs=%s path_runs=%s" % [line_usec, path_usec, str(line_times), str(path_times)])
	_check(line_usec <= QUERY_BUDGET_USEC, "ten thousand terrain-bearing height queries along the ramp line (median %d us of %d runs) stay under %d us" % [line_usec, TIMING_RUNS, QUERY_BUDGET_USEC])
	_check(path_usec <= QUERY_BUDGET_USEC, "ten thousand terrain-bearing height queries along a driven path (median %d us of %d runs) stay under %d us" % [path_usec, TIMING_RUNS, QUERY_BUDGET_USEC])
	return true


## The placement suite's pattern: a line of queries through the ramps, one a pixel.
func _time_line_queries(map: TrackHeightMap, origin: Vector2, axis: Vector2) -> int:
	var started := Time.get_ticks_usec()
	var accumulated := 0.0
	for query in range(QUERY_COUNT):
		accumulated += map.sample_at(origin + axis * float(query % 8000 - 4000)).ground_height
	var elapsed := Time.get_ticks_usec() - started
	if accumulated == INF:
		print("unreachable, keeps the accumulator live")
	return elapsed


## The car's pattern: two samples a tick, 10 px apart, along a loop that stays in warmed cells.
func _time_path_queries(map: TrackHeightMap, origin: Vector2, axis: Vector2) -> int:
	var position := origin - axis * 500.0
	var direction := axis
	var started := Time.get_ticks_usec()
	var accumulated := 0.0
	for tick in range(QUERY_COUNT / 2):
		accumulated += map.sample_at(position).ground_height
		accumulated += map.sample_at(position + direction * 10.0).ground_height
		position += direction * 10.0
		direction = direction.rotated(PATH_TURN_RATE)
	var elapsed := Time.get_ticks_usec() - started
	if accumulated == INF:
		print("unreachable, keeps the accumulator live")
	return elapsed


## The road damping was withdrawn in #47's scope change; the field that carried its width must
## not survive as dead data.
func _verify_road_flatten_width_is_gone() -> bool:
	var catalog := load(TERRAIN_CATALOG_PATH) as TerrainCatalog
	var names := {}
	for property in catalog.get_property_list():
		names[property.name] = true
	_check(not names.has("road_flatten_width"), "TerrainCatalog no longer declares road_flatten_width")
	_check(names.has("amplitude"), "the property listing sees the catalog's real fields, so the absence above is not an empty listing")
	var text := FileAccess.get_file_as_string(TERRAIN_CATALOG_PATH)
	_check(text.find("road_flatten") == -1, "the shipped terrain catalog resource carries no road_flatten value")
	_check(text.find("amplitude") != -1, "the resource text was read, so the absence above is not an empty read")
	var source := FileAccess.get_file_as_string("res://world/terrain/terrain_catalog.gd")
	_check(source.find("damping envelope") == -1 and source.find("road_flatten") == -1, "the catalog docstring no longer describes the withdrawn damping envelope")
	return true


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


## A section's completion is a guard, not an assertion: it fails only when the section bailed out
## early, and it is not counted toward the check total the final line reports.
func _section(ran: bool, message: String) -> void:
	_sections += 1
	if ran:
		print("DONE: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Terrain height map checks passed: %d checks across %d sections" % [_checks, _sections])
		quit(0)
		return
	for failure in _failures:
		push_error("Terrain height map check failed: %s" % failure)
	quit(1)
