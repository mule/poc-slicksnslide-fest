class_name TerrainShading
extends Node2D

## Draws the terrain's elevation so a hill reads as a hill. Nothing here samples a field of its
## own: every colour is computed from a HeightSample handed in by the caller, and TrackRuntime
## hands in the same TrackHeightMap the car drives on, so the tint under the car and the car's
## own ride height cannot disagree.
##
## Two cues, one colour function. Height tints: brightness rises with the sampled height, from
## 1 - HEIGHT_CONTRAST at minus the catalog's total amplitude to 1 + HEIGHT_CONTRAST at plus it.
## Slope lights: a slope rising away from a light in the screen's top-left faces that light and
## brightens by up to SLOPE_CONTRAST; one rising toward it turns away and darkens; across a
## crest the term changes sign. The slope term is the Lambert term of a height field, n . l with
## n = (-dh/dx, -dh/dy, 1), less the constant, scaled by the catalog's slope bound so terrain at
## its steepest saturates it. The gradient is the field's exact derivative, so this is the
## cheapest directional cue there is: no second sample, no finite difference.
##
## The ground is one Polygon2D: a grid over the play area, one vertex every GROUND_CELL px, each
## vertex coloured from the sample at it and the GPU interpolating between them. GROUND_CELL is
## the fingerprint and object-placement pitch, 250 px. The finest octave the shipped catalog has
## is 750 px wide and 2.5 px tall, so three vertices per finest cell resolve everything the eye
## can see, and the sample count is the fingerprint's: about 3,000 to 4,000 vertices for a play
## area of 12,000 to 17,000 px a side, at 4 to 5 us a query about 15 to 20 ms once per track
## build. The road ribbons are Line2D nodes and take a Gradient with one stop per centreline
## sample, a further 1,100 to 1,500 samples, placed by distance along the line because that is
## how Line2D reads a gradient.
##
## The same function colours the road ribbons, the boundary lines and the ramp wedges, so nothing
## the track draws can disagree with the ground it sits on. Every base colour it multiplies is
## chosen so that base times peak_brightness() stays inside the displayable range: the boundary
## line's cream is the one exception, and a 6 px line saturating toward white at plus the total
## amplitude on a slope at the bound facing the light is accepted and documented.
##
## Shadows lengthen with the ground under them. The car's Shadow already fades with the car's
## height above the ground; an off-track solid stands on the ground, so its shadow is stretched
## and thrown further along SHADOW_DIRECTION by shadow_length_factor of the terrain height at its
## foot. Both rates are 0.15 a metre. This class owns the rule so every consumer stretches alike.

## The session's background: level ground is drawn in it so the play-area edge, where the grid
## stops and the background shows, is not a seam. Lightened from the pre-terrain background
## (#203a1e) in #50's fix round: the shading is multiplicative, so on a dark base a 45% swing was
## a small absolute step and the off-track ground read as nearly flat beside the dirt ribbon.
const GROUND_COLOR := Color(0.168627, 0.294118, 0.160784)
## Unit vector toward the light, in the ground plane: the screen's top-left.
const LIGHT_DIRECTION := Vector2(-0.7071067811865476, -0.7071067811865476)
## Unit vector a shadow is thrown along: directly away from the light.
const SHADOW_DIRECTION := Vector2(0.7071067811865476, 0.7071067811865476)
## Brightness change at plus or minus the catalog's total amplitude.
const HEIGHT_CONTRAST := 0.45
## Brightness change at the catalog's slope bound facing directly toward or away from the light.
const SLOPE_CONTRAST := 0.35
## Ground vertex pitch in px: the fingerprint and off-track placement cell.
const GROUND_CELL := TerrainField.FINGERPRINT_SPACING
## Shadow length factor per metre of ground height under a solid; the car's SHADOW_FADE_PER_METRE.
const SHADOW_LENGTHEN_PER_METRE := 0.15
const SHADOW_LENGTH_FLOOR := 0.5
const SHADOW_LENGTH_CEILING := 2.0

var _height_reference: float
var _slope_reference: float
var _ground_sample_count := 0


func _init(catalog: TerrainCatalog = TrackHeightMap.DEFAULT_TERRAIN_CATALOG) -> void:
	_height_reference = catalog.total_amplitude()
	_slope_reference = catalog.slope_bound()


