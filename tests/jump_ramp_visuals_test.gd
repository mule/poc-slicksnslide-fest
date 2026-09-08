extends SceneTree

## Ramps draw one wedge each; the car's ground height lifts body and shadow together, straight up
## the screen, while only its height above the ground opens a gap, grows the body and fades the
## shadow (#52, the off-track objects' rule); an airborne car draws above y-sorted objects; and
## dust stays off in the air.

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
## The shadow offset the car scene bakes in: vehicle/top_down_car.tscn, Shadow.position.
const SHADOW_BASE := Vector2(4.0, 6.0)
## The airborne fixture must be clearly in the air before its gap is read, or a near-zero gap
## would pass every ratio below.
const AIRBORNE_GAP_FLOOR := 10.0

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(_verify_wedges(), "the wedge verification ran to completion")
	_check(await _verify_body_lift_and_shadow(), "the lift and shadow verification ran to completion")
	_check(await _verify_airborne_draw_order_and_dust(), "the draw order verification ran to completion")
	_check(_verify_overlay_line(), "the overlay verification ran to completion")
	_finish()


func _verify_wedges() -> bool:
	var visuals := JumpRampVisuals.new()
	root.add_child(visuals)
	var ramps: Array[JumpRampPlacement] = []
	ramps.append(_ramp("h1:0:10", Vector2(100.0, 0.0), 240.0))
	ramps.append(_ramp("h1:0:80", Vector2(900.0, 0.0), 200.0))
	var invalid := _ramp("h1:0:99", Vector2(1500.0, 0.0), 0.0)
	ramps.append(invalid)
	ramps.append(null)
	visuals.build(ramps)
	_check(visuals.visual_count() == 2, "two valid ramps build two wedges; the invalid and null records build none")
	var first := visuals.get_node_or_null("Ramp_h1_0_10") as Node2D
	_check(first != null, "wedges are named by stable id")
	if first != null:
		var wedge := first.get_node_or_null("Wedge") as Polygon2D
		_check(wedge != null and wedge.polygon.size() == 6, "each ramp draws a six-point wedge: a foot, the crest and a foot on each side")
		_check(wedge != null and wedge.vertex_colors.is_empty() and wedge.color == JumpRampVisuals.WEDGE_COLOR, "without a shading and a height query the wedge is the flat wedge colour")
		if wedge != null:
			var min_y := INF
			var max_y := -INF
			for point in wedge.polygon:
				min_y = minf(min_y, point.y)
				max_y = maxf(max_y, point.y)
			_check(is_equal_approx(max_y - min_y, 240.0), "the wedge spans the placement width")
		_check(first.get_node_or_null("Crest") is Line2D, "each ramp draws a crest line")
		_check(first.get_node_or_null("ChevronIn") is Line2D and first.get_node_or_null("ChevronOut") is Line2D, "each ramp draws a chevron per face")
	visuals.build([])
	_check(visuals.visual_count() == 0 and visuals.get_child_count() == 0, "rebuilding with no ramps frees the wedges")
	visuals.queue_free()
	return true


