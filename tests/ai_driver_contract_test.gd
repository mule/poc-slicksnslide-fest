extends SceneTree

var _failures: Array[String] = []
var _checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_check(_verify_drivers(), "driver verification completed")
	_check(_verify_seam_isolation(), "seam isolation verification completed")
	_check(_verify_settings(), "settings verification completed")
	_check(_verify_camera(), "camera verification completed")
	_check(_verify_session(), "session verification completed")
	_check(_verify_fingerprints(), "fingerprint verification completed")
	print("AI driver contract: %d checks, %d failures" % [_checks, _failures.size()])
	quit(0 if _failures.is_empty() else 1)

func _verify_drivers() -> bool:
	var driver := AiDriver.new(7, 2)
	var idle := IdleDriver.new(7, 2)
	_check(idle is AiDriver, "IdleDriver implements the AiDriver seam")
	_check(driver.car_index == 2 and idle.car_index == 2, "drivers retain their stable car index")
	_check(driver.driver_seed == AiDriver.new(7, 2).driver_seed, "same track seed and index repeat")
	_check(driver.driver_seed != AiDriver.new(7, 3).driver_seed, "changing car index changes driver seed")
	_check(driver.driver_seed != AiDriver.new(8, 2).driver_seed, "changing track seed changes driver seed")
	_check(driver.driver_seed == DomainSeed.child(DomainSeed.derive(1, 7, "ai_driver"), 2, 0), "identity uses the specified domain and child derivation")
	_check(AiDriver.new(7, 2, 2).driver_seed == DomainSeed.child(DomainSeed.derive(2, 7, "ai_driver"), 2, 0), "explicit version reaches domain derivation")
	_check(driver.driver_seed == 54569277199214867, "driver seed matches independently computed SHA-256 fixture")
	_check(idle.driver_seed == driver.driver_seed, "IdleDriver inherits identity")
	for producer: AiDriver in [driver, idle]:
		for delta in [0.0, 1.0 / 60.0, 0.5]:
			var state := producer.drive(delta)
			_check(state != null and state.steer == 0.0 and state.throttle == 0.0 and state.brake == 0.0 and state.handbrake == 0.0, "driver returns all four neutral controls at delta %s" % delta)
			# Load-bearing, not dead code: dirtying the state we just checked makes the NEXT call
			# prove it is a fresh instance. A drive() returning a cached member fails the assertion
			# above on the following iteration. Do not delete this line as unused.
			state.set_controls(1.0, 1.0, 1.0, 1.0)
	return true

## The issue's one hard "do not": a driver may never hold a reference to the car it drives, because
## a driver that can reach its own RigidBody2D reads ground truth instead of its senses and every
## later determinism guarantee becomes unprovable. Task 2 adds senses and is exactly where this
## erodes, so the rule is asserted structurally rather than left to inspection.
func _verify_seam_isolation() -> bool:
	for producer: AiDriver in [AiDriver.new(7, 2), IdleDriver.new(7, 2)]:
		var class_name_text: String = producer.get_script().get_global_name()
		var declared := 0
		for property in producer.get_property_list():
			if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
				continue
			declared += 1
			# TYPE_NIL closes the hole the rest of this list leaves open. A DECLARED type is always
			# reported, so `var _car: Node2D` comes back as TYPE_OBJECT even while it is null and the
			# list below already refuses it. What comes back as TYPE_NIL is an UNTYPED `var _car`,
			# which the engine cannot describe and which may hold a RigidBody2D the moment anything
			# assigns one. Refusing TYPE_NIL therefore says: every field a driver declares must state
			# a type, and that type must not be a handle.
			_check(int(property["type"]) not in [TYPE_NIL, TYPE_OBJECT, TYPE_NODE_PATH, TYPE_RID, TYPE_CALLABLE, TYPE_SIGNAL], "%s.%s is not a handle to anything (type %d)" % [class_name_text, property["name"], property["type"]])
		# Without this the loop above would pass vacuously the day the properties stop being
		# reported: AiDriver declares car_index, driver_seed and their two backing fields.
		_check(declared >= 4, "%s declares its four identity properties for the check above to see" % class_name_text)
		var construction_arguments := 0
		for method in producer.get_method_list():
			if method["name"] != "_init":
				continue
			for argument in method["args"]:
				construction_arguments += 1
				_check(int(argument["type"]) == TYPE_INT, "%s._init takes %s as an int, not a handle" % [class_name_text, argument["name"]])
		_check(construction_arguments == 3, "%s._init takes exactly the three identity integers" % class_name_text)
	return true

func _verify_settings() -> bool:
	var settings := SessionSettings.new()
	_check(settings.opponent_count == 0, "opponents default to zero")
	for pair in [[-1, 0], [0, 0], [1, 1], [19, 19], [20, 20], [21, 20]]:
		settings.opponent_count = pair[0]
		_check(settings.opponent_count == pair[1], "opponent count %d clamps to %d" % pair)
	return true

