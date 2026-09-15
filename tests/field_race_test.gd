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
## - **Each rival is its own driver, through the session**: on IDENTITY_SEED every rival the session
##   spawns carries its slot's car index and the `DomainSeed` derivation of its seed -- rival 2's pinned
##   to the value computed in Python -- the twenty skills are twenty different ones, and after a tick
##   each was sensed at its own `sensing_horizon()`, which are not all one horizon. The only assertions
##   of per-car identity that run on the rivals the game spawns rather than on hand-built drivers.
## - **Overrunning the snap's bound refuses the race**: a session whose bound is forced to 0 builds no
##   track, no car and no sensing pass on RACE_SEED, and says why; the same session back at the proved
##   bound builds the race. Prints one deliberate ERROR line per pose past the bound.
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
## - **Deterministic with mistakes on** (#61 criterion 3): the same two histories on RACE_SEED with
##   `opponent_mistakes_enabled` on. The same order and finishing ticks, every control stream identical
##   at 64 bits, and every rival's whole mistake log identical. Guarded by the field logging mistakes of at
##   least two kinds and, when the mistakes-off races ran in the same process, by streams that differ
##   from the mistakes-off race's.
## - **A field that has to go round** (#61): twenty rivals on PASS_SEED, mistakes off, the player idle at
##   pole. On #61a's driver this field met the stuck rule (144 of 120 ticks): the player's car, shoved into
##   the road, stopped with a queue behind it. Every rival laps, none meets the stuck rule, none strays.
##   Guarded by the rivals having gone round a stopped car at least once, so the seed still asks for it.
## - **Collision does not desync a deterministic run** (#60, deferred): the race is full of car-to-car
##   contact (guarded: most cars touch another before finishing), and every car's stream is still
##   identical through and after its contacts. It is not independent of the stream assertion above:
##   it is that assertion restricted to cars that touched another, and on RACE_SEED all twenty do.
##   What it adds is the guard that the determinism was measured through contact, not around it.
##
## ## What is not asserted
##
## One seed, twenty rivals, one machine, each pair once with mistakes off and once on. Two histories are
## varied, not every history there is; the task #61 report measures more of them. Nothing here says
## anything across machines.
##
## ## Mutations, all must fail
##
##   -- --break-spawn-snap       the session spawns rivals at the raw grid pose. Must fail the fixed
##                               point assertion and the DETERMINISTIC assertions.
##   -- --break-fresh-world      the session restarts into the space it already has. Must fail the
##                               FRESH WORLD assertion and the DETERMINISTIC assertions.
##   -- --break-go-round        in the PASS_SEED race only, every rival's driver is swapped, before its
##                               first tick, for one whose stalls are never caused by a rival, so it
##                               reverses behind a stopped car as #61a's did. Must fail the GO ROUND
##                               stuck assertion. The same flag in tests/reactive_driver_test.gd fails
##                               the unit checks.
##   -- --break-contact-replay   evidence, not a production mutation: in the second race only, the
##                               first rival to touch another car is moved 0.05 px on that tick. Must
##                               fail the COLLISION assertion, which shows the comparison can see a
##                               difference that starts at a contact.
##   -- --break-mistake-replay   in the mistakes-on races only, every rival's driver is swapped, before
##                               its first tick, for one whose mistake draws are offset by a count of
##                               every draw made in the process -- a stream consumed from shared state,
##                               the global-RNG defect -- so the second race draws different mistakes.
##                               Must fail the MISTAKES REPLAY assertion.
##
## Exploration: --only=a,b runs only the named sections (zero, poses, refuse, identity, switch, race,
## mistakes, pass).

const MAIN_SCENE_PATH := "res://session/main.tscn"
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
## The production 1 / 60 s step, ten times faster in real time, as the driver suites run it.
const PHYSICS_TICKS_PER_SECOND := 600
const TIME_SCALE := 10.0
const TICK := 1.0 / 60.0
const FULL_FIELD := 20
const RACE_SEED := 0
## The field #61's stuck fix was diagnosed on.
const PASS_SEED := 41
## The seed tests/ai_driver_contract_test.gd and tests/skill_and_mistakes_test.gd pin identity on, and
## what Python makes of rival 2 there: DomainSeed.child(DomainSeed.derive(1, 7, "ai_driver"), 2, 0), and
## its skill, DomainSeed.child(domain, 2, 1) / 16^15. Restated here, not derived.
const IDENTITY_SEED := 7
const IDENTITY_PINNED_INDEX := 2
const IDENTITY_PINNED_SEED := 54569277199214867
const IDENTITY_PINNED_SKILL := 0.1027125029750845
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
var _break_go_round := false
var _break_mistake_replay := false
var _tuning: VehicleTuning
## The mistakes-off race 1's control streams, kept for the mistakes-on section's guard when both run.
var _mistakes_off_streams: Array = []


