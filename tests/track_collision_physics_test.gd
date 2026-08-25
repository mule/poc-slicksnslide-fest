extends SceneTree

## Containment coverage. The circuit has no walls; a single rectangle far outside the track
## keeps the car recoverable and stops it reaching the featureless void beyond the background.

const ORDINARY_RACING_SPEED := 300.0
const TEST_TICKS_PER_SECOND := 60.0
const TEST_BODY_RADIUS := 4.0
## `play_area = bounds.grow(PLAY_AREA_MARGIN)`, and every centerline point lies inside `bounds`,
## so the nearest play-area edge is never closer than PLAY_AREA_MARGIN (2000 px) from a start
## point on the centerline. At 5 px/tick, 500 ticks covers 2500 px — enough to clear that 2000 px
## floor with margin to spare (measured minimum across seeds 0/4/9 is ~2400 px) so a probe with
## containment removed actually reaches and passes the boundary instead of running out of ticks
## first.
const ESCAPE_TICKS := 500
## The probe is a point-like body; allow its radius plus solver margin outside the nominal edge.
const CONTAINMENT_TOLERANCE := 8.0

var _failures: Array[String] = []
var _checks := 0
var _physics_ticks := 0
var _break_collision := false


func _initialize() -> void:
	_break_collision = OS.get_cmdline_user_args().has("--break-collision")
	call_deferred("_run")


func _run() -> void:
	var generator_script := load("res://track/track_generator.gd") as GDScript
	var runtime_script := load("res://track/track_runtime.gd") as GDScript
	_check(generator_script != null, "real TrackGenerator loads")
	_check(runtime_script != null, "real TrackRuntime loads")
	if generator_script == null or runtime_script == null:
		_finish()
		return

	var generator = generator_script.new()
	for seed in [0, 4, 9]:
		var definition = generator.generate(seed)
		var world := Node2D.new()
		world.name = "PhysicsWorldSeed%d" % seed
		root.add_child(world)
		var runtime = runtime_script.new(definition)
		world.add_child(runtime)
		await physics_frame
		_physics_ticks += 1

		_verify_bounds_body_exists(runtime, seed)
		if _break_collision:
			_remove_containment(runtime)
		await _verify_probe_stays_inside(world, definition, seed)

		world.queue_free()
		await process_frame
		await physics_frame
		_physics_ticks += 1

	_finish()


func _verify_bounds_body_exists(runtime: Node, seed: int) -> void:
	var body := runtime.get_node_or_null("PlayAreaBounds") as StaticBody2D
	_check(body != null, "seed %d builds a PlayAreaBounds body" % seed)
	if body == null:
		return
	_check(body.get_child_count() == 4, "seed %d containment is four segments (got %d)" % [seed, body.get_child_count()])
	_check(runtime.get_node_or_null("TrackEdges") == null, "seed %d builds no per-segment track walls" % seed)


func _remove_containment(runtime: Node) -> void:
	var body := runtime.get_node_or_null("PlayAreaBounds") as StaticBody2D
	if body == null:
		return
	for child in body.get_children():
		body.remove_child(child)
		child.queue_free()


## Drive a probe outward from the track towards each side of the play area and confirm the
## containment boundary stops it. Four runs per seed, one per edge.
func _verify_probe_stays_inside(world: Node2D, definition, seed: int) -> void:
	var play_area: Rect2 = definition.play_area
	var directions := [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]
	var names := ["right", "left", "down", "up"]
	for index in range(directions.size()):
		var body := _create_test_body()
		world.add_child(body)
		body.position = definition.centerline[0]
		await physics_frame
		_physics_ticks += 1

		var direction: Vector2 = directions[index]
		for tick in range(ESCAPE_TICKS):
			body.move_and_collide(direction * ORDINARY_RACING_SPEED / TEST_TICKS_PER_SECOND)
			await physics_frame
			_physics_ticks += 1

		var grown := play_area.grow(CONTAINMENT_TOLERANCE)
		_check(
			grown.has_point(body.position),
			"seed %d probe driven %s stays inside the play area (at %.1f,%.1f)" % [seed, names[index], body.position.x, body.position.y]
		)
		body.queue_free()
		await process_frame


func _create_test_body() -> CharacterBody2D:
	var body := CharacterBody2D.new()
	body.name = "ContainmentProbe"
	body.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	body.collision_layer = 2
	body.collision_mask = 1
	body.safe_margin = 0.05
	var collision_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = TEST_BODY_RADIUS
	collision_shape.shape = circle
	body.add_child(collision_shape)
	return body


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	print("track_containment physics_ticks=%d checks=%d mutation=%s" % [_physics_ticks, _checks, str(_break_collision)])
	if _failures.is_empty():
		print("Track containment checks passed")
		quit(0)
		return
	for failure in _failures:
		push_error("Track containment check failed: %s" % failure)
	quit(1)
