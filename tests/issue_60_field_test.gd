extends SceneTree

## Task #60: the field, per-car lap progress, and standings.
##
## Everything here drives the production session through its real paths: the field is spawned by
## restart_with_seed, progress moves through the session's own checkpoint sampling, and standings
## are read through get_race_order(). No car steers itself — the drivers are #56's idle ones, which
## is exactly what this task was sized to run on.
##
## Mutation flag:
##   -- --break-standings-order  re-ranks the session's own entries with a lap-blind comparator
##      (checkpoints passed, then distance, then index) and asserts production agrees, so the run
##      fails on the case a naive comparison gets wrong: the car a lap ahead sits at an earlier
##      checkpoint. A guard first asserts the lap-blind order differs, so the failing case below
##      can never pass vacuously.
##
## Deferred to #61 (they need #59's real drivers): two runs at the same seed and count producing
## identical final standings and a full-field race. Idle-field contact determinism is checked here.

const MAIN_SCENE_PATH := "res://session/main.tscn"
const SEED := 7
const FULL_FIELD := 20
const COUNT_CASES := [0, 1, 2, 10, 20]
const TICK := 1.0 / 60.0
## Parking offsets for the standings scenario, in metres through the scale contract.
const NEAR_GATE_OFFSET_M := 8.0
const FAR_GATE_OFFSET_M := 48.0

var _failures: Array[String] = []
var _checks := 0
var _break_standings := false


func _initialize() -> void:
	_break_standings = OS.get_cmdline_user_args().has("--break-standings-order")
	call_deferred("_run")


func _run() -> void:
	_check(await _verify_counts_build_playable_sessions(), "counts verification ran to completion")
	_check(await _verify_zero_opponents_is_today(), "zero-opponent verification ran to completion")
	_check(await _verify_grid_layout(), "grid layout verification ran to completion")
	_check(await _verify_car_to_car_collision(), "car-to-car collision verification ran to completion")
	_check(await _verify_standings(), "standings verification ran to completion")
	_check(await _verify_rival_reset(), "rival reset verification ran to completion")
	_finish()


## Counts of 0, 1, 2, 10 and 20 all build a playable session, the player's spawn slot never moves
## with the count, and the player is the only camera in the field.
func _verify_counts_build_playable_sessions() -> bool:
	for count in COUNT_CASES:
		var session := await _open_session(count, SEED)
		var mount := session.get_node("World/VehicleMount")
		var definition: TrackDefinition = session.get_node("World/TrackMount/GeneratedTrack").definition
		_check(mount.get_child_count() == count + 1, "count %d mounts the player plus %d cars (%d)" % [count, count, mount.get_child_count()])
		_check(mount.get_child(0).name == "PlayerCar", "the player's car is mount child 0 at count %d" % count)
		var all_cars := true
		var all_tuned := true
		var camera_enabled_count := 0
		for child in mount.get_children():
			var car := child as TopDownCar
			all_cars = all_cars and car != null
			all_tuned = all_tuned and car != null and car.tuning == session.vehicle_tuning
			camera_enabled_count += int(car != null and car.camera_enabled)
		_check(all_cars, "every mounted node at count %d is a TopDownCar" % count)
		_check(all_tuned, "every car at count %d uses the session tuning resource" % count)
		_check(camera_enabled_count == 1, "exactly one car at count %d has its camera enabled" % count)
		_check(root.get_camera_2d() == session.get_node("World/VehicleMount/PlayerCar/FollowCamera"), "the player owns the viewport at count %d" % count)
		var snapshot := session.get_session_snapshot()
		_check(int(snapshot.get("field_size", -1)) == count + 1, "the snapshot reports the field size at count %d" % count)
		_check(int(snapshot.get("player_position", -1)) == 1, "the player starts from pole at count %d" % count)
		var fresh_order := session.get_race_order()
		_check(fresh_order[0] == 0, "the player is first on a fresh field at count %d" % count)
		var sorted_order: Array[int] = fresh_order.duplicate()
		sorted_order.sort()
		_check(sorted_order == _index_run(count + 1), "the fresh order at count %d ranks every car exactly once" % count)
		_check((session.get_node("%PosLabel") as Label).text == "POS  1/%d" % (count + 1), "the HUD shows position and field size at count %d" % count)
		# The player's slot must not move with the count: every lap time in this repo's evidence
		# was measured from spawn_transform.
		var player := session.get_node("World/VehicleMount/PlayerCar") as TopDownCar
		_check(player.global_transform == definition.spawn_transform, "the player's spawn pose is the definition's spawn transform at count %d" % count)
		if count == FULL_FIELD:
			# A mid-session count change re-reads the setting on the next restart.
			session.session_settings.opponent_count = 5
			session.restart_with_seed(SEED)
			await process_frame
			_check(session.get_node("World/VehicleMount").get_child_count() == 6, "restarting from twenty at five mounts six cars")
		session.free()
		await process_frame
	return true


