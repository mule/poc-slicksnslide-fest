extends SceneTree

## Elevation is drawn from the same height map the car drives on. The ground grid under the play
## area and the two road ribbons are tinted by the height and lit by the gradient that
## TrackHeightMap reports at each vertex; the car's own ride height and the tint under it are
## asserted to come from the same field at the same position; the light term flips sign across a
## crest; an off-track solid on raised ground casts a longer shadow than the same solid on flat
## ground; and rebuilding frees the previous shading rather than stacking a second grid on it.
##
## The agreement checks compare the runtime's map against a TrackHeightMap built the way the
## session builds the car's (`TrackHeightMap.new(definition)`), so a runtime that reconstructed
## the field independently -- a TerrainField from the track seed, or the terrain without the
## ramps -- fails them. That falsification is performed live in the task report, not by a flag:
## the shading has no production switch for sampling the wrong field.

const MAIN_SCENE_PATH := "res://session/main.tscn"
const TERRAIN_CATALOG_PATH := "res://data/default_terrain_catalog.tres"
const OBJECT_CATALOG_PATH := "res://data/default_offtrack_object_catalog.tres"
## Seeds 0 and 10 both place ramps, so the crest checks below are not vacuous, and seed 10's spawn
## sits 14 px up its terrain, so the spawn agreement is not agreement near zero.
const GRID_SEED := 0
const SESSION_SEED := 10
const RESTART_SEED := 5
## The spawn agreement is only meaningful on ground that is clearly not flat: a tenth of the
## catalog's total amplitude, 5.25 px.
const SPAWN_HEIGHT_FLOOR := 5.0
## Smallest luminance spread, absolute, the seed 0 ground grid must show: a relative spread would
## pass on a near-black base that a player could not read.
const GROUND_LUMINANCE_SPREAD := 0.15
## The production ramp crest height, from data/default_height_channel_catalog.tres.
const WEDGE_CREST := 9.0
## The session's background ColorRect. The ground grid must be this colour at zero height, so the
## play-area edge, where the grid stops and the background shows, is not a visible seam.
const BACKGROUND_NODE := "BackgroundLayer/Background"
## The shadow offset OfftrackObjectMeshFactory bakes into every solid: (0.32 m, 0.48 m).
const FACTORY_SHADOW_OFFSET := Vector2(4.0, 6.0)
## Terrain sampling costs about 4-5 us a query. The budget is three times that per sample, which
## leaves the colour arithmetic and the array writes inside it and still separates a per-vertex
## build from anything that samples finer than it claims. Median of three, as the other terrain
## suites do: two suites in this repo miss their budgets a third to two thirds of the time under
## load on a single run.
const PER_SAMPLE_BUDGET_USEC := 15.0
const TIMING_RUNS := 3
const COLOR_TOLERANCE := 1e-5

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(_verify_shade_terms(), "the shade term verification ran to completion")
	_check(_verify_light_flips_across_a_crest(), "the crest verification ran to completion")
	_check(_verify_ground_grid(), "the ground grid verification ran to completion")
	_check(_verify_ribbon_gradients(), "the ribbon gradient verification ran to completion")
	_check(_verify_wedges_shade_from_the_map(), "the wedge shading verification ran to completion")
	_check(await _verify_shading_agrees_with_the_car(), "the car agreement verification ran to completion")
	_check(_verify_object_shadows(), "the object shadow verification ran to completion")
	_check(await _verify_rebuild_frees_shading(), "the rebuild verification ran to completion")
	_check(_verify_build_cost(), "the build cost verification ran to completion")
	_finish()


func _shading() -> TerrainShading:
	return TerrainShading.new(load(TERRAIN_CATALOG_PATH) as TerrainCatalog)


func _sample(height: float, gradient: Vector2 = Vector2.ZERO) -> HeightQuery.HeightSample:
	return HeightQuery.HeightSample.new(height, gradient)


func _brightness(color: Color, base: Color) -> float:
	return color.r / base.r


