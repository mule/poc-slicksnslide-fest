extends SceneTree

## Graphical desktop evidence for the height channel. Runs the production MainSession in a
## 1280x720 SubViewport, records ramp counts and fingerprints for seeds 0..19, drives the
## production car over the first ramp of three seeds at the speed the car actually reaches on
## dirt, and captures the approach, the apex, and the landing. It then measures how far sideways
## a flight can drift against how far outside the road edge a generated solid can sit, and
## captures the production car clearing a generated rock. Run windowed, not headless:
##   godot --path . --script res://tests/capture_height_channel_evidence.gd
##
## Two frames matter here and are kept apart deliberately. Speeds attached to a jump are measured
## at the crest, not at the seat the car was placed on, because a throttled approach changes the
## speed between the two. Sideways distances are measured outward from the road edge, because that
## is the frame the off-track catalog's solid clearance is expressed in; a reach measured from the
## crest would double-count the road's half width when compared against it.

const MAIN_SCENE_PATH := "res://session/main.tscn"
const OUTPUT_DIRECTORY := "res://docs/evidence/height-channel"
const TRACE_PATH := OUTPUT_DIRECTORY + "/desktop-trace-seeds-0-4-9.txt"
const OBJECT_CATALOG_PATH := "res://data/default_offtrack_object_catalog.tres"
const LEDGER_SEEDS := 20
const CAPTURE_SEEDS := [0, 4, 9]
## The car's own terminal speed on dirt under full throttle, not the 640 px/s safety clamp.
const APPROACH_SPEED := 600.0
const APPROACH_DISTANCE := 420.0
const APPROACH_SHOT_DISTANCE := 250.0
## Seat speeds, not crest speeds: the car is under throttle over the approach, so each row's real
## crest speed is measured and reported alongside.
const SEAT_SPEED_SWEEP := [200.0, 250.0, 300.0, 350.0, 400.0, 450.0, 500.0, 550.0, 600.0]
const REACH_SEED := 0
const REACH_ANGLES_DEGREES := 85
const REACH_ANGLE_STEP := 5
## Lateral seat offsets as a fraction of the road's half width. A ramp spans the full road width,
## so a car crossing it along the road edge launches that far off the centreline and carries the
## offset through the flight; a sweep seated only on the centreline would understate the reach.
## The +/-1.0 seats put the car exactly on the road edge, which is the extreme the corridor
## comparison needs: any further out and the car is already off the track and slower.
const REACH_LATERAL_FRACTIONS := [-1.0, -0.5, 0.0, 0.5, 1.0]
const MAX_TICKS := 400
## A reach pass that has not left the ground within this many ticks never will.
const REACH_TICKS := 200
## Long enough for a car left in the air by a previous pass to fall back to flat ground.
const SETTLE_TICKS := 90
const WARMUP_FRAMES := 30
const ROCK_PROBE_SPEED := 200.0
## The rock archetype's collision radius and the car capsule's, from the catalog and the scene.
const ROCK_COLLISION_RADIUS := 15.0
const CAR_COLLISION_RADIUS := 15.0

var _failures: Array[String] = []
var _checks := 0
var _apex_heights: Array[float] = []
var _reach_beyond_edge_above_clearance := 0.0
var _reach_beyond_edge_airborne := 0.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_DIRECTORY))
	_check(directory_error == OK, "evidence output directory exists")
	var main_scene := load(MAIN_SCENE_PATH) as PackedScene
	_check(main_scene != null, "the production main scene loads")
	var lines: Array[String] = []
	lines.append("# Height channel desktop trace")
	lines.append("# renderer=graphical SubViewport=1280x720 seat_speed=%.0f approach_distance=%.0f" % [APPROACH_SPEED, APPROACH_DISTANCE])
	lines.append("# speeds attached to a jump are measured at the crest; sideways distances are measured outward from the road edge")
	_check(_record_ledger(lines), "the seeds 0..19 ledger ran to completion")
	for seed in CAPTURE_SEEDS:
		_check(await _capture_jump(main_scene, seed, lines), "seed %d jump capture ran to completion" % seed)
	_check(await _record_lift_off_speed_sweep(main_scene, lines), "the lift-off speed sweep ran to completion")
	_check(await _record_flight_reach(main_scene, lines), "the flight reach measurement ran to completion")
	_check(_record_solid_corridor(lines), "the solid corridor measurement ran to completion")
	_check(await _capture_rock_clearance(main_scene, lines), "the rock clearance capture ran to completion")
	var file := FileAccess.open(ProjectSettings.globalize_path(TRACE_PATH), FileAccess.WRITE)
	_check(file != null, "the trace file opens")
	if file != null:
		file.store_string("\n".join(lines) + "\n")
		file.close()
	_finish()


