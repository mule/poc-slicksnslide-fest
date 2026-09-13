extends SceneTree

## Task #61, part A: the session's field drives itself, and on seed 0 races the same way twice across the
## two histories below (scope under "What is not asserted").
##
## Everything here runs the production session from `session/main.tscn`. The rivals are the session's
## own `ReactiveDriver`s, sensed by the session's own `SensingPass` in its own `_physics_process`; this
## file only watches. The player's car sits at pole with no input, as it does in any headless run.
##
## ## What is asserted
##
## - **Count 0 runs no field**: no rival, no sensing pass, over real physics ticks. Count 1 does build
##   one, so the check can tell the two apart.
## - **Every rival spawns at a physics fixed point**: rebuilding its transform from its rotation and
##   origin -- what a physics step does to a resting body -- changes nothing. The snap's bound is proved
##   over its whole angle lattice in the engine; 200,000 random rotations and every rival on seeds 0-19,
##   41 and 58 are checked against it. See _verify_rivals_spawn_at_physics_fixed_points.
## - **The mistake switch is total**: with `opponent_mistakes_enabled` on, every rival's driver has
##   mistakes on and plans one; off (the race below), every driver has them off, plans none and logs none.
## - **A full-field race** (#60, deferred): twenty rivals on RACE_SEED, mistakes off. Every rival laps,
##   none meets the stuck rule, none leaves the play area or gets lost.
## - **Deterministic final standings** (#60, deferred): the same seed and count raced twice in one
##   process, with the two histories the #59 review and task #61 found each decide the race on their
##   own. Race 1 is a new session's restart from an idle frame. Race 2 is an in-session restart --
##   the same session first races OTHER_SEED's track -- called from a physics frame, so a physics step
##   runs between spawn and first sense (0 steps against 1, counted by a probe body, not assumed). The
##   finishing order, every car's finishing tick, and every car's whole control stream at the 64 bits
##   VehicleInputState holds, are identical.
## - **Collision does not desync a deterministic run** (#60, deferred): the race is full of car-to-car
##   contact (guarded: most cars touch another before finishing), and every car's stream is still
##   identical through and after its contacts. It is not independent of the stream assertion above:
##   it is that assertion restricted to cars that touched another, and on RACE_SEED all twenty do.
##   What it adds is the guard that the determinism was measured through contact, not around it.
##
## ## What is not asserted
##
## One seed, twenty rivals, one machine. Two histories are varied, not every history there is; the
## task #61 report measures more of them. Nothing here says anything across machines.
##
## ## Mutations, all must fail
##
##   -- --break-spawn-snap       the session spawns rivals at the raw grid pose. Must fail the fixed
##                               point assertion and the DETERMINISTIC assertions.
##   -- --break-fresh-world      the session restarts into the space it already has. Must fail the
##                               FRESH WORLD assertion and the DETERMINISTIC assertions.
##   -- --break-contact-replay   evidence, not a production mutation: in the second race only, the
##                               first rival to touch another car is moved 0.05 px on that tick. Must
##                               fail the COLLISION assertion, which shows the comparison can see a
##                               difference that starts at a contact.
##
## Exploration: --only=a,b runs only the named sections (zero, poses, switch, race).