func _verify_shade_terms() -> bool:
	var shading := _shading()
	var catalog := load(TERRAIN_CATALOG_PATH) as TerrainCatalog
	var base := Color("426b32")
	var flat := shading.shade(base, _sample(0.0))
	_check(flat.is_equal_approx(base), "flat, level ground is drawn in the base colour exactly")
	var raised := shading.shade(base, _sample(20.0))
	var lowered := shading.shade(base, _sample(-20.0))
	_check(_brightness(raised, base) > 1.0 + 1e-6 and _brightness(lowered, base) < 1.0 - 1e-6, "raised ground is brighter than the base and lowered ground darker")
	_check(is_equal_approx(_brightness(raised, base) - 1.0, 1.0 - _brightness(lowered, base)), "the height term is odd: +20 px brightens as much as -20 px darkens")
	_check(is_equal_approx(raised.g / base.g, raised.r / base.r) and is_equal_approx(raised.b / base.b, raised.r / base.r), "the height term scales every channel alike, so the hue survives")
	_check(is_equal_approx(raised.a, base.a), "shading leaves alpha alone")
	# The height term reaches full contrast at the catalog's total amplitude and not before, and
	# saturates beyond it: 52.5 px in the shipped catalog.
	var reference: float = catalog.total_amplitude()
	_check(is_equal_approx(shading.height_term(reference), 1.0) and is_equal_approx(shading.height_term(-reference), -1.0), "the height term is +-1 at +-total amplitude (%.1f px)" % reference)
	_check(is_equal_approx(shading.height_term(reference * 2.0), 1.0), "the height term saturates above the total amplitude")
	_check(is_equal_approx(shading.height_term(reference * 0.5), 0.5), "the height term is linear inside the amplitude")
	_check(is_equal_approx(_brightness(shading.shade(base, _sample(reference)), base), 1.0 + TerrainShading.HEIGHT_CONTRAST), "full height contrast is HEIGHT_CONTRAST")
	# The light comes from the top-left of the screen. A slope rising away from the light faces it
	# and brightens; one rising toward the light turns away and darkens; one running across the
	# light is unlit either way.
	_check(TerrainShading.LIGHT_DIRECTION.x < 0.0 and TerrainShading.LIGHT_DIRECTION.y < 0.0 and TerrainShading.LIGHT_DIRECTION.is_normalized(), "the light direction points to the screen's top-left and is a unit vector")
	_check(TerrainShading.SHADOW_DIRECTION.is_equal_approx(-TerrainShading.LIGHT_DIRECTION), "shadows fall directly away from the light")
	var slope_reference: float = catalog.slope_bound()
	var away := Vector2(1.0, 1.0).normalized() * slope_reference
	_check(shading.light_term(away) > 0.99 and shading.light_term(away) <= 1.0, "a slope at the slope bound rising away from the light is fully lit")
	_check(is_equal_approx(shading.light_term(-away), -shading.light_term(away)), "the same slope rising toward the light is fully in shade")
	_check(is_zero_approx(shading.light_term(Vector2(1.0, -1.0) * slope_reference)), "a slope across the light is unlit")
	_check(is_equal_approx(shading.light_term(away * 4.0), 1.0), "the light term saturates at the slope bound")
	_check(is_equal_approx(_brightness(shading.shade(base, _sample(0.0, away)), base), 1.0 + TerrainShading.SLOPE_CONTRAST), "full light contrast is SLOPE_CONTRAST")
	var both := shading.shade(base, _sample(reference, away))
	_check(is_equal_approx(_brightness(both, base), 1.0 + TerrainShading.HEIGHT_CONTRAST + TerrainShading.SLOPE_CONTRAST), "height and light add")
	# shade() clamps, so a clamped value against the clamp bound proves nothing; the intent is that no
	# fill colour blows out, so the PRE-clamp product is asserted for every fill the track draws.
	var peak: float = TerrainShading.peak_brightness()
	_check(is_equal_approx(peak, 1.0 + TerrainShading.HEIGHT_CONTRAST + TerrainShading.SLOPE_CONTRAST) and is_equal_approx(peak, 1.8), "the peak multiplier is full height plus full light, 1.8")
	for fill in [["ground", TerrainShading.GROUND_COLOR], ["grass", TrackRuntime.GRASS_COLOR], ["dirt", TrackRuntime.DIRT_COLOR], ["wedge", JumpRampVisuals.WEDGE_COLOR]]:
		var color: Color = fill[1]
		var brightest_channel := maxf(color.r, maxf(color.g, color.b)) * peak
		_check(brightest_channel <= 1.0, "%s at full height and full light stays inside the displayable range before the clamp (%.3f)" % [fill[0], brightest_channel])
	var edge_peak := maxf(TrackRuntime.EDGE_COLOR.r, maxf(TrackRuntime.EDGE_COLOR.g, TrackRuntime.EDGE_COLOR.b)) * peak
	print("edge_color_pre_clamp_peak=%.3f (documented: the 6 px boundary line may saturate at the extreme)" % edge_peak)
	_check(edge_peak > 1.0, "the boundary cream is the one base that can saturate, which the docs state; if it stops being so, drop the exception from them")
	_check(TerrainShading.HEIGHT_CONTRAST > 0.0 and TerrainShading.SLOPE_CONTRAST > 0.0, "both contrasts are positive, so the checks above test a direction and not a sign convention")
	shading.free()
	return true


## A symmetric hump along +x: the same height either side of the crest, mirrored gradients. The
## light term must change sign and nothing else.
func _verify_light_flips_across_a_crest() -> bool:
	var shading := _shading()
	var hump := HeightChannelTestHeightProvider.new()
	hump.mode = HeightChannelTestHeightProvider.Mode.HUMP
	hump.crest_x = 0.0
	var before := hump.sample_at(Vector2(-75.0, 0.0))
	var after := hump.sample_at(Vector2(75.0, 0.0))
	_check(is_equal_approx(before.ground_height, after.ground_height) and before.ground_height > 0.0, "the two probes sit at the same height on opposite faces")
	_check(before.gradient.is_equal_approx(-after.gradient) and not before.gradient.is_zero_approx(), "the two probes see mirrored gradients")
	var lit_before := shading.light_term(before.gradient)
	var lit_after := shading.light_term(after.gradient)
	_check(absf(lit_before) > 0.5, "the hump's 0.12 slope is a strong cue, not a rounding artefact (|term| %.3f)" % absf(lit_before))
	_check(is_equal_approx(lit_before, -lit_after), "the light term flips sign across the crest")
	_check(lit_before > 0.0, "the face rising toward +x, away from a top-left light, is the lit one")
	var base := Color("895426")
	var level := shading.shade(base, _sample(before.ground_height))
	var shade_before := shading.shade(base, before)
	var shade_after := shading.shade(base, after)
	_check(_brightness(shade_before, base) > _brightness(level, base) and _brightness(shade_after, base) < _brightness(level, base), "one face is brighter than level ground at its height and the other darker")
	_check(is_equal_approx(_brightness(shade_before, base) - _brightness(level, base), _brightness(level, base) - _brightness(shade_after, base)), "the two faces sit symmetrically about level ground at their height")
	shading.free()
	return true


## Counts the grid by walking it: a vertex at the origin and one every cell while inside the
## area, then one on the far edge. Written differently from the shading's own arithmetic.
func _walked_count(start: float, end: float, cell: float) -> int:
	var count := 0
	var x := start
	while x < end:
		count += 1
		x += cell
	return count + 1


