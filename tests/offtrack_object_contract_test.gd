extends SceneTree

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(_verify_contracts(), "the off-track object contracts verification ran to completion")
	_check(_verify_seed_vectors(), "the off-track seed verification ran to completion")
	_finish()


func _verify_contracts() -> bool:
	var placement := OfftrackObjectPlacement.new()
	placement.stable_id = "v1:0:3:-2"
	placement.archetype_id = &"tree"
	placement.transform = Transform2D(0.25, Vector2(500.0, 750.0))
	placement.scale_factor = 1.1
	placement.visual_variant = 1
	placement.solid = true
	placement.collision_profile = &"tree_circle"
	_check(placement.stable_id == "v1:0:3:-2", "placement stores a stable ID")
	_check(placement.solid and placement.collision_profile == &"tree_circle", "placement stores its physics classification")

	var catalog := load("res://data/default_offtrack_object_catalog.tres") as OfftrackObjectCatalog
	_check(catalog != null, "default off-track object catalog loads")
	if catalog == null:
		return false
	_check(catalog.version == 1, "catalog pins placement algorithm version 1")
	_check(is_equal_approx(catalog.cell_size, WorldScale.metres(20.0)), "catalog uses a 20 m placement grid")
	_check(is_equal_approx(catalog.solid_clearance, WorldScale.metres(20.0)), "catalog preserves a 20 m solid recovery corridor")
	_check(catalog.archetype_by_id(&"grass") != null, "catalog contains grass")
	_check(catalog.archetype_by_id(&"debris") != null, "catalog contains debris")
	_check(catalog.archetype_by_id(&"tree").solid, "catalog marks trees solid")
	_check(catalog.archetype_by_id(&"rock").solid, "catalog marks rocks solid")
	return true


func _verify_seed_vectors() -> bool:
	_check(OfftrackSeed.domain_seed(0, 1) == 845162064041503952, "seed 0 domain vector is stable")
	_check(OfftrackSeed.domain_seed(42, 1) == 365479572614719053, "seed 42 domain vector is stable")
	_check(OfftrackSeed.cell_seed(845162064041503952, Vector2i(3, -2)) == 173704369122287513, "cell vector is stable")
	return true


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("offtrack_contract checks=%d" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Off-track contract check failed: %s" % failure)
	print("offtrack_contract checks=%d" % _checks)
	quit(1)
