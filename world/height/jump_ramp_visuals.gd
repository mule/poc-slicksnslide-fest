class_name JumpRampVisuals
extends Node2D

## One wedge per valid ramp: a lighter dirt quad the width of the road, a crest line, and a
## chevron on each face pointing at the crest. Pure presentation; never touches physics.

const WEDGE_COLOR := Color("9c6a33")
const CREST_COLOR := Color("e2c98a")
const CHEVRON_COLOR := Color("c7a15f")
const CREST_WIDTH := 6.0
const CHEVRON_WIDTH := 4.0

var _visual_count := 0


func build(ramps: Array[JumpRampPlacement]) -> void:
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
		wedge.polygon = PackedVector2Array([
			Vector2(-ramp.half_length, -half_width),
			Vector2(ramp.half_length, -half_width),
			Vector2(ramp.half_length, half_width),
			Vector2(-ramp.half_length, half_width),
		])
		wedge.color = WEDGE_COLOR
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
