# world/height/jump_ramp_placer.gd
class_name JumpRampPlacer
extends RefCounted

## Places symmetric jump ramps on straight runs of an accepted centerline. Runs after road
## acceptance, draws from a domain-separated seed, and never touches the road RNG.

const DOMAIN := "height_channel"


func place(definition: TrackDefinition, catalog: HeightChannelCatalog) -> JumpRampPlacementResult:
	var started_usec := Time.get_ticks_usec()
	var result := JumpRampPlacementResult.new()
	if definition == null or catalog == null or definition.centerline.size() < 3:
		result.fingerprint = _fingerprint(catalog.version if catalog != null else 0, result.placements)
		result.generation_usec = Time.get_ticks_usec() - started_usec
		result.diagnostics = {"invalid_input": 1}
		return result

	var diagnostics := {
		"eligible_runs": 0,
		"requested": 0,
		"placed": 0,
		"rejected_spawn_candidates": 0,
		"rejected_checkpoint_candidates": 0,
		"rejected_spacing_candidates": 0,
		"underfilled": false,
	}
	var centerline := definition.centerline
	var unique_count := centerline.size() - 1
	# Generated definitions carry lap_length; a hand-built fixture may not, so measure when needed.
	var lap_length := definition.lap_length if definition.lap_length > 0.0 else _polyline_length(centerline)
	var spacing := lap_length / float(unique_count)
	var runs := _straight_runs(centerline, catalog, spacing)
	diagnostics["eligible_runs"] = runs.size()

	var domain_seed := DomainSeed.derive(catalog.version, definition.seed, DOMAIN)
	var rng := RandomNumberGenerator.new()
	rng.seed = domain_seed
	var requested := rng.randi_range(catalog.ramps_per_lap_min, catalog.ramps_per_lap_max)
	diagnostics["requested"] = requested

	# Samples a face-plus-clearance occupies, rounded up so the whole zone is inside the run.
	var before := int(ceil((catalog.approach_clearance + catalog.half_length) / spacing))
	var after := int(ceil((catalog.landing_clearance + catalog.half_length) / spacing))
	var crests: Array[Vector2] = []
	for run in runs:
		if result.placements.size() >= requested:
			break
		var run_start: int = run.start
		var run_count: int = run.count
		var window_size := run_count - before - after
		if window_size <= 0:
			continue
		# Every run draws a without-replacement candidate stream from its own child seed, so a
		# rejection here cannot shift another run and every legal crest can be tried at most once.
		rng.seed = DomainSeed.child(domain_seed, run_start, run_count)
		var candidate_offsets: Array[int] = []
		for offset in range(window_size):
			candidate_offsets.append(offset)
		for offset in range(candidate_offsets.size() - 1, 0, -1):
			var swap_index := rng.randi_range(0, offset)
			var held := candidate_offsets[offset]
			candidate_offsets[offset] = candidate_offsets[swap_index]
			candidate_offsets[swap_index] = held
		for attempt in range(candidate_offsets.size()):
			if result.placements.size() >= requested:
				break
			var crest_index := (run_start + before + candidate_offsets[attempt]) % unique_count
			var crest := centerline[crest_index]
			var reason := _rejection_reason(crest, definition, catalog, crests)
			if not reason.is_empty():
				var rejection_key := "rejected_%s_candidates" % reason
				diagnostics[rejection_key] = int(diagnostics[rejection_key]) + 1
				continue
			var next := centerline[(crest_index + 1) % unique_count]
			var previous := centerline[(crest_index - 1 + unique_count) % unique_count]
			var axis := (next - previous).normalized()
			var placement := JumpRampPlacement.new()
			placement.stable_id = "h%d:%d:%d:%d" % [catalog.version, definition.seed, run_start, attempt]
			placement.transform = Transform2D(axis.angle(), crest)
			placement.half_length = catalog.half_length
			placement.crest_height = catalog.crest_height()
			placement.width = definition.track_width
			result.placements.append(placement)
			crests.append(crest)

	result.placements.sort_custom(func(a: JumpRampPlacement, b: JumpRampPlacement) -> bool: return a.stable_id < b.stable_id)
	diagnostics["placed"] = result.placements.size()
	diagnostics["underfilled"] = result.placements.size() < requested
	result.diagnostics = diagnostics
	result.fingerprint = _fingerprint(catalog.version, result.placements)
	result.generation_usec = Time.get_ticks_usec() - started_usec
	return result


## Maximal runs of consecutive gentle samples, as {start, count}, in centerline order. The
## generator rotates the loop so the longest straight starts at index 0 and the sample before it is
## curved, but the scan still wraps so a fallback or fixture loop is handled the same way.
func _straight_runs(centerline: PackedVector2Array, catalog: HeightChannelCatalog, spacing: float) -> Array[Dictionary]:
	var unique_count := centerline.size() - 1
	var gentle: Array[bool] = []
	var first_curved := -1
	for index in range(unique_count):
		var is_gentle := _curvature_at(centerline, index) <= TrackGenerator.STRAIGHT_CURVATURE
		gentle.append(is_gentle)
		if not is_gentle and first_curved < 0:
			first_curved = index
	var minimum_samples := int(ceil(catalog.minimum_run_length() / spacing))
	var runs: Array[Dictionary] = []
	if first_curved < 0:
		if unique_count >= minimum_samples:
			runs.append({"start": 0, "count": unique_count})
		return runs
	var run_start := -1
	var run_count := 0
	for offset in range(1, unique_count + 1):
		var index := (first_curved + offset) % unique_count
		if gentle[index]:
			if run_start < 0:
				run_start = index
				run_count = 0
			run_count += 1
			continue
		if run_start >= 0 and run_count >= minimum_samples:
			runs.append({"start": run_start, "count": run_count})
		run_start = -1
		run_count = 0
	runs.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.start) < int(b.start))
	return runs


func _rejection_reason(crest: Vector2, definition: TrackDefinition, catalog: HeightChannelCatalog, crests: Array[Vector2]) -> String:
	if crest.distance_to(definition.spawn_transform.origin) < catalog.spawn_exclusion + catalog.half_length:
		return "spawn"
	for checkpoint in definition.checkpoints:
		if crest.distance_to(checkpoint.origin) < catalog.checkpoint_exclusion + catalog.half_length:
			return "checkpoint"
	for other in crests:
		if other.distance_to(crest) < catalog.minimum_spacing:
			return "spacing"
	return ""


func _curvature_at(points: PackedVector2Array, index: int) -> float:
	var unique_count := points.size() - 1
	var incoming := points[index] - points[(index - 1 + unique_count) % unique_count]
	var outgoing := points[(index + 1) % unique_count] - points[index]
	var distance := (incoming.length() + outgoing.length()) * 0.5
	if distance <= 0.0:
		return 0.0
	return absf(incoming.angle_to(outgoing)) / distance


func _polyline_length(points: PackedVector2Array) -> float:
	var length := 0.0
	for index in range(points.size() - 1):
		length += points[index].distance_to(points[index + 1])
	return length


func _fingerprint(version: int, placements: Array[JumpRampPlacement]) -> String:
	var components := PackedStringArray(["version=%d" % version])
	for placement in placements:
		var origin := placement.transform.origin
		components.append("%s|%.3f,%.3f|%.6f|%.3f|%.3f|%.3f" % [
			placement.stable_id,
			origin.x,
			origin.y,
			placement.transform.get_rotation(),
			placement.half_length,
			placement.crest_height,
			placement.width,
		])
	return "|".join(components).sha256_text()