## The fixture car points along +x (rotation PI/2), so a lift applied in the car's own frame, as
## it was until #52, fails every screen-frame pin here: the car would draw ahead of its shadow.
func _verify_body_lift_and_shadow() -> bool:
	var tuning := load(TUNING_PATH) as VehicleTuning
	for metres in [0.0, 1.0, 3.0]:
		var context := _make_car(WorldScale.metres(metres))
		var car: TopDownCar = context.car
		for frame in range(4):
			await process_frame
		var lift := car.get_node("Lift") as Node2D
		var shadow := car.get_node("Shadow") as Polygon2D
		var height := WorldScale.metres(metres)
		var expected := Vector2(0.0, -height * tuning.lift_pixels_per_pixel)
		_check(not car.is_airborne() and is_equal_approx(car.get_height(), height) and is_equal_approx(car.get_ground_height(), height), "at %.0f m the fixture car stands on the plateau, so the pins below are ground cues" % metres)
		_check(car.transform.basis_xform(lift.position).is_equal_approx(expected), "on ground at %.0f m the body lifts %.1f px straight up the screen, not along the heading" % [metres, height * tuning.lift_pixels_per_pixel])
		_check(car.transform.basis_xform(shadow.position - SHADOW_BASE).is_equal_approx(expected), "on ground at %.0f m the shadow is anchored to the same lift, so a parked car does not float above its shadow" % metres)
		_check(is_equal_approx(lift.scale.x, 1.0), "on the ground at %.0f m the body does not grow: scale is an air cue" % metres)
		_check(is_equal_approx(shadow.modulate.a, 1.0), "on the ground at %.0f m the shadow does not fade: the fade is an air cue" % metres)
		_check(lift.get_node_or_null("Body") != null and lift.get_node_or_null("Windshield") != null and lift.get_node_or_null("DirectionMark") != null, "the body parts live under Lift")
		context.world.queue_free()
		await process_frame
	# Airborne: off a 40 px plateau edge onto level ground. The shadow sits at its base over the
	# ground below (height zero), the body lifts by the car's height, and the gap, the growth and
	# the fade all follow that same height above the ground.
	var context := _make_car(40.0, 50.0)
	var car: TopDownCar = context.car
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var seen_airborne := false
	for _tick in range(240):
		await physics_frame
		await process_frame
		if car.is_airborne():
			seen_airborne = true
			# process_frame fires before Node._process(); present the airborne state just seen.
			await process_frame
			break
	_check(seen_airborne, "the car falls off the plateau edge")
	var lift := car.get_node("Lift") as Node2D
	var shadow := car.get_node("Shadow") as Polygon2D
	var body_lift := car.transform.basis_xform(lift.position)
	var shadow_lift := car.transform.basis_xform(shadow.position - SHADOW_BASE)
	var gap := shadow_lift.y - body_lift.y
	_check(gap > AIRBORNE_GAP_FLOOR, "in the air a gap of %.1f px opens between body and shadow" % gap)
	_check(is_zero_approx(shadow_lift.length()) and is_zero_approx(car.get_ground_height()), "over level ground the airborne shadow sits at its base: it is anchored to the ground, not to the body")
	_check(absf(body_lift.x) < 1e-3, "the airborne body lifts straight up the screen")
	_check(absf(body_lift.y + car.get_height() * tuning.lift_pixels_per_pixel) <= 0.1 * car.get_height(), "the airborne body lift (%.1f px) is the car's height above the ground (%.1f px), to within the tick between physics and draw" % [-body_lift.y, car.get_height()])
	var presented_metres := WorldScale.to_metres(gap)
	_check(is_equal_approx(lift.scale.x, 1.0 + presented_metres * tuning.scale_per_metre), "in the air the body grows by the presented height above the ground (%.2f)" % lift.scale.x)
	_check(is_equal_approx(shadow.modulate.a, clampf(1.0 - presented_metres * TopDownCar.SHADOW_FADE_PER_METRE, 0.25, 1.0)), "in the air the shadow fades by the presented height above the ground (%.2f)" % shadow.modulate.a)
	context.world.queue_free()
	await process_frame
	return true


func _verify_airborne_draw_order_and_dust() -> bool:
	_check(await _verify_airborne_suppresses_dust(), "the airborne dust suppression verification ran to completion")
	_check(await _verify_landing_burst(), "the landing burst verification ran to completion")
	return true


func _verify_airborne_suppresses_dust() -> bool:
	var context := _make_car(40.0, 50.0)
	var car: TopDownCar = context.car
	var dust := car.get_node("Dust") as CPUParticles2D
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	var seen_airborne := false
	var z_in_air := 0
	var dust_in_air := false
	var speed_above_dust_threshold := false
	for _tick in range(240):
		await physics_frame
		await process_frame
		if car.is_airborne():
			seen_airborne = true
			# SceneTree.process_frame fires before Node._process(), so sample after the car has
			# presented the airborne physics state just observed above.
			await process_frame
			z_in_air = car.z_index
			dust_in_air = dust.emitting
			speed_above_dust_threshold = car.get_speed() > WorldScale.metres(4.0)
			break
	_check(seen_airborne, "the car falls off the plateau edge")
	_check(speed_above_dust_threshold, "the airborne dirt car is fast enough that ordinary dust would emit")
	_check(z_in_air == 1, "an airborne car draws at z_index 1")
	_check(not dust_in_air, "continuous dirt dust does not emit in the air")
	context.world.queue_free()
	await process_frame
	return true