## Zero opponents is today's single-car session, structurally: one car named PlayerCar at the
## spawn transform with the only camera, no rival nodes anywhere, and the fingerprints unperturbed
## by the field code existing.
func _verify_zero_opponents_is_today() -> bool:
	var session := await _open_session(0, SEED)
	var mount := session.get_node("World/VehicleMount")
	_check(mount.get_child_count() == 1 and mount.get_child(0).name == "PlayerCar", "zero opponents leaves the vehicle mount exactly as it was")
	_check(_find_nodes_named(session, "RivalCar").is_empty(), "zero opponents spawns no rival nodes anywhere in the session")
	var player := mount.get_child(0) as TopDownCar
	var definition: TrackDefinition = session.get_node("World/TrackMount/GeneratedTrack").definition
	_check(player.global_transform == definition.spawn_transform, "the player sits at the definition's spawn transform")
	_check(player.camera_enabled and root.get_camera_2d() == player.get_node("FollowCamera"), "the player keeps the viewport")
	_check(session.get_race_entries().size() == 1 and session.get_race_order() == [0], "the race is a field of one")
	var snapshot := session.get_session_snapshot()
	for key in ["seed", "opponent_count", "lap_count", "next_checkpoint", "current_lap_time", "session_time", "last_lap_time", "best_lap_time", "paused", "geometry_fingerprint", "offtrack_object_fingerprint", "height_fingerprint"]:
		_check(snapshot.has(key), "the pre-field snapshot key %s is still published" % key)
	_check(int(snapshot.get("opponent_count", -1)) == 0, "zero opponents is published as zero")
	_check(str(snapshot.get("geometry_fingerprint", "")) == definition.geometry_fingerprint, "the road fingerprint is the freshly generated one")
	# The pre-task keys must carry the values they carried before the field existed.
	_check(int(snapshot.get("lap_count", -1)) == 0 and int(snapshot.get("next_checkpoint", -1)) == 1, "a fresh session still starts before gate 1")
	_check(is_zero_approx(float(snapshot.get("current_lap_time", -1.0))) and is_zero_approx(float(snapshot.get("session_time", -1.0))), "a fresh session still starts at zero time")
	session.free()
	await process_frame
	return true


## The grid at a full field: deterministic slots, every car on the road facing forward, no two of
## the twenty-one cars overlapping — checked for all of them, not a sample.
func _verify_grid_layout() -> bool:
	for seed in ([SEED] if OS.get_cmdline_user_args().has("--proof-seed-only") else range(20)):
		_check(await _verify_grid_seed(seed), "grid seed %d verification ran to completion" % seed)
	return true