func _verify_camera() -> bool:
	var scene := load("res://vehicle/top_down_car.tscn") as PackedScene
	var player := scene.instantiate() as TopDownCar
	player.camera_enabled = true
	player.position = Vector2(WorldScale.metres(8.0), WorldScale.metres(-4.0))
	player.freeze = true
	root.add_child(player)
	player.set_process(false)
	var camera := player.get_node("FollowCamera") as Camera2D
	_check(camera.is_current(), "player camera is current before rival enters")
	# The issue's premise is twenty cars competing for one viewport and opponent_count clamps at 20,
	# so the field is what has to hold. A two-car spot check bounds enabled_count at 2 by its own
	# fixture and never speaks to the case the epic exists for.
	var rivals: Array[TopDownCar] = []
	var cameras: Array[Camera2D] = [camera]
	for index in range(20):
		var extra := scene.instantiate() as TopDownCar
		extra.freeze = true
		root.add_child(extra)
		rivals.append(extra)
		cameras.append(extra.get_node("FollowCamera") as Camera2D)
	var rival: TopDownCar = rivals[0]
	var rival_camera: Camera2D = cameras[1]
	var current_count := 0
	var enabled_count := 0
	for field_camera in cameras:
		current_count += int(field_camera.is_current())
		enabled_count += int(field_camera.enabled)
	print("field: cars=%d current=%d enabled=%d viewport=%s" % [cameras.size(), current_count, enabled_count, root.get_camera_2d()])
	# Guards the two counts above against a fixture that quietly stopped building the field: with
	# one car they would both read 1 and every assertion below would pass while proving nothing.
	_check(cameras.size() == 21 and rivals.size() == 20, "the field fixture holds twenty rivals besides the player")
	# A Viewport holds at most one current Camera2D whatever the cars do, so summing is_current()
	# can never report "too many" — on its own that count is a one-sided guard that catches a field
	# with no camera and never a field with twenty. The quantity that does run away under the bug
	# this task exists to prevent is how many cameras are ELIGIBLE for the viewport, which is what
	# the gate controls: twenty cars, twenty enabled cameras, and whichever entered last wins. Both
	# counts are asserted together so the claim in the name is the claim that is checked. Verified
	# by falsification: defaulting camera_enabled to true fails this on enabled_count == 2, and
	# deleting the gate line fails it on current_count == 0.
	_check(current_count == 1 and enabled_count == 1, "a field of twenty-one cars yields exactly one current camera and exactly one eligible for it")
	var rivals_enabled := enabled_count - int(camera.enabled)
	_check(camera.enabled and camera.is_current() and rivals_enabled == 0, "the eligible camera is the player's and none of the twenty rivals has one")
	_check(root.get_camera_2d() == camera and not rival_camera.is_current(), "rival insertion preserves the player's current camera")

	# C1. _ready() early-returns when tuning is null, BEFORE the camera gate, so on that path the
	# scene's baked enabled = false is the only thing keeping the car off the viewport. Task 60
	# spawns the field and is exactly the code that would add a rival before assigning its tuning.
	# The ERROR line this prints is the guard under test, not a failure.
	var tuningless := scene.instantiate() as TopDownCar
	tuningless.tuning = null
	tuningless.freeze = true
	root.add_child(tuningless)
	var tuningless_camera := tuningless.get_node("FollowCamera") as Camera2D
	print("tuningless car: enabled=%s current=%s viewport=%s" % [tuningless_camera.enabled, tuningless_camera.is_current(), root.get_camera_2d()])
	_check(tuningless.tuning == null, "the tuningless fixture really has no tuning")
	_check(not tuningless_camera.enabled and not tuningless_camera.is_current(), "a car whose _ready early-returns on null tuning takes no camera")
	_check(root.get_camera_2d() == camera, "a tuningless car does not take the viewport from the player")
	tuningless.free()
	# camera_enabled writes through, so a caller that assigns it after the car is already in the
	# tree is not silently ignored. Without the setter the camera would keep whatever _ready() gave
	# it. This is a footgun fix, not a coverage fix: the reordering it protects against inside
	# main.gd is already caught by _verify_session below.
	player.camera_enabled = false
	_check(not camera.enabled and root.get_camera_2d() == null, "clearing camera_enabled after _ready takes the camera away")
	player.camera_enabled = true
	_check(camera.enabled and root.get_camera_2d() == camera, "restoring camera_enabled after _ready gives the camera back")
	# Both flags are set in top_down_car.tscn, so this guards the SCENE against an accidental edit
	# and would still pass if _ready()'s top_level line were deleted. zoom below is the assertion
	# that genuinely exercises _ready(), because zoom is absent from the scene.
	_check(camera.top_level and camera.ignore_rotation, "the scene keeps the camera in the screen frame, unrotated")
	_check(camera.position_smoothing_enabled and camera.position_smoothing_speed == 7.0, "camera retains engine smoothing at 7")
	_check(camera.zoom == Vector2.ONE * 0.8, "camera retains zoom 0.8")
	_check(camera.position == Vector2(WorldScale.metres(8.0), WorldScale.metres(-4.0)), "camera starts at original player position")
	# Captured from the unmodified production car on task-56's base (447cadb). These are measured
	# pixel evidence, not design literals, so they are pinned as pixels and routed back through
	# WorldScale rather than divided by a hardcoded 12.5 — the round trip is deliberately a no-op
	# and keeps PIXELS_PER_METRE out of the expectation. Exact Vector2 equality pins bits.
	var expected := {
		0: _pinned_pixels(113.5606689453125, -56.78033447265625),
		29: _pinned_pixels(285.44244384765625, -142.721221923828125),
		59: _pinned_pixels(11.255821228027344, -23.901229858398438),
	}
	for tick in range(60):
		player.global_position = Vector2(WorldScale.metres(8.0 + tick * 0.2), WorldScale.metres(-4.0 - tick * 0.1))
		player.linear_velocity = Vector2(WorldScale.metres(30.0), WorldScale.metres(-15.0)) if tick < 30 else Vector2(WorldScale.metres(-60.0), WorldScale.metres(25.0))
		player._process(1.0 / 60.0)
		if expected.has(tick):
			print("tick=%d camera=%.9f,%.9f" % [tick + 1, camera.position.x, camera.position.y])
			_check(camera.position == expected[tick], "camera tick %d matches pre-change bits" % (tick + 1))
	player.free()
	# restart_with_seed frees and re-creates the player car on every restart (session/main.gd's
	# _install_scene), so "the viewport is free for a moment with the field still in the tree" is a
	# path that ships, not a hypothetical.
	var claimed_after_free := 0
	for field_camera in cameras.slice(1):
		claimed_after_free += int(field_camera.is_current())
	_check(claimed_after_free == 0 and root.get_camera_2d() == null, "no rival in the field acquires the viewport when the player is freed")
	# Reverse insertion order must also work.
	player = scene.instantiate() as TopDownCar
	player.camera_enabled = true
	root.add_child(player)
	_check(root.get_camera_2d() == player.get_node("FollowCamera") and not rival_camera.is_current(), "player owns viewport when spawned after the field")
	player.free()
	for extra in rivals:
		extra.free()
	return true

