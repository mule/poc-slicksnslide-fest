class_name OfftrackObjectPlacer
extends RefCounted

const POINT_OFFSETS := [Vector2i.ZERO, Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]


func place(definition: TrackDefinition, catalog: OfftrackObjectCatalog) -> OfftrackObjectPlacementResult:
	var started_usec := Time.get_ticks_usec()
	var result := OfftrackObjectPlacementResult.new()
	if definition == null or catalog == null or definition.centerline.size() < 2:
		result.fingerprint = _fingerprint(catalog.version if catalog != null else 0, result.placements)
		result.generation_usec = Time.get_ticks_usec() - started_usec
		result.diagnostics = {"invalid_input": 1}
		return result

	var diagnostics := _new_diagnostics()
	var distance_index := _build_distance_index(definition)
	var domain_seed := OfftrackSeed.domain_seed(definition.seed, catalog.version)
	var cell_min := Vector2i(
		floori(definition.play_area.position.x / catalog.cell_size),
		floori(definition.play_area.position.y / catalog.cell_size)
	)
	var cell_max := Vector2i(
		ceili(definition.play_area.end.x / catalog.cell_size) - 1,
		ceili(definition.play_area.end.y / catalog.cell_size) - 1
	)
	var solid_placements: Array[OfftrackObjectPlacement] = []
	for cell_x in range(cell_min.x, cell_max.x + 1):
		for cell_y in range(cell_min.y, cell_max.y + 1):
			var cell := Vector2i(cell_x, cell_y)
			_consider_cell(cell, domain_seed, definition, catalog, distance_index, result.placements, solid_placements, diagnostics)

	result.placements.sort_custom(func(a, b): return a.stable_id < b.stable_id)
	result.fingerprint = _fingerprint(catalog.version, result.placements)
	result.generation_usec = Time.get_ticks_usec() - started_usec
	result.diagnostics = _finalize_diagnostics(diagnostics, catalog.minimum_fill_ratio)
	return result


func _build_distance_index(definition: TrackDefinition) -> Dictionary:
	const COARSE_SPACING := 20
	var points := PackedVector2Array()
	var point_cells := {}
	var unique_count := definition.centerline.size() - 1
	for index in range(0, unique_count, COARSE_SPACING):
		points.append(definition.centerline[index])
		var point_cell := Vector2i(floori(definition.centerline[index].x / 1000.0), floori(definition.centerline[index].y / 1000.0))
		if not point_cells.has(point_cell):
			point_cells[point_cell] = []
		point_cells[point_cell].append(points.size() - 1)
	return {"points": points, "point_cells": point_cells}

func _consider_cell(cell: Vector2i, domain_seed: int, definition: TrackDefinition, catalog: OfftrackObjectCatalog, distance_index: Dictionary, placements: Array[OfftrackObjectPlacement], solid_placements: Array[OfftrackObjectPlacement], diagnostics: Dictionary) -> void:
	diagnostics["total_cells"] = int(diagnostics.get("total_cells", 0)) + 1
	var rng := RandomNumberGenerator.new()
	rng.seed = OfftrackSeed.cell_seed(domain_seed, cell)
	var position := Vector2(cell) * catalog.cell_size + Vector2(rng.randf(), rng.randf()) * catalog.cell_size
	var coarse_distance := _nearest_coarse_distance(position, distance_index)
	if not is_finite(coarse_distance):
		return
	var edge_distance := coarse_distance - definition.track_width * 0.5
	var upper_edge_distance := edge_distance
	var near_shoulder := edge_distance <= catalog.near_max_distance
	var zone_name := "near_shoulder" if near_shoulder else "hazard"
	var zone: Dictionary = diagnostics["zones"][zone_name]
	if edge_distance < 0.0:
		zone["road_or_recovery"] = int(zone.get("road_or_recovery", 0)) + 1
		return
	if edge_distance > catalog.hazard_max_distance + catalog.cell_size:
		return
	zone["valid_cells"] = int(zone.get("valid_cells", 0)) + 1
	var occupancy := catalog.near_occupancy if near_shoulder else catalog.hazard_occupancy
	if rng.randf() > occupancy:
		return
	zone["occupied_draws"] = int(zone.get("occupied_draws", 0)) + 1
	var archetype := _choose_archetype(rng, catalog.archetypes_for_zone(near_shoulder), near_shoulder)
	if archetype == null:
		return
	# Coarse samples overestimate the true distance by at most one placement cell.
	# Use the conservative lower bound for road/recovery checks and the upper bound
	# for the outer hazard boundary, avoiding an unbounded per-cell refinement pass.
	var lower_edge_distance := edge_distance - catalog.cell_size * 2.0
	if lower_edge_distance - archetype.footprint_radius * archetype.max_scale < 0.0:
		zone["road_or_recovery"] = int(zone.get("road_or_recovery", 0)) + 1
		return
	edge_distance = lower_edge_distance
	var scale_factor := rng.randf_range(archetype.min_scale, archetype.max_scale)
	var rotation := rng.randf_range(-PI, PI)
	var visual_variant := rng.randi_range(0, maxi(archetype.visual_variant_count - 1, 0))
	var footprint := archetype.footprint_radius * scale_factor
	var contracted_play_area := definition.play_area.grow(-(catalog.containment_buffer + footprint))
	var inside_recovery := archetype.solid and edge_distance - footprint < catalog.solid_clearance
	var outside_zone := upper_edge_distance + footprint > catalog.hazard_max_distance
	var outside_road := edge_distance - footprint < 0.0
	if outside_road or inside_recovery or outside_zone:
		zone["road_or_recovery"] = int(zone.get("road_or_recovery", 0)) + 1
		return
	if not contracted_play_area.has_point(position):
		zone["containment"] = int(zone.get("containment", 0)) + 1
		return
	if archetype.solid and _blocks_spawn_or_checkpoint(position, footprint, definition, catalog):
		zone["spawn_checkpoint"] = int(zone.get("spawn_checkpoint", 0)) + 1
		return
	if archetype.solid and _overlaps_solid(position, archetype.collision_radius * scale_factor, solid_placements, catalog):
		zone["solid_overlap"] = int(zone.get("solid_overlap", 0)) + 1
		return

	var placement := OfftrackObjectPlacement.new()
	placement.stable_id = "v%d:%d:%d:%d" % [catalog.version, definition.seed, cell.x, cell.y]
	placement.archetype_id = archetype.id
	placement.transform = Transform2D(rotation, position)
	placement.scale_factor = scale_factor
	placement.visual_variant = visual_variant
	placement.solid = archetype.solid
	placement.collision_profile = archetype.collision_profile
	placements.append(placement)
	if placement.solid:
		solid_placements.append(placement)
	zone["accepted"] = int(zone.get("accepted", 0)) + 1