func _verify_grid_seed(seed: int) -> bool:
	var session := await _open_session(FULL_FIELD, seed)
	var definition: TrackDefinition = session.get_node("World/TrackMount/GeneratedTrack").definition
	var surface := TrackSurfaceMap.new(definition)
	var cars := _field_cars(session)
	for rival in session.get("_rivals"):
		var detector: CheckpointCrossingDetector = rival["detector"]
		_check(detector.get("_has_previous_position") and detector.get("_previous_position") == rival["car"].global_position, "seed %d rival %d detector is seeded at spawn before its first sample" % [seed, rival["index"]])
	_check(cars.size() == FULL_FIELD + 1, "the grid fixture holds twenty-one cars")
	for index in range(cars.size()):
		var car := cars[index]
		_check(surface.sample_at(car.global_position).surface_type == SurfaceQuery.SurfaceType.DIRT, "car %d starts on the road" % index)
		_check(car.mass == session.vehicle_tuning.mass_kg and car.is_physics_processing(), "seed %d car %d ready uses session mass and enables physics" % [seed, index])
		_check(car.get_safe_reset_pose() == car.global_transform, "seed %d car %d ready captures its grid reset pose" % [seed, index])
		car.call("_sample_surface", car.global_position)
		_check(car.get("_surface_type") == SurfaceQuery.SurfaceType.DIRT, "seed %d car %d samples road through its own surface query" % [seed, index])
		var ground: HeightQuery.HeightSample = car.call("_sample_ground_at", car.global_position)
		var expected_ground := TrackHeightMap.new(definition).sample_at(car.global_position)
		_check(ground.ground_height == expected_ground.ground_height and ground.gradient == expected_ground.gradient, "seed %d car %d samples terrain through its own height query" % [seed, index])
		_check(car.get("_surface_query") == cars[0].get("_surface_query"), "seed %d car %d shares the player surface map" % [seed, index])
		var shape := (car.get_node("CollisionShape2D") as CollisionShape2D).shape as CapsuleShape2D
		for side in [-1.0, 1.0]:
			_check(surface.sample_at(car.global_position + car.global_transform.x * shape.radius * side).surface_type == SurfaceQuery.SurfaceType.DIRT, "seed %d car %d body edge %d is on road" % [seed, index, int(side)])
		var tangent := _nearest_tangent(definition, car.global_position)
		var car_forward := -car.global_transform.y
		_check(car_forward.dot(tangent) > 0.995, "car %d faces along the direction of travel (dot %.4f)" % [index, car_forward.dot(tangent)])
		_check(car.collision_layer == 1 and car.collision_mask == 3, "car %d keeps the shared collision layer 1 and mask 3" % index)
	# Pairwise capsule clearance for every pair, from the cars' own collision shapes.
	var capsule := (cars[0].get_node("CollisionShape2D") as CollisionShape2D).shape as CapsuleShape2D
	_check(capsule != null, "the production car's collision shape is a capsule")
	if capsule == null:
		session.free()
		await process_frame
		return true
	var saved_a := cars[0].global_transform
	var saved_b := cars[1].global_transform
	cars[0].global_transform = Transform2D(0.0, Vector2.ZERO)
	cars[1].global_transform = Transform2D(PI * 0.5, Vector2.ZERO)
	_check(is_zero_approx(_capsule_clearance(cars[0], cars[1])), "crossed capsule medial segments have zero separation")
	cars[1].global_transform = Transform2D(0.0, Vector2(0.0, WorldScale.metres(8.0)))
	_check(is_equal_approx(_capsule_clearance(cars[0], cars[1]), WorldScale.metres(8.0) - capsule.height + 2.0 * capsule.radius), "capsule medial length excludes the rounded end radii")
	cars[0].global_transform = saved_a
	cars[1].global_transform = saved_b
	var pairs := 0
	var closest := INF
	for a in range(cars.size()):
		for b in range(a + 1, cars.size()):
			pairs += 1
			closest = minf(closest, _capsule_clearance(cars[a], cars[b]))
	_check(pairs == 210, "all 210 pairs of the twenty-one cars were checked (%d)" % pairs)
	_check(closest >= capsule.radius * 2.0, "no two cars overlap at spawn (closest capsules %.1f px apart, need %.1f)" % [closest, capsule.radius * 2.0])
	var first_poses: Array[Transform2D] = []
	for car in cars:
		first_poses.append(car.global_transform)
	session.session_settings.opponent_count = 5
	session.restart_with_seed(seed)
	var cars_again := _field_cars(session)
	for index in range(cars_again.size()):
		_check(cars_again[index].global_transform == first_poses[index], "seed %d slot %d is independent of field count (20 versus 5)" % [seed, index])
	session.free()
	await process_frame
	return true