const MAIN_SCENE_PATH := "res://session/main.tscn"
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
## The production 1 / 60 s step, ten times faster in real time, as the driver suites run it.
const PHYSICS_TICKS_PER_SECOND := 600
const TIME_SCALE := 10.0
const TICK := 1.0 / 60.0
const FULL_FIELD := 20
const RACE_SEED := 0
## The track race 2's session races first, and for how long, before its restart onto RACE_SEED.
const OTHER_SEED := 1
const OTHER_TICKS := 600
## The grid seeds the pose sweep spawns: 0-19, plus 41 and 58, whose rivals the old snap -- rebuild
## until nothing changes, capped at 64 rounds -- left unsnapped (41's rivals 13 and 14 need 14,670).
const POSE_SEEDS := [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 41, 58]
## Random starting rotations for the seedless check.
const SEEDLESS_ROTATIONS := 200000
## The old snap's cap, and how far the guard below follows an iteration to see it exceeded.
const OLD_SNAP_ROUNDS := 64
const ROUNDS_SEARCHED := 20000
## Two hundred seconds. The slowest of the field lapped in under a hundred on RACE_SEED.
const RACE_TICK_BUDGET := 12000
## Twenty-five seconds of a mistakes-on field: enough for every rival to start racing cleanly, which is
## when a driver draws its first mistake.
const SWITCH_TICKS := 1500
## A probe moving one pixel per physics step counts the steps.
const PROBE_SPEED := 60.0
const CONTACT_NUDGE_PX := 0.05

var _failures: Array[String] = []
var _checks := 0
var _only: Array[String] = []
var _break_spawn_snap := false
var _break_contact_replay := false
var _break_fresh_world := false
var _tuning: VehicleTuning


## --break-spawn-snap: the pose as the grid built it.
class UnsnappedSession extends MainSession:
	func _physics_fixed_pose(pose: Transform2D) -> Transform2D:
		return pose


## --break-fresh-world: the old race is still freed first, but the new one reuses its space.
class ReusedSpaceSession extends MainSession:
	func _host_race_in_a_fresh_world() -> void:
		for mount in [%TrackMount, %VehicleMount]:
			for child in mount.get_children():
				child.free()


func _initialize() -> void:
	Engine.physics_ticks_per_second = PHYSICS_TICKS_PER_SECOND
	Engine.time_scale = TIME_SCALE
	var arguments := OS.get_cmdline_user_args()
	_break_spawn_snap = arguments.has("--break-spawn-snap")
	_break_contact_replay = arguments.has("--break-contact-replay")
	_break_fresh_world = arguments.has("--break-fresh-world")
	for argument in arguments:
		if argument.begins_with("--only="):
			for name in argument.trim_prefix("--only=").split(","):
				_only.append(name)
	call_deferred("_run")


func _wants(section: String) -> bool:
	return _only.is_empty() or _only.has(section)


func _run() -> void:
	_tuning = load(TUNING_PATH) as VehicleTuning
	if _break_spawn_snap:
		print("NOTE: --break-spawn-snap is on; rivals spawn at the raw grid pose.")
	if _break_contact_replay:
		print("NOTE: --break-contact-replay is on; the second race nudges the first rival to touch another car.")
	if _break_fresh_world:
		print("NOTE: --break-fresh-world is on; a restart reuses the physics space it already has.")
	if _wants("race"):
		_check(await _verify_the_field_races_the_same_way_twice(), "the race verification ran to completion")
	if _wants("zero"):
		_check(await _verify_count_zero_runs_no_field(), "the count-zero verification ran to completion")
	if _wants("poses"):
		_check(await _verify_rivals_spawn_at_physics_fixed_points(), "the fixed-pose verification ran to completion")
	if _wants("switch"):
		_check(await _verify_the_mistake_switch_reaches_every_rival(), "the mistake switch verification ran to completion")
	_finish()


# ---------------------------------------------------------------------------------------------
# Sections


func _verify_count_zero_runs_no_field() -> bool:
	var session := _new_session(0, false, RACE_SEED)
	root.add_child(session)
	for tick in range(60):
		await physics_frame
	var rivals: Array = session.get("_rivals")
	_check(session.get_node("World/VehicleMount").get_child_count() == 1 and rivals.is_empty(), "count 0 spawns no rival (%d mounted)" % session.get_node("World/VehicleMount").get_child_count())
	_check(session.get("_sensing") == null, "count 0 builds no sensing pass, so no rival sensing or driving runs over 60 physics ticks")
	session.free()
	await process_frame
	var one := _new_session(1, false, RACE_SEED)
	root.add_child(one)
	await physics_frame
	await physics_frame
	var driver: AiDriver = (one.get("_rivals") as Array)[0]["driver"]
	_check(one.get("_sensing") != null and _driver_int(driver, "_tick") > 0, "count 1 builds the pass and its rival drives with senses, so the check above can tell them apart")
	one.free()
	await process_frame
	return true