## --break-go-round: nothing ahead is ever what stopped the car, so every stall is an ordinary reversal.
class NoGoingRoundDriver extends ReactiveDriver:
	func _blocked_by_a_rival() -> bool:
		return false


## --break-mistake-replay: every draw is offset by how many draws any such driver in this process has
## made before it, so a race's mistakes depend on what ran before it.
class SharedDrawDriver extends ReactiveDriver:
	static var draws_made := 0

	func _draw(n: int, draw: int) -> float:
		draws_made += 1
		return super(n + draws_made, draw)


## The refusal check: the snap's bound forced low, so real grid poses overrun it. `max_steps` is set back
## to the production bound to show the same session then builds its race.
class TightBoundSession extends MainSession:
	var max_steps := 0

	func _spawn_angle_max_steps() -> int:
		return max_steps


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
	_break_go_round = arguments.has("--break-go-round")
	_break_mistake_replay = arguments.has("--break-mistake-replay")
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
	if _break_go_round:
		print("NOTE: --break-go-round is on; in the seed %d race no rival goes round a car stopped in front of it." % PASS_SEED)
	if _break_mistake_replay:
		print("NOTE: --break-mistake-replay is on; in the mistakes-on races every rival draws its mistakes from shared state.")
	if _wants("race"):
		_check(await _verify_the_field_races_the_same_way_twice(false), "the race verification ran to completion")
	if _wants("mistakes"):
		_check(await _verify_the_field_races_the_same_way_twice(true), "the mistakes-on race verification ran to completion")
	if _wants("pass"):
		_check(await _verify_a_field_that_has_to_go_round(), "the go-round field verification ran to completion")
	if _wants("zero"):
		_check(await _verify_count_zero_runs_no_field(), "the count-zero verification ran to completion")
	if _wants("poses"):
		_check(await _verify_rivals_spawn_at_physics_fixed_points(), "the fixed-pose verification ran to completion")
	if _wants("refuse"):
		_check(await _verify_a_pose_past_the_bound_refuses_the_race(), "the refusal verification ran to completion")
	if _wants("identity"):
		_check(await _verify_each_rival_is_its_own_driver(), "the identity verification ran to completion")
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


## I3 of the PR #62 review: past the snap's bound a restart must not place a rival unsnapped. The bound is
## forced to 0, which real seed-0 grid poses overrun, and the session must build nothing of the race.
## Then the same session at the production bound restarts onto the same seed and builds it, which shows
## the refusal is the bound's doing and not a session that cannot build a race at all.
func _verify_a_pose_past_the_bound_refuses_the_race() -> bool:
	var session := _new_session(FULL_FIELD, false, RACE_SEED, TightBoundSession)
	print("NOTE: the refusal check forces the snap's bound to 0; the ERROR lines that follow are the behaviour under test.")
	root.add_child(session)
	await process_frame
	var failure := str(session.call("get_spawn_failure")) if session.has_method("get_spawn_failure") else ""
	var mounted := session.get_node("World/VehicleMount").get_child_count() + session.get_node("World/TrackMount").get_child_count()
	_check(not failure.is_empty(), "REFUSED: with the bound forced to 0, seed %d's restart reports a rival pose past it (%s)" % [RACE_SEED, failure])
	_check(mounted == 0 and (session.get("_rivals") as Array).is_empty() and session.get("_sensing") == null, "REFUSED: and builds nothing of the race: no track, no car, no rival, no sensing pass (%d nodes mounted, %d rivals)" % [mounted, (session.get("_rivals") as Array).size()])
	_check(session.get_session_snapshot().is_empty() and session.get_race_order().is_empty(), "REFUSED: the snapshot and the standings are empty (%d keys, %d ranked)" % [session.get_session_snapshot().size(), session.get_race_order().size()])
	var status := session.get_node("%StatusLabel") as Label
	_check(status.text == MainSession.SPAWN_REFUSED_STATUS and (session.get_node("%StatusPanel") as Control).visible, "REFUSED: the status line says the race did not start (\"%s\")" % status.text)
	for tick in range(30):
		await physics_frame
	await process_frame
	mounted = session.get_node("World/VehicleMount").get_child_count() + session.get_node("World/TrackMount").get_child_count()
	_check(mounted == 0 and (session.get_node("%StatusPanel") as Control).visible, "REFUSED: 30 physics ticks later nothing has been built and the status line is still up (%d mounted)" % mounted)
	session.set("max_steps", MainSession.SPAWN_ANGLE_MAX_STEPS)
	session.restart_with_seed(RACE_SEED)
	_check(str(session.call("get_spawn_failure")).is_empty() and (session.get("_rivals") as Array).size() == FULL_FIELD and session.get_node("World/VehicleMount").get_child_count() == FULL_FIELD + 1, "the same session at the proved bound of %d restarts onto seed %d and builds all %d rivals (%d cars mounted)" % [MainSession.SPAWN_ANGLE_MAX_STEPS, RACE_SEED, FULL_FIELD, session.get_node("World/VehicleMount").get_child_count()])
	session.free()
	await process_frame
	return true


