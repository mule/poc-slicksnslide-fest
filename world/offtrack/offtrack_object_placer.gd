class_name OfftrackObjectPlacer
extends RefCounted

const SAMPLE_STRIDE := 4
const INDEX_CELL_SIZE_METRES := 160.0


func place(definition: TrackDefinition, catalog: OfftrackObjectCatalog) -> OfftrackObjectPlacementResult:
	var started_usec := Time.get_ticks_usec()
	var result := OfftrackObjectPlacementResult.new()
	if definition == null or catalog == null or definition.centerline.size() < 2:
		result.fingerprint = _fingerprint(catalog.version if catalog != null else 0, result.placements)
		result.generation_usec = Time.get_ticks_usec() - started_usec
		result.diagnostics = {"invalid_input": 1}
		return result

	var diagnostics := _new_diagnostics()
	var distance_index := _build_distance_index(definition, catalog)
	var domain_seed := OfftrackSeed.domain_seed(definition.seed, catalog.version)
	var cell_min := Vector2i(
		floori(definition.play_area.position.x / catalog.cell_size),
		floori(definition.play_area.position.y / catalog.cell_size)
	)
	var cell_max := Vector2i(
		ceili(definition.play_area.end.x / catalog.cell_size) - 1,
		ceili(definition.play_area.end.y / catalog.cell_size) - 1
	)
	var rng := RandomNumberGenerator.new()
	var near_choices := catalog.archetypes_for_zone(true)
	var hazard_choices := catalog.archetypes_for_zone(false)
	var solid_index := _new_solid_index(catalog)
	for cell_x in range(cell_min.x, cell_max.x + 1):
		for cell_y in range(cell_min.y, cell_max.y + 1):
			var cell := Vector2i(cell_x, cell_y)
			_consider_cell(cell, domain_seed, definition, catalog, distance_index, rng, near_choices, hazard_choices, result.placements, solid_index, diagnostics)

	result.placements.sort_custom(func(a, b): return a.stable_id < b.stable_id)
	result.fingerprint = _fingerprint(catalog.version, result.placements)
	result.generation_usec = Time.get_ticks_usec() - started_usec
	result.diagnostics = _finalize_diagnostics(diagnostics, catalog.minimum_fill_ratio)
	return result


func _build_distance_index(definition: TrackDefinition, catalog: OfftrackObjectCatalog) -> Dictionary:
	var unique_count := definition.centerline.size() - 1
	var sample_indices: Array[int] = []
	for index in range(0, unique_count, SAMPLE_STRIDE):
		sample_indices.append(index)
	# Closed circuits already retain the repeated endpoint at index zero; keep an
	# open polyline's final endpoint so the half-interval covering proof also holds.
	if sample_indices[-1] != unique_count and definition.centerline[unique_count] != definition.centerline[0]:
		sample_indices.append(unique_count)

	# Every point on an interval between retained vertices is within half that interval's
	# arc length of one endpoint. The triangle inequality therefore gives an honest lower
	# bound on distance to every segment, independent of sample spacing or track shape.
	var cover_radius := WorldScale.metres(0.001)
	for sample_slot in range(sample_indices.size()):
		var interval_start := sample_indices[sample_slot]
		var interval_end := sample_indices[sample_slot + 1] if sample_slot + 1 < sample_indices.size() else unique_count
		var interval_length := 0.0
		for segment_index in range(interval_start, interval_end):
			interval_length += definition.centerline[segment_index].distance_to(definition.centerline[segment_index + 1])
		cover_radius = maxf(cover_radius, interval_length * 0.5 + WorldScale.metres(0.001))

	var index_cell_size := WorldScale.metres(INDEX_CELL_SIZE_METRES)
	var query_radius := catalog.hazard_max_distance + definition.track_width
	var sample_cells := {}
	var sample_points := PackedVector2Array()
	for centerline_index in sample_indices:
		var sample_index := sample_points.size()
		var point := definition.centerline[centerline_index]
		sample_points.append(point)
		_index_bounds(sample_cells, sample_index, point, point, query_radius + cover_radius, index_cell_size)

	# A segment is inserted into every spatial cell overlapped by its query-radius-expanded
	# AABB. A lookup is therefore a superset of TrackSurfaceMap's candidates; the following
	# point-to-segment narrowphase is exact and never relies on a local segment window.
	var segment_cells := {}
	for segment_index in range(unique_count):
		_index_bounds(
			segment_cells,
			segment_index,
			definition.centerline[segment_index],
			definition.centerline[segment_index + 1],
			query_radius,
			index_cell_size
		)

	return {
		"sample_points": sample_points,
		"sample_cells": sample_cells,
		"segment_cells": segment_cells,
		"segments": definition.centerline,
		"cell_size": index_cell_size,
		"cover_radius": cover_radius,
	}


