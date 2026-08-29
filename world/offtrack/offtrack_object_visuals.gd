class_name OfftrackObjectVisuals
extends Node2D

var _visual_count := 0
var _decorative_batch_count := 0
var _solid_visual_count := 0


func build(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> void:
	_clear_children()
	var decorative := Node2D.new()
	decorative.name = "DecorativeBatches"
	add_child(decorative)
	var solids := Node2D.new()
	solids.name = "SolidObjects"
	solids.y_sort_enabled = true
	add_child(solids)
	_build_decorative(placements, catalog, decorative)
	_build_solids(placements, catalog, solids)


func visual_count() -> int:
	return _visual_count


func decorative_batch_count() -> int:
	return _decorative_batch_count


func solid_visual_count() -> int:
	return _solid_visual_count


func _build_decorative(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog, parent: Node2D) -> void:
	var groups: Dictionary = {}
	for placement in placements:
		if placement == null or placement.solid:
			continue
		var chunk := Vector2i(
			floori(placement.transform.origin.x / catalog.chunk_size),
			floori(placement.transform.origin.y / catalog.chunk_size)
		)
		var key := "%d:%d:%s:%d" % [chunk.x, chunk.y, placement.archetype_id, placement.visual_variant]
		if not groups.has(key):
			groups[key] = []
		var group: Array = groups[key]
		group.append(placement)
		groups[key] = group
	for key in groups.keys():
		var typed_group: Array[OfftrackObjectPlacement] = []
		for placement in groups[key]:
			typed_group.append(placement)
		_add_batch(parent, key, typed_group, catalog)


func _add_batch(parent: Node2D, key: String, group: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> void:
	var first := group[0]
	var mesh := OfftrackObjectMeshFactory.decorative_mesh(first.archetype_id, first.visual_variant)
	if mesh == null:
		push_error("Unknown decorative archetype %s" % first.archetype_id)
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.mesh = mesh
	multimesh.instance_count = group.size()
	for index in range(group.size()):
		var placement := group[index]
		var instance_transform := placement.transform.scaled_local(Vector2.ONE * placement.scale_factor)
		multimesh.set_instance_transform_2d(index, instance_transform)
	var chunk := Vector2i(floori(first.transform.origin.x / catalog.chunk_size), floori(first.transform.origin.y / catalog.chunk_size))
	multimesh.custom_aabb = AABB(
		Vector3(chunk.x * catalog.chunk_size, chunk.y * catalog.chunk_size, -1.0),
		Vector3(catalog.chunk_size, catalog.chunk_size, 2.0)
	)
	var instance := MultiMeshInstance2D.new()
	instance.name = key
	instance.multimesh = multimesh
	instance.z_index = -1
	parent.add_child(instance)
	_decorative_batch_count += 1
	_visual_count += group.size()


func _build_solids(placements: Array[OfftrackObjectPlacement], _catalog: OfftrackObjectCatalog, parent: Node2D) -> void:
	for placement in placements:
		if placement == null or not placement.solid:
			continue
		var visual := OfftrackObjectMeshFactory.solid_visual(placement.archetype_id, placement.visual_variant)
		if visual == null:
			push_error("Unknown solid archetype %s" % placement.archetype_id)
			continue
		visual.name = placement.stable_id.replace(":", "_")
		visual.position = placement.transform.origin
		visual.rotation = placement.transform.get_rotation()
		visual.scale = Vector2.ONE * placement.scale_factor
		parent.add_child(visual)
		_solid_visual_count += 1
		_visual_count += 1


func _clear_children() -> void:
	for child in get_children():
		child.free()
	_visual_count = 0
	_decorative_batch_count = 0
	_solid_visual_count = 0