## Three checks of MainSession._physics_fixed_pose, each able to fail on a snap that is not total:
##
## 1. **The bound is proved over the whole lattice, in the engine.** Every lattice angle a spawn can round
##    to, and SPAWN_ANGLE_MAX_STEPS either side of the ends, is tested with the rebuild the physics step
##    does; the worst distance from any of them to the nearest fixed one must be within the constant.
## 2. **Seedless:** SEEDLESS_ROTATIONS random rotations each come back fixed, at the same origin, within
##    the bound. Guarded by how many of them the old iteration needed more than 64 rounds for.
## 3. **Seeds:** every rival spawned on POSE_SEEDS sits at a fixed pose within the bound of its raw grid
##    pose. Guarded by the raw poses that are not fixed, and the most rounds the old iteration needed.
func _verify_rivals_spawn_at_physics_fixed_points() -> bool:
	var session := _new_session(FULL_FIELD, false, RACE_SEED)
	root.add_child(session)
	await process_frame
	# Read by name, so this suite still loads -- and fails here by name -- against a session without them.
	var constants := {}
	var script := session.get_script() as Script
	while script != null:
		for name in script.get_script_constant_map():
			if not constants.has(name):
				constants[name] = script.get_script_constant_map()[name]
		script = script.get_base_script()
	var lattice := float(constants.get("SPAWN_ANGLE_LATTICE", 0.0))
	var max_steps := int(constants.get("SPAWN_ANGLE_MAX_STEPS", -1))
	_check(lattice > 0.0 and max_steps >= 0, "the session declares its spawn-angle lattice (%s) and its proved bound (%d steps)" % [lattice, max_steps])
	var bound := (max_steps + 0.5) / lattice if lattice > 0.0 else 0.0

	# 1. The proof.
	if lattice > 0.0 and max_steps >= 0:
		var float32 := PackedByteArray()
		float32.resize(4)
		float32.encode_float(0, PI)
		var top := roundi(float32.decode_float(0) * lattice)
		var reach := top + max_steps + 1
		var fixed := PackedByteArray()
		fixed.resize(2 * reach + 1)
		var non_fixed := 0
		for index in range(-reach, reach + 1):
			var candidate := Transform2D(index / lattice, Vector2.ZERO)
			var is_fixed := Transform2D(candidate.get_rotation(), candidate.origin) == candidate
			fixed[index + reach] = int(is_fixed)
			non_fixed += int(not is_fixed and absi(index) <= top)
		var worst := 0
		var worst_at := 0
		var last_fixed := -1000000000
		var from_left := PackedInt32Array()
		from_left.resize(2 * reach + 1)
		for slot in range(2 * reach + 1):
			if fixed[slot] == 1:
				last_fixed = slot
			from_left[slot] = mini(slot - last_fixed, 1000000000)
		var next_fixed := 1000000000
		for slot in range(2 * reach, -1, -1):
			if fixed[slot] == 1:
				next_fixed = slot
			if absi(slot - reach) > top:
				continue
			var distance := mini(from_left[slot], next_fixed - slot)
			if distance > worst:
				worst = distance
				worst_at = slot - reach
		_check(non_fixed > 0, "the lattice holds angles a physics step would move, so there is something to prove (%d of %d)" % [non_fixed, 2 * top + 1])
		_check(worst <= max_steps, "PROVED BOUND: from every one of the %d lattice angles a spawn rounds to, a fixed one is within %d steps (worst %d, at %.9f rad)" % [2 * top + 1, max_steps, worst, worst_at / lattice])

	# 2. Seedless.
	var rng := RandomNumberGenerator.new()
	rng.seed = 61
	var seedless_bad := 0
	var beyond_old_cap := 0
	for sample in range(SEEDLESS_ROTATIONS):
		var raw := Transform2D(rng.randf_range(-PI, PI), Vector2(rng.randf_range(-5000.0, 5000.0), rng.randf_range(-5000.0, 5000.0)))
		beyond_old_cap += int(_rounds_to_fixed_point(raw, OLD_SNAP_ROUNDS + 1) > OLD_SNAP_ROUNDS)
		seedless_bad += int(not _is_snapped(session.call("_physics_fixed_pose", raw), raw, bound))
	_check(beyond_old_cap > 0, "the seedless rotations include ones the old iteration needed more than %d rounds for (%d of %d)" % [OLD_SNAP_ROUNDS, beyond_old_cap, SEEDLESS_ROTATIONS])
	_check(seedless_bad == 0, "FIXED POSE (seedless): every one of %d random rotations snaps to a pose a physics step leaves unchanged, at the same origin, within the bound (%d do not)" % [SEEDLESS_ROTATIONS, seedless_bad])

	# 3. Seeds.
	var not_snapped: Array[String] = []
	var placed := 0
	var raw_not_fixed := 0
	var most_rounds := 0
	for seed: int in POSE_SEEDS:
		session.restart_with_seed(seed)
		for rival in session.get("_rivals"):
			var car := rival["car"] as TopDownCar
			var raw: Transform2D = session.call("_grid_slot_transform", int(rival["index"]))
			placed += 1
			if not _is_snapped(car.global_transform, raw, bound):
				not_snapped.append("seed %d rival %d" % [seed, int(rival["index"])])
			raw_not_fixed += int(Transform2D(raw.get_rotation(), raw.origin) != raw)
			most_rounds = maxi(most_rounds, _rounds_to_fixed_point(raw, ROUNDS_SEARCHED))
	_check(raw_not_fixed > 0, "the raw grid poses on the swept seeds include ones a physics step would move (%d of %d)" % [raw_not_fixed, placed])
	_check(most_rounds > OLD_SNAP_ROUNDS, "one of them needs more than the old snap's %d rounds to reach a fixed point by iteration (%d)" % [OLD_SNAP_ROUNDS, most_rounds])
	_check(not_snapped.is_empty(), "FIXED POSE: every rival on seeds 0-19, 41 and 58 spawns at a pose a physics step leaves unchanged, at its grid origin, within the bound (%d of %d are not: %s)" % [not_snapped.size(), placed, ", ".join(not_snapped)])
	session.free()
	await process_frame
	return true


