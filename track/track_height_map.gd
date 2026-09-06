# track/track_height_map.gd
class_name TrackHeightMap
extends HeightQuery

## Answers ground height as the terrain field plus a definition's jump ramps. Heights add and
## gradients add: the terrain sample is taken first, at every query, and a ramp's wedge is summed
## onto it when the position is inside that ramp. Ramps never overlap, so the first ramp whose
## local frame contains the position is the only one. With at most a handful of ramps per track a
## linear scan beats an index; the placement test bounds its cost. Per-ramp bounds live in scalar
## packed arrays and a conservative reach test rejects most misses before any transform work.
##
## Across the road the wedge is the linear hump of #37 at full height. Beyond each road edge it
## fades to nothing over the placement's `flank_width`, along the quintic fade whose first and
## second derivatives vanish at both ends, so the total height is continuous everywhere and its
## second derivative has no step at either edge of the flank. #37's height map cut the wedge off
## at the road edge, leaving a vertical wall a car crossing from the side drove under; a car now
## rides the flank onto the wedge. A placement with a zero flank width is that hard cut.
##
## The miss path hands back one shared sample instead of allocating per query, rewritten with the
## terrain sample on every return so a consumer's stray write self-heals on the next query: hold
## and read the sample freely, but never write through it -- a mutation only corrupts what is read
## before the next miss query rewrites it. A hit allocates its own sample, as before.
##
## Terrain is built from the definition's `terrain_seed` and the same default catalog resource the
## generator preloads, so the map reproduces the field the fingerprint was taken from; a
## definition without a terrain seed (a hand-built fixture) gets a flat base, so a ramp-only
## fixture reads exactly as it did before terrain existed.

const DEFAULT_TERRAIN_CATALOG := preload("res://data/default_terrain_catalog.tres")

var _terrain: TerrainField
var _sample := HeightSample.new()
var _origin_xs := PackedFloat64Array()
var _origin_ys := PackedFloat64Array()
var _reach_xs := PackedFloat64Array()
var _radii_squared := PackedFloat64Array()
var _inverses: Array[Transform2D] = []
var _axes: PackedVector2Array = PackedVector2Array()
var _laterals: PackedVector2Array = PackedVector2Array()
var _half_lengths := PackedFloat64Array()
var _half_widths := PackedFloat64Array()
var _outer_half_widths := PackedFloat64Array()
var _flank_widths := PackedFloat64Array()
var _crest_heights := PackedFloat64Array()
var _slopes := PackedFloat64Array()


func _init(definition) -> void:
	if definition == null:
		return
	if definition.terrain_seed != 0:
		_terrain = TerrainField.new(definition.terrain_seed, DEFAULT_TERRAIN_CATALOG)
	for ramp: JumpRampPlacement in definition.jump_ramps:
		if ramp == null or not ramp.is_valid():
			continue
		var half_length: float = ramp.half_length
		var half_width: float = ramp.width * 0.5
		var outer_half_width: float = half_width + ramp.flank_width
		_origin_xs.append(ramp.transform.origin.x)
		_origin_ys.append(ramp.transform.origin.y)
		_reach_xs.append(sqrt(half_length * half_length + outer_half_width * outer_half_width))
		_radii_squared.append(half_length * half_length + outer_half_width * outer_half_width)
		_inverses.append(ramp.transform.affine_inverse())
		_axes.append(ramp.transform.x.normalized())
		_laterals.append(ramp.transform.y.normalized())
		_half_lengths.append(half_length)
		_half_widths.append(half_width)
		_outer_half_widths.append(outer_half_width)
		_flank_widths.append(ramp.flank_width)
		_crest_heights.append(ramp.crest_height)
		_slopes.append(ramp.crest_height / half_length)


func ramp_count() -> int:
	return _inverses.size()


func has_terrain() -> bool:
	return _terrain != null


func sample_at(world_position: Vector2) -> HeightSample:
	if _terrain != null:
		_terrain.sample_into(world_position, _sample)
	else:
		_sample.ground_height = 0.0
		_sample.gradient = Vector2.ZERO
	_sample.feature_height = 0.0
	var px := world_position.x
	var py := world_position.y
	var count := _inverses.size()
	for index in count:
		var dx := px - _origin_xs[index]
		var reach := _reach_xs[index]
		if dx > reach or dx < -reach:
			continue
		var dy := py - _origin_ys[index]
		if dx * dx + dy * dy > _radii_squared[index]:
			continue
		var local := _inverses[index] * world_position
		var half_length := _half_lengths[index]
		var along := absf(local.x)
		var across := absf(local.y)
		if along > half_length or across > _outer_half_widths[index]:
			continue
		var crest := _crest_heights[index]
		var profile := 1.0 - along / half_length
		# Full height across the road; on a flank the fade and its slope, measured outward.
		var falloff := 1.0
		var falloff_slope := 0.0
		var half_width := _half_widths[index]
		if across > half_width:
			var flank := _flank_widths[index]
			var t := (across - half_width) / flank
			falloff = 1.0 - t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
			falloff_slope = -30.0 * t * t * (t - 1.0) * (t - 1.0) / flank
		# Rising toward the crest from either side, and toward the road from either flank.
		var along_slope := -signf(local.x) * _slopes[index] * falloff
		var across_slope := crest * profile * falloff_slope * signf(local.y)
		var gradient := _axes[index] * along_slope + _laterals[index] * across_slope
		var wedge := crest * profile * falloff
		return HeightSample.new(_sample.ground_height + wedge, _sample.gradient + gradient, wedge)
	return _sample
