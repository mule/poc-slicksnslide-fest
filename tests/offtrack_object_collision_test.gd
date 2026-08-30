extends SceneTree

const VEHICLE_SCENE_PATH := "res://vehicle/top_down_car.tscn"
const DEFAULT_TUNING_PATH := "res://data/default_vehicle_tuning.tres"

var _tree_position := Vector2(WorldScale.metres(16.0), 0.0)
var _rock_position := Vector2(WorldScale.metres(32.0), 0.0)

var _failures: Array[String] = []
var _checks := 0
var _remove_solid_collider := false
var _solid_decoration := false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	_remove_solid_collider = args.has("--remove-solid-collider")
	_solid_decoration = args.has("--solid-decoration")
	call_deferred("_run")


func _run() -> void:
	var catalog := load("res://data/default_offtrack_object_catalog.tres") as OfftrackObjectCatalog
	_check(catalog != null, "default off-track object catalog loads")
	if catalog == null:
		_finish()
		return
	_check(await _verify_contract(catalog), "fixture collision verification ran to completion")
	_finish()


func _fixture_placements() -> Array[OfftrackObjectPlacement]:
	var placements: Array[OfftrackObjectPlacement] = []
	placements.append(_placement("v1:0:0:0", &"grass", Vector2(WorldScale.metres(4.0), 0.0), 0.15, 0.8, 1, false, &"none"))
	placements.append(_placement("v1:0:0:1", &"debris", Vector2(WorldScale.metres(6.0), 0.0), -0.35, 1.1, 2, false, &"none"))
	placements.append(_placement("v1:0:0:2", &"tree", _tree_position, 0.5, 0.9, 1, true, &"tree_circle"))
	placements.append(_placement("v1:0:0:3", &"rock", _rock_position, -0.7, 1.2, 2, true, &"rock_circle"))
	return placements


func _placement(stable_id: String, archetype_id: StringName, position: Vector2, rotation: float, scale_factor: float, variant: int, solid: bool, collision_profile: StringName) -> OfftrackObjectPlacement:
	var placement := OfftrackObjectPlacement.new()
	placement.stable_id = stable_id
	placement.archetype_id = archetype_id
	placement.transform = Transform2D(rotation, position)
	placement.scale_factor = scale_factor
	placement.visual_variant = variant
	placement.solid = solid
	placement.collision_profile = collision_profile
	return placement


func _verify_contract(catalog: OfftrackObjectCatalog) -> bool:
	var placements := _fixture_placements()
	if _solid_decoration:
		placements[0].solid = true
		placements[0].collision_profile = &"tree_circle"
	var collisions := OfftrackObjectCollisions.new()
	root.add_child(collisions)
	collisions.build(placements, catalog)
	if _remove_solid_collider:
		_remove_first_shape(collisions)
	_check(_verify_catalog_alignment(placements, catalog), "placement/catalog physics alignment completed")
	_check(collisions.collider_count() == 2, "only tree and rock produce colliders")
	_check(collisions.chunk_body_count() == 1, "nearby solid fixtures share one chunk body")
	_check(_verify_shape_contract(collisions, placements, catalog), "solid shape transforms and radii match fixtures")
	_check(_verify_chunk_local_alignment(catalog), "non-zero chunk alignment verification completed")
	_check(await _verify_sweep(collisions, Vector2.ZERO, Vector2(WorldScale.metres(24.0), 0.0), "tree"), "tree sweep verification completed")
	_check(await _verify_sweep(collisions, Vector2(WorldScale.metres(20.8), 0.0), Vector2(WorldScale.metres(19.2), 0.0), "rock"), "rock sweep verification completed")
	_check(await _verify_car_impact(collisions), "real car impact verification completed")
	collisions.queue_free()
	return true