func _verify_ground_grid() -> bool:
	var definition: TrackDefinition = TrackGenerator.new().generate(GRID_SEED)
	var runtime := TrackRuntime.new(definition)
	root.add_child(runtime)
	var shading := runtime.get_node_or_null("TerrainShading") as TerrainShading
	_check(shading != null, "the runtime mounts a TerrainShading layer")
	var ground := runtime.get_node_or_null("TerrainShading/Ground") as Polygon2D
	_check(ground != null, "the shading layer draws the ground as one Polygon2D")
	if shading == null or ground == null:
		runtime.free()
		return false
	_check(shading.z_index < -3, "the ground draws under the grass shoulder (z %d)" % shading.z_index)
	var area: Rect2 = definition.play_area
	var cell: float = TerrainShading.GROUND_CELL
	_check(is_equal_approx(cell, TerrainField.FINGERPRINT_SPACING), "the ground grid samples on the fingerprint and placement pitch, %.0f px" % cell)
	var columns := _walked_count(area.position.x, area.end.x, cell)
	var rows := _walked_count(area.position.y, area.end.y, cell)
	var vertices := ground.polygon
	_check(vertices.size() == columns * rows, "the grid has %d x %d vertices for a %.0f x %.0f px play area (%d)" % [columns, rows, area.size.x, area.size.y, vertices.size()])
	_check(ground.polygons.size() == (columns - 1) * (rows - 1), "one quad per cell (%d)" % ground.polygons.size())
	var min_corner := Vector2(INF, INF)
	var max_corner := Vector2(-INF, -INF)
	for vertex in vertices:
		min_corner = Vector2(minf(min_corner.x, vertex.x), minf(min_corner.y, vertex.y))
		max_corner = Vector2(maxf(max_corner.x, vertex.x), maxf(max_corner.y, vertex.y))
	_check(min_corner.is_equal_approx(area.position) and max_corner.is_equal_approx(area.end), "the grid covers the play area exactly, edge to edge")
	var quads_ok := true
	for indices: PackedInt32Array in ground.polygons:
		if indices.size() != 4:
			quads_ok = false
			break
		for index in indices:
			if index < 0 or index >= vertices.size():
				quads_ok = false
		if not quads_ok:
			break
		# Four distinct corners of one cell, whichever corner the quad starts at.
		var low := Vector2(INF, INF)
		var high := Vector2(-INF, -INF)
		var distinct := {}
		for index in indices:
			distinct[index] = true
			low = Vector2(minf(low.x, vertices[index].x), minf(low.y, vertices[index].y))
			high = Vector2(maxf(high.x, vertices[index].x), maxf(high.y, vertices[index].y))
		var span := high - low
		if distinct.size() != 4 or span.x <= 0.0 or span.y <= 0.0 or span.x > cell + 1e-3 or span.y > cell + 1e-3:
			quads_ok = false
			break
	_check(quads_ok, "every quad is four distinct in-range vertices spanning one cell")
	var flipped := 0
	for indices: PackedInt32Array in ground.polygons:
		if indices[0] != mini(mini(indices[0], indices[1]), mini(indices[2], indices[3])):
			flipped += 1
	_check(flipped * 2 >= ground.polygons.size() - 1 and flipped * 2 <= ground.polygons.size() + 1, "alternate cells start at their second corner so the triangle diagonals form a lattice, not streaks (%d of %d)" % [flipped, ground.polygons.size()])
	# The colours come from the map the car would be given: a TrackHeightMap built from this
	# definition, the way the session builds the car's. Every vertex is checked.
	var car_map := TrackHeightMap.new(definition)
	_check(car_map.has_terrain(), "the seed %d map carries terrain, so agreement below is not agreement on a flat plane" % GRID_SEED)
	var mismatches := 0
	var worst := 0.0
	var brightest := -INF
	var darkest := INF
	var lightest_luminance := -INF
	var darkest_luminance := INF
	var on_wedge := 0
	var lit := 0
	var shaded := 0
	for index in range(vertices.size()):
		var sample := car_map.sample_at(vertices[index])
		if sample.on_feature:
			on_wedge += 1
		var light := shading.light_term(sample.gradient)
		if light > 0.1:
			lit += 1
		elif light < -0.1:
			shaded += 1
		var expected := shading.shade(TerrainShading.GROUND_COLOR, sample)
		var actual := ground.vertex_colors[index]
		var error := maxf(maxf(absf(actual.r - expected.r), absf(actual.g - expected.g)), maxf(absf(actual.b - expected.b), absf(actual.a - expected.a)))
		worst = maxf(worst, error)
		if error > COLOR_TOLERANCE:
			mismatches += 1
		var brightness := _brightness(actual, TerrainShading.GROUND_COLOR)
		brightest = maxf(brightest, brightness)
		darkest = minf(darkest, brightness)
		lightest_luminance = maxf(lightest_luminance, actual.get_luminance())
		darkest_luminance = minf(darkest_luminance, actual.get_luminance())
	print("ground_grid seed=%d vertices=%d mismatches=%d worst_channel_error=%.9f brightness=%.3f..%.3f luminance=%.3f..%.3f on_wedge=%d lit=%d shaded=%d" % [GRID_SEED, vertices.size(), mismatches, worst, darkest, brightest, darkest_luminance, lightest_luminance, on_wedge, lit, shaded])
	_check(mismatches == 0, "every ground vertex is shaded from the car's height map at that vertex")
	# Without this the agreement above would pass unchanged against a terrain-only reconstruction if
	# no vertex happened to land on a wedge; 12 do on seed 0.
	_check(on_wedge > 0, "%d ground vertices sit on a ramp wedge, so the agreement discriminates the summed map from bare terrain" % on_wedge)
	_check(brightest - darkest > 0.3, "the ground actually varies in brightness across the play area (%.3f to %.3f)" % [darkest, brightest])
	# Absolute, not relative: a relative spread passes on a near-black base a player cannot read.
	_check(lightest_luminance - darkest_luminance >= GROUND_LUMINANCE_SPREAD, "the ground spans at least %.2f of absolute luminance (%.3f to %.3f)" % [GROUND_LUMINANCE_SPREAD, darkest_luminance, lightest_luminance])
	_check(lit > 0 and shaded > 0, "on real terrain the light term takes both signs across the grid (%d lit, %d shaded vertices)" % [lit, shaded])
	var background_scene := load(MAIN_SCENE_PATH) as PackedScene
	var session := background_scene.instantiate()
	var background := session.get_node_or_null(BACKGROUND_NODE) as ColorRect
	_check(background != null and TerrainShading.GROUND_COLOR.is_equal_approx(background.color), "level ground matches the session background, so the play-area edge shows no seam")
	session.free()
	runtime.free()
	return true