## A physics step leaves it unchanged, it stands where the raw pose stands, and its rotation is within
## `bound` radians of the raw pose's.
func _is_snapped(pose: Transform2D, raw: Transform2D, bound: float) -> bool:
	return (
		Transform2D(pose.get_rotation(), pose.origin) == pose
		and pose.origin == raw.origin
		and absf(angle_difference(raw.get_rotation(), pose.get_rotation())) <= bound
	)


func _verify_the_mistake_switch_reaches_every_rival() -> bool:
	var session := _new_session(FULL_FIELD, true, RACE_SEED)
	root.add_child(session)
	for tick in range(SWITCH_TICKS):
		await physics_frame
	var switched_on := 0
	var planning := 0
	for rival in session.get("_rivals"):
		var driver: AiDriver = rival["driver"]
		switched_on += int(driver.get("mistakes_enabled") == true)
		planning += int(_driver_int(driver, "mistakes_planned") > 0)
	_check(switched_on == FULL_FIELD, "SWITCH ON: every one of the twenty rivals' drivers has mistakes on (%d)" % switched_on)
	_check(planning == FULL_FIELD, "SWITCH ON: every rival has drawn a mistake within %d s of racing (%d of %d)" % [SWITCH_TICKS / 60, planning, FULL_FIELD])
	session.free()
	await process_frame
	return true