func _verify_catalog_alignment(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> bool:
	for placement in placements:
		var archetype := catalog.archetype_by_id(placement.archetype_id)
		var expected_solid := archetype != null and archetype.solid
		var expected_profile := archetype.collision_profile if archetype != null else &""
		_check(placement.solid == expected_solid, "%s solid flag matches its catalog archetype" % placement.stable_id)
		_check(placement.collision_profile == expected_profile, "%s collision profile matches its catalog archetype" % placement.stable_id)
	return true


func _verify_shape_contract(collisions: OfftrackObjectCollisions, placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> bool:
	for placement in placements:
		if not placement.solid:
			continue
		var shape := _find_collision_shape(collisions, placement.stable_id.replace(":", "_"))
		var body := shape.get_parent() as StaticBody2D if shape != null else null
		var archetype := catalog.archetype_by_id(placement.archetype_id)
		var chunk := Vector2i(
			floori(placement.transform.origin.x / catalog.chunk_size),
			floori(placement.transform.origin.y / catalog.chunk_size)
		)
		var expected_chunk_origin := Vector2(chunk) * catalog.chunk_size
		_check(body != null, "%s belongs to its chunk body" % placement.stable_id)
		_check(shape != null, "%s has a fixture collision shape" % placement.stable_id)
		if body == null or shape == null or archetype == null:
			continue
		var circle := shape.shape as CircleShape2D
		var expected_radius := archetype.collision_radius * placement.scale_factor
		_check(circle != null, "%s uses a circular collision shape" % placement.stable_id)
		_check(circle != null and is_equal_approx(circle.radius, expected_radius), "%s radius follows catalog radius and placement scale" % placement.stable_id)
		_check(body.position.is_equal_approx(expected_chunk_origin), "%s chunk body is positioned at its chunk origin" % placement.stable_id)
		_check(shape.position.is_equal_approx(placement.transform.origin - expected_chunk_origin), "%s shape stores a chunk-local origin" % placement.stable_id)
		_check(shape.global_position.is_equal_approx(placement.transform.origin), "%s shape global position preserves the placement origin" % placement.stable_id)
		_check(is_equal_approx(shape.rotation, placement.transform.get_rotation()), "%s shape copies placement rotation" % placement.stable_id)
	return true


func _verify_chunk_local_alignment(catalog: OfftrackObjectCatalog) -> bool:
	var placements: Array[OfftrackObjectPlacement] = []
	placements.append(_placement("chunk:tree", &"tree", Vector2(WorldScale.metres(96.0), 0.0), 0.5, 0.9, 1, true, &"tree_circle"))
	placements.append(_placement("chunk:rock", &"rock", Vector2(WorldScale.metres(112.0), 0.0), -0.7, 1.2, 2, true, &"rock_circle"))
	var collisions := OfftrackObjectCollisions.new()
	root.add_child(collisions)
	collisions.build(placements, catalog)
	_check(collisions.chunk_body_count() == 1, "non-zero fixtures share one chunk body")
	_check(_verify_shape_contract(collisions, placements, catalog), "non-zero fixture shapes preserve local/global alignment")
	collisions.free()
	return true


func _find_collision_shape(node: Node, stable_name: String) -> CollisionShape2D:
	for child in node.get_children():
		if child is CollisionShape2D and child.name == stable_name:
			return child
		var found := _find_collision_shape(child, stable_name)
		if found != null:
			return found
	return null


func _remove_first_shape(collisions: OfftrackObjectCollisions) -> void:
	for body in collisions.get_children():
		if not body is StaticBody2D:
			continue
		if body.get_child_count() == 0:
			continue
		var shape := body.get_child(0) as CollisionShape2D
		body.remove_child(shape)
		shape.free()
		return


func _verify_sweep(collisions: OfftrackObjectCollisions, start: Vector2, motion: Vector2, target_name: String) -> bool:
	var body := CharacterBody2D.new()
	body.name = "SweepProbe_%s" % target_name
	body.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
	body.collision_layer = 2
	body.collision_mask = 1
	body.safe_margin = 0.05
	var collision_shape := CollisionShape2D.new()
	var circle := CircleShape2D.new()
	circle.radius = WorldScale.metres(0.32)
	collision_shape.shape = circle
	body.add_child(collision_shape)
	root.add_child(body)
	body.global_position = start
	await physics_frame
	var collision := body.move_and_collide(motion)
	var target := _tree_position if target_name == "tree" else _rock_position
	_check(collision != null, "%s sweep returns a real collision" % target_name)
	_check(body.global_position.x < target.x, "%s sweep stops before target center (%.2f < %.2f)" % [target_name, body.global_position.x, target.x])
	body.queue_free()
	await process_frame
	return true


func _verify_car_impact(collisions: OfftrackObjectCollisions) -> bool:
	var vehicle_scene := load(VEHICLE_SCENE_PATH) as PackedScene
	var tuning := load(DEFAULT_TUNING_PATH) as VehicleTuning
	_check(vehicle_scene != null, "real CCD-enabled car scene loads")
	_check(tuning != null, "default car tuning loads for impact")
	if vehicle_scene == null or tuning == null:
		return true
	var car := vehicle_scene.instantiate() as TopDownCar
	car.global_position = Vector2.ZERO
	car.linear_velocity = Vector2.RIGHT * tuning.max_safe_speed
	root.add_child(car)
	await physics_frame
	for _tick in range(120):
		await physics_frame
		if car.get_collision_count() >= 1:
			break
	_check(car.get_collision_count() >= 1, "real car records an object collision")
	_check(car.get_speed() <= tuning.max_safe_speed * 1.05, "car impact speed remains bounded (%.2f)" % car.get_speed())
	_check(car.global_position.x < _tree_position.x, "CCD car remains short of tree center (%.2f < %.2f)" % [car.global_position.x, _tree_position.x])
	car.queue_free()
	await process_frame
	return true


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	print("offtrack_collision checks=%d failures=%d mutation_remove=%s mutation_decoration=%s" % [_checks, _failures.size(), str(_remove_solid_collider), str(_solid_decoration)])
	if _failures.is_empty():
		quit(0)
		return
	for failure in _failures:
		push_error("Off-track collision check failed: %s" % failure)
	quit(1)
