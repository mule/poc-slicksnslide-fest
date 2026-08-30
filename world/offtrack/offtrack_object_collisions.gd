class_name OfftrackObjectCollisions
extends Node2D

var _chunk_body_count := 0


func build(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> void:
	_clear_children()
	if catalog == null or catalog.chunk_size <= 0.0:
		push_error("Off-track collision catalog requires a positive chunk size")
		return
	var bodies: Dictionary = {}
	for placement in placements:
		if not placement.solid:
			continue
		var archetype := catalog.archetype_by_id(placement.archetype_id)
		if archetype == null or not archetype.solid or archetype.collision_radius <= 0.0:
			push_error("Invalid solid off-track placement %s" % placement.stable_id)
			continue
		var chunk := Vector2i(
			floori(placement.transform.origin.x / catalog.chunk_size),
			floori(placement.transform.origin.y / catalog.chunk_size)
		)
		var body: StaticBody2D = bodies.get(chunk)
		if body == null:
			body = StaticBody2D.new()
			body.name = "Chunk_%d_%d" % [chunk.x, chunk.y]
			body.collision_layer = 1
			body.collision_mask = 0
			add_child(body)
			bodies[chunk] = body
			_chunk_body_count += 1
		var shape := CollisionShape2D.new()
		shape.name = placement.stable_id.replace(":", "_")
		shape.position = placement.transform.origin
		shape.rotation = placement.transform.get_rotation()
		var circle := CircleShape2D.new()
		circle.radius = archetype.collision_radius * placement.scale_factor
		shape.shape = circle
		body.add_child(shape)


func collider_count() -> int:
	var count := 0
	for body in get_children():
		if not body is StaticBody2D:
			continue
		for shape in body.get_children():
			if shape is CollisionShape2D and shape.shape != null:
				count += 1
	return count


func chunk_body_count() -> int:
	return _chunk_body_count


func _clear_children() -> void:
	for child in get_children():
		child.free()
	_chunk_body_count = 0
