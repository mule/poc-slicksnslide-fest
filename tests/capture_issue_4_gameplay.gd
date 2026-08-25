extends SceneTree

## Deterministic evidence capture from the real physics body. SVG frames keep
## capture available on CI's dummy renderer; GStreamer packages them as WebM.

const CAPTURE_PATH := "res://docs/vehicle/evidence/issue-4-gameplay-still.svg"
const DRIFT_CAPTURE_PATH := "res://docs/vehicle/evidence/issue-4-drift-recovery.svg"
const FRAME_DIRECTORY := "/tmp/issue-4-gameplay-frames"
const START_POSE := Transform2D(0.0, Vector2(4000.0, 6500.0))
## Distance scaled by 12.5 alongside speed, so the maneuver phases (accel,
## handbrake, counter-steer) still land on the same tick numbers as before the
## rescale. But the car now needs materially longer to close the approach and
## settle after impact, so the run itself was extended from 480 to 600 ticks;
## verified against an instrumented run: first wall contact lands at tick 507,
## speed settles below 2 px/s by roughly tick 525.
const TOTAL_TICKS := 600
const DRIFT_CAPTURE_TICK := 235
## The physics arena is sized in real world pixels (12.5 px/m) so the capture
## exercises the actual tuning at the actual terminal speed. The 1280x720 SVG
## canvas cannot show that arena at 1:1, so every drawn position is converted
## through WorldScale.to_metres() before it is used as an SVG coordinate; that
## recovers exactly the old, canvas-sized numbers because the old hand-picked
## arena constants were themselves already metre-scaled.

var _car: TopDownCar
var _controls := VehicleInputState.new()
var _frame_index := 0
var _last_video_frame_collision_count := -1
var _trail: PackedVector2Array = []
var _capture_failed := false


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	DirAccess.make_dir_recursive_absolute(FRAME_DIRECTORY)
	var arena := Node2D.new()
	root.add_child(arena)
	_add_wall(arena)
	var scene := load("res://vehicle/top_down_car.tscn") as PackedScene
	_car = scene.instantiate() as TopDownCar
	_car.global_transform = START_POSE
	_car.set_input_state(_controls)
	var provider := Issue4TestSurfaceProvider.new()
	provider.boundary_y = 4875.0
	_car.set_surface_query(provider)
	arena.add_child(_car)
	_car.set_safe_reset_pose(START_POSE)
	await physics_frame

	for tick in TOTAL_TICKS:
		_drive_tick(tick)
		await physics_frame
		_trail.append(_car.global_position)
		if tick % 4 == 0:
			_save_svg("%s/frame_%03d.svg" % [FRAME_DIRECTORY, _frame_index], tick)
			_last_video_frame_collision_count = _car.get_collision_count()
			_frame_index += 1
		if tick == DRIFT_CAPTURE_TICK:
			_save_svg(DRIFT_CAPTURE_PATH, tick)
	_save_svg("%s/frame_%03d.svg" % [FRAME_DIRECTORY, _frame_index - 1], TOTAL_TICKS - 1)
	_last_video_frame_collision_count = _car.get_collision_count()
	if _car.get_collision_count() < 1:
		_capture_failed = true
		push_error("Evidence capture ended before a real wall contact")
	if _last_video_frame_collision_count < 1:
		_capture_failed = true
		push_error("Last generated video frame does not show the real wall contact")
	if _car.get_collision_count() >= 1 and _car.get_speed() > 2.0:
		_capture_failed = true
		push_error("Evidence capture ended before the post-impact state settled")
	_save_svg(CAPTURE_PATH, TOTAL_TICKS - 1)
	if _capture_failed:
		quit(1)
		return
	print(
		"Saved issue #4 gameplay evidence: contacts=%d final_speed=%.2f center_y=%.2f"
		% [_car.get_collision_count(), _car.get_speed(), _car.global_position.y]
	)
	quit(0)


func _drive_tick(tick: int) -> void:
	if tick < 150:
		_controls.set_controls(0.0, 1.0, 0.0, 0.0)
	elif tick < 210:
		_controls.set_controls(0.85, 0.55, 0.0, 1.0)
	elif tick < 300:
		_controls.set_controls(-0.75, 0.3, 0.0, 0.0)
	else:
		if tick == 300:
			_car.set_safe_reset_pose(Transform2D(0.0, Vector2(4000.0, 5375.0)))
			_car.request_safe_reset()
			_trail = PackedVector2Array()
		_controls.set_controls(0.0, 1.0, 0.0, 0.0)


func _phase_for_tick(tick: int) -> String:
	if tick < 150:
		return "ACCELERATION"
	if tick < 210:
		return "HANDBRAKE ROTATION"
	if tick < 300:
		return "COUNTER-STEER RECOVERY"
	return "RESET · GRASS · WALL IMPACT"


func _to_canvas(world_pos: Vector2) -> Vector2:
	return Vector2(WorldScale.to_metres(world_pos.x), WorldScale.to_metres(world_pos.y))


