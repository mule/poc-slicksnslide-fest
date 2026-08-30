class_name OfftrackObjectRuntime
extends Node2D

var _visuals: OfftrackObjectVisuals
var _collisions: OfftrackObjectCollisions


func _init(placements: Array[OfftrackObjectPlacement] = [], catalog: OfftrackObjectCatalog = null) -> void:
	name = "OfftrackObjects"
	_visuals = OfftrackObjectVisuals.new()
	_visuals.name = "Visuals"
	add_child(_visuals)
	_collisions = OfftrackObjectCollisions.new()
	_collisions.name = "Collisions"
	add_child(_collisions)
	if catalog != null:
		_visuals.build(placements, catalog)
		_collisions.build(placements, catalog)


func get_metrics() -> Dictionary:
	return {
		"visuals": _visuals.visual_count(),
		"decorative_batches": _visuals.decorative_batch_count(),
		"solid_visuals": _visuals.solid_visual_count(),
		"colliders": _collisions.collider_count(),
		"collision_chunks": _collisions.chunk_body_count(),
	}