## Cars share layer 1 with mask 3, so car-to-car contact should already work; this confirms it
## through the physics server rather than assuming it.
func _verify_car_to_car_collision() -> bool:
	var traces: Array[Array] = []
	for run in range(2):
		var session := await _open_session(2, SEED)
		# Align both restarts to the same physics boundary, independent of render scheduling.
		await physics_frame
		session.restart_with_seed(SEED)
		var player := session.get_node("World/VehicleMount/PlayerCar") as TopDownCar
		var rival := session.get_node("World/VehicleMount/RivalCar1") as TopDownCar
		var player_hits: Array[Node] = []
		var rival_hits: Array[Node] = []
		player.body_entered.connect(func(body: Node): player_hits.append(body))
		rival.body_entered.connect(func(body: Node): rival_hits.append(body))
		var player_forward := -player.global_transform.y
		rival.global_transform = Transform2D(player.global_rotation, player.global_position + player_forward * WorldScale.metres(0.5))
		var trace: Array = []
		for frame in range(20):
			await physics_frame
			trace.append([player.global_transform, player.linear_velocity, rival.global_transform, rival.linear_velocity, session.get_race_order()])
		_check(player_hits.has(rival), "run %d player's contact identifies the rival body" % run)
		_check(rival_hits.has(player), "run %d rival's contact identifies the player body" % run)
		traces.append(trace)
		session.free()
		await process_frame
	if traces[0] != traces[1]:
		for tick in range(20):
			if traces[0][tick] != traces[1][tick]:
				print("CONTACT_DIFF tick=%d first=%s second=%s" % [tick, traces[0][tick], traces[1][tick]])
				break
	_check(traces[0] == traces[1], "two idle-field contact runs reproduce every sampled pose, velocity and standing")
	return true


