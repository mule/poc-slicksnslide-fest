extends SceneTree

## Rocks are low obstacles on layer 2 and trees are tall obstacles on layer 1. A car above the
## clearance height drops layer 2 from its mask, so it clears a rock and still hits a tree; a car
## on the ground hits both; a car that falls through the clearance over a rock hits the rock.
## Mutation: -- --break-height-layers puts every solid on the tall layer, so the pass-over fails.

const VEHICLE_SCENE := preload("res://vehicle/top_down_car.tscn")
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const CATALOG_PATH := "res://data/default_offtrack_object_catalog.tres"
const HEADING_PLUS_X := PI * 0.5
const ROCK_X := 400.0
const TREE_X := 900.0
const PROBE_SPEED := 200.0
## The probe must be able to reach its default target unobstructed, or "did not reach it" says
## nothing: TREE_X + 60 = 960 px at 200 px/s over a 60 Hz tick needs 288 ticks.
const PROBE_TICKS := 300
## A grounded car stopped by the rock sits at x = 359.3; one with nothing in its way runs on to the
## tree at x = 859.3. This is the same bound the raised car is required to pass.
const STOPPED_AT_ROCK_X := ROCK_X + 60.0

var _failures: Array[String] = []
var _checks := 0
var _break_layers := false


func _initialize() -> void:
	_break_layers = OS.get_cmdline_user_args().has("--break-height-layers")
	call_deferred("_run")


func _run() -> void:
	_check(_verify_layers_by_height(), "the layer assignment verification ran to completion")
	_check(await _verify_grounded_car_hits_both(), "the grounded collision verification ran to completion")
	_check(await _verify_raised_car_clears_the_rock_and_hits_the_tree(), "the raised collision verification ran to completion")
	_check(await _verify_falling_through_clearance_hits_the_rock(), "the descent collision verification ran to completion")
	_check(await _verify_mask_restores_on_the_ground(), "the mask restore verification ran to completion")
	_finish()


func _verify_layers_by_height() -> bool:
	var context := _make_field(0.0)
	var collisions: OfftrackObjectCollisions = context.collisions
	_check(collisions.low_collider_count() == 1, "the rock is a low collider")
	_check(collisions.tall_collider_count() == 1, "the tree is a tall collider")
	_check(collisions.chunk_body_count() == 2, "one chunk with both levels builds two bodies")
	var low_body := collisions.get_node_or_null("Chunk_0_0_low") as StaticBody2D
	var tall_body := collisions.get_node_or_null("Chunk_0_0_tall") as StaticBody2D
	_check(low_body != null and low_body.collision_layer == OfftrackObjectCollisions.LOW_LAYER, "the low body is on layer 2")
	_check(tall_body != null and tall_body.collision_layer == OfftrackObjectCollisions.TALL_LAYER, "the tall body is on layer 1")
	context.world.queue_free()
	return true


func _verify_grounded_car_hits_both() -> bool:
	var context := _make_field(0.0)
	var car: TopDownCar = context.car
	var reached_tree := await _probe(car)
	print("grounded_probe stop_x=%.1f collisions=%d reached_tree=%s" % [car.global_position.x, car.get_collision_count(), reached_tree])
	_check(car.get_collision_count() >= 1, "a grounded car collides with the rock")
	_check(not reached_tree, "a grounded car never reaches past the tree")
	# Where it stopped, not merely that it stopped: `_probe` returns false for a tree collision too,
	# so with no rock in the way this run still ends short of the target and only the position
	# distinguishes the two. Removing the rock moves this from 359.3 to 859.3 and fails here.
	_check(
		car.global_position.x < STOPPED_AT_ROCK_X,
		"a grounded car is stopped at the rock (x=%.1f, bound %.1f), not carried on to the tree at %.1f" % [car.global_position.x, STOPPED_AT_ROCK_X, TREE_X]
	)
	context.world.queue_free()
	await process_frame
	return true


func _verify_raised_car_clears_the_rock_and_hits_the_tree() -> bool:
	var tuning := load(TUNING_PATH) as VehicleTuning
	var context := _make_field(tuning.low_obstacle_clearance + 5.0)
	var car: TopDownCar = context.car
	var passed_rock := await _probe(car, ROCK_X + 60.0)
	_check(passed_rock, "a car above the clearance height passes over the rock")
	_check(car.get_collision_count() == 0, "passing over the rock registers no collision")
	await _probe(car, TREE_X + 60.0)
	_check(car.get_collision_count() >= 1, "the same raised car still collides with the tree")
	_check(car.global_position.x < TREE_X, "the tree stops the raised car")
	context.world.queue_free()
	await process_frame
	return true