func _verify_the_field_races_the_same_way_twice() -> bool:
	var first := await _race(false)
	var second := await _race(true)
	for record in [first, second]:
		var label: String = record.label
		_check(record.steps_before_first_sense == (1 if record.after_a_step else 0), "%s: %d physics step(s) ran between spawn and the first sense" % [label, record.steps_before_first_sense])
		_check(record.finished == FULL_FIELD, "FULL FIELD: %s: every one of the twenty rivals laps (%d)" % [label, record.finished])
		# These three are only true of a rival that was watched driving: a car is observed from its
		# driver's first sensed tick, so an idle field would pass them unobserved.
		var watched: int = record.watched
		_check(watched == FULL_FIELD and record.worst_slow < _stuck_ticks(), "FULL FIELD: %s: all %d rivals were watched driving and none meets the stuck rule (%d watched, longest slow streak %d of %d ticks)" % [label, FULL_FIELD, watched, record.worst_slow, _stuck_ticks()])
		_check(watched == FULL_FIELD and record.strayed == 0, "FULL FIELD: %s: all %d rivals were watched driving and none leaves the play area or gets lost (%d watched, %d strayed)" % [label, FULL_FIELD, watched, record.strayed])
		_check(watched == FULL_FIELD and record.switched_on == 0 and record.mistakes == 0 and record.planned == 0, "SWITCH OFF: %s: all %d rivals were watched driving and none has mistakes on, plans one or logs one (%d watched, %d on, %d planned, %d logged)" % [label, FULL_FIELD, watched, record.switched_on, record.planned, record.mistakes])
		_check(is_equal_approx(record.step_delta, TICK), "%s: the session drove at the production step (%.6f s)" % [label, record.step_delta])
		print("%s: finished %d in %d ticks, order %s, cars touching another before finishing %d, contact ticks %d" % [label, record.finished, record.ticks, record.order, record.touched, record.contact_ticks])

	_check(first.order.size() == FULL_FIELD and first.order == second.order, "DETERMINISTIC: the same seed and count finish, all twenty, in the same order in both races (%s against %s)" % [first.order, second.order])
	var same_finish := 0
	var same_stream := 0
	var diverged: Array[String] = []
	for slot in range(FULL_FIELD):
		same_finish += int(first.finish[slot] >= 0 and first.finish[slot] == second.finish[slot])
		var difference := _first_difference(first.streams[slot], second.streams[slot])
		if difference < 0 and first.streams[slot].size() > 0:
			same_stream += 1
		else:
			diverged.append("car %d at tick %d (first contact tick %d)" % [slot + 1, difference / 4, first.first_contact[slot]])
	_check(same_finish == FULL_FIELD, "DETERMINISTIC: every rival finishes, on the same tick in both races (%d of %d)" % [same_finish, FULL_FIELD])
	_check(same_stream == FULL_FIELD, "DETERMINISTIC: every rival's control stream is non-empty and identical at 64 bits (%d of %d; diverged: %s)" % [same_stream, FULL_FIELD, ", ".join(diverged)])

	# Collision. Only a stream that went through contact can show contact did not desync it.
	var through_contact := 0
	var through_contact_same := 0
	for slot in range(FULL_FIELD):
		if first.first_contact[slot] < 0:
			continue
		through_contact += 1
		through_contact_same += int(first.streams[slot].size() > int(first.first_contact[slot]) * 4 and _first_difference(first.streams[slot], second.streams[slot]) < 0)
	_check(through_contact >= FULL_FIELD / 2, "the race is a contact race: %d of %d rivals touch another car before finishing" % [through_contact, FULL_FIELD])
	_check(through_contact > 0 and through_contact_same == through_contact, "COLLISION: every rival that touched another car drives an identical stream through and after its contacts (%d of %d)" % [through_contact_same, through_contact])
	return true