## Standings: a scripted scenario with known, different progress, asserted to the exact order; the
## first-tick tie-break; order-independence of the ranking; and the mutation flag.
func _verify_standings() -> bool:
	var session := await _open_session(3, SEED)
	var definition: TrackDefinition = session.get_node("World/TrackMount/GeneratedTrack").definition
	var checkpoints := definition.checkpoints
	var player := session.get_node("World/VehicleMount/PlayerCar") as TopDownCar
	var rival1 := session.get_node("World/VehicleMount/RivalCar1") as TopDownCar
	var rival2 := session.get_node("World/VehicleMount/RivalCar2") as TopDownCar
	var rival3 := session.get_node("World/VehicleMount/RivalCar3") as TopDownCar
	var gate1_forward := checkpoints[1].x.normalized()
	var gate2_forward := checkpoints[2].x.normalized()

	# Rival 3 drives a whole lap: crossings credited through the session's own sampling.
	_drive_full_lap(session, rival3, definition)
	_drive_to(session, rival3, definition, checkpoints[1].origin - gate1_forward * WorldScale.metres(FAR_GATE_OFFSET_M))
	# Player and rival 1 pass gate 1 and stop FAR and NEAR from gate 2: same checkpoint, different
	# progress.
	_drive_to(session, player, definition, checkpoints[2].origin - gate2_forward * WorldScale.metres(FAR_GATE_OFFSET_M))
	_drive_to(session, rival1, definition, checkpoints[2].origin - gate2_forward * WorldScale.metres(NEAR_GATE_OFFSET_M))
	# Rival 2 passes no gate: same lap as the player, an earlier checkpoint.
	_drive_to(session, rival2, definition, checkpoints[1].origin - gate1_forward * WorldScale.metres(FAR_GATE_OFFSET_M))

	var by_index := {}
	for entry in session.get_race_entries():
		by_index[int(entry["index"])] = entry
	_check(by_index.size() == 4, "the scenario ranks four cars")
	_check(int(by_index[3]["laps"]) == 1 and int(by_index[3]["next_checkpoint"]) == 1, "rival 3 completed a lap and is back working on gate 1")
	_check(int(by_index[0]["next_checkpoint"]) == 2 and int(by_index[1]["next_checkpoint"]) == 2, "the player and rival 1 both passed gate 1")
	_check(float(by_index[0]["next_checkpoint_distance"]) > float(by_index[1]["next_checkpoint_distance"]), "the player stands farther gate 2 than rival 1 (%.1f vs %.1f px)" % [float(by_index[0]["next_checkpoint_distance"]), float(by_index[1]["next_checkpoint_distance"])])
	_check(int(by_index[2]["next_checkpoint"]) == 1 and int(by_index[2]["laps"]) == 0, "rival 2 has passed no gate on the opening lap")

	var expected: Array[int] = [3, 1, 0, 2]
	_check(session.get_race_order() == expected, "standings rank lap count, then checkpoints passed, then progress: %s" % str(session.get_race_order()))
	_check(session.get_player_position() == 3, "the player is third of four")
	_check(int(session.get_session_snapshot().get("player_position", -1)) == 3, "the snapshot publishes the player's position")
	session.call("_refresh_hud")
	_check((session.get_node("%PosLabel") as Label).text == "POS  3/4", "the HUD shows the mid-race position")

	if _break_standings:
		var naive := _rank_without_laps(session.get_race_entries())
		_check(naive != session.get_race_order(), "the lap-blind order differs from the real one, so the case below cannot pass vacuously")
		_check(session.get_race_order() == naive, "MUTATION --break-standings-order: ranking without lap counts still puts the car a lap ahead (at an earlier checkpoint) first — expected order %s, lap-blind order %s" % [str(expected), str(naive)])

	# The tie-break. A fresh field has identical lap and checkpoint progress everywhere; the
	# distances differ slot by slot because the grid sits on the curve behind the start line, so
	# the exact first-tick tie is manufactured here rather than assumed.
	session.restart_with_seed(SEED)
	var fresh_order := session.get_race_order()
	_check(fresh_order[0] == 0, "the player starts from pole on a fresh field (%s)" % str(fresh_order))
	var sorted_fresh: Array[int] = fresh_order.duplicate()
	sorted_fresh.sort()
	_check(sorted_fresh == _index_run(4), "the fresh order ranks every car exactly once")
	var rival1_car := session.get_node("World/VehicleMount/RivalCar1") as TopDownCar
	var rival2_car := session.get_node("World/VehicleMount/RivalCar2") as TopDownCar
	rival2_car.global_position = rival1_car.global_position
	var tied_entries := session.get_race_entries()
	_check(float(tied_entries[1]["next_checkpoint_distance"]) == float(tied_entries[2]["next_checkpoint_distance"]), "the two rivals now stand at identical progress — a real first-tick tie")
	tied_entries.reverse()
	var tied_order: Array[int] = session.call("_rank_entries", tied_entries)
	print("TIE_ORDER seed=7 count=3: %s" % str(tied_order))
	_check(tied_order == [0, 1, 2, 3], "exact tie matches the checked-in cross-process order [0, 1, 2, 3]")
	_check(tied_order.find(1) < tied_order.find(2), "an exact progress tie between two rivals breaks by car index, not by list order")
	# Order-independence: the same production ranking fed permuted entry lists must return the
	# same order. The expectation is the control ranking above rather than an independent
	# derivation — the correctness of the order is the scenario's job above; this check fixes the
	# invariance alone.
	for permutation in [[3, 2, 1, 0], [2, 3, 0, 1], [1, 0, 3, 2]]:
		var permuted: Array[Dictionary] = []
		for index in permutation:
			permuted.append(tied_entries[index])
		var ranked: Array[int] = session.call("_rank_entries", permuted)
		_check(ranked == tied_order, "ranking the permuted entry list %s still yields %s" % [str(permutation), str(tied_order)])
	# Stable across restarts.
	session.restart_with_seed(SEED)
	_check(session.get_race_order() == fresh_order, "the fresh order repeats after a restart")
	session.free()
	await process_frame
	return true


