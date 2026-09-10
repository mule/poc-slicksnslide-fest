extends SceneTree

var _failures: Array[String] = []
var _checks := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_check(_verify_drivers(), "driver verification completed")
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
			state.set_controls(1.0, 1.0, 1.0, 1.0)
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
	var rival := scene.instantiate() as TopDownCar
	rival.freeze = true
	root.add_child(rival)
	var rival_camera := rival.get_node("FollowCamera") as Camera2D
	var current_count := int(camera.is_current()) + int(rival_camera.is_current())
	var enabled_count := int(camera.enabled) + int(rival_camera.enabled)
	print("two cars: current=%d enabled=%d player_current=%s rival_current=%s" % [current_count, enabled_count, camera.is_current(), rival_camera.is_current()])
	# A Viewport holds at most one current Camera2D whatever the cars do, so summing is_current()
	# can never report "too many" — on its own that count is a one-sided guard that catches a field
	# with no camera and never a field with twenty. The quantity that does run away under the bug
	# this task exists to prevent is how many cameras are ELIGIBLE for the viewport, which is what
	# the gate controls: twenty cars, twenty enabled cameras, and whichever entered last wins. Both
	# counts are asserted together so the claim in the name is the claim that is checked. Verified
	# by falsification: defaulting camera_enabled to true fails this on enabled_count == 2, and
	# deleting the gate line fails it on current_count == 0.
	_check(current_count == 1 and enabled_count == 1, "two cars yield exactly one current camera and exactly one eligible for it")
	_check(camera.enabled and camera.is_current() and not rival_camera.enabled, "the eligible camera is the player's and the rival has none")
	_check(root.get_camera_2d() == camera and not rival_camera.is_current(), "rival insertion preserves the player's current camera")
	_check(camera.top_level and camera.ignore_rotation, "camera retains screen-frame position and rotation")
	_check(camera.position_smoothing_enabled and camera.position_smoothing_speed == 7.0, "camera retains engine smoothing at 7")
	_check(camera.zoom == Vector2.ONE * 0.8, "camera retains zoom 0.8")
	_check(camera.position == Vector2(WorldScale.metres(8.0), WorldScale.metres(-4.0)), "camera starts at original player position")
	# Captured from the unmodified production car on task-56's base. Express pixel evidence in
	# metres here to preserve the repository's scale contract. Exact Vector2 equality pins bits.
	var expected := {
		0: Vector2(WorldScale.metres(113.5606689453125 / 12.5), WorldScale.metres(-56.78033447265625 / 12.5)),
		29: Vector2(WorldScale.metres(285.44244384765625 / 12.5), WorldScale.metres(-142.721221923828125 / 12.5)),
		59: Vector2(WorldScale.metres(11.255821228027344 / 12.5), WorldScale.metres(-23.901229858398438 / 12.5)),
	}
	for tick in range(60):
		player.global_position = Vector2(WorldScale.metres(8.0 + tick * 0.2), WorldScale.metres(-4.0 - tick * 0.1))
		player.linear_velocity = Vector2(WorldScale.metres(30.0), WorldScale.metres(-15.0)) if tick < 30 else Vector2(WorldScale.metres(-60.0), WorldScale.metres(25.0))
		player._process(1.0 / 60.0)
		if expected.has(tick):
			print("tick=%d camera=%.9f,%.9f" % [tick + 1, camera.position.x, camera.position.y])
			_check(camera.position == expected[tick], "camera tick %d matches pre-change bits" % (tick + 1))
	player.free()
	_check(not rival_camera.is_current() and root.get_camera_2d() == null, "rival does not acquire viewport when player is freed")
	# Reverse insertion order must also work.
	player = scene.instantiate() as TopDownCar
	player.camera_enabled = true
	root.add_child(player)
	_check(root.get_camera_2d() == player.get_node("FollowCamera") and not rival_camera.is_current(), "player owns viewport when spawned after rival")
	player.free()
	rival.free()
	return true

func _verify_session() -> bool:
	var session := load("res://session/main.tscn").instantiate() as MainSession
	session.session_settings = SessionSettings.new()
	root.add_child(session)
	_check(session.get_session_snapshot().get("opponent_count", -1) == 0, "session stores default count")
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