func _nearest_coarse_distance(position: Vector2, distance_index: Dictionary) -> float:
	const POINT_CELL_SIZE := 1000.0
	var points: PackedVector2Array = distance_index["points"]
	var point_cells: Dictionary = distance_index["point_cells"]
	var origin_cell := Vector2i(floori(position.x / POINT_CELL_SIZE), floori(position.y / POINT_CELL_SIZE))
	var nearest_squared := INF
	for offset in POINT_OFFSETS:
		for point_index in point_cells.get(origin_cell + offset, []):
			nearest_squared = minf(nearest_squared, position.distance_squared_to(points[point_index]))
	return sqrt(nearest_squared)


func _choose_archetype(rng: RandomNumberGenerator, choices: Array[OfftrackObjectArchetype], near_shoulder: bool) -> OfftrackObjectArchetype:
	var total := 0.0
	for choice in choices:
		total += choice.near_weight if near_shoulder else choice.hazard_weight
	if total <= 0.0:
		return null
	var target := rng.randf() * total
	for choice in choices:
		target -= choice.near_weight if near_shoulder else choice.hazard_weight
		if target <= 0.0:
			return choice
	return choices[-1]


func _blocks_spawn_or_checkpoint(position: Vector2, footprint: float, definition: TrackDefinition, catalog: OfftrackObjectCatalog) -> bool:
	if position.distance_to(definition.spawn_transform.origin) < catalog.spawn_checkpoint_exclusion + footprint:
		return true
	for checkpoint in definition.checkpoints:
		if position.distance_to(checkpoint.origin) < catalog.spawn_checkpoint_exclusion + footprint:
			return true
	return false


func _overlaps_solid(position: Vector2, collision_radius: float, solid_placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog) -> bool:
	for existing in solid_placements:
		var existing_archetype := catalog.archetype_by_id(existing.archetype_id)
		if existing_archetype == null:
			continue
		var existing_radius := existing_archetype.collision_radius * existing.scale_factor
		if position.distance_to(existing.transform.origin) < collision_radius + existing_radius:
			return true
	return false


func _new_diagnostics() -> Dictionary:
	return {
		"total_cells": 0,
		"zones": {
			"near_shoulder": _new_zone_diagnostics(),
			"hazard": _new_zone_diagnostics(),
		},
	}


func _new_zone_diagnostics() -> Dictionary:
	return {
		"valid_cells": 0,
		"occupied_draws": 0,
		"accepted": 0,
		"road_or_recovery": 0,
		"containment": 0,
		"spawn_checkpoint": 0,
		"solid_overlap": 0,
		"underfilled": false,
	}


func _finalize_diagnostics(diagnostics: Dictionary, minimum_fill_ratio: float) -> Dictionary:
	for zone_name in ["near_shoulder", "hazard"]:
		var zone: Dictionary = diagnostics["zones"][zone_name]
		var occupied := int(zone.get("occupied_draws", 0))
		var accepted := int(zone.get("accepted", 0))
		zone["underfilled"] = occupied > 0 and float(accepted) / float(occupied) < minimum_fill_ratio
	return diagnostics


func _fingerprint(version: int, placements: Array[OfftrackObjectPlacement]) -> String:
	var components := PackedStringArray(["version=%d" % version])
	for placement in placements:
		components.append("%s|%s|%.3f,%.3f|%.6f|%.3f|%d|%s|%s" % [
			placement.stable_id,
			placement.archetype_id,
			placement.transform.origin.x,
			placement.transform.origin.y,
			placement.transform.get_rotation(),
			placement.scale_factor,
			placement.visual_variant,
			str(placement.solid),
			placement.collision_profile,
		])
	return "|".join(components).sha256_text()