## Exercise the session's half of the reset protocol at the pending-teleport boundary.
func _verify_rival_reset() -> bool:
	var session := await _open_session(2, SEED)
	var definition: TrackDefinition = session.get_node("World/TrackMount/GeneratedTrack").definition
	var rivals: Array = session.get("_rivals")
	var rival: TopDownCar = rivals[0]["car"]
	var detector: CheckpointCrossingDetector = rivals[0]["detector"]
	var progress: LapProgressTracker = rivals[0]["progress"]
	var gate := definition.checkpoints[1]
	var before := gate.origin - gate.x.normalized() * WorldScale.metres(2.0)
	var after := gate.origin + gate.x.normalized() * WorldScale.metres(2.0)
	var control := CheckpointCrossingDetector.new(definition)
	control.reset(before)
	_check(control.sample(after).get("checkpoint", -1) == 1, "reset fixture chord really crosses the next gate")
	detector.reset(before)
	rival.global_position = before
	# Set only the producer's notice and destination; invoke the real session consumer below.
	rival.set("_safe_reset_pose", Transform2D(rival.global_rotation, after))
	rival.set("_auto_reset_notice", true)
	session.call("_physics_process", TICK)
	_check(not rival.consume_auto_reset_notice(), "rival reset notice is drained by the session")
	_check(detector.get("_previous_position") == after, "rival detector is reseeded to destination without sampling stale pose")
	rival.global_position = after
	session.call("_physics_process", TICK)
	_check(progress.next_checkpoint == 1 and progress.lap_count == 0, "rival reset teleport earns no phantom checkpoint or lap")
	# A later legitimate crossing must still count.
	rival.global_position = before
	session.call("_physics_process", TICK)
	rival.global_position = after
	session.call("_physics_process", TICK)
	_check(progress.next_checkpoint == 2, "rival sampling resumes and credits a later real crossing")
	rival.free()
	_check(session.get_field_size() == 2 and session.get_race_entries().size() == 2, "field size excludes a freed rival just like the ranked entries")
	session.call("_refresh_hud")
	_check((session.get_node("%PosLabel") as Label).text.ends_with("/2"), "HUD size excludes the freed rival")
	session.free()
	await process_frame
	return true


# --- helpers -----------------------------------------------------------------


func _open_session(count: int, seed: int) -> MainSession:
	var scene := load(MAIN_SCENE_PATH) as PackedScene
	var session := scene.instantiate() as MainSession
	var settings := SessionSettings.new()
	settings.opponent_count = count
	session.session_settings = settings
	session.vehicle_tuning = session.vehicle_tuning.duplicate()
	session.vehicle_tuning.mass_kg = 1234.0
	root.add_child(session)
	await process_frame
	# No frame is awaited after the restart on purpose: one physics tick round-trips the car's
	# transform through the physics server and costs the pose its last float bit, and the spawn
	# assertions below pin the exact pose the session places, not the pose after simulation noise.
	session.restart_with_seed(seed)
	return session


func _field_cars(session: MainSession) -> Array[TopDownCar]:
	var cars: Array[TopDownCar] = []
	var mount := session.get_node("World/VehicleMount")
	cars.append(mount.get_child(0) as TopDownCar)
	for index in range(1, mount.get_child_count()):
		cars.append(mount.get_node("RivalCar%d" % index) as TopDownCar)
	return cars