## Frees any previous ground and draws the area as one vertex-coloured grid sampled from the
## height query. An empty area draws nothing.
func build(area: Rect2, height_query: HeightQuery) -> void:
	for child in get_children():
		child.free()
	_ground_sample_count = 0
	if area.size.x <= 0.0 or area.size.y <= 0.0:
		return
	var columns := ground_columns(area)
	var rows := ground_rows(area)
	var vertices := PackedVector2Array()
	var colors := PackedColorArray()
	vertices.resize(columns * rows)
	colors.resize(columns * rows)
	var index := 0
	for row in rows:
		var y := minf(area.position.y + float(row) * GROUND_CELL, area.end.y)
		for column in columns:
			var vertex := Vector2(minf(area.position.x + float(column) * GROUND_CELL, area.end.x), y)
			vertices[index] = vertex
			colors[index] = shade(GROUND_COLOR, height_query.sample_at(vertex))
			index += 1
	_ground_sample_count = index
	# Polygon2D splits each quad into two triangles along one diagonal, and the GPU interpolates
	# linearly within each, so a cell whose tint is not planar shows a faint crease on that
	# diagonal. With every cell split the same way the creases line up into streaks across the
	# whole area; starting alternate cells at their second corner flips the diagonal so the
	# creases form a lattice instead, which the eye does not follow. Same vertices, same colours.
	var quads: Array[PackedInt32Array] = []
	for row in rows - 1:
		for column in columns - 1:
			var corner := row * columns + column
			if (row + column) % 2 == 0:
				quads.append(PackedInt32Array([corner, corner + 1, corner + columns + 1, corner + columns]))
			else:
				quads.append(PackedInt32Array([corner + 1, corner + columns + 1, corner + columns, corner]))
	var ground := Polygon2D.new()
	ground.name = "Ground"
	ground.polygon = vertices
	ground.vertex_colors = colors
	ground.polygons = quads
	add_child(ground)


## One stop per point, placed by cumulative distance along the line, coloured from the sample at
## the point. Line2D reads a gradient by distance travelled, not by point index.
func ribbon_gradient(points: PackedVector2Array, base: Color, height_query: HeightQuery) -> Gradient:
	var count := points.size()
	var distances := PackedFloat32Array()
	distances.resize(count)
	var total := 0.0
	for index in range(1, count):
		total += points[index].distance_to(points[index - 1])
		distances[index] = total
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	offsets.resize(count)
	colors.resize(count)
	for index in count:
		offsets[index] = distances[index] / total if total > 0.0 else 0.0
		colors[index] = shade(base, height_query.sample_at(points[index]))
	var gradient := Gradient.new()
	gradient.offsets = offsets
	gradient.colors = colors
	return gradient


## The base colour brightened or darkened by the height and light terms; alpha untouched.
func shade(base: Color, sample: HeightQuery.HeightSample) -> Color:
	var brightness := 1.0 + HEIGHT_CONTRAST * height_term(sample.ground_height) + SLOPE_CONTRAST * light_term(sample.gradient)
	return Color(
		clampf(base.r * brightness, 0.0, 1.0),
		clampf(base.g * brightness, 0.0, 1.0),
		clampf(base.b * brightness, 0.0, 1.0),
		base.a,
	)


## Height as a fraction of the catalog's total amplitude, clamped to [-1, 1].
func height_term(ground_height: float) -> float:
	return clampf(ground_height / _height_reference, -1.0, 1.0)


## How squarely the slope faces the light, as a fraction of the catalog's slope bound, clamped to
## [-1, 1]. Positive faces the light: the ground rises away from it.
func light_term(gradient: Vector2) -> float:
	return clampf(-gradient.dot(LIGHT_DIRECTION) / _slope_reference, -1.0, 1.0)


func ground_sample_count() -> int:
	return _ground_sample_count


## The largest multiplier shade() can apply before clamping: full height and full light together.
static func peak_brightness() -> float:
	return 1.0 + HEIGHT_CONTRAST + SLOPE_CONTRAST


## Vertices across the area: one at the origin, one every cell, and one on the far edge.
static func ground_columns(area: Rect2) -> int:
	return ceili(area.size.x / GROUND_CELL) + 1


static func ground_rows(area: Rect2) -> int:
	return ceili(area.size.y / GROUND_CELL) + 1


## Factor by which a solid's shadow is stretched and displaced for the ground height at its foot.
static func shadow_length_factor(ground_height: float) -> float:
	return clampf(1.0 + WorldScale.to_metres(ground_height) * SHADOW_LENGTHEN_PER_METRE, SHADOW_LENGTH_FLOOR, SHADOW_LENGTH_CEILING)
