extends SceneTree

## Containment coverage. The circuit has no walls; a single rectangle far outside the track
## keeps the car recoverable and stops it reaching the featureless void beyond the background.

const ORDINARY_RACING_SPEED := 300.0
const TEST_TICKS_PER_SECOND := 60.0
const TEST_BODY_RADIUS := 4.0
const TEST_STEP := ORDINARY_RACING_SPEED / TEST_TICKS_PER_SECOND
## The distance from a probe's start point (`centerline[0]`) to the play-area edge it is driven
## towards varies enormously by seed and direction — from ~2400 px to over 12000 px across seeds
## 0/4/9. A single fixed tick budget sized for the nearest case leaves every farther probe
## stopping thousands of pixels short of the wall, never touching it, so the "stays inside" check
## passes trivially whether or not containment exists. Instead, the tick budget is derived per
## direction from the actual distance between the start point and that edge of `definition.play_area`,
## plus a small tick slack, so every probe is guaranteed to travel far enough to actually reach and
## be stopped by the boundary — and stays correct if seeds, SAMPLE_SPACING, the tick rate, or
## ORDINARY_RACING_SPEED ever change.
const ESCAPE_SLACK_TICKS := 20
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

		# Each verification reports whether it ran to completion. A GDScript runtime error aborts
		# only the function it occurs in and returns false to here, so without this the script
		# would exit 0 with assertions silently skipped. See tests/harness_contract_test.gd.
		_check(_verify_bounds_body_exists(runtime, seed), "the bounds body exists verification ran to completion")
		if _break_collision:
			_remove_containment(runtime)
		_check(await _verify_probe_stays_inside(world, definition, seed), "the probe stays inside verification ran to completion")
		world.queue_free()
		await process_frame
		await physics_frame
		_physics_ticks += 1

	_finish()


func _verify_bounds_body_exists(runtime: Node, seed: int) -> bool:
	var body := runtime.get_node_or_null("PlayAreaBounds") as StaticBody2D
	_check(body != null, "seed %d builds a PlayAreaBounds body" % seed)
	if body == null:
		return false
	_check(body.get_child_count() == 4, "seed %d containment is four segments (got %d)" % [seed, body.get_child_count()])
	_check(runtime.get_node_or_null("TrackEdges") == null, "seed %d builds no per-segment track walls" % seed)
	return true


func _remove_containment(runtime: Node) -> void:
	var body := runtime.get_node_or_null("PlayAreaBounds") as StaticBody2D
	if body == null:
		return
	for child in body.get_children():
		body.remove_child(child)
		child.queue_free()


## Drive a probe outward from the track towards each side of the play area and confirm it
## actually reaches the containment boundary and is stopped there. Four runs per seed, one per
## edge.
func _verify_probe_stays_inside(world: Node2D, definition, seed: int) -> bool:
	var play_area: Rect2 = definition.play_area
	var start: Vector2 = definition.centerline[0]
	var directions := [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP]
	var names := ["right", "left", "down", "up"]
	for index in range(directions.size()):
		var direction: Vector2 = directions[index]
		var name: String = names[index]
		var edge_coordinate: float
		var edge_distance: float
		match name:
			"right":
				edge_coordinate = play_area.end.x
				edge_distance = edge_coordinate - start.x
			"left":
				edge_coordinate = play_area.position.x
				edge_distance = start.x - edge_coordinate
			"down":
				edge_coordinate = play_area.end.y
				edge_distance = edge_coordinate - start.y
			"up":
				edge_coordinate = play_area.position.y
				edge_distance = start.y - edge_coordinate
		var escape_ticks := int(ceil(edge_distance / TEST_STEP)) + ESCAPE_SLACK_TICKS

		var body := _create_test_body()
		world.add_child(body)
		body.position = start
		await physics_frame
		_physics_ticks += 1

		for tick in range(escape_ticks):
			body.move_and_collide(direction * TEST_STEP)
			await physics_frame
			_physics_ticks += 1

		var grown := play_area.grow(CONTAINMENT_TOLERANCE)
		_check(
			grown.has_point(body.position),
			"seed %d probe driven %s stays inside the play area (at %.1f,%.1f)" % [seed, name, body.position.x, body.position.y]
		)
		var reached_coordinate: float = body.position.x if (name == "right" or name == "left") else body.position.y
		_check(
			abs(reached_coordinate - edge_coordinate) <= CONTAINMENT_TOLERANCE,
			"seed %d probe driven %s reaches the play area boundary (at %.1f,%.1f, edge %.1f, %d ticks budgeted)" % [seed, name, body.position.x, body.position.y, edge_coordinate, escape_ticks]
		)
		body.queue_free()
		await process_frame
	return true


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
