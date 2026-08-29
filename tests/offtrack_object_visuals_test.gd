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
	_check(_verify_prototype_dimensions(), "prototype dimensions use world-scale metres")
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


func _verify_prototype_dimensions() -> bool:
	var grass_mesh := OfftrackObjectMeshFactory.decorative_mesh(&"grass", 1)
	var grass_vertices: PackedVector3Array = grass_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(
		grass_vertices[0].is_equal_approx(Vector3(WorldScale.metres(-0.32), WorldScale.metres(0.4), 0.0)),
		"grass vertex dimensions preserve the intended world metres"
	)
	_check(
		grass_vertices[1].is_equal_approx(Vector3(WorldScale.metres(0.0), WorldScale.metres(-0.8), 0.0)),
		"grass variant height is expressed in world metres"
	)
	var debris_mesh := OfftrackObjectMeshFactory.decorative_mesh(&"debris", 2)
	var debris_vertices: PackedVector3Array = debris_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(
		debris_vertices[1].is_equal_approx(Vector3(WorldScale.metres(0.56), WorldScale.metres(-0.16), 0.0)),
		"debris variant dimensions preserve the intended world metres"
	)
	var tree := OfftrackObjectMeshFactory.solid_visual(&"tree", 1)
	var tree_body := tree.get_child(1) as Polygon2D
	_check(
		tree_body.polygon[2].is_equal_approx(Vector2(WorldScale.metres(0.0), WorldScale.metres(-2.24))),
		"tree apex dimensions preserve the intended world metres"
	)
	var rock := OfftrackObjectMeshFactory.solid_visual(&"rock", 0)
	var rock_body := rock.get_child(1) as Polygon2D
	_check(
		rock_body.polygon[0].is_equal_approx(Vector2(WorldScale.metres(-1.44), WorldScale.metres(0.64))),
		"rock dimensions preserve the intended world metres"
	)
	tree.free()
	rock.free()
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