func _record_ledger(lines: Array[String]) -> bool:
	var generator := TrackGenerator.new()
	var seeds_with_ramps := 0
	var total_ramps := 0
	for seed in range(LEDGER_SEEDS):
		var definition: TrackDefinition = generator.generate(seed)
		if not definition.jump_ramps.is_empty():
			seeds_with_ramps += 1
		total_ramps += definition.jump_ramps.size()
		lines.append("ledger seed=%d ramps=%d requested=%d eligible_runs=%d placement_usec=%d height=%s road=%s objects=%s" % [
			seed,
			definition.jump_ramps.size(),
			int(definition.height_diagnostics.get("requested", -1)),
			int(definition.height_diagnostics.get("eligible_runs", -1)),
			definition.height_generation_usec,
			definition.height_fingerprint,
			definition.geometry_fingerprint,
			definition.offtrack_object_fingerprint,
		])
	lines.append("ledger seeds=%d with_ramps=%d total_ramps=%d mean_ramps=%.2f" % [
		LEDGER_SEEDS, seeds_with_ramps, total_ramps, float(total_ramps) / float(LEDGER_SEEDS)
	])
	_check(seeds_with_ramps == LEDGER_SEEDS, "every seed in 0..%d places at least one ramp" % (LEDGER_SEEDS - 1))
	return true


## Places the production car on the first ramp's approach and captures the approach, the apex, and
## the first grounded frame. The seat speed is the speed a full-throttle car holds on dirt; the
## speed reported for the jump is the one measured as the car leaves the crest.
func _capture_jump(main_scene: PackedScene, seed: int, lines: Array[String]) -> bool:
	var context := await _open_session(main_scene, seed)
	var viewport: SubViewport = context["viewport"]
	var definition: TrackDefinition = context["definition"]
	var car: TopDownCar = context["car"]
	var camera: Camera2D = context["camera"]
	_check(not definition.jump_ramps.is_empty(), "seed %d has a ramp to capture" % seed)
	if definition.jump_ramps.is_empty():
		_close_session(context)
		await process_frame
		return false
	var ramp: JumpRampPlacement = definition.jump_ramps[0]
	var axis := ramp.transform.x.normalized()
	_check(
		await _seat_car(car, context["height_map"], ramp.transform.origin - axis * APPROACH_DISTANCE, axis, APPROACH_SPEED),
		"seed %d car is settled on the ground before the run" % seed
	)
	var apex := 0.0
	var apex_image: Image = null
	var apex_speed := 0.0
	var crest_speed := 0.0
	var launched := false
	var landed := false
	var air_time := 0.0
	var speed_before_landing := 0.0
	var speed_after_landing := 0.0
	var approach_saved := false
	# Only the frames that become evidence wait on a draw. Awaiting one every tick would tie the
	# whole approach to the render rate, which on a loaded machine is well under the physics rate.
	for tick in range(MAX_TICKS):
		await physics_frame
		var to_crest := ramp.transform.origin - car.global_position
		if not approach_saved and not launched and to_crest.dot(axis) <= APPROACH_SHOT_DISTANCE:
			approach_saved = true
			_check(await _save(viewport, camera, car, "seed-%d-approach.png" % seed), "seed %d approach image saved" % seed)
		if car.is_airborne():
			if not launched:
				crest_speed = car.get_speed()
			launched = true
			air_time = car.get_air_time()
			speed_before_landing = car.get_speed()
			if car.get_height() > apex:
				apex = car.get_height()
				apex_speed = car.get_speed()
				camera.global_position = car.global_position
				await RenderingServer.frame_post_draw
				apex_image = viewport.get_texture().get_image()
		elif launched:
			landed = true
			speed_after_landing = car.get_speed()
			_check(await _save(viewport, camera, car, "seed-%d-landing.png" % seed), "seed %d landing image saved" % seed)
			break
	_check(approach_saved, "seed %d approach frame was reached" % seed)
	_check(launched and landed, "seed %d production car launches from ramp %s and lands" % [seed, ramp.stable_id])
	_check(apex_image != null, "seed %d apex frame was captured" % seed)
	if apex_image != null:
		_check(apex_image.save_png(ProjectSettings.globalize_path("%s/seed-%d-apex.png" % [OUTPUT_DIRECTORY, seed])) == OK, "seed %d apex image saved" % seed)
	_check(apex > ramp.crest_height, "seed %d apex (%.2f px) is above the crest it launched from (%.2f px)" % [seed, apex, ramp.crest_height])
	_apex_heights.append(apex)
	lines.append("jump seed=%d ramp=%s crest_px=%.2f seat_px_s=%.0f crest_px_s=%.1f crest_kph=%.1f apex_px=%.2f apex_m=%.3f apex_speed_kph=%.1f air_time_s=%.3f speed_before_kph=%.1f speed_after_kph=%.1f kept=%.3f recovery_s=%.3f" % [
		seed,
		ramp.stable_id,
		ramp.crest_height,
		APPROACH_SPEED,
		crest_speed,
		WorldScale.to_kph(crest_speed),
		apex,
		WorldScale.to_metres(apex),
		WorldScale.to_kph(apex_speed),
		air_time,
		WorldScale.to_kph(speed_before_landing),
		WorldScale.to_kph(speed_after_landing),
		speed_after_landing / maxf(speed_before_landing, 0.001),
		car.get_landing_recovery_remaining(),
	])
	_close_session(context)
	await process_frame
	return true


