class_name JumpRampVisuals
extends Node2D

## One wedge per valid ramp: a packed-dirt quad the width of the road, a crest line, and a chevron
## on each face pointing at the crest. Pure presentation; never touches physics.
##
## Given a TerrainShading and the height query the rest of the track is drawn from, the wedge is
## shaded from that same map at its two feet and its crest on each side (#50): a ramp in a hollow
## draws dark like the hollow, a ramp on a rise draws bright like the rise, the crest is a shade
## brighter than the feet because the wedge's own height is in the sample, and the two faces take
## the light from opposite sides because the wedge's slope is in the gradient. Without them the
## wedge is the flat WEDGE_COLOR, as on the fixtures that predate terrain.

const WEDGE_COLOR := Color("866040")
## Wedge colours are sampled this far inside the wedge's edges, in px, so every sample is inside
## the ramp rather than on its boundary, where float rounding could put a corner just outside it.
const SAMPLE_INSET := 1.0
const CREST_COLOR := Color("e2c98a")
const CHEVRON_COLOR := Color("c7a15f")
const CREST_WIDTH := 6.0
const CHEVRON_WIDTH := 4.0

var _visual_count := 0


func build(ramps: Array[JumpRampPlacement], shading: TerrainShading = null, height_query: HeightQuery = null) -> void:
	for child in get_children():
		child.free()
	_visual_count = 0
	for ramp in ramps:
		if ramp == null or not ramp.is_valid():
			continue
		var holder := Node2D.new()
		holder.name = "Ramp_" + ramp.stable_id.replace(":", "_")
		holder.transform = ramp.transform
		add_child(holder)
		var half_width := ramp.width * 0.5
		var wedge := Polygon2D.new()
		wedge.name = "Wedge"
		# Two feet and the crest on each side, so the crest carries its own colour.
		wedge.polygon = PackedVector2Array([
			Vector2(-ramp.half_length, -half_width),
			Vector2(0.0, -half_width),
			Vector2(ramp.half_length, -half_width),
			Vector2(ramp.half_length, half_width),
			Vector2(0.0, half_width),
			Vector2(-ramp.half_length, half_width),
		])
		wedge.color = WEDGE_COLOR
		if shading != null and height_query != null:
			var colors := PackedColorArray()
			for corner in wedge.polygon:
				colors.append(shading.shade(WEDGE_COLOR, height_query.sample_at(holder.transform * sample_point(corner))))
			wedge.vertex_colors = colors
		holder.add_child(wedge)
		var crest := Line2D.new()
		crest.name = "Crest"
		crest.points = PackedVector2Array([Vector2(0.0, -half_width), Vector2(0.0, half_width)])
		crest.width = CREST_WIDTH
		crest.default_color = CREST_COLOR
		crest.antialiased = true
		holder.add_child(crest)
		holder.add_child(_chevron("ChevronIn", -ramp.half_length * 0.5, half_width * 0.6, 1.0))
		holder.add_child(_chevron("ChevronOut", ramp.half_length * 0.5, half_width * 0.6, -1.0))
		_visual_count += 1


func visual_count() -> int:
	return _visual_count


## Where a wedge corner's colour is sampled, in the ramp's frame: the corner moved SAMPLE_INSET
## inward on each axis it sits on the edge of.
static func sample_point(corner: Vector2) -> Vector2:
	return Vector2(corner.x - signf(corner.x) * SAMPLE_INSET, corner.y - signf(corner.y) * SAMPLE_INSET)


## A chevron at along_x whose point faces the crest (direction +1 points toward +x).
func _chevron(chevron_name: String, along_x: float, half_span: float, direction: float) -> Line2D:
	var line := Line2D.new()
	line.name = chevron_name
	var depth := half_span * 0.5 * direction
	line.points = PackedVector2Array([
		Vector2(along_x - depth, -half_span),
		Vector2(along_x + depth, 0.0),
		Vector2(along_x - depth, half_span),
	])
	line.width = CHEVRON_WIDTH
	line.default_color = CHEVRON_COLOR
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.antialiased = true
	return line
