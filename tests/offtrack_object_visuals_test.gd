extends SceneTree

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var catalog := load("res://data/default_offtrack_object_catalog.tres") as OfftrackObjectCatalog
	_check(catalog != null, "default off-track object catalog loads")
	if catalog != null:
		_check(_verify_visuals(catalog), "the fixture-driven visual verification ran to completion")
	_finish()


func _fixture_placements() -> Array[OfftrackObjectPlacement]:
	var placements: Array[OfftrackObjectPlacement] = []
	placements.append(_placement("v1:0:1:0", &"grass", Vector2(100.0, 100.0), 0.15, 0.8, 1, false))
	placements.append(_placement("v1:0:1:1", &"debris", Vector2(140.0, 100.0), -0.35, 1.1, 2, false))
	placements.append(_placement("v1:0:4:0", &"tree", Vector2(1200.0, 100.0), 0.5, 0.9, 1, true))
	placements.append(_placement("v1:0:5:0", &"rock", Vector2(1300.0, 100.0), -0.7, 1.2, 2, true))
	return placements


func _placement(stable_id: String, archetype_id: StringName, position: Vector2, rotation: float, scale_factor: float, variant: int, solid: bool) -> OfftrackObjectPlacement:
	var placement := OfftrackObjectPlacement.new()
	placement.stable_id = stable_id
	placement.archetype_id = archetype_id
	placement.transform = Transform2D(rotation, position)
	placement.scale_factor = scale_factor
	placement.visual_variant = variant
	placement.solid = solid
	return placement


func _verify_visuals(catalog: OfftrackObjectCatalog) -> bool:
	var placements := _fixture_placements()
	var visuals := OfftrackObjectVisuals.new()
	root.add_child(visuals)
	visuals.build(placements, catalog)
	_check(visuals.visual_count() == 4, "every fixture placement has a visual")
	_check(visuals.solid_visual_count() == 2, "tree and rock use solid visual nodes")
	_check(visuals.decorative_batch_count() == 2, "grass and debris create separate archetype batches")
	_check(visuals.get_node_or_null("SolidObjects/v1_0_4_0") != null, "tree stable ID names its visual node")
	_check(visuals.get_node_or_null("SolidObjects/v1_0_5_0") != null, "rock stable ID names its visual node")
	_check(_verify_solid_transform(visuals, placements[2]), "tree transform verification completed")
	visuals.queue_free()
	return true


func _verify_solid_transform(visuals: OfftrackObjectVisuals, placement: OfftrackObjectPlacement) -> bool:
	var node := visuals.get_node_or_null("SolidObjects/%s" % placement.stable_id.replace(":", "_")) as Node2D
	if node == null:
		return false
	_check(node.position.is_equal_approx(placement.transform.origin), "solid visual copies placement position")
	_check(is_equal_approx(node.rotation, placement.transform.get_rotation()), "solid visual copies placement rotation")
	_check(node.scale.is_equal_approx(Vector2.ONE * placement.scale_factor), "solid visual copies placement scale")
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
		print("offtrack_visuals checks=%d" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Off-track visual check failed: %s" % failure)
	print("offtrack_visuals checks=%d" % _checks)
	quit(1)