## The same ramp at nine seat speeds. Lift-off vertical speed is the slope times the speed at the
## crest, so the apex has to climb with the crest speed -- which is measured on the first airborne
## tick rather than assumed from the seat, because the throttle is down over the approach.
func _record_lift_off_speed_sweep(main_scene: PackedScene, lines: Array[String]) -> bool:
	var context := await _open_session(main_scene, REACH_SEED)
	var definition: TrackDefinition = context["definition"]
	var car: TopDownCar = context["car"]
	var tuning: VehicleTuning = car.tuning
	var ramp: JumpRampPlacement = definition.jump_ramps[0]
	var axis := ramp.transform.x.normalized()
	var previous_crest_speed := -1.0
	var previous_apex := -1.0
	var rising := true
	var ordered := true
	var settled := true
	var highest_below_clearance := 0.0
	var lowest_above_clearance := INF
	for seat_speed in SEAT_SPEED_SWEEP:
		if not await _seat_car(car, context["height_map"], ramp.transform.origin - axis * APPROACH_DISTANCE, axis, seat_speed):
			settled = false
		var apex := 0.0
		var air_time := 0.0
		var crest_speed := 0.0
		var launched := false
		for tick in range(MAX_TICKS):
			await physics_frame
			if car.is_airborne():
				if not launched:
					crest_speed = car.get_speed()
				launched = true
				apex = maxf(apex, car.get_height())
				air_time = maxf(air_time, car.get_air_time())
			elif launched:
				break
		_check(launched, "the car leaves the ramp seated at %.0f px/s" % seat_speed)
		if crest_speed <= previous_crest_speed:
			ordered = false
		if apex <= previous_apex:
			rising = false
		previous_crest_speed = crest_speed
		previous_apex = apex
		if apex > tuning.low_obstacle_clearance:
			lowest_above_clearance = minf(lowest_above_clearance, crest_speed)
		else:
			highest_below_clearance = maxf(highest_below_clearance, crest_speed)
		lines.append("sweep seed=%d ramp=%s seat_px_s=%.0f crest_px_s=%.1f crest_kph=%.1f apex_px=%.2f apex_m=%.3f air_time_s=%.3f clears_%.1f_px=%s" % [
			REACH_SEED, ramp.stable_id, seat_speed, crest_speed, WorldScale.to_kph(crest_speed),
			apex, WorldScale.to_metres(apex), air_time, tuning.low_obstacle_clearance,
			"yes" if apex > tuning.low_obstacle_clearance else "no",
		])
	lines.append("sweep floor highest_crest_below_clearance_px_s=%.1f lowest_crest_above_clearance_px_s=%.1f clearance_px=%.2f" % [
		highest_below_clearance, lowest_above_clearance, tuning.low_obstacle_clearance
	])
	_check(settled, "every sweep pass started from a grounded car")
	_check(ordered, "a faster seat produces a faster crest crossing at every step")
	_check(rising, "the apex rises with every step of crest speed")
	_check(
		highest_below_clearance < lowest_above_clearance and lowest_above_clearance < INF,
		"the sweep brackets the clearance floor between %.1f px/s and %.1f px/s at the crest" % [highest_below_clearance, lowest_above_clearance]
	)
	_close_session(context)
	await process_frame
	return true