func _save_svg(path: String, tick: int) -> void:
	var metrics := _car.get_diagnostics()
	var car_canvas := _to_canvas(_car.global_position)
	var trail_points := ""
	for point in _trail:
		var canvas_point := _to_canvas(point)
		trail_points += "%.1f,%.1f " % [canvas_point.x, canvas_point.y]
	var lead := _car.linear_velocity * _car.tuning.camera_lead_seconds
	lead = lead.limit_length(_car.tuning.camera_max_lead)
	var lead_target := _to_canvas(_car.global_position + lead)
	var skid_opacity := clampf(float(metrics.slip) * 2.2 + _controls.handbrake * 0.65, 0.0, 0.9)
	var lines := PackedStringArray([
		"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1280\" height=\"720\" viewBox=\"0 0 1280 720\">",
		"<rect width=\"1280\" height=\"720\" fill=\"#24451f\"/>",
		"<rect y=\"390\" width=\"1280\" height=\"330\" fill=\"#815127\"/>",
		"<line x1=\"0\" y1=\"390\" x2=\"1280\" y2=\"390\" stroke=\"#caa15d\" stroke-width=\"5\"/>",
		"<text x=\"680\" y=\"383\" fill=\"#fff3d2\" font-family=\"sans-serif\" font-size=\"17\">DIRT / GRASS BOUNDARY</text>",
		"<rect x=\"30\" y=\"339\" width=\"580\" height=\"22\" rx=\"4\" fill=\"#ded5b9\" stroke=\"#514b40\" stroke-width=\"3\"/>",
		"<text x=\"620\" y=\"358\" fill=\"#fff\" font-family=\"sans-serif\" font-size=\"17\">COLLISION BOUNDARY</text>",
		"<polyline points=\"%s\" fill=\"none\" stroke=\"#20150d\" stroke-opacity=\"%.2f\" stroke-width=\"7\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>" % [trail_points, skid_opacity],
		"<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#68d4ff\" stroke-width=\"3\" stroke-dasharray=\"8 6\"/>" % [car_canvas.x, car_canvas.y, lead_target.x, lead_target.y],
		"<circle cx=\"%.1f\" cy=\"%.1f\" r=\"7\" fill=\"#68d4ff\"/>" % [lead_target.x, lead_target.y],
		"<g transform=\"translate(%.1f %.1f) rotate(%.1f)\">" % [car_canvas.x, car_canvas.y, rad_to_deg(_car.global_rotation)],
		"<ellipse cx=\"4\" cy=\"6\" rx=\"18\" ry=\"29\" fill=\"#071009\" opacity=\"0.45\"/>",
		"<path d=\"M -13 -24 L 13 -24 L 17 18 L 0 27 L -17 18 Z\" fill=\"#e12e12\" stroke=\"#fff1c5\" stroke-width=\"2\"/>",
		"<path d=\"M -9 -13 L 9 -13 L 11 2 L -11 2 Z\" fill=\"#122d36\"/>",
		"<path d=\"M -4 -21 L 4 -21 L 0 -29 Z\" fill=\"#ffd45a\"/>",
		"</g>",
		"<rect x=\"22\" y=\"20\" width=\"625\" height=\"142\" rx=\"7\" fill=\"#081008\" opacity=\"0.88\"/>",
		"<text x=\"38\" y=\"48\" fill=\"#fff3d2\" font-family=\"monospace\" font-size=\"19\">ISSUE #4 · %s</text>" % _phase_for_tick(tick),
		"<text x=\"38\" y=\"78\" fill=\"#e8f0dc\" font-family=\"monospace\" font-size=\"17\">speed %5.1f km/h   local %5.1f / %5.1f</text>" % [metrics.speed_kph, metrics.local_longitudinal, metrics.local_lateral],
		"<text x=\"38\" y=\"106\" fill=\"#e8f0dc\" font-family=\"monospace\" font-size=\"17\">slip %.2f   steer %+.2f   throttle %.2f   surface %s</text>" % [metrics.slip, metrics.steering, metrics.throttle, metrics.surface],
		"<text x=\"38\" y=\"136\" fill=\"#ffdd72\" font-family=\"monospace\" font-size=\"17\">contacts %d   %s   center y %.1f</text>" % [_car.get_collision_count(), "POST-IMPACT" if _car.get_collision_count() > 0 else "APPROACH", car_canvas.y],
		"<text x=\"790\" y=\"692\" fill=\"#fff3d2\" font-family=\"sans-serif\" font-size=\"16\">blue marker = bounded velocity camera lead</text>",
		"</svg>",
	])
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_capture_failed = true
		push_error("Could not open evidence frame %s" % path)
		return
	file.store_string("\n".join(lines))


func _add_wall(arena: Node2D) -> void:
	var wall := StaticBody2D.new()
	wall.position = Vector2(4000.0, 4375.0)
	var shape_node := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(7250.0, 275.0)
	shape_node.shape = shape
	wall.add_child(shape_node)
	arena.add_child(wall)