func _index_run(count: int) -> Array[int]:
	var indices: Array[int] = []
	for index in range(count):
		indices.append(index)
	return indices


func _find_nodes_named(node: Node, node_name: String) -> Array[Node]:
	var found: Array[Node] = []
	for child in node.get_children():
		if child.name == node_name:
			found.append(child)
		found.append_array(_find_nodes_named(child, node_name))
	return found


func _nearest_sample(points: PackedVector2Array, unique: int, position: Vector2) -> int:
	var nearest := 0
	var nearest_distance := INF
	for index in range(unique):
		var distance := position.distance_squared_to(points[index])
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = index
	return nearest


func _nearest_tangent(definition: TrackDefinition, position: Vector2) -> Vector2:
	var points := definition.centerline
	var unique := points.size() - 1
	var index := _nearest_sample(points, unique, position)
	var previous := points[(index - 1 + unique) % unique]
	var following := points[(index + 1) % unique]
	return (following - previous).normalized()


## Steps a car forward along the generated centreline one sample at a time, ticking the session
## between steps so crossings are credited through the production path. Small steps on the road
## itself: a teleport chord across the infield could cross an unrelated gate's half-plane and the
## detector would have no way to tell.
func _drive_to(session: MainSession, car: TopDownCar, definition: TrackDefinition, target: Vector2) -> void:
	var points := definition.centerline
	var unique := points.size() - 1
	var step := _nearest_sample(points, unique, car.global_position)
	var goal := _nearest_sample(points, unique, target)
	while step != goal:
		step = (step + 1) % unique
		car.global_position = points[step]
		session.call("_physics_process", TICK)
	if car.global_position != target:
		car.global_position = target
		session.call("_physics_process", TICK)


func _drive_full_lap(session: MainSession, car: TopDownCar, definition: TrackDefinition) -> void:
	var points := definition.centerline
	var unique := points.size() - 1
	for index in range(unique):
		car.global_position = points[(index + 1) % unique]
		session.call("_physics_process", TICK)


## The comparator a naive implementation writes: everything but the lap count.
func _rank_without_laps(entries: Array[Dictionary]) -> Array[int]:
	var sorted_entries := entries.duplicate()
	sorted_entries.sort_custom(func(a, b):
		if int(a["checkpoints_passed"]) != int(b["checkpoints_passed"]):
			return int(a["checkpoints_passed"]) > int(b["checkpoints_passed"])
		if float(a["next_checkpoint_distance"]) != float(b["next_checkpoint_distance"]):
			return float(a["next_checkpoint_distance"]) < float(b["next_checkpoint_distance"])
		return int(a["index"]) < int(b["index"]))
	var order: Array[int] = []
	for entry in sorted_entries:
		order.append(int(entry["index"]))
	return order


func _capsule_clearance(a: TopDownCar, b: TopDownCar) -> float:
	var shape_a := (a.get_node("CollisionShape2D") as CollisionShape2D).shape as CapsuleShape2D
	var shape_b := (b.get_node("CollisionShape2D") as CollisionShape2D).shape as CapsuleShape2D
	if shape_a == null or shape_b == null:
		return -1.0
	var forward_a := -a.global_transform.y
	var forward_b := -b.global_transform.y
	var a1 := a.global_position + forward_a * (shape_a.height * 0.5 - shape_a.radius)
	var a2 := a.global_position - forward_a * (shape_a.height * 0.5 - shape_a.radius)
	var b1 := b.global_position + forward_b * (shape_b.height * 0.5 - shape_b.radius)
	var b2 := b.global_position - forward_b * (shape_b.height * 0.5 - shape_b.radius)
	var closest := Geometry2D.get_closest_points_between_segments(a1, a2, b1, b2)
	return closest[0].distance_to(closest[1])



func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Issue #60 field checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Issue #60 field check failed: %s" % failure)
	print("Issue #60 field checks=%d failures=%d" % [_checks, _failures.size()])
	quit(1)