## The horizontal half of the clearance question. A flight is a fixed arc the car cannot steer, so
## how far sideways it drifts is a property of the ramp shape and the car, not of the seed. The
## sweep covers every launch heading and five lateral seats across the road, because a ramp spans
## the full road width and a car crossing it near the edge launches that far off the centreline.
## Both results are converted to distance outside the road edge, the frame the off-track catalog's
## solid clearance uses.
func _record_flight_reach(main_scene: PackedScene, lines: Array[String]) -> bool:
	var context := await _open_session(main_scene, REACH_SEED)
	var definition: TrackDefinition = context["definition"]
	var car: TopDownCar = context["car"]
	var tuning: VehicleTuning = car.tuning
	var ramp: JumpRampPlacement = definition.jump_ramps[0]
	var axis := ramp.transform.x.normalized()
	var perpendicular := Vector2(-axis.y, axis.x)
	var half_width: float = definition.track_width * 0.5
	var drift_airborne := 0.0
	var drift_above_clearance := 0.0
	var beyond_edge_airborne := 0.0
	var beyond_edge_above_clearance := 0.0
	var launched_passes := 0
	var total_passes := 0
	var settled := true
	for degrees in range(0, REACH_ANGLES_DEGREES + 1, REACH_ANGLE_STEP):
		var direction := axis.rotated(deg_to_rad(float(degrees)))
		for fraction in REACH_LATERAL_FRACTIONS:
			total_passes += 1
			var seat_offset: float = half_width * fraction
			var seat := ramp.transform.origin - direction * APPROACH_DISTANCE + perpendicular * seat_offset
			if not await _seat_car(car, context["height_map"], seat, direction, APPROACH_SPEED):
				settled = false
			var launched := false
			for tick in range(REACH_TICKS):
				await physics_frame
				if car.is_airborne():
					launched = true
					# Signed, so a pass that crosses the centreline is not folded back on itself.
					var from_centre := (car.global_position - ramp.transform.origin).dot(perpendicular)
					var drift := absf(from_centre - seat_offset)
					var beyond_edge := maxf(absf(from_centre) - half_width, 0.0)
					drift_airborne = maxf(drift_airborne, drift)
					beyond_edge_airborne = maxf(beyond_edge_airborne, beyond_edge)
					if car.get_height() > tuning.low_obstacle_clearance:
						drift_above_clearance = maxf(drift_above_clearance, drift)
						beyond_edge_above_clearance = maxf(beyond_edge_above_clearance, beyond_edge)
				elif launched:
					break
			if launched:
				launched_passes += 1
	_reach_beyond_edge_above_clearance = beyond_edge_above_clearance
	_reach_beyond_edge_airborne = beyond_edge_airborne
	lines.append("reach seed=%d ramp=%s headings=%d lateral_seats=%d passes=%d launched=%d seat_px_s=%.0f half_width_px=%.1f max_drift_airborne_px=%.1f max_drift_above_clearance_px=%.1f max_beyond_edge_airborne_px=%.1f max_beyond_edge_above_clearance_px=%.1f" % [
		REACH_SEED,
		ramp.stable_id,
		REACH_ANGLES_DEGREES / REACH_ANGLE_STEP + 1,
		REACH_LATERAL_FRACTIONS.size(),
		total_passes,
		launched_passes,
		APPROACH_SPEED,
		half_width,
		drift_airborne,
		drift_above_clearance,
		beyond_edge_airborne,
		beyond_edge_above_clearance,
	])
	_check(settled, "every reach pass started from a grounded car")
	_check(launched_passes > 0, "at least one launch heading left the ground (%d of %d)" % [launched_passes, total_passes])
	_check(
		beyond_edge_above_clearance > 0.0,
		"the sweep observed flight past the road edge while above the clearance height, so the reach figure is measured rather than vacuous"
	)
	_close_session(context)
	await process_frame
	return true