## I1 of the PR #62 review. What makes one rival differ from another -- its seed, and through it its skill,
## its mistakes and its look-ahead -- asserted over the rivals the session itself spawns and senses.
func _verify_each_rival_is_its_own_driver() -> bool:
	var session := _new_session(FULL_FIELD, false, IDENTITY_SEED)
	root.add_child(session)
	await process_frame
	await physics_frame
	await physics_frame
	var rivals: Array = session.get("_rivals")
	var domain := DomainSeed.derive(1, IDENTITY_SEED, "ai_driver")
	var own_index := 0
	var own_seed := 0
	var driven := 0
	var skills := {}
	var horizons := {}
	var sensed_at_own := 0
	var mismatched: Array[String] = []
	var pinned: AiDriver = null
	for slot in range(rivals.size()):
		var index := int(rivals[slot]["index"])
		var driver: AiDriver = rivals[slot]["driver"]
		own_index += int(index == slot + 1 and driver.car_index == index)
		own_seed += int(driver.driver_seed == DomainSeed.child(domain, index, 0))
		driven += int(_driver_int(driver, "_tick") > 0)
		skills[driver.get("skill")] = true
		var horizon := driver.sensing_horizon()
		horizons[horizon] = true
		var sensed = driver.get("_look_ahead")
		if sensed != null and float(sensed) == horizon:
			sensed_at_own += 1
		else:
			mismatched.append("rival %d sensed at %s, asks for %.3f" % [index, sensed, horizon])
		if index == IDENTITY_PINNED_INDEX:
			pinned = driver
	_check(rivals.size() == FULL_FIELD and own_index == FULL_FIELD, "IDENTITY: every one of the twenty rivals the session spawns on seed %d drives with its own slot's car index (%d of %d)" % [IDENTITY_SEED, own_index, rivals.size()])
	_check(own_seed == FULL_FIELD, "IDENTITY: every rival's driver seed is DomainSeed.child(DomainSeed.derive(1, %d, \"ai_driver\"), index, 0) (%d of %d)" % [IDENTITY_SEED, own_seed, rivals.size()])
	var pinned_seed: int = pinned.driver_seed if pinned != null else -1
	var pinned_skill = pinned.get("skill") if pinned != null else null
	_check(pinned_seed == IDENTITY_PINNED_SEED and pinned_skill != null and absf(float(pinned_skill) - IDENTITY_PINNED_SKILL) < 1e-12, "IDENTITY: rival %d's seed and skill are the values computed independently in Python (%d against %d, %s against %.16f)" % [IDENTITY_PINNED_INDEX, pinned_seed, IDENTITY_PINNED_SEED, pinned_skill, IDENTITY_PINNED_SKILL])
	_check(skills.size() == FULL_FIELD, "IDENTITY: the twenty rivals drive with twenty different skills (%d distinct)" % skills.size())
	_check(driven == FULL_FIELD, "every rival has sensed and driven at least one tick, so the horizons below were sensed (%d of %d)" % [driven, FULL_FIELD])
	_check(horizons.size() > 1, "the rivals ask for more than one sensing horizon, so sensing each at its own is not sensing all at one (%d distinct)" % horizons.size())
	_check(sensed_at_own == FULL_FIELD, "HORIZON: the session senses every rival at the horizon its own driver asks for (%d of %d; %s)" % [sensed_at_own, FULL_FIELD, ", ".join(mismatched)])
	session.free()
	await process_frame
	return true


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