func _verify_ribbon_gradients() -> bool:
	var definition: TrackDefinition = TrackGenerator.new().generate(GRID_SEED)
	var runtime := TrackRuntime.new(definition)
	root.add_child(runtime)
	var shading := runtime.get_node("TerrainShading") as TerrainShading
	var car_map := TrackHeightMap.new(definition)
	var points: PackedVector2Array = definition.centerline
	var offsets := PackedFloat32Array()
	var total := 0.0
	for index in range(1, points.size()):
		total += points[index].distance_to(points[index - 1])
	var travelled := 0.0
	offsets.append(0.0)
	for index in range(1, points.size()):
		travelled += points[index].distance_to(points[index - 1])
		offsets.append(travelled / total)
	for ribbon_name in ["Dirt", "GrassShoulder"]:
		var line := runtime.get_node_or_null(ribbon_name) as Line2D
		_check(line != null and line.gradient != null, "%s carries a colour gradient along the road" % ribbon_name)
		if line == null or line.gradient == null:
			continue
		var gradient: Gradient = line.gradient
		_check(gradient.get_point_count() == points.size(), "%s has one gradient stop per centreline sample (%d)" % [ribbon_name, gradient.get_point_count()])
		if gradient.get_point_count() != points.size():
			continue
		var base: Color = line.default_color
		_check(base.is_equal_approx(TrackRuntime.DIRT_COLOR if ribbon_name == "Dirt" else TrackRuntime.GRASS_COLOR), "%s keeps its base colour as the gradient's reference" % ribbon_name)
		var offset_errors := 0
		var mismatches := 0
		var on_wedge := 0
		var brightest := -INF
		var darkest := INF
		for index in range(points.size()):
			# Line2D places a gradient stop by distance travelled along the line, so the stops
			# must be the cumulative centreline distance and not the sample index.
			if absf(gradient.get_offset(index) - offsets[index]) > 1e-5:
				offset_errors += 1
			var sample := car_map.sample_at(points[index])
			if sample.on_feature:
				on_wedge += 1
			var expected := shading.shade(base, sample)
			var actual := gradient.get_color(index)
			if not actual.is_equal_approx(expected):
				mismatches += 1
			var brightness := _brightness(actual, base)
			brightest = maxf(brightest, brightness)
			darkest = minf(darkest, brightness)
		print("ribbon %s stops=%d offset_errors=%d mismatches=%d on_wedge=%d brightness=%.3f..%.3f" % [ribbon_name, points.size(), offset_errors, mismatches, on_wedge, darkest, brightest])
		_check(offset_errors == 0, "%s stops sit at the cumulative centreline distance" % ribbon_name)
		_check(mismatches == 0, "%s is shaded from the car's height map at every centreline sample" % ribbon_name)
		_check(on_wedge > 0, "%d %s stops sit on a ramp wedge, so the agreement discriminates the summed map from bare terrain" % [on_wedge, ribbon_name])
		_check(brightest - darkest > 0.2, "%s varies in brightness around the lap (%.3f to %.3f)" % [ribbon_name, darkest, brightest])
	# The boundary lines are shaded too, from their own points, or they would stay a constant cream
	# rim over dirt that darkens around them.
	for edge in [["LeftEdge", definition.left_boundary], ["RightEdge", definition.right_boundary]]:
		var edge_name: String = edge[0]
		var edge_points: PackedVector2Array = edge[1]
		var line := runtime.get_node_or_null(edge_name) as Line2D
		_check(line != null and line.gradient != null and line.gradient.get_point_count() == edge_points.size(), "%s carries one gradient stop per boundary point (%d)" % [edge_name, edge_points.size()])
		if line == null or line.gradient == null or line.gradient.get_point_count() != edge_points.size():
			continue
		var mismatches := 0
		var brightest := -INF
		var darkest := INF
		for index in range(edge_points.size()):
			var expected := shading.shade(TrackRuntime.EDGE_COLOR, car_map.sample_at(edge_points[index]))
			var actual: Color = line.gradient.get_color(index)
			if not actual.is_equal_approx(expected):
				mismatches += 1
			brightest = maxf(brightest, _brightness(actual, TrackRuntime.EDGE_COLOR))
			darkest = minf(darkest, _brightness(actual, TrackRuntime.EDGE_COLOR))
		_check(mismatches == 0, "%s is shaded from the car's height map at every boundary point" % edge_name)
		_check(brightest - darkest > 0.2, "%s varies in brightness around the lap (%.3f to %.3f)" % [edge_name, darkest, brightest])
	runtime.free()
	return true


## Adds a constant to another query's height: the fixture ramp placed in a hollow or on a rise.
class ShiftedMap:
	extends HeightQuery

	var inner: HeightQuery
	var shift := 0.0


	func sample_at(world_position: Vector2) -> HeightSample:
		var sample := inner.sample_at(world_position)
		return HeightSample.new(sample.ground_height + shift, sample.gradient, sample.on_feature)