## The other side of the same question, from placement data rather than physics, in the same frame.
## An off-track solid is kept at least the catalog's `solid_clearance` outside the road edge, so a
## flight that cannot drift that far past the edge while high can never clear a rock on any seed.
func _record_solid_corridor(lines: Array[String]) -> bool:
	var generator := TrackGenerator.new()
	var catalog := load(OBJECT_CATALOG_PATH) as OfftrackObjectCatalog
	var nearest_overall := INF
	var rampless_seeds := 0
	for seed in range(LEDGER_SEEDS):
		var definition: TrackDefinition = generator.generate(seed)
		if definition.jump_ramps.is_empty():
			rampless_seeds += 1
			continue
		var half_width: float = definition.track_width * 0.5
		var nearest := INF
		for placement in definition.offtrack_objects:
			if placement.solid:
				nearest = minf(nearest, _distance_to_centerline(definition.centerline, placement.transform.origin) - half_width)
		nearest_overall = minf(nearest_overall, nearest)
		lines.append("corridor seed=%d ramps=%d solids=%d half_width_px=%.1f nearest_solid_beyond_edge_px=%.1f rule_min_beyond_edge_px=%.1f" % [
			seed, definition.jump_ramps.size(), _solid_count(definition), half_width, nearest, catalog.solid_clearance
		])
	lines.append("corridor seeds=%d nearest_solid_beyond_edge_px=%.1f rule_min_beyond_edge_px=%.1f flight_beyond_edge_above_clearance_px=%.1f flight_beyond_edge_airborne_px=%.1f" % [
		LEDGER_SEEDS, nearest_overall, catalog.solid_clearance, _reach_beyond_edge_above_clearance, _reach_beyond_edge_airborne
	])
	_check(rampless_seeds == 0, "every seed in 0..%d has a ramp to measure against (%d without)" % [LEDGER_SEEDS - 1, rampless_seeds])
	_check(
		_reach_beyond_edge_above_clearance < catalog.solid_clearance,
		"a flight drifts at most %.1f px past the road edge while above the clearance height, and the catalog keeps every solid at least %.1f px past it" % [_reach_beyond_edge_above_clearance, catalog.solid_clearance]
	)
	_check(
		_reach_beyond_edge_airborne < nearest_overall,
		"not even the whole flight envelope (%.1f px past the road edge) reaches the nearest solid actually generated in seeds 0..%d (%.1f px past it)" % [_reach_beyond_edge_airborne, LEDGER_SEEDS - 1, nearest_overall]
	)
	return true


func _solid_count(definition: TrackDefinition) -> int:
	var count := 0
	for placement in definition.offtrack_objects:
		if placement.solid:
			count += 1
	return count


func _distance_to_centerline(centerline: PackedVector2Array, point: Vector2) -> float:
	var nearest := INF
	for index in range(centerline.size() - 1):
		var closest := Geometry2D.get_closest_point_to_segment(point, centerline[index], centerline[index + 1])
		nearest = minf(nearest, point.distance_to(closest))
	return nearest