func _verify_the_field_races_the_same_way_twice(mistakes: bool) -> bool:
	var swap: GDScript = SharedDrawDriver if mistakes and _break_mistake_replay else null
	var first := await _race(false, RACE_SEED, swap, mistakes)
	var second := await _race(true, RACE_SEED, swap, mistakes)
	for record in [first, second]:
		var label: String = record.label
		_check(record.steps_before_first_sense == (1 if record.after_a_step else 0), "%s: %d physics step(s) ran between spawn and the first sense" % [label, record.steps_before_first_sense])
		_check(record.finished == FULL_FIELD, "FULL FIELD: %s: every one of the twenty rivals laps (%d)" % [label, record.finished])
		# These three are only true of a rival that was watched driving: a car is observed from its
		# driver's first sensed tick, so an idle field would pass them unobserved.
		var watched: int = record.watched
		_check(watched == FULL_FIELD and record.worst_slow < _stuck_ticks(), "FULL FIELD: %s: all %d rivals were watched driving and none meets the stuck rule (%d watched, longest slow streak %d of %d ticks)" % [label, FULL_FIELD, watched, record.worst_slow, _stuck_ticks()])
		_check(watched == FULL_FIELD and record.strayed == 0, "FULL FIELD: %s: all %d rivals were watched driving and none leaves the play area or gets lost (%d watched, %d strayed)" % [label, FULL_FIELD, watched, record.strayed])
		if mistakes:
			_check(watched == FULL_FIELD and record.switched_on == FULL_FIELD and record.mistakes > 0, "SWITCH ON: %s: all %d rivals were watched driving with mistakes on, and the field logged mistakes (%d watched, %d on, %d planned, %d logged)" % [label, FULL_FIELD, watched, record.switched_on, record.planned, record.mistakes])
		else:
			_check(watched == FULL_FIELD and record.switched_on == 0 and record.mistakes == 0 and record.planned == 0, "SWITCH OFF: %s: all %d rivals were watched driving and none has mistakes on, plans one or logs one (%d watched, %d on, %d planned, %d logged)" % [label, FULL_FIELD, watched, record.switched_on, record.planned, record.mistakes])
		_check(is_equal_approx(record.step_delta, TICK), "%s: the session drove at the production step (%.6f s)" % [label, record.step_delta])
		print("%s: finished %d in %d ticks, order %s, cars touching another before finishing %d, contact ticks %d, mistakes logged %d" % [label, record.finished, record.ticks, record.order, record.touched, record.contact_ticks, record.mistakes])

	var tag := " with mistakes on" if mistakes else ""
	_check(first.order.size() == FULL_FIELD and first.order == second.order, "DETERMINISTIC%s: the same seed and count finish, all twenty, in the same order in both races (%s against %s)" % [tag, first.order, second.order])
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
	_check(same_finish == FULL_FIELD, "DETERMINISTIC%s: every rival finishes, on the same tick in both races (%d of %d)" % [tag, same_finish, FULL_FIELD])
	_check(same_stream == FULL_FIELD, "DETERMINISTIC%s: every rival's control stream is non-empty and identical at 64 bits (%d of %d; diverged: %s)" % [tag, same_stream, FULL_FIELD, ", ".join(diverged)])

	if mistakes:
		var kinds := {}
		var same_log := 0
		var differing_logs: Array[String] = []
		for slot in range(FULL_FIELD):
			for entry in first.logs[slot]:
				kinds[entry.kind] = true
			if first.logs[slot] == second.logs[slot]:
				same_log += 1
			else:
				differing_logs.append("rival %d (%d against %d logged)" % [slot + 1, first.logs[slot].size(), second.logs[slot].size()])
		_check(first.mistakes > 0 and kinds.size() >= 2, "the mistakes-on race logs mistakes of at least two kinds, so identical logs are not two empty ones (%d logged, %d kinds)" % [first.mistakes, kinds.size()])
		_check(same_log == FULL_FIELD, "MISTAKES REPLAY: every rival logs the identical mistakes in both races -- plan number, kind, tick, amount, seconds and end (%d of %d; differ: %s)" % [same_log, FULL_FIELD, ", ".join(differing_logs)])
		if _mistakes_off_streams.size() == FULL_FIELD:
			var acted := 0
			for slot in range(FULL_FIELD):
				acted += int(_first_difference(first.streams[slot], _mistakes_off_streams[slot]) >= 0)
			_check(acted > 0, "the logged mistakes acted: rivals whose mistakes-on stream differs from the same race with mistakes off (%d of %d)" % [acted, FULL_FIELD])
		return true
	_mistakes_off_streams = first.streams

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