func _fixture_ramp(rotation: float) -> JumpRampPlacement:
	var ramp := JumpRampPlacement.new()
	ramp.stable_id = "h1:0:1"
	ramp.transform = Transform2D(rotation, Vector2.ZERO)
	ramp.half_length = 150.0
	ramp.crest_height = WEDGE_CREST
	ramp.width = 240.0
	return ramp


func _wedge_brightnesses(visuals: JumpRampVisuals) -> Array[float]:
	var wedge := visuals.get_node("Ramp_h1_0_1/Wedge") as Polygon2D
	var values: Array[float] = []
	for color in wedge.vertex_colors:
		values.append(_brightness(color, JumpRampVisuals.WEDGE_COLOR))
	return values


## The wedge is the one thing the first round left flat over shaded ground: a ramp in a hollow drew
## as the brightest thing on screen. It now takes its colour from the same map at six points.
func _verify_wedges_shade_from_the_map() -> bool:
	var shading := _shading()
	var definition := TrackDefinition.new()
	definition.jump_ramps = [_fixture_ramp(0.0)]
	var flat_base := TrackHeightMap.new(definition)
	_check(flat_base.ramp_count() == 1 and not flat_base.has_terrain(), "the fixture map is one wedge on a flat base, so every difference below is the wedge's or the shift's")
	var shifted := ShiftedMap.new()
	shifted.inner = flat_base
	var visuals := JumpRampVisuals.new()
	root.add_child(visuals)
	# Every sampled wedge point must be inside the ramp, or a foot would read bare ground.
	var inset_ok := true
	for corner in [Vector2(-150.0, -120.0), Vector2(0.0, -120.0), Vector2(150.0, -120.0), Vector2(150.0, 120.0), Vector2(0.0, 120.0), Vector2(-150.0, 120.0)]:
		if not flat_base.sample_at(JumpRampVisuals.sample_point(corner)).on_feature:
			inset_ok = false
	_check(inset_ok, "all six wedge sample points fall inside the ramp")
	shifted.shift = -40.0
	visuals.build(definition.jump_ramps, shading, shifted)
	var hollow := _wedge_brightnesses(visuals)
	shifted.shift = 40.0
	visuals.build(definition.jump_ramps, shading, shifted)
	var rise := _wedge_brightnesses(visuals)
	_check(hollow.size() == 6 and rise.size() == 6, "a shaded wedge carries six vertex colours")
	if hollow.size() != 6 or rise.size() != 6:
		visuals.free()
		return false
	var hollow_mean := 0.0
	var rise_mean := 0.0
	var every_vertex_darker := true
	for index in 6:
		hollow_mean += hollow[index] / 6.0
		rise_mean += rise[index] / 6.0
		if hollow[index] >= rise[index]:
			every_vertex_darker = false
	print("wedge hollow=%s rise=%s" % [str(hollow), str(rise)])
	_check(hollow_mean < rise_mean, "the same wedge is drawn darker in a 40 px hollow (%.3f) than on a 40 px rise (%.3f)" % [hollow_mean, rise_mean])
	_check(every_vertex_darker, "every one of its six vertices is darker in the hollow than on the rise")
	_check(hollow_mean < 1.0 and rise_mean > 1.0, "the hollow wedge is darker than the flat wedge colour and the rise wedge brighter")
	_check(is_equal_approx(rise_mean - hollow_mean, 2.0 * TerrainShading.HEIGHT_CONTRAST * 40.0 / 52.5), "the difference is exactly the height term of 80 px, %.3f" % (rise_mean - hollow_mean))
	# On a flat base: the two faces take the light from opposite sides, and the crest is a shade
	# brighter than the mean of the feet because the wedge's own height is in the sample.
	shifted.shift = 0.0
	visuals.build(definition.jump_ramps, shading, shifted)
	var level := _wedge_brightnesses(visuals)
	var lit_face := (level[0] + level[5]) * 0.5
	var shaded_face := (level[2] + level[3]) * 0.5
	var crest := (level[1] + level[4]) * 0.5
	# The feet are sampled SAMPLE_INSET px inside the ramp, so each carries that sliver of wedge
	# height (0.06 px, a 0.0005 brightness) plus the face's light term, worked here from the
	# constants: slope 9 / 150 along +x against a light at 45 degrees, over the slope bound.
	var catalog := load(TERRAIN_CATALOG_PATH) as TerrainCatalog
	var foot_height_term: float = TerrainShading.HEIGHT_CONTRAST * (WEDGE_CREST * JumpRampVisuals.SAMPLE_INSET / 150.0) / catalog.total_amplitude()
	var foot_light_term: float = TerrainShading.SLOPE_CONTRAST * (WEDGE_CREST / 150.0 * 0.7071067811865476) / catalog.slope_bound()
	_check(lit_face > 1.0 and shaded_face < 1.0, "the face rising toward +x, away from the top-left light, is lit (%.3f) and the far face shaded (%.3f)" % [lit_face, shaded_face])
	_check(absf(lit_face - (1.0 + foot_height_term + foot_light_term)) < 1e-6 and absf(shaded_face - (1.0 + foot_height_term - foot_light_term)) < 1e-6, "the faces are lit by +-%.4f about the feet's %.4f, both from the constants" % [foot_light_term, 1.0 + foot_height_term])
	_check(absf(foot_light_term - 0.1697) < 1e-3, "the wedge face light term is 0.170 on the shipped constants, a visible cue")
	_check(crest > (lit_face + shaded_face) * 0.5, "the crest is brighter than the mean of the feet")
	# Turned across the light the faces are unlit, so the crest's own height is all that differs.
	definition.jump_ramps = [_fixture_ramp(-PI * 0.25)]
	var across := TrackHeightMap.new(definition)
	visuals.build(definition.jump_ramps, shading, across)
	var across_values := _wedge_brightnesses(visuals)
	var foot := 1.0 + foot_height_term
	_check(absf(across_values[0] - foot) < 1e-6 and absf(across_values[2] - foot) < 1e-6 and absf(across_values[3] - foot) < 1e-6 and absf(across_values[5] - foot) < 1e-6, "across the light the four feet carry only the inset's sliver of height (%.4f), no light" % foot)
	var expected_crest := 1.0 + TerrainShading.HEIGHT_CONTRAST * WEDGE_CREST / 52.5
	_check(is_equal_approx(across_values[1], expected_crest) and is_equal_approx(across_values[4], expected_crest), "the crest is brighter by its own 9 px, a factor of %.4f" % expected_crest)
	_check(absf(expected_crest - 1.0771) < 1e-3, "that factor is 1.077 from the shipped constants")
	visuals.free()
	# Production: every wedge on seed 0 is coloured from the car's map at the inset sample points.
	var generated: TrackDefinition = TrackGenerator.new().generate(GRID_SEED)
	var runtime := TrackRuntime.new(generated)
	root.add_child(runtime)
	var car_map := TrackHeightMap.new(generated)
	var ramps := runtime.get_node("JumpRamps") as JumpRampVisuals
	var wedges := 0
	var mismatches := 0
	var off_feature := 0
	for holder in ramps.get_children():
		var wedge := holder.get_node("Wedge") as Polygon2D
		if wedge.vertex_colors.size() != 6:
			mismatches += 1
			continue
		wedges += 1
		for index in 6:
			var world := (holder as Node2D).transform * JumpRampVisuals.sample_point(wedge.polygon[index])
			var sample := car_map.sample_at(world)
			if not sample.on_feature:
				off_feature += 1
			if not wedge.vertex_colors[index].is_equal_approx(runtime.get_node("TerrainShading").shade(JumpRampVisuals.WEDGE_COLOR, sample)):
				mismatches += 1
	_check(wedges == generated.jump_ramps.size() and wedges > 0, "every generated wedge on seed %d carries six vertex colours (%d)" % [GRID_SEED, wedges])
	_check(mismatches == 0, "every generated wedge vertex is shaded from the car's height map at its sample point")
	_check(off_feature == 0, "every generated wedge sample point is inside its ramp")
	runtime.free()
	shading.free()
	return true


