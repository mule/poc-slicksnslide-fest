class_name TrackRuntime
extends Node2D

const GRASS_COLOR := Color("426b32")
const DIRT_COLOR := Color("895426")
const EDGE_COLOR := Color("c7a15f")

var definition


func _init(initial_definition = null) -> void:
	definition = initial_definition


func _ready() -> void:
	if definition == null:
		push_error("TrackRuntime requires a TrackDefinition")
		return
	_build_line("GrassShoulder", definition.track_width + 24.0, GRASS_COLOR, -3)
	_build_line("Dirt", definition.track_width, DIRT_COLOR, -2)
	_build_boundary_line("LeftEdge", definition.left_boundary)
	_build_boundary_line("RightEdge", definition.right_boundary)
	_build_start_finish_line()
	_build_collision()


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
	line.width = 2.0
	line.default_color = EDGE_COLOR
	line.antialiased = true
	line.z_index = -1
	add_child(line)


func _build_start_finish_line() -> void:
	if definition.checkpoints.is_empty():
		return
	var checkpoint: Transform2D = definition.checkpoints[0]
	var lateral := checkpoint.y.normalized()
	var half_width: float = definition.track_width * 0.5
	var line := Line2D.new()
	line.name = "StartFinishLine"
	line.points = PackedVector2Array([
		checkpoint.origin - lateral * half_width,
		checkpoint.origin + lateral * half_width,
	])
	line.width = 5.0
	line.default_color = Color("f4edc9")
	line.antialiased = true
	line.z_index = 0
	add_child(line)


func _build_collision() -> void:
	var body := StaticBody2D.new()
	body.name = "TrackEdges"
	add_child(body)
	_add_boundary_collision(body, definition.left_boundary, "Left")
	_add_boundary_collision(body, definition.right_boundary, "Right")


func _add_boundary_collision(body: StaticBody2D, points: PackedVector2Array, prefix: String) -> void:
	for index in range(points.size() - 1):
		var shape := SegmentShape2D.new()
		shape.a = points[index]
		shape.b = points[index + 1]
		var collision := CollisionShape2D.new()
		collision.name = "%sEdge%03d" % [prefix, index]
		collision.shape = shape
		body.add_child(collision)