func _index_bounds(cells: Dictionary, item_index: int, first: Vector2, second: Vector2, expansion: float, cell_size: float) -> void:
	var bounds_min := Vector2(minf(first.x, second.x), minf(first.y, second.y)) - Vector2(expansion, expansion)
	var bounds_max := Vector2(maxf(first.x, second.x), maxf(first.y, second.y)) + Vector2(expansion, expansion)
	var cell_min := Vector2i(floori(bounds_min.x / cell_size), floori(bounds_min.y / cell_size))
	var cell_max := Vector2i(floori(bounds_max.x / cell_size), floori(bounds_max.y / cell_size))
	for cell_x in range(cell_min.x, cell_max.x + 1):
		for cell_y in range(cell_min.y, cell_max.y + 1):
			var cell := Vector2i(cell_x, cell_y)
			if not cells.has(cell):
				cells[cell] = PackedInt32Array()
			cells[cell].append(item_index)


func _consider_cell(cell: Vector2i, domain_seed: int, definition: TrackDefinition, catalog: OfftrackObjectCatalog, distance_index: Dictionary, rng: RandomNumberGenerator, near_choices: Array[OfftrackObjectArchetype], hazard_choices: Array[OfftrackObjectArchetype], placements: Array[OfftrackObjectPlacement], solid_index: Dictionary, diagnostics: Dictionary) -> void:
	diagnostics["total_cells"] = int(diagnostics.get("total_cells", 0)) + 1
	rng.seed = OfftrackSeed.cell_seed(domain_seed, cell)
	var position := Vector2(cell) * catalog.cell_size + Vector2(rng.randf(), rng.randf()) * catalog.cell_size
	var distance_bounds := _distance_bounds(position, distance_index)
	if not is_finite(distance_bounds.y):
		return
	var lower_distance: float = distance_bounds.x
	var upper_distance: float = distance_bounds.y
	var half_width: float = definition.track_width * 0.5
	var near_boundary := half_width + catalog.near_max_distance
	var hazard_boundary := half_width + catalog.hazard_max_distance
	var centerline_distance := INF
	var exact_distance_known := false
	if upper_distance < half_width or lower_distance > hazard_boundary:
		return
	if lower_distance < half_width or upper_distance > hazard_boundary or (lower_distance <= near_boundary and upper_distance > near_boundary):
		centerline_distance = _exact_distance_to_centerline(position, distance_index)
		exact_distance_known = true
		if not is_finite(centerline_distance):
			return
		if centerline_distance < half_width or centerline_distance > hazard_boundary:
			return
		lower_distance = centerline_distance
		upper_distance = centerline_distance
	var near_shoulder := upper_distance <= near_boundary
	var zone_name := "near_shoulder" if near_shoulder else "hazard"
	var zone: Dictionary = diagnostics["zones"][zone_name]
	zone["valid_cells"] = int(zone.get("valid_cells", 0)) + 1
	var occupancy := catalog.near_occupancy if near_shoulder else catalog.hazard_occupancy
	if rng.randf() > occupancy:
		return
	zone["occupied_draws"] = int(zone.get("occupied_draws", 0)) + 1
	var archetype := _choose_archetype(rng, near_choices if near_shoulder else hazard_choices, near_shoulder)
	if archetype == null:
		return
	var scale_factor := rng.randf_range(archetype.min_scale, archetype.max_scale)
	var rotation := rng.randf_range(-PI, PI)
	var visual_variant := rng.randi_range(0, maxi(archetype.visual_variant_count - 1, 0))
	var footprint := archetype.footprint_radius * scale_factor
	var contracted_play_area := definition.play_area.grow(-(catalog.containment_buffer + footprint))
	var minimum_distance := half_width + footprint + (catalog.solid_clearance if archetype.solid else 0.0)
	var maximum_distance := hazard_boundary - footprint
	if not exact_distance_known and not (lower_distance >= minimum_distance and upper_distance <= maximum_distance):
		centerline_distance = _exact_distance_to_centerline(position, distance_index)
		exact_distance_known = true
	if not exact_distance_known and lower_distance < near_boundary + footprint and upper_distance > near_boundary - footprint:
		centerline_distance = _exact_distance_to_centerline(position, distance_index)
		exact_distance_known = true
	if exact_distance_known:
		lower_distance = centerline_distance
		upper_distance = centerline_distance
	if not is_finite(lower_distance) or lower_distance < minimum_distance or upper_distance > maximum_distance:
		zone["road_or_recovery"] = int(zone.get("road_or_recovery", 0)) + 1
		return
	if lower_distance - footprint < near_boundary and upper_distance + footprint > near_boundary:
		zone["zone_boundary"] = int(zone.get("zone_boundary", 0)) + 1
		return
	if not contracted_play_area.has_point(position):
		zone["containment"] = int(zone.get("containment", 0)) + 1
		return
	if archetype.solid and _blocks_spawn_or_checkpoint(position, footprint, definition, catalog):
		zone["spawn_checkpoint"] = int(zone.get("spawn_checkpoint", 0)) + 1
		return
	var collision_radius := archetype.collision_radius * scale_factor
	if archetype.solid and _overlaps_solid(position, collision_radius, solid_index, catalog):
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
		_index_solid(placement, solid_index)
	zone["accepted"] = int(zone.get("accepted", 0)) + 1