## The production session: the car's ride height and the shading under it come from the same
## field at the same position, at the spawn and on a ramp crest, where terrain alone would be
## wrong by the crest height.
func _verify_shading_agrees_with_the_car() -> bool:
	var main_scene := load(MAIN_SCENE_PATH) as PackedScene
	var session := main_scene.instantiate()
	root.add_child(session)
	await process_frame
	session.call("restart_with_seed", SESSION_SEED)
	await process_frame
	var runtime := session.get_node("World/TrackMount/GeneratedTrack") as TrackRuntime
	var car := session.get_node("World/VehicleMount/PlayerCar") as TopDownCar
	var definition: TrackDefinition = runtime.definition
	var shading := runtime.get_node("TerrainShading") as TerrainShading
	var ground := runtime.get_node("TerrainShading/Ground") as Polygon2D
	var runtime_map := runtime.height_query()
	_check(runtime_map is TrackHeightMap and (runtime_map as TrackHeightMap).has_terrain(), "the runtime shades from a TrackHeightMap with terrain")
	var spawn_shading := runtime_map.sample_at(car.global_position).ground_height
	_check(absf(spawn_shading) > SPAWN_HEIGHT_FLOOR, "the spawn sits more than %.1f px from level (%.3f px), so agreement there is not agreement near flat ground" % [SPAWN_HEIGHT_FLOOR, spawn_shading])
	_check(absf(car.get_height() - spawn_shading) < 1e-6, "at the spawn the car rides at %.4f px and the shading samples %.4f px" % [car.get_height(), spawn_shading])
	# The vertex nearest the car is coloured from the same sample the car's own map gives there.
	var car_map := TrackHeightMap.new(definition)
	var nearest := -1
	var nearest_distance := INF
	for index in range(ground.polygon.size()):
		var distance := ground.polygon[index].distance_squared_to(car.global_position)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = index
	_check(nearest >= 0 and sqrt(nearest_distance) <= TerrainShading.GROUND_CELL, "a ground vertex lies within one cell of the car")
	if nearest >= 0:
		var expected := shading.shade(TerrainShading.GROUND_COLOR, car_map.sample_at(ground.polygon[nearest]))
		_check(ground.vertex_colors[nearest].is_equal_approx(expected), "the ground vertex under the car is shaded from the car's own map at that vertex")
	var crest_ramp: JumpRampPlacement = definition.jump_ramps[0] if not definition.jump_ramps.is_empty() else null
	_check(crest_ramp != null, "seed %d places a ramp to reset the car onto" % SESSION_SEED)
	if crest_ramp != null:
		_check(car.set_safe_reset_pose(Transform2D(0.0, crest_ramp.transform.origin)), "the crest is a collision-clear safe pose")
		car.request_safe_reset()
		await physics_frame
		var crest_shading := runtime_map.sample_at(car.global_position)
		_check(crest_shading.on_feature, "the car now sits on the ramp, where terrain alone would be wrong by the crest height")
		_check(absf(car.get_height() - crest_shading.ground_height) < 1e-6, "on the crest the car rides at %.4f px and the shading samples %.4f px" % [car.get_height(), crest_shading.ground_height])
		var terrain_only := TerrainField.new(definition.terrain_seed, load(TERRAIN_CATALOG_PATH) as TerrainCatalog).height_at(car.global_position)
		_check(absf(crest_shading.ground_height - terrain_only) > 1.0, "the crest sample differs from bare terrain by %.2f px, so the two agreements above are on the summed map" % absf(crest_shading.ground_height - terrain_only))
	session.free()
	return true


func _shadow_extent(shadow: Polygon2D, world_rotation: float, axis: Vector2) -> float:
	var low := INF
	var high := -INF
	for point in shadow.polygon:
		var along := point.rotated(world_rotation).dot(axis)
		low = minf(low, along)
		high = maxf(high, along)
	return high - low