func _verify_landing_burst() -> bool:
	var context := _make_car(40.0, 50.0)
	var car: TopDownCar = context.car
	var dust := car.get_node("Dust") as CPUParticles2D
	var landing_burst := car.get_node("LandingBurst") as CPUParticles2D
	_check(landing_burst.one_shot, "the landing burst is a one-shot emitter")
	_check(landing_burst.amount > 1, "the landing burst emits multiple particles at once")
	_check(is_equal_approx(landing_burst.explosiveness, 1.0), "the landing burst releases its full amount instantly")
	_check(not landing_burst.emitting, "the landing burst is idle before a landing")
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	# Off-track keeps the ordinary plume off, isolating the dedicated landing emitter.
	(context.surface as Issue4TestSurfaceProvider).force_off_track = true
	var seen_airborne := false
	var z_on_landing := -1
	var burst_on_landing := false
	var dust_on_landing := false
	for _tick in range(240):
		await physics_frame
		await process_frame
		if car.is_airborne():
			seen_airborne = true
		elif seen_airborne:
			# Let the car present the just-observed physics landing before sampling its visuals.
			await process_frame
			z_on_landing = car.z_index
			burst_on_landing = landing_burst.emitting
			dust_on_landing = dust.emitting
			break
	_check(seen_airborne, "the burst scenario falls off the plateau edge")
	_check(z_on_landing == 0, "a landed car returns to z_index 0")
	_check(burst_on_landing, "landing starts the dedicated one-shot burst")
	_check(not dust_on_landing, "the fixture's forced off-track surface keeps the continuous plume off, so the burst asserted above is the dedicated emitter rather than the plume")
	context.world.queue_free()
	await process_frame
	return true


func _verify_overlay_line() -> bool:
	var overlay_scene := load("res://session/main.tscn") as PackedScene
	var session := overlay_scene.instantiate()
	root.add_child(session)
	var overlay := session.get_node("%DiagnosticsOverlay") as DiagnosticsOverlay
	overlay.set_release_mode(false)
	overlay.visible = true
	overlay.set_height_metrics(1.5, -3.25, true, 0.75)
	var label := overlay.find_child("MetricsLabel", true, false) as Label
	_check(label.text.contains("height: 1.50 m"), "the overlay reports height in metres")
	_check(label.text.contains("vz: -3.25 m/s"), "the overlay reports vertical speed")
	_check(label.text.contains("air: 0.75 s"), "the overlay reports air time while airborne")
	session.queue_free()
	return true


func _ramp(id: String, origin: Vector2, width: float) -> JumpRampPlacement:
	var ramp := JumpRampPlacement.new()
	ramp.stable_id = id
	ramp.transform = Transform2D(0.0, origin)
	ramp.half_length = 150.0
	ramp.crest_height = 18.0
	ramp.width = width
	return ramp


func _make_car(plateau_height: float, plateau_end_x: float = INF) -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = load(TUNING_PATH) as VehicleTuning
	car.global_transform = Transform2D(PI * 0.5, Vector2.ZERO)
	var height := HeightChannelTestHeightProvider.new()
	height.mode = HeightChannelTestHeightProvider.Mode.PLATEAU
	height.plateau_height = plateau_height
	height.plateau_end_x = plateau_end_x
	car.set_height_query(height)
	var surface := Issue4TestSurfaceProvider.new()
	car.set_surface_query(surface)
	world.add_child(car)
	return {"world": world, "car": car, "surface": surface}


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Jump ramp visual checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Jump ramp visual check failed: %s" % failure)
	quit(1)