func _distance_bounds(position: Vector2, distance_index: Dictionary) -> Vector2:
	var cell_size: float = distance_index["cell_size"]
	var origin_cell := Vector2i(floori(position.x / cell_size), floori(position.y / cell_size))
	var points: PackedVector2Array = distance_index["sample_points"]
	var nearest_squared := INF
	for point_index in distance_index["sample_cells"].get(origin_cell, PackedInt32Array()):
		nearest_squared = minf(nearest_squared, position.distance_squared_to(points[point_index]))
	if not is_finite(nearest_squared):
		return Vector2(INF, INF)
	var nearest_distance := sqrt(nearest_squared)
	return Vector2(maxf(nearest_distance - float(distance_index["cover_radius"]), 0.0), nearest_distance)


func _exact_distance_to_centerline(position: Vector2, distance_index: Dictionary) -> float:
	var points: PackedVector2Array = distance_index["segments"]
	var nearest_squared := INF
	var cell_size: float = distance_index["cell_size"]
	var cell := Vector2i(floori(position.x / cell_size), floori(position.y / cell_size))
	var candidates: PackedInt32Array = distance_index["segment_cells"].get(cell, PackedInt32Array())
	for segment_index in candidates:
		# Use the same native exact primitive as TrackSurfaceMap. The expanded-AABB
		# index is only a broadphase, so changing its cell size cannot change results.
		var closest := Geometry2D.get_closest_point_to_segment(
			position,
			points[segment_index],
			points[segment_index + 1],
		)
		nearest_squared = minf(nearest_squared, position.distance_squared_to(closest))
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


func _new_solid_index(catalog: OfftrackObjectCatalog) -> Dictionary:
	var maximum_radius := WorldScale.metres(1.0)
	for archetype in catalog.archetypes:
		if archetype != null and archetype.solid:
			maximum_radius = maxf(maximum_radius, archetype.collision_radius * archetype.max_scale)
	return {
		"cells": {},
		"cell_size": maximum_radius * 2.0,
		"maximum_radius": maximum_radius,
	}


func _overlaps_solid(position: Vector2, collision_radius: float, solid_index: Dictionary, catalog: OfftrackObjectCatalog) -> bool:
	var cell_size: float = solid_index.cell_size
	var origin_cell := Vector2i(floori(position.x / cell_size), floori(position.y / cell_size))
	var cell_radius := ceili((collision_radius + float(solid_index.maximum_radius)) / cell_size)
	for cell_x in range(origin_cell.x - cell_radius, origin_cell.x + cell_radius + 1):
		for cell_y in range(origin_cell.y - cell_radius, origin_cell.y + cell_radius + 1):
			for existing: OfftrackObjectPlacement in solid_index.cells.get(Vector2i(cell_x, cell_y), []):
				var existing_archetype := catalog.archetype_by_id(existing.archetype_id)
				if existing_archetype == null:
					continue
				var existing_radius: float = existing_archetype.collision_radius * existing.scale_factor
				if position.distance_to(existing.transform.origin) < collision_radius + existing_radius:
					return true
	return false


func _index_solid(placement: OfftrackObjectPlacement, solid_index: Dictionary) -> void:
	var cell_size: float = solid_index.cell_size
	var cell := Vector2i(floori(placement.transform.origin.x / cell_size), floori(placement.transform.origin.y / cell_size))
	if not solid_index.cells.has(cell):
		solid_index.cells[cell] = []
	solid_index.cells[cell].append(placement)


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
		"zone_boundary": 0,
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