# ---------------------------------------------------------------------------------------------
# The race


## A new session at RACE_SEED with twenty rivals, mistakes off, raced until every rival laps. Its spawn
## is the session's own restart_with_seed, called either from an idle frame -- the next thing to run
## is the session's own sensing -- or from a call deferred out of a physics frame, which runs after the
## session's _physics_process and before that frame's step, so one step comes first.
func _race(after_a_step: bool) -> Dictionary:
	var label := "race 2 (in-session restart after seed %d, spawned before a physics step)" % OTHER_SEED if after_a_step else "race 1 (new session, spawned in an idle frame)"
	var session := _new_session(FULL_FIELD, false, OTHER_SEED if after_a_step else RACE_SEED)
	root.add_child(session)
	await process_frame
	var probe := _step_probe()
	var world_before := root.world_2d
	if after_a_step:
		for tick in range(OTHER_TICKS):
			await physics_frame
		var raced_other := _driver_int((session.get("_rivals") as Array)[0]["driver"], "_tick")
		_check(raced_other >= OTHER_TICKS - 2, "%s: the session raced seed %d first (%d ticks)" % [label, OTHER_SEED, raced_other])
		world_before = root.world_2d
		await physics_frame
		_restart.call_deferred(session, probe)
	else:
		_restart(session, probe)
	var rivals: Array = session.get("_rivals")
	await physics_frame
	_check(root.world_2d != world_before, "FRESH WORLD: %s: the restart replaced the viewport's World2D (it shows the swap ran, not that nothing outside World came along)" % label)
	var definition: TrackDefinition = session.get("_track_definition")
	var surface := TrackSurfaceMap.new(definition)
	var record := {
		"label": label, "after_a_step": after_a_step, "order": [], "finished": 0, "worst_slow": 0, "strayed": 0,
		"touched": 0, "watched": 0, "contact_ticks": 0, "switched_on": 0, "planned": 0, "mistakes": 0, "ticks": 0,
		"steps_before_first_sense": -1, "step_delta": 0.0,
	}
	var finish: Array[int] = []
	var streams: Array[PackedFloat64Array] = []
	var first_contact: Array[int] = []
	var slow: Array[int] = []
	var strayed: Array[bool] = []
	for slot in range(FULL_FIELD):
		finish.append(-1)
		streams.append(PackedFloat64Array())
		first_contact.append(-1)
		slow.append(0)
		strayed.append(false)
	var nudged := false
	# Read after the restart above has placed this race's rivals.
	rivals = session.get("_rivals")
	for frame in range(RACE_TICK_BUDGET + 2):
		# Each frame is observed before the session's _physics_process for it: what is seen is the
		# decision the last tick made and the pose the last step left.
		for slot in range(FULL_FIELD):
			var car := rivals[slot]["car"] as TopDownCar
			var tick := _driver_int(rivals[slot]["driver"], "_tick")
			if tick == 0 or finish[slot] >= 0:
				continue
			if record.steps_before_first_sense < 0:
				record.steps_before_first_sense = roundi(probe.position.x) - tick
			if streams[slot].size() / 4 < tick:
				var controls: VehicleInputState = car.get("_input_state")
				streams[slot].append_array(PackedFloat64Array([controls.steer, controls.throttle, controls.brake, controls.handbrake]))
			slow[slot] = slow[slot] + 1 if car.get_speed() < _tuning.auto_reset_stuck_speed else 0
			record.worst_slow = maxi(record.worst_slow, slow[slot])
			if not definition.play_area.has_point(car.global_position) or surface.distance_to_centerline(car.global_position, _tuning.auto_reset_lost_distance * 2.0) > _tuning.auto_reset_lost_distance:
				strayed[slot] = true
			for body in car.get_colliding_bodies():
				if body is TopDownCar:
					record.contact_ticks += 1
					if first_contact[slot] < 0:
						first_contact[slot] = tick
						if _break_contact_replay and after_a_step and not nudged:
							nudged = true
							car.global_position += Vector2(CONTACT_NUDGE_PX, 0.0)
					break
			if (rivals[slot]["progress"] as LapProgressTracker).lap_count >= 1:
				finish[slot] = tick
				record.order.append(slot + 1)
				record.ticks = maxi(record.ticks, tick)
		if record.order.size() == FULL_FIELD:
			break
		await physics_frame
	record.step_delta = session.get_physics_process_delta_time()
	record.finish = finish
	record.streams = streams
	record.first_contact = first_contact
	for slot in range(FULL_FIELD):
		var driver: AiDriver = rivals[slot]["driver"]
		record.finished += int(finish[slot] >= 0)
		record.strayed += int(strayed[slot])
		record.watched += int(streams[slot].size() > 0)
		record.touched += int(first_contact[slot] >= 0)
		record.switched_on += int(driver.get("mistakes_enabled") == true)
		record.planned += _driver_int(driver, "mistakes_planned")
		record.mistakes += (driver.call("mistake_log") as Array).size() if driver.has_method("mistake_log") else 0
	probe.free()
	session.free()
	await process_frame
	return record


