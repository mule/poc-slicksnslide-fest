# track/track_height_map.gd
class_name TrackHeightMap
extends HeightQuery

## Answers ground height from a definition's jump ramps. Ramps never overlap, so the first ramp
## whose local frame contains the position is the only one. With at most a handful of ramps per
## track a linear scan beats an index; the placement test bounds its cost. Per-ramp bounds live in
## scalar packed arrays and a conservative reach test rejects most misses before any transform
## work. The flat miss path hands back one shared sample instead of allocating per query, re-zeroed
## on every return so a consumer's stray write self-heals on the next query: hold and read the
## sample freely, but never write through it — a mutation only corrupts what is read before the
## next flat query resets it.

var _flat := HeightSample.new()
var _origin_xs := PackedFloat64Array()
var _origin_ys := PackedFloat64Array()
var _reach_xs := PackedFloat64Array()
var _radii_squared := PackedFloat64Array()
var _inverses: Array[Transform2D] = []
var _axes: PackedVector2Array = PackedVector2Array()
var _half_lengths := PackedFloat64Array()
var _half_widths := PackedFloat64Array()
var _crest_heights := PackedFloat64Array()
var _slopes := PackedFloat64Array()


func _init(definition) -> void:
	if definition == null:
		return
	for ramp: JumpRampPlacement in definition.jump_ramps:
		if ramp == null or not ramp.is_valid():
			continue
		var half_length: float = ramp.half_length
		var half_width: float = ramp.width * 0.5
		_origin_xs.append(ramp.transform.origin.x)
		_origin_ys.append(ramp.transform.origin.y)
		_reach_xs.append(sqrt(half_length * half_length + half_width * half_width))
		_radii_squared.append(half_length * half_length + half_width * half_width)
		_inverses.append(ramp.transform.affine_inverse())
		_axes.append(ramp.transform.x.normalized())
		_half_lengths.append(half_length)
		_half_widths.append(half_width)
		_crest_heights.append(ramp.crest_height)
		_slopes.append(ramp.crest_height / half_length)


func ramp_count() -> int:
	return _inverses.size()


func sample_at(world_position: Vector2) -> HeightSample:
	var px := world_position.x
	var py := world_position.y
	var count := _inverses.size()
	for index in range(count):
		var dx := px - _origin_xs[index]
		var reach := _reach_xs[index]
		if dx > reach or dx < -reach:
			continue
		var dy := py - _origin_ys[index]
		if dx * dx + dy * dy > _radii_squared[index]:
			continue
		var local := _inverses[index] * world_position
		var half_length := _half_lengths[index]
		if absf(local.x) > half_length or absf(local.y) > _half_widths[index]:
			continue
		# Rising toward the crest from either side: the gradient points at the crest.
		var along := -signf(local.x) * _slopes[index]
		return HeightSample.new(_crest_heights[index] * (1.0 - absf(local.x) / half_length), _axes[index] * along)
	_flat.ground_height = 0.0
	_flat.gradient = Vector2.ZERO
	return _flat
