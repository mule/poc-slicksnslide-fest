class_name TrackRuntime
extends Node2D

const GRASS_COLOR := Color("426b32")
const DIRT_COLOR := Color("895426")
const EDGE_COLOR := Color("c7a15f")
## Deliberately the same hue as EDGE_COLOR today, so the gates read as part of the track's own
## furniture rather than an overlay. Kept separate so the boundary line can be retuned without
## silently moving the gates with it.
const GATE_COLOR := Color("c7a15f")
const START_FINISH_COLOR := Color("f4edc9")
const START_FINISH_WIDTH := 15.0
const NEXT_GATE_WIDTH := 12.0
const GATE_WIDTH := 8.0
## Gates that are not the one you need next. Low enough to read as background, high enough to still
## show the circuit's shape ahead of you.
const INACTIVE_GATE_ALPHA := 0.35

var definition

var _checkpoint_markers: Array[Line2D] = []
var _next_checkpoint := 0


func _init(initial_definition = null) -> void:
	y_sort_enabled = true
	definition = initial_definition


func _ready() -> void:
	if definition == null:
		push_error("TrackRuntime requires a TrackDefinition")
		return
	_build_line("GrassShoulder", definition.track_width * 1.4, GRASS_COLOR, -3)
	_build_line("Dirt", definition.track_width, DIRT_COLOR, -2)
	_build_jump_ramps()
	_build_boundary_line("LeftEdge", definition.left_boundary)
	_build_boundary_line("RightEdge", definition.right_boundary)
	_build_checkpoint_markers()
	_build_collision()
	var object_runtime := OfftrackObjectRuntime.new(
		definition.offtrack_objects,
		preload("res://data/default_offtrack_object_catalog.tres"),
	)
	add_child(object_runtime)


func _build_jump_ramps() -> void:
	var visuals := JumpRampVisuals.new()
	visuals.name = "JumpRamps"
	visuals.z_index = -1
	add_child(visuals)
	visuals.build(definition.jump_ramps)


func _build_line(line_name: String, width: float, color: Color, z_layer: int) -> void:
	var line := Line2D.new()
	line.name = line_name
	line.points = definition.centerline
	line.width = width
	line.default_color = color
	line.joint_mode = Line2D.LINE_JOINT_ROUND
	line.begin_cap_mode = Line2D.LINE_CAP_ROUND
	line.end_cap_mode = Line2D.LINE_CAP_ROUND
	line.antialiased = true
	line.z_index = z_layer
	add_child(line)


func _build_boundary_line(line_name: String, points: PackedVector2Array) -> void:
	var line := Line2D.new()
	line.name = line_name
	line.points = points
	line.width = 6.0
	line.default_color = EDGE_COLOR
	line.antialiased = true
	line.z_index = -1
	add_child(line)


## One gate per checkpoint, not just the finish line. The gates are ordered and unforgiving --
## passing them out of sequence silently voids the lap -- and on a circuit 5.5 to 8 screens wide you
## cannot see which one is next. So width and hue mark the start/finish, and alpha alone carries
## "this is the one you need", keeping one visual channel per meaning.
func _build_checkpoint_markers() -> void:
	_checkpoint_markers.clear()
	var half_width: float = definition.track_width * 0.5
	for index in range(definition.checkpoints.size()):
		var checkpoint: Transform2D = definition.checkpoints[index]
		var lateral := checkpoint.y.normalized()
		var line := Line2D.new()
		line.name = "Checkpoint%d" % index
		line.points = PackedVector2Array([
			checkpoint.origin - lateral * half_width,
			checkpoint.origin + lateral * half_width,
		])
		line.antialiased = true
		line.z_index = -1
		add_child(line)
		_checkpoint_markers.append(line)
	set_next_checkpoint(_next_checkpoint)


## Index of the gate the driver must cross next, as reported by LapProgressTracker. Safe to call
## before the markers exist; the value is reapplied when they are built.
func set_next_checkpoint(index: int) -> void:
	_next_checkpoint = index
	for marker_index in range(_checkpoint_markers.size()):
		var line: Line2D = _checkpoint_markers[marker_index]
		var is_start_finish := marker_index == 0
		var is_next := marker_index == index
		var color: Color = START_FINISH_COLOR if is_start_finish else GATE_COLOR
		color.a = 1.0 if is_next else INACTIVE_GATE_ALPHA
		line.default_color = color
		if is_start_finish:
			line.width = START_FINISH_WIDTH
		else:
			line.width = NEXT_GATE_WIDTH if is_next else GATE_WIDTH


## The circuit has no walls. A single rectangle far outside the track keeps the car recoverable
## without turning the boundary line into a barrier. This also drops collision shapes per track
## from roughly 2,500 to 4.
func _build_collision() -> void:
	var body := StaticBody2D.new()
	body.name = "PlayAreaBounds"
	# Must stay on the tall layer so an airborne car that drops the low layer from its mask cannot
	# escape past the world boundary. Named, not a literal 1, so the invariant moves with the
	# constant instead of holding by coincidence.
	body.collision_layer = OfftrackObjectCollisions.TALL_LAYER
	body.collision_mask = 0
	add_child(body)
	var area: Rect2 = definition.play_area
	var corners := [
		area.position,
		Vector2(area.end.x, area.position.y),
		area.end,
		Vector2(area.position.x, area.end.y),
	]
	for index in range(corners.size()):
		var shape := SegmentShape2D.new()
		shape.a = corners[index]
		shape.b = corners[(index + 1) % corners.size()]
		var collision := CollisionShape2D.new()
		collision.name = "Edge%d" % index
		collision.shape = shape
		body.add_child(collision)
