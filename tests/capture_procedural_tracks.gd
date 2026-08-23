extends SceneTree

const OUTPUT_PATH := "res://docs/evidence/procedural-tracks-seeds-0-5.png"
const CAPTURE_SIZE := Vector2i(1200, 800)
const CELL_SIZE := Vector2(400.0, 400.0)
const BACKGROUND := Color("152219")
const GRASS := Color("426b32")
const DIRT := Color("895426")
const EDGE := Color("d4b36f")


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var generator_script := load("res://track/track_generator.gd") as GDScript
	var runtime_script := load("res://track/track_runtime.gd") as GDScript
	if generator_script == null or runtime_script == null:
		push_error("Cannot load procedural track capture dependencies")
		quit(1)
		return

	var image := Image.create(CAPTURE_SIZE.x, CAPTURE_SIZE.y, false, Image.FORMAT_RGBA8)
	image.fill(BACKGROUND)
	var generator = generator_script.new()
	for seed in range(6):
		var row := seed / 3
		var column := seed % 3
		var cell_origin := Vector2(column, row) * CELL_SIZE
		var definition = generator.generate(seed)
		var available := CELL_SIZE - Vector2(42.0, 42.0)
		var scale_factor: float = minf(available.x / definition.bounds.size.x, available.y / definition.bounds.size.y)
		var offset: Vector2 = cell_origin + CELL_SIZE * 0.5 - definition.bounds.get_center() * scale_factor
		_draw_polyline(image, definition.centerline, scale_factor, offset, (definition.track_width + 24.0) * scale_factor, GRASS)
		_draw_polyline(image, definition.centerline, scale_factor, offset, definition.track_width * scale_factor, DIRT)
		_draw_polyline(image, definition.left_boundary, scale_factor, offset, 2.0, EDGE)
		_draw_polyline(image, definition.right_boundary, scale_factor, offset, 2.0, EDGE)
		_draw_seed_marker(image, cell_origin + Vector2(16.0, 16.0), seed)

	for x in [399, 400, 799, 800]:
		_draw_axis_line(image, Vector2(x, 0), Vector2(x, CAPTURE_SIZE.y - 1), Color("38503d"))
	for y in [399, 400]:
		_draw_axis_line(image, Vector2(0, y), Vector2(CAPTURE_SIZE.x - 1, y), Color("38503d"))

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs/evidence"))
	var save_error := image.save_png(OUTPUT_PATH)
	if save_error != OK:
		push_error("Cannot save procedural track evidence: error %d" % save_error)
		quit(1)
		return
	print("Saved procedural track evidence to %s" % ProjectSettings.globalize_path(OUTPUT_PATH))
	quit(0)


func _draw_polyline(image: Image, points: PackedVector2Array, scale_factor: float, offset: Vector2, width: float, color: Color) -> void:
	for index in range(points.size() - 1):
		_draw_thick_segment(image, points[index] * scale_factor + offset, points[index + 1] * scale_factor + offset, width, color)


func _draw_thick_segment(image: Image, from: Vector2, to: Vector2, width: float, color: Color) -> void:
	var steps := maxi(ceili(from.distance_to(to)), 1)
	var radius := maxi(ceili(width * 0.5), 1)
	for step in range(steps + 1):
		var center := from.lerp(to, float(step) / float(steps))
		_draw_disc(image, Vector2i(roundi(center.x), roundi(center.y)), radius, color)


func _draw_disc(image: Image, center: Vector2i, radius: int, color: Color) -> void:
	var radius_squared := radius * radius
	for y_offset in range(-radius, radius + 1):
		for x_offset in range(-radius, radius + 1):
			if x_offset * x_offset + y_offset * y_offset > radius_squared:
				continue
			var pixel := center + Vector2i(x_offset, y_offset)
			if pixel.x >= 0 and pixel.x < image.get_width() and pixel.y >= 0 and pixel.y < image.get_height():
				image.set_pixelv(pixel, color)


func _draw_seed_marker(image: Image, origin: Vector2, seed: int) -> void:
	# Six bars make the row-major seed ordering visible without font/rendering dependencies.
	for bar in range(seed + 1):
		var from := origin + Vector2(bar * 7, 0)
		_draw_thick_segment(image, from, from + Vector2(0, 20), 4.0, Color("f3dfad"))


func _draw_axis_line(image: Image, from: Vector2, to: Vector2, color: Color) -> void:
	_draw_thick_segment(image, from, to, 1.0, color)