## Plateau ends before the rock: the car drops off the edge and falls through the clearance height
## before reaching the rock, so the low layer is back in its mask when it arrives.
func _verify_falling_through_clearance_hits_the_rock() -> bool:
	var context := _make_field(30.0, ROCK_X - 250.0)
	var car: TopDownCar = context.car
	var was_airborne := false
	for tick in range(PROBE_TICKS):
		car.linear_velocity = Vector2(PROBE_SPEED, 0.0) if not car.is_airborne() else car.linear_velocity
		await physics_frame
		if car.is_airborne():
			was_airborne = true
		if car.get_collision_count() > 0:
			break
	_check(was_airborne, "the car leaves the plateau edge")
	_check(car.get_collision_count() >= 1, "a car that has fallen below the clearance collides with the rock")
	context.world.queue_free()
	await process_frame
	return true


func _verify_mask_restores_on_the_ground() -> bool:
	var tuning := load(TUNING_PATH) as VehicleTuning
	var context := _make_field(tuning.low_obstacle_clearance + 5.0, 100.0)
	var car: TopDownCar = context.car
	await physics_frame
	await physics_frame
	_check(car.get_collision_level_mask() == TopDownCar.TALL_LAYER, "above the clearance the mask holds only the tall layer")
	car.global_position = Vector2(300.0, 0.0)
	car.linear_velocity = Vector2.ZERO
	for tick in range(90):
		await physics_frame
	_check(not car.is_airborne(), "the car is back on flat ground")
	_check(car.get_collision_level_mask() == TopDownCar.TALL_LAYER | TopDownCar.LOW_LAYER, "on the ground the mask holds both layers")
	context.world.queue_free()
	await process_frame
	return true


## Holds the car at PROBE_SPEED along +X until it collides or passes target_x.
func _probe(car: TopDownCar, target_x: float = TREE_X + 60.0) -> bool:
	var initial_collisions := car.get_collision_count()
	for tick in range(PROBE_TICKS):
		car.linear_velocity = Vector2(PROBE_SPEED, 0.0)
		await physics_frame
		if car.get_collision_count() > initial_collisions:
			return false
		if car.global_position.x >= target_x:
			return true
	return false


func _make_field(plateau_height: float, plateau_end_x: float = INF) -> Dictionary:
	var world := Node2D.new()
	root.add_child(world)
	var catalog := (load(CATALOG_PATH) as OfftrackObjectCatalog).duplicate(true) as OfftrackObjectCatalog
	if _break_layers:
		catalog.low_obstacle_height = -1.0
	var placements: Array[OfftrackObjectPlacement] = []
	placements.append(_solid(catalog, &"rock", Vector2(ROCK_X, 0.0)))
	placements.append(_solid(catalog, &"tree", Vector2(TREE_X, 0.0)))
	var collisions := OfftrackObjectCollisions.new()
	world.add_child(collisions)
	collisions.build(placements, catalog)
	var car := VEHICLE_SCENE.instantiate() as TopDownCar
	car.tuning = load(TUNING_PATH) as VehicleTuning
	car.global_transform = Transform2D(HEADING_PLUS_X, Vector2(0.0, 0.0))
	var height := HeightChannelTestHeightProvider.new()
	height.mode = HeightChannelTestHeightProvider.Mode.PLATEAU
	height.plateau_height = plateau_height
	height.plateau_end_x = plateau_end_x
	car.set_height_query(height)
	car.set_surface_query(Issue4TestSurfaceProvider.new())
	world.add_child(car)
	return {"world": world, "car": car, "collisions": collisions}


func _solid(catalog: OfftrackObjectCatalog, archetype_id: StringName, origin: Vector2) -> OfftrackObjectPlacement:
	var archetype := catalog.archetype_by_id(archetype_id)
	var placement := OfftrackObjectPlacement.new()
	placement.stable_id = "v1:0:%s" % archetype_id
	placement.archetype_id = archetype_id
	placement.transform = Transform2D(0.0, origin)
	placement.scale_factor = 1.0
	placement.solid = true
	placement.visual_variant = 0
	placement.collision_profile = archetype.collision_profile
	return placement


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Airborne obstacle level checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Airborne obstacle level check failed: %s" % failure)
	quit(1)
