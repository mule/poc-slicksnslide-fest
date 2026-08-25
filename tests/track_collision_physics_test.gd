extends SceneTree

const TrackGeneratorScript := preload("res://track/track_generator.gd")

const ORDINARY_RACING_SPEED := 300.0
const TEST_TICKS_PER_SECOND := 60.0
const TEST_BODY_RADIUS := 4.0
const SWEEP_START_CLEARANCE := 12.0
const JOINT_TRAVERSAL_COUNT := 28

## The probe is held against the wall by this much outward push while it drives forward, so each
## step lands slightly off the straight line to the target and only its cosine closes the gap.
const OUTWARD_BIAS := 36.0
## A joint counts as reached inside this distance, so a probe can start the next joint this far
## behind the joint it just cleared.
const JOINT_ARRIVAL_TOLERANCE := 1.5
## Widest boundary joint gap as a multiple of the generator's nominal sample spacing. Measured
## across seeds 0/4/9: gaps run 21.50-30.46 px against SAMPLE_SPACING = 25.0, i.e. up to 1.22x.
const JOINT_GAP_TO_SPACING := 1.25
## Headroom between the quality bar and the loop's escape cap. These must stay two different
## numbers: the assertion compares the *measured* tick count, which the loop bounds by its own
## cap, so collapsing them would make the check structurally incapable of failing.
const JOINT_TRAVERSAL_ESCAPE_MARGIN := 4

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

		if _break_collision and seed == 0:
			_break_representative_joint(runtime, definition)

		await _verify_sweeps_stop_at_segments_and_joints(world, definition, seed)
		await _verify_body_traverses_contacting_joints(world, definition, seed)
		world.queue_free()
		await process_frame
		await physics_frame
		_physics_ticks += 1

	_finish()


func _verify_sweeps_stop_at_segments_and_joints(world: Node2D, definition, seed: int) -> void:
	var unique_count: int = definition.centerline.size() - 1
	var representative_indices := [1, unique_count / 4, unique_count / 2, unique_count * 3 / 4]
	for edge_name in ["left", "right"]:
		var boundary: PackedVector2Array = definition.left_boundary if edge_name == "left" else definition.right_boundary
		for sample_index in representative_indices:
			var collision_result := await _sweep_body_outward(world, definition.centerline, boundary, sample_index)
			_check(collision_result.hit, "seed %d %s edge sample/joint %d blocks a body at %.0f units/s" % [seed, edge_name, sample_index, ORDINARY_RACING_SPEED])
			_check(collision_result.outside_distance <= 0.5, "seed %d %s edge sample/joint %d does not tunnel (outside %.2f)" % [seed, edge_name, sample_index, collision_result.outside_distance])


func _sweep_body_outward(world: Node2D, centerline: PackedVector2Array, boundary: PackedVector2Array, sample_index: int) -> Dictionary:
	var body := _create_test_body()
	world.add_child(body)
	var edge_position: Vector2 = boundary[sample_index]
	var inward := (centerline[sample_index] - edge_position).normalized()
	var outward := -inward
	body.position = edge_position + inward * (TEST_BODY_RADIUS + SWEEP_START_CLEARANCE)
	await physics_frame
	_physics_ticks += 1

	var hit := false
	var motion_per_tick := outward * (ORDINARY_RACING_SPEED / TEST_TICKS_PER_SECOND)
	for _tick in range(12):
		var collision := body.move_and_collide(motion_per_tick)
		if collision != null:
			hit = true
		await physics_frame
		_physics_ticks += 1
	var outside_distance := (body.position - edge_position).dot(outward)
	body.queue_free()
	await process_frame
	return {"hit": hit, "outside_distance": outside_distance}