## Round-trips captured pixel evidence through the scale contract. metres(to_metres(px)) is px by
## construction; the point is that no expectation in this file spells PIXELS_PER_METRE itself.
func _pinned_pixels(x_px: float, y_px: float) -> Vector2:
	return Vector2(WorldScale.metres(WorldScale.to_metres(x_px)), WorldScale.metres(WorldScale.to_metres(y_px)))

func _verify_session() -> bool:
	var session := load("res://session/main.tscn").instantiate() as MainSession
	session.session_settings = SessionSettings.new()
	# Set before the session enters the tree, so the value _ready()'s own restart reads is not the
	# field's initial value. Asserting the default 0 here proved nothing: _opponent_count starts at
	# 0 too, so deleting the read in restart_with_seed left it passing. Three does not.
	session.session_settings.opponent_count = 3
	root.add_child(session)
	_check(session.get_session_snapshot().get("opponent_count", -1) == 3, "the session's first restart reads the count and publishes it in the snapshot")
	session.session_settings.opponent_count = 20
	session.restart_with_seed(7)
	_check(session.get_session_snapshot().get("opponent_count", -1) == 20, "restart reads updated opponent count")
	_check(session.get_node("World/VehicleMount").get_child_count() == 1, "count is stored only until task 60 spawns the field")
	_check(root.get_camera_2d() == session.get_node("World/VehicleMount/PlayerCar/FollowCamera"), "session explicitly grants the player its camera")
	session.free()
	return true

func _verify_fingerprints() -> bool:
	var rows := 0
	for line in FileAccess.get_file_as_string("res://docs/evidence/terrain/terrain-ledger-seeds-0-19.txt").split("\n"):
		if not line.begins_with("ledger seed="):
			continue
		var fields := {}
		for token in line.split(" "):
			var pair := token.split("=")
			if pair.size() == 2:
				fields[pair[0]] = pair[1]
		var definition: TrackDefinition = TrackGenerator.new().generate(int(fields.seed))
		_check(definition.geometry_fingerprint == fields.road, "seed %s road fingerprint unchanged" % fields.seed)
		_check(definition.offtrack_object_fingerprint == fields.objects, "seed %s objects fingerprint unchanged" % fields.seed)
		_check(definition.height_fingerprint == fields.height, "seed %s height fingerprint unchanged" % fields.seed)
		_check(definition.terrain_fingerprint == fields.terrain, "seed %s terrain fingerprint unchanged" % fields.seed)
		rows += 1
	_check(rows == 20, "all twenty ledger seeds checked")
	return true

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)
	print("%s: %s" % ["PASS" if condition else "FAIL", message])