## The seed-41 field: the race-1 protocol (a new session, restarted from an idle frame) on PASS_SEED.
func _verify_a_field_that_has_to_go_round() -> bool:
	var record := await _race(false, PASS_SEED, NoGoingRoundDriver if _break_go_round else null)
	var label := "seed %d, twenty rivals, the player idle at pole" % PASS_SEED
	var watched: int = record.watched
	_check(record.finished == FULL_FIELD, "GO ROUND: %s: every one of the twenty rivals laps (%d, in %d ticks)" % [label, record.finished, record.ticks])
	_check(watched == FULL_FIELD and record.worst_slow < _stuck_ticks(), "GO ROUND: %s: all %d rivals were watched driving and none meets the stuck rule (%d watched, longest slow streak %d of %d ticks, by rival %d)" % [label, FULL_FIELD, watched, record.worst_slow, _stuck_ticks(), record.worst_slow_rival])
	_check(watched == FULL_FIELD and record.strayed == 0, "GO ROUND: %s: all %d rivals were watched driving and none leaves the play area or gets lost (%d watched, %d strayed)" % [label, FULL_FIELD, watched, record.strayed])
	_check(record.passes > 0, "GO ROUND: %s: the field went round a stopped car, so this seed still asks for it (%d passes)" % [label, record.passes])
	print("seed %d go-round field: finished %d in %d ticks, longest slow %d (rival %d), passes %d, reversals %d, turn-arounds %d, contact ticks %d" % [PASS_SEED, record.finished, record.ticks, record.worst_slow, record.worst_slow_rival, record.passes, record.reversals, record.turn_arounds, record.contact_ticks])
	return true


# ---------------------------------------------------------------------------------------------
# The race


## A new session at `seed` with twenty rivals, mistakes as asked, raced until every rival laps. Its spawn
## is the session's own restart_with_seed, called either from an idle frame -- the next thing to run
## is the session's own sensing -- or from a call deferred out of a physics frame, which runs after the
## session's _physics_process and before that frame's step, so one step comes first. `swap`, when set,
## is a driver class every rival's driver is replaced by inside that restart, before its first tick.
func _race(after_a_step: bool, seed := RACE_SEED, swap: GDScript = null, mistakes := false) -> Dictionary:
	var label := "race 2 (in-session restart after seed %d, spawned before a physics step)" % OTHER_SEED if after_a_step else "race 1 (new session, spawned in an idle frame)"
	if mistakes:
		label += ", mistakes on"
	var session := _new_session(FULL_FIELD, mistakes, OTHER_SEED if after_a_step else seed)
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
		_restart.call_deferred(session, probe, seed, swap)
	else:
		_restart(session, probe, seed, swap)
	var rivals: Array = session.get("_rivals")
	await physics_frame
	_check(root.world_2d != world_before, "FRESH WORLD: %s: the restart replaced the viewport's World2D (it shows the swap ran, not that nothing outside World came along)" % label)
	var definition: TrackDefinition = session.get("_track_definition")
	var surface := TrackSurfaceMap.new(definition)
	var record := {
		"label": label, "after_a_step": after_a_step, "order": [], "finished": 0, "worst_slow": 0, "worst_slow_rival": 0, "strayed": 0,
		"passes": 0, "reversals": 0, "turn_arounds": 0,
		"touched": 0, "watched": 0, "contact_ticks": 0, "switched_on": 0, "planned": 0, "mistakes": 0, "ticks": 0,
		"steps_before_first_sense": -1, "step_delta": 0.0, "logs": [],
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
			if slow[slot] > record.worst_slow:
				record.worst_slow = slow[slot]
				record.worst_slow_rival = slot + 1
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
		record.passes += _driver_int(driver, "passes")
		record.reversals += _driver_int(driver, "reversals")
		record.turn_arounds += _driver_int(driver, "turn_arounds")
		record.switched_on += int(driver.get("mistakes_enabled") == true)
		record.planned += _driver_int(driver, "mistakes_planned")
		var log: Array = driver.call("mistake_log") if driver.has_method("mistake_log") else []
		record.mistakes += log.size()
		record.logs.append(log)
	probe.free()
	session.free()
	await process_frame
	return record


## The probe goes in after the restart, into the space the race is hosted in. A swap happens here, before
## the first physics frame, so each replacement drives every tick its rival drives.
func _restart(session: MainSession, probe: RigidBody2D, seed: int, swap: GDScript) -> void:
	session.restart_with_seed(seed)
	root.add_child(probe)
	if swap == null:
		return
	for rival in session.get("_rivals"):
		var replacement: AiDriver = swap.new(seed, int(rival["index"]))
		replacement.set("mistakes_enabled", (rival["driver"] as AiDriver).get("mistakes_enabled") == true)
		rival["driver"] = replacement


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


func _new_session(count: int, mistakes: bool, seed: int, script: GDScript = null) -> MainSession:
	var session := (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	if script == null and (_break_spawn_snap or _break_fresh_world):
		script = UnsnappedSession if _break_spawn_snap else ReusedSpaceSession
	if script != null:
		session.set_script(script)
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