func _verify_body_traverses_contacting_joints(world: Node2D, definition, seed: int) -> void:
	var boundary: PackedVector2Array = definition.right_boundary
	var unique_count: int = definition.centerline.size() - 1
	var first_curve_index := _find_first_curve_index(definition.centerline)
	var start_index := maxi(first_curve_index - 5, 0)
	var body := _create_test_body()
	world.add_child(body)
	var start_outward: Vector2 = (boundary[start_index] - definition.centerline[start_index]).normalized()
	body.position = boundary[start_index] - start_outward * (TEST_BODY_RADIUS + 0.25)
	await physics_frame
	_physics_ticks += 1

	# One tick closes at most step_per_tick, and the outward bias angles each step away from the
	# straight line to the target, so only its cosine counts. Size the bar off the widest gap the
	# generator can produce rather than the gaps these three seeds happen to contain.
	var step_per_tick: float = ORDINARY_RACING_SPEED / TEST_TICKS_PER_SECOND
	var closing_step: float = step_per_tick * cos(atan(OUTWARD_BIAS / ORDINARY_RACING_SPEED))
	var widest_gap: float = TrackGeneratorScript.SAMPLE_SPACING * JOINT_GAP_TO_SPACING
	var approach := widest_gap + JOINT_ARRIVAL_TOLERANCE - step_per_tick
	var quality_ticks: int = int(ceil(approach / closing_step)) + 1
	var escape_ticks: int = quality_ticks + JOINT_TRAVERSAL_ESCAPE_MARGIN

	var reached_joints := 0
	var maximum_ticks_for_joint := 0
	var contact_count := 0
	for offset in range(1, JOINT_TRAVERSAL_COUNT + 1):
		var sample_index := (start_index + offset) % unique_count
		var outward: Vector2 = (boundary[sample_index] - definition.centerline[sample_index]).normalized()
		var target: Vector2 = boundary[sample_index] - outward * (TEST_BODY_RADIUS + 0.25)
		var ticks_for_joint := 0
		while body.position.distance_to(target) > JOINT_ARRIVAL_TOLERANCE and ticks_for_joint < escape_ticks:
			var toward_target: Vector2 = body.position.direction_to(target)
			var remaining: float = body.position.distance_to(target)
			var commanded_velocity: Vector2 = (toward_target * ORDINARY_RACING_SPEED + outward * OUTWARD_BIAS) \
				.limit_length(minf(ORDINARY_RACING_SPEED, remaining * TEST_TICKS_PER_SECOND))
			contact_count += _move_and_slide_remainder(body, commanded_velocity / TEST_TICKS_PER_SECOND)
			ticks_for_joint += 1
			await physics_frame
			_physics_ticks += 1
		maximum_ticks_for_joint = maxi(maximum_ticks_for_joint, ticks_for_joint)
		if body.position.distance_to(target) <= JOINT_ARRIVAL_TOLERANCE:
			reached_joints += 1
		else:
			break

	_check(reached_joints == JOINT_TRAVERSAL_COUNT, "seed %d body traverses %d contacting edge joints without snagging (%d contacts)" % [seed, JOINT_TRAVERSAL_COUNT, contact_count])
	_check(maximum_ticks_for_joint <= quality_ticks, "seed %d contacting joint traversal maintains ordinary racing progress (max %d ticks/joint, bar %d, escape %d)" % [seed, maximum_ticks_for_joint, quality_ticks, escape_ticks])
	_check(contact_count > 0, "seed %d joint traversal exercises real edge contacts" % seed)
	body.queue_free()
	await process_frame


func _move_and_slide_remainder(body: CharacterBody2D, motion: Vector2) -> int:
	var collision := body.move_and_collide(motion)
	if collision == null:
		return 0
	var remainder := collision.get_remainder().slide(collision.get_normal())
	if remainder.length_squared() > 0.0001:
		body.move_and_collide(remainder)
	return 1


func _create_test_body() -> CharacterBody2D:
	var body := CharacterBody2D.new()
	body.name = "OrdinarySpeedPhysicsProbe"
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


## The first sample whose heading change clears the generator's own straight/curve boundary.
## The previous version returned the first sample below centerline[0] in y, which only meant
## something while index 0 sat on a horizontal stadium straight. Against a spline with an
## arbitrary start heading it returned 1 for seeds 4 and 9 -- inside the mandated start straight,
## where there is no curve at all -- and 770 for seed 0.
func _find_first_curve_index(centerline: PackedVector2Array) -> int:
	var unique_count: int = centerline.size() - 1
	var straight_turn: float = TrackGeneratorScript.STRAIGHT_CURVATURE * TrackGeneratorScript.SAMPLE_SPACING
	for index in range(1, unique_count):
		var incoming: Vector2 = centerline[index] - centerline[index - 1]
		var outgoing: Vector2 = centerline[(index + 1) % unique_count] - centerline[index]
		if incoming.length_squared() < 0.000001 or outgoing.length_squared() < 0.000001:
			continue
		if absf(incoming.angle_to(outgoing)) > straight_turn:
			return index
	return 1


func _break_representative_joint(runtime: Node, definition) -> void:
	var body := runtime.get_node("TrackEdges") as StaticBody2D
	var center_index := int((definition.centerline.size() - 1) / 4)
	for index in range(center_index - 4, center_index + 5):
		var shape := body.get_node_or_null("RightEdge%03d" % index)
		if shape != null:
			shape.free()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	print("track_collision_physics speed=%.0f ticks_per_second=%.0f physics_ticks=%d checks=%d mutation=%s" % [
		ORDINARY_RACING_SPEED,
		TEST_TICKS_PER_SECOND,
		_physics_ticks,
		_checks,
		str(_break_collision),
	])
	if _failures.is_empty():
		print("Procedural track collision physics checks passed")
		quit(0)
		return
	for failure in _failures:
		push_error("Procedural track collision physics check failed: %s" % failure)
	quit(1)
