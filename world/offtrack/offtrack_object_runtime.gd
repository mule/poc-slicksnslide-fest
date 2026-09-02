class_name OfftrackObjectRuntime
extends Node2D

var _visuals: OfftrackObjectVisuals
var _collisions: OfftrackObjectCollisions
var _validation_errors: Array[String] = []


func _init(placements: Array[OfftrackObjectPlacement] = [], catalog: OfftrackObjectCatalog = null) -> void:
	name = "OfftrackObjects"
	y_sort_enabled = true
	_visuals = OfftrackObjectVisuals.new()
	_visuals.name = "Visuals"
	add_child(_visuals)
	_collisions = OfftrackObjectCollisions.new()
	_collisions.name = "Collisions"
	add_child(_collisions)
	if catalog != null:
		var valid_placements := _validated_placements(placements, catalog)
		_visuals.build(valid_placements, catalog)
		_collisions.build(valid_placements, catalog)


func get_metrics() -> Dictionary:
	return {
		"visuals": _visuals.visual_count(),
		"decorative_batches": _visuals.decorative_batch_count(),
		"solid_visuals": _visuals.solid_visual_count(),
		"colliders": _collisions.collider_count(),
		"collision_chunks": _collisions.chunk_body_count(),
		"invalid_placements": _validation_errors.size(),
	}


func validation_errors() -> Array[String]:
	var errors: Array[String] = []
	errors.assign(_validation_errors)
	return errors


func _validated_placements(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> Array[OfftrackObjectPlacement]:
	_validation_errors.clear()
	var valid: Array[OfftrackObjectPlacement] = []
	for index in range(placements.size()):
		var placement := placements[index]
		var error := _placement_error(placement, catalog, index)
		if not error.is_empty():
			_validation_errors.append(error)
			push_error("Invalid off-track %s" % error)
			continue
		valid.append(placement)
	return valid


func _placement_error(placement: OfftrackObjectPlacement, catalog: OfftrackObjectCatalog, index: int) -> String:
	if placement == null:
		return "placement[%d]: null record" % index
	var record := "placement[%d] %s" % [index, placement.stable_id]
	var archetype := catalog.archetype_by_id(placement.archetype_id)
	if archetype == null:
		return "%s: unknown archetype %s" % [record, placement.archetype_id]
	if placement.solid != archetype.solid:
		return "%s: solid does not match catalog" % record
	if placement.collision_profile != archetype.collision_profile:
		return "%s: collision profile does not match catalog" % record
	var origin := placement.transform.origin
	if not is_finite(origin.x) or not is_finite(origin.y):
		return "%s: position must be finite" % record
	var rotation := placement.transform.get_rotation()
	if not is_finite(rotation):
		return "%s: rotation must be finite" % record
	if not is_finite(placement.scale_factor):
		return "%s: scale must be finite" % record
	if placement.scale_factor <= 0.0:
		return "%s: scale must be positive" % record
	return ""