func _tree(id: String, position: Vector2, rotation: float) -> OfftrackObjectPlacement:
	var placement := OfftrackObjectPlacement.new()
	placement.stable_id = id
	placement.archetype_id = &"tree"
	placement.transform = Transform2D(rotation, position)
	placement.scale_factor = 1.0
	placement.visual_variant = 0
	placement.solid = true
	placement.collision_profile = &"trunk"
	return placement


func _verify_object_shadows() -> bool:
	var catalog := load(OBJECT_CATALOG_PATH) as OfftrackObjectCatalog
	var raised_height := 40.0
	var expected_factor := 1.0 + WorldScale.to_metres(raised_height) * TerrainShading.SHADOW_LENGTHEN_PER_METRE
	_check(is_equal_approx(TerrainShading.shadow_length_factor(raised_height), expected_factor), "40 px of ground lengthens a shadow by the per-metre rate")
	_check(is_equal_approx(expected_factor, 1.48), "40 px is 3.2 m, so the factor is 1.48")
	_check(is_equal_approx(TerrainShading.shadow_length_factor(0.0), 1.0), "level ground leaves the shadow at its baseline")
	_check(TerrainShading.shadow_length_factor(-raised_height) < 1.0, "lowered ground shortens the shadow")
	_check(is_equal_approx(TerrainShading.shadow_length_factor(-1000.0), TerrainShading.SHADOW_LENGTH_FLOOR), "a deep hollow cannot shrink the shadow past the floor")
	_check(is_equal_approx(TerrainShading.shadow_length_factor(1000.0), TerrainShading.SHADOW_LENGTH_CEILING), "a tall rise cannot stretch the shadow past the ceiling")
	# A plateau for x < 1000: one tree on it, an identical tree past its edge on level ground.
	var plateau := HeightChannelTestHeightProvider.new()
	plateau.mode = HeightChannelTestHeightProvider.Mode.PLATEAU
	plateau.plateau_height = raised_height
	plateau.plateau_end_x = 1000.0
	var rotation := 0.5
	var placements: Array[OfftrackObjectPlacement] = [_tree("v1:0:1:0", Vector2(500.0, 0.0), rotation), _tree("v1:0:1:1", Vector2(1500.0, 0.0), rotation)]
	var visuals := OfftrackObjectVisuals.new()
	root.add_child(visuals)
	visuals.build(placements, catalog, plateau)
	_check(visuals.solid_visual_count() == 2, "both trees are drawn")
	var raised := visuals.get_node("SolidObjects/v1_0_1_0")
	var level := visuals.get_node("SolidObjects/v1_0_1_1")
	var raised_shadow := raised.get_child(0) as Polygon2D
	var level_shadow := level.get_child(0) as Polygon2D
	var raised_body := raised.get_child(1) as Polygon2D
	var level_body := level.get_child(1) as Polygon2D
	_check(raised_shadow != null and level_shadow != null, "each solid's first child is its shadow polygon")
	var baseline := FACTORY_SHADOW_OFFSET.length()
	_check(is_equal_approx(level_shadow.position.length(), baseline), "on level ground the shadow sits at the factory's offset distance, %.2f px" % baseline)
	_check(is_equal_approx(raised_shadow.position.length(), baseline * expected_factor), "on the plateau the shadow is displaced 1.48 times as far (%.2f px)" % raised_shadow.position.length())
	_check(raised_shadow.position.length() > level_shadow.position.length(), "the raised tree's shadow is thrown further than the level tree's")
	# Shadows fall away from the light in world space, whatever the object's own rotation, so the
	# cue agrees with the ground shading's light.
	var world_offset := level_shadow.position.rotated(rotation)
	_check(world_offset.normalized().is_equal_approx(TerrainShading.SHADOW_DIRECTION), "the shadow falls along the world shadow direction, not the object's local frame")
	var along := TerrainShading.SHADOW_DIRECTION
	var across := Vector2(-along.y, along.x)
	var level_extent := _shadow_extent(level_shadow, rotation, along)
	var raised_extent := _shadow_extent(raised_shadow, rotation, along)
	_check(is_equal_approx(raised_extent, level_extent * expected_factor), "the raised shadow polygon is 1.48 times as long along the light (%.2f vs %.2f px)" % [raised_extent, level_extent])
	_check(is_equal_approx(_shadow_extent(raised_shadow, rotation, across), _shadow_extent(level_shadow, rotation, across)), "the raised shadow is no wider across the light")
	# Since #51 the body stands on the ground: lifted up the screen by the plateau height, its
	# polygon unchanged; the level tree's body stays at its foot. tests/offtrack_object_terrain_test.gd
	# owns the seating rule; this pins that the shadow treatment did not move the body itself.
	_check(raised_body.polygon == level_body.polygon, "the tree bodies keep the same polygon; the lift moves, it does not reshape")
	_check((raised as Node2D).transform.basis_xform(raised_body.position).is_equal_approx(TerrainShading.lift_offset(raised_height)) and level_body.position == Vector2.ZERO, "the raised body is lifted by the plateau height and the level body is not")
	_check(is_equal_approx(raised_shadow.color.a, level_shadow.color.a), "elevation changes the shadow's length, not its darkness")
	# Lowered ground: the same pair on a plateau below zero.
	plateau.plateau_height = -raised_height
	visuals.build(placements, catalog, plateau)
	var lowered_shadow := visuals.get_node("SolidObjects/v1_0_1_0").get_child(0) as Polygon2D
	_check(lowered_shadow.position.length() < baseline - 1e-3, "a tree in a hollow casts a shorter shadow than one on level ground (%.2f px)" % lowered_shadow.position.length())
	_check(_shadow_extent(lowered_shadow, rotation, along) < level_extent, "the hollow's shadow polygon is shorter along the light")
	# No height query at all: the pre-terrain fixtures, whose shadows keep the factory's length.
	visuals.build(placements, catalog)
	var plain_shadow := visuals.get_node("SolidObjects/v1_0_1_0").get_child(0) as Polygon2D
	_check(is_equal_approx(plain_shadow.position.length(), baseline), "without a height query every shadow keeps the factory's offset distance")
	_check(is_equal_approx(_shadow_extent(plain_shadow, rotation, along), level_extent), "without a height query the shadow polygon keeps its length")
	_check(plain_shadow.position.rotated(rotation).normalized().is_equal_approx(TerrainShading.SHADOW_DIRECTION), "without a height query the shadow is still thrown along the world shadow direction: the reorientation applies on both paths")
	visuals.free()
	return true