## The vertical half. A generated rock from a generated track, the production car's real collision
## mask, and the car held at the apex height its own ramps produce: the rock passes underneath.
func _capture_rock_clearance(main_scene: PackedScene, lines: Array[String]) -> bool:
	var context := await _open_session(main_scene, 0)
	var viewport: SubViewport = context["viewport"]
	var definition: TrackDefinition = context["definition"]
	var car: TopDownCar = context["car"]
	var camera: Camera2D = context["camera"]
	var tuning: VehicleTuning = car.tuning
	var rock := _rock_with_a_clear_approach(definition)
	_check(rock != null, "seed 0 has a generated rock with no other solid on its +X approach")
	if rock == null:
		_close_session(context)
		await process_frame
		return false
	var measured_apex := _minimum(_apex_heights)
	_check(measured_apex > tuning.low_obstacle_clearance, "the lowest measured ramp apex (%.2f px) is above the clearance height (%.2f px)" % [measured_apex, tuning.low_obstacle_clearance])
	var provider := HeightChannelTestHeightProvider.new()
	provider.mode = HeightChannelTestHeightProvider.Mode.PLATEAU
	provider.plateau_height = measured_apex
	var start := rock.transform.origin - Vector2(320.0, 0.0)
	car.global_transform = Transform2D(PI * 0.5, start)
	car.linear_velocity = Vector2(ROCK_PROBE_SPEED, 0.0)
	car.angular_velocity = 0.0
	car.sleeping = false
	car.set_height_query(provider)
	car.set_auto_reset_enabled(false)
	var before := car.get_collision_count()
	var over_image: Image = null
	var over_height := 0.0
	var overlapping_ticks := 0
	var minimum_distance := INF
	var mask_dropped_low := true
	# Every tick on which the two collision circles overlap is a tick a grounded car would have
	# been stopped on, so the mask is checked on all of them -- and the check is kept off the frame
	# that waits for a draw, because a draw wait lets several physics ticks pass between loop
	# iterations and would silently sample only a handful of the overlap.
	#
	# The still is taken once the car is just past the rock: the body is drawn offset along the
	# car's heading, so only with the rock behind it is the rock visible rather than underneath it.
	var contact_distance := ROCK_COLLISION_RADIUS * rock.scale_factor + CAR_COLLISION_RADIUS
	for tick in range(MAX_TICKS):
		car.linear_velocity = Vector2(ROCK_PROBE_SPEED, 0.0)
		await physics_frame
		var distance := car.global_position.distance_to(rock.transform.origin)
		minimum_distance = minf(minimum_distance, distance)
		if distance <= contact_distance:
			overlapping_ticks += 1
			over_height = car.get_height()
			if car.get_collision_level_mask() != TopDownCar.TALL_LAYER:
				mask_dropped_low = false
		var past := car.global_position.x - rock.transform.origin.x
		if over_image == null and past >= contact_distance * 0.6 and past <= contact_distance * 1.2:
			camera.global_position = car.global_position
			await RenderingServer.frame_post_draw
			over_image = viewport.get_texture().get_image()
		if past > 120.0:
			break
	_check(overlapping_ticks > 0, "the car overlapped the generated rock on %d physics ticks" % overlapping_ticks)
	_check(
		minimum_distance <= ROCK_COLLISION_RADIUS * rock.scale_factor,
		"the car drove over the rock's centre rather than grazing it (closest approach %.2f px against a %.2f px collider)" % [minimum_distance, ROCK_COLLISION_RADIUS * rock.scale_factor]
	)
	_check(car.global_position.x > rock.transform.origin.x, "the car is past the generated rock %s" % rock.stable_id)
	_check(car.get_collision_count() == before, "clearing the generated rock registers no collision")
	_check(mask_dropped_low, "the car's mask held only the tall layer on every overlapping tick")
	if over_image != null:
		_check(over_image.save_png(ProjectSettings.globalize_path("%s/seed-0-rock-cleared.png" % OUTPUT_DIRECTORY)) == OK, "rock clearance image saved")
	lines.append("rock seed=0 rock=%s scale=%.2f held_height_px=%.2f held_height_m=%.3f clearance_px=%.2f contact_distance_px=%.1f overlapping_ticks=%d min_distance_px=%.2f speed_kph=%.1f collisions=%d source=scripted_plateau_at_measured_apex" % [
		rock.stable_id,
		rock.scale_factor,
		over_height,
		WorldScale.to_metres(over_height),
		tuning.low_obstacle_clearance,
		contact_distance,
		overlapping_ticks,
		minimum_distance,
		WorldScale.to_kph(ROCK_PROBE_SPEED),
		car.get_collision_count() - before,
	])
	_close_session(context)
	await process_frame
	return true


## The first rock whose straight +X approach (320 px before to 120 px after) has no other solid
## within 60 px, so the only solid on the path is the rock being cleared.
func _rock_with_a_clear_approach(definition: TrackDefinition) -> OfftrackObjectPlacement:
	for candidate in definition.offtrack_objects:
		if candidate.archetype_id != &"rock":
			continue
		var origin := candidate.transform.origin
		var path_start := origin - Vector2(320.0, 0.0)
		var path_end := origin + Vector2(120.0, 0.0)
		var clear := true
		for other in definition.offtrack_objects:
			if not other.solid or other.stable_id == candidate.stable_id:
				continue
			var closest := Geometry2D.get_closest_point_to_segment(other.transform.origin, path_start, path_end)
			if closest.distance_to(other.transform.origin) < 60.0:
				clear = false
				break
		if clear:
			return candidate
	return null