## The probe goes in after the restart, into the space the race is hosted in.
func _restart(session: MainSession, probe: RigidBody2D) -> void:
	session.restart_with_seed(RACE_SEED)
	root.add_child(probe)


## A body that moves exactly one pixel per physics step and touches nothing, so its x counts steps.
func _step_probe() -> RigidBody2D:
	var probe := RigidBody2D.new()
	probe.custom_integrator = true
	probe.gravity_scale = 0.0
	probe.can_sleep = false
	probe.collision_layer = 0
	probe.collision_mask = 0
	probe.linear_velocity = Vector2(PROBE_SPEED, 0.0)
	var shape := CollisionShape2D.new()
	shape.shape = CircleShape2D.new()
	probe.add_child(shape)
	return probe


# ---------------------------------------------------------------------------------------------
# Helpers


func _new_session(count: int, mistakes: bool, seed: int) -> MainSession:
	var session := (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	if _break_spawn_snap or _break_fresh_world:
		session.set_script(UnsnappedSession if _break_spawn_snap else ReusedSpaceSession)
		session.vehicle_tuning = _tuning
	var settings := SessionSettings.new()
	settings.seed = seed
	settings.opponent_count = count
	settings.opponent_mistakes_enabled = mistakes
	session.session_settings = settings
	return session as MainSession


## Read through the seam's base type, so a field whose drivers are not ReactiveDrivers -- the idle
## field this task replaced -- fails the assertions that read these rather than aborting the section.
func _driver_int(driver: AiDriver, property: String) -> int:
	var value = driver.get(property)
	return int(value) if value != null else 0


## Rebuilds until nothing changes, as the old snap did; `limit` when it has not stopped by then.
func _rounds_to_fixed_point(pose: Transform2D, limit: int) -> int:
	for round in range(limit):
		var rebuilt := Transform2D(pose.get_rotation(), pose.origin)
		if rebuilt == pose:
			return round
		pose = rebuilt
	return limit


func _stuck_ticks() -> int:
	return roundi(_tuning.auto_reset_stuck_seconds / TICK)


func _first_difference(left: PackedFloat64Array, right: PackedFloat64Array) -> int:
	for index in range(mini(left.size(), right.size())):
		if left[index] != right[index]:
			return index
	return -1 if left.size() == right.size() else mini(left.size(), right.size())


func _check(condition: bool, message: String) -> bool:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)
	return condition


func _finish() -> void:
	print("Field race: %d checks, %d failures" % [_checks, _failures.size()])
	quit(0 if _failures.is_empty() else 1)