func _verify_rebuild_frees_shading() -> bool:
	var definition: TrackDefinition = TrackGenerator.new().generate(GRID_SEED)
	var shading := _shading()
	root.add_child(shading)
	var map := TrackHeightMap.new(definition)
	shading.build(definition.play_area, map)
	var first_ground := shading.get_node("Ground")
	var first_count := shading.ground_sample_count()
	shading.build(definition.play_area, map)
	_check(shading.get_child_count() == 1, "rebuilding leaves one ground polygon, not two")
	_check(not is_instance_valid(first_ground), "the previous ground polygon is freed, not merely detached")
	_check(shading.ground_sample_count() == first_count and first_count > 0, "the rebuilt grid is sampled afresh with the same count (%d)" % first_count)
	shading.build(Rect2(), map)
	_check(shading.get_child_count() == 0 and shading.ground_sample_count() == 0, "an empty area builds no ground and samples nothing")
	shading.free()
	# The session path: a seed restart frees the whole previous track, shading included.
	var main_scene := load(MAIN_SCENE_PATH) as PackedScene
	var session := main_scene.instantiate()
	root.add_child(session)
	await process_frame
	session.call("restart_with_seed", SESSION_SEED)
	await process_frame
	var first_shading := session.get_node("World/TrackMount/GeneratedTrack/TerrainShading")
	session.call("restart_with_seed", RESTART_SEED)
	await process_frame
	_check(session.get_node("World/TrackMount").get_child_count() == 1, "one track is mounted after a seed restart")
	_check(not is_instance_valid(first_shading), "the previous track's shading is freed with it")
	var second_runtime := session.get_node("World/TrackMount/GeneratedTrack") as TrackRuntime
	var second_shading := second_runtime.get_node_or_null("TerrainShading") as TerrainShading
	_check(second_shading != null and second_shading.get_child_count() == 1, "the restarted track carries exactly one ground polygon")
	var second_definition: TrackDefinition = second_runtime.definition
	_check(second_definition.seed == RESTART_SEED and second_shading != null and second_shading.ground_sample_count() == _walked_count(second_definition.play_area.position.x, second_definition.play_area.end.x, TerrainShading.GROUND_CELL) * _walked_count(second_definition.play_area.position.y, second_definition.play_area.end.y, TerrainShading.GROUND_CELL), "the restarted grid is sized to the new seed's play area")
	session.free()
	return true


func _median(values: Array[int]) -> int:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _verify_build_cost() -> bool:
	var definition: TrackDefinition = TrackGenerator.new().generate(GRID_SEED)
	var map := TrackHeightMap.new(definition)
	var shading := _shading()
	root.add_child(shading)
	var ground_runs: Array[int] = []
	var ribbon_runs: Array[int] = []
	for run in range(TIMING_RUNS):
		var started := Time.get_ticks_usec()
		shading.build(definition.play_area, map)
		ground_runs.append(Time.get_ticks_usec() - started)
		started = Time.get_ticks_usec()
		var gradient := shading.ribbon_gradient(definition.centerline, TrackRuntime.DIRT_COLOR, map)
		ribbon_runs.append(Time.get_ticks_usec() - started)
		_check(gradient.get_point_count() == definition.centerline.size(), "run %d built a full ribbon gradient" % run)
	var samples := shading.ground_sample_count()
	var expected_samples := _walked_count(definition.play_area.position.x, definition.play_area.end.x, TerrainShading.GROUND_CELL) * _walked_count(definition.play_area.position.y, definition.play_area.end.y, TerrainShading.GROUND_CELL)
	_check(samples == expected_samples, "the timed build sampled the full grid (%d), so the budget is not met by sampling less" % samples)
	var ground_median := _median(ground_runs)
	var ribbon_median := _median(ribbon_runs)
	var ground_budget := int(float(samples) * PER_SAMPLE_BUDGET_USEC)
	var ribbon_budget := int(float(definition.centerline.size()) * PER_SAMPLE_BUDGET_USEC)
	print("build_cost seed=%d ground_samples=%d ground_usec=%s median=%d per_sample=%.2f budget=%d ribbon_stops=%d ribbon_usec=%s median=%d per_stop=%.2f budget=%d" % [
		GRID_SEED, samples, str(ground_runs), ground_median, float(ground_median) / float(samples), ground_budget,
		definition.centerline.size(), str(ribbon_runs), ribbon_median, float(ribbon_median) / float(definition.centerline.size()), ribbon_budget,
	])
	_check(ground_median <= ground_budget, "the ground grid builds within %.0f us a sample (median %d us for %d samples)" % [PER_SAMPLE_BUDGET_USEC, ground_median, samples])
	_check(ribbon_median <= ribbon_budget, "a ribbon gradient builds within %.0f us a stop (median %d us for %d stops)" % [PER_SAMPLE_BUDGET_USEC, ribbon_median, definition.centerline.size()])
	shading.free()
	return true


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Terrain visual checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Terrain visual check failed: %s" % failure)
	quit(1)