func _open_session(main_scene: PackedScene, seed: int) -> Dictionary:
	var viewport := _new_viewport()
	root.add_child(viewport)
	var session := main_scene.instantiate() as MainSession
	viewport.add_child(session)
	await process_frame
	session.restart_with_seed(seed)
	for frame in range(WARMUP_FRAMES):
		await process_frame
	var runtime := session.get_node("World/TrackMount/GeneratedTrack") as TrackRuntime
	var definition: TrackDefinition = runtime.definition
	var car := session.get_node("World/VehicleMount/PlayerCar") as TopDownCar
	car.set_auto_reset_enabled(false)
	var controls := VehicleInputState.new()
	controls.throttle = 1.0
	car.set_input_state(controls)
	# The production session pauses the whole SceneTree when the window loses focus, through
	# ApplicationLifecycle's NOTIFICATION_APPLICATION_FOCUS_OUT. A paused tree still emits
	# physics_frame but stops simulating, so on a desktop where the window never holds focus the
	# car sits at its seat while the drive loop counts ticks and the run silently measures nothing.
	# The capture drives the car itself and has no use for that behaviour, so it is disconnected
	# for the life of the session and the tree is asserted unpaused before anything is measured.
	var lifecycle := session.get_node("ApplicationLifecycle")
	var suspension := Callable(session, "_on_application_suspension_requested")
	if lifecycle.suspension_requested.is_connected(suspension):
		lifecycle.suspension_requested.disconnect(suspension)
	session.set_session_paused(false)
	_check(not paused, "the scene tree is running for this capture session")
	var camera := Camera2D.new()
	camera.name = "HeightChannelCaptureCamera"
	camera.top_level = true
	camera.zoom = Vector2.ONE * car.tuning.camera_zoom
	session.add_child(camera)
	camera.make_current()
	return {
		"viewport": viewport,
		"session": session,
		"definition": definition,
		"car": car,
		"camera": camera,
		"height_map": TrackHeightMap.new(definition),
	}


func _close_session(context: Dictionary) -> void:
	var viewport: SubViewport = context["viewport"]
	viewport.free()


## Places the car on flat road ahead of a ramp, pointing along direction at speed. A teleport does
## not clear the vertical channel, so a pass whose flight had not finished would otherwise be
## scored as an instant launch: the car is held still until it is back on the ground first.
## Returns false if it never settled, so a caller can fail rather than publish that pass.
func _seat_car(car: TopDownCar, height_map: TrackHeightMap, position: Vector2, direction: Vector2, speed: float) -> bool:
	var pose := Transform2D(direction.angle() + PI * 0.5, position)
	car.set_height_query(height_map)
	car.global_transform = pose
	car.linear_velocity = Vector2.ZERO
	car.angular_velocity = 0.0
	car.sleeping = false
	var settled := not car.is_airborne()
	for tick in range(SETTLE_TICKS):
		if settled:
			break
		await physics_frame
		car.global_transform = pose
		car.linear_velocity = Vector2.ZERO
		car.angular_velocity = 0.0
		settled = not car.is_airborne()
	car.global_transform = pose
	car.linear_velocity = direction * speed
	car.angular_velocity = 0.0
	car.sleeping = false
	return settled


## Frames the camera on the car, waits for that frame to be drawn, and writes it out.
func _save(viewport: SubViewport, camera: Camera2D, car: TopDownCar, file_name: String) -> bool:
	camera.global_position = car.global_position
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	return image.save_png(ProjectSettings.globalize_path("%s/%s" % [OUTPUT_DIRECTORY, file_name])) == OK


func _minimum(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var result := values[0]
	for value in values:
		result = minf(result, value)
	return result


func _new_viewport() -> SubViewport:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280, 720)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	return viewport


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Height channel evidence capture passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Height channel evidence capture failed: %s" % failure)
	quit(1)
