extends SceneTree

## Pins the terrain field before any consumer exists: the catalog defaults and derivations, the
## seed vectors, determinism, the fingerprint, the definition fields, and the two properties the
## rest of the epic leans on -- the gradient is the field's true derivative, and the curvature never
## reaches the level at which the car's lift-off rule fires at max_safe_speed.
##
## Mutations:
##   -- --break-terrain-version    bumps the catalog version on every second build, so repeat
##                                 samples and fingerprints stop agreeing
##   -- --break-terrain-seed       derives every second build's seed from the wrong domain, as a
##                                 field whose seed derivation drifted would, so repeats stop agreeing
##   -- --break-terrain-curvature  quadruples the amplitude, so the field breaks the lift-off bound

const CATALOG_PATH := "res://data/default_terrain_catalog.tres"
const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const BROKEN_AMPLITUDE_FACTOR := 4.0
## Central-difference steps. Truncation error is step^2 / 6 times the next derivative, which the
## shipped catalog bounds near 1e-6 per px^3 for the gradient check and 1e-8 per px^4 for the
## curvature check, so both differences are good to a few times 1e-8. Vector2 is float32, so every
## position the checks use is snapped to a multiple of 0.5 px: below 8192 px those are exact, and
## a step of 0.5 or 1 px stays exact too, leaving only the float32 rounding of the returned
## gradient (a few 1e-9) in the curvature difference.
const GRADIENT_STEP := 0.5
const CURVATURE_STEP := 1.0
const GRADIENT_TOLERANCE := 1e-6
const CURVATURE_TOLERANCE := 1e-8
## Region the curvature sweep and the fingerprints cover: four base cells across, so every octave
## crosses many cell boundaries in both axes.
const SWEEP_AREA := Rect2(-6000.0, -6000.0, 12000.0, 12000.0)
const SWEEP_STEPS := 150
const CURVATURE_SEEDS := [0, 7, 13]
const FINGERPRINT_SEED_COUNT := 20
## The seed 0 fingerprint over SWEEP_AREA. Any change to the field's arithmetic moves it.
const SEED_0_FINGERPRINT := "3ec9ea63e98ee3d1306e8efe6405df7d1d368963ea1f3f0fecfd89e01c8eba17"

var _failures: Array[String] = []
var _checks := 0
var _break_version := false
var _break_seed := false
var _break_curvature := false


func _initialize() -> void:
	_break_version = OS.get_cmdline_user_args().has("--break-terrain-version")
	_break_seed = OS.get_cmdline_user_args().has("--break-terrain-seed")
	_break_curvature = OS.get_cmdline_user_args().has("--break-terrain-curvature")
	call_deferred("_run")


func _run() -> void:
	_check(_verify_catalog_defaults(), "the catalog defaults verification ran to completion")
	_check(_verify_cell_curvature_constant(), "the cell curvature constant verification ran to completion")
	_check(_verify_seed_vectors(), "the seed vector verification ran to completion")
	_check(_verify_determinism(), "the determinism verification ran to completion")
	_check(_verify_gradient_is_the_derivative(), "the gradient verification ran to completion")
	_check(_verify_curvature_is_bounded(), "the curvature bound verification ran to completion")
	_check(_verify_fingerprints(), "the fingerprint verification ran to completion")
	_check(_verify_definition_fields(), "the definition fields verification ran to completion")
	_check(_verify_generator_attaches_the_field(), "the generator attachment verification ran to completion")
	_finish()


func _catalog() -> TerrainCatalog:
	var catalog := load(CATALOG_PATH) as TerrainCatalog
	if catalog != null and _break_curvature:
		var steep := catalog.duplicate(true) as TerrainCatalog
		steep.amplitude *= BROKEN_AMPLITUDE_FACTOR
		print("break_curvature amplitude=%.1f" % steep.amplitude)
		return steep
	return catalog


## The second build of any pair. Under --break-terrain-version it runs on a bumped version; under
## --break-terrain-seed its seed is derived from the height channel's domain instead of the terrain
## domain, the regression a drifted derivation would produce.
func _repeat_field(track_seed: int, catalog: TerrainCatalog) -> TerrainField:
	if _break_version:
		var bumped := catalog.duplicate(true) as TerrainCatalog
		bumped.version += 1
		return TerrainField.for_track(track_seed, bumped)
	if _break_seed:
		return TerrainField.new(DomainSeed.derive(catalog.version, track_seed, "height_channel"), catalog)
	return TerrainField.for_track(track_seed, catalog)


func _verify_catalog_defaults() -> bool:
	var catalog := load(CATALOG_PATH) as TerrainCatalog
	_check(catalog != null, "the default terrain catalog loads")
	if catalog == null:
		return false
	_check(catalog.version == 1, "catalog version is 1")
	_check(is_equal_approx(catalog.amplitude, WorldScale.metres(3.2)), "base amplitude is 3.2 m")
	_check(is_equal_approx(catalog.base_wavelength, WorldScale.metres(240.0)), "base wavelength is 240 m")
	_check(catalog.octaves == 3, "three octaves")
	_check(is_equal_approx(catalog.persistence, 0.25), "persistence is 0.25")
	_check(is_equal_approx(catalog.lacunarity, 2.0), "lacunarity is 2")
	# Persistence 0.25 against lacunarity 2 is deliberate: curvature scales with amplitude over
	# wavelength squared, so each octave contributes exactly as much curvature as the one below it
	# instead of the finest octave dominating the bound.
	_check(is_equal_approx(catalog.persistence * catalog.lacunarity * catalog.lacunarity, 1.0), "every octave carries equal curvature weight")
	_check(is_equal_approx(catalog.octave_amplitude(0), 40.0), "octave 0 amplitude is the base amplitude")
	_check(is_equal_approx(catalog.octave_amplitude(1), 10.0), "octave 1 amplitude is a quarter")
	_check(is_equal_approx(catalog.octave_amplitude(2), 2.5), "octave 2 amplitude is a sixteenth")
	_check(is_equal_approx(catalog.octave_wavelength(0), 3000.0), "octave 0 wavelength is the base wavelength")
	_check(is_equal_approx(catalog.octave_wavelength(1), 1500.0), "octave 1 wavelength halves")
	_check(is_equal_approx(catalog.octave_wavelength(2), 750.0), "octave 2 wavelength quarters")
	_check(is_equal_approx(catalog.total_amplitude(), 52.5), "total amplitude sums the octaves to 52.5 px")
	# Expected values below are worked from the pinned numbers, never from the catalog's own
	# derivations, so a wrong derivation cannot agree with itself.
	var expected_curvature := 225.0 / 16.0 * (40.0 / (3000.0 * 3000.0) + 10.0 / (1500.0 * 1500.0) + 2.5 / (750.0 * 750.0))
	# is_equal_approx floors its tolerance at 1e-5 absolute, a 5% window at this magnitude, so the
	# bound is pinned with an explicit absolute tolerance instead.
	_check(absf(catalog.curvature_bound() - expected_curvature) < 1e-12, "curvature bound is the cell constant times amplitude over wavelength squared, summed")
	_check(absf(catalog.curvature_bound() - 1.875e-4) < 1e-12, "curvature bound is 1.875e-4 per px")
	var expected_slope := 2.0 * 15.0 / 8.0 * (40.0 / 3000.0 + 10.0 / 1500.0 + 2.5 / 750.0)
	_check(absf(catalog.slope_bound() - expected_slope) < 1e-12, "slope bound is twice the peak fade slope times amplitude over wavelength, summed")
	_check(absf(catalog.slope_bound() - 0.0875) < 1e-12, "slope bound is 8.75% per axis")
	var script_defaults := TerrainCatalog.new()
	_check(script_defaults.version == catalog.version, "script default version matches the resource")
	_check(is_equal_approx(script_defaults.amplitude, catalog.amplitude), "script default amplitude matches the resource")
	_check(is_equal_approx(script_defaults.base_wavelength, catalog.base_wavelength), "script default base wavelength matches the resource")
	_check(script_defaults.octaves == catalog.octaves, "script default octave count matches the resource")
	_check(is_equal_approx(script_defaults.persistence, catalog.persistence), "script default persistence matches the resource")
	_check(is_equal_approx(script_defaults.lacunarity, catalog.lacunarity), "script default lacunarity matches the resource")
	return true


## The catalog's bound rests on one constant: the largest directional second derivative a quintic-
## fade value-noise cell can reach with corner values in [-1, 1]. Rederive it by brute force over
## every corner sign pattern, a grid of cell positions and the Hessian's spectral radius, so the
## constant is checked rather than trusted.
func _verify_cell_curvature_constant() -> bool:
	var patterns: Array[Array] = []
	for bits in range(16):
		patterns.append([
			1.0 if bits & 1 else -1.0,
			1.0 if bits & 2 else -1.0,
			1.0 if bits & 4 else -1.0,
			1.0 if bits & 8 else -1.0,
		])
	var steps := 200
	var found := 0.0
	var found_at := Vector2.ZERO
	for row in range(steps + 1):
		var tv := float(row) / float(steps)
		var sv := _fade(tv)
		var dsv := _fade_slope(tv)
		var ddsv := _fade_curvature(tv)
		for column in range(steps + 1):
			var tu := float(column) / float(steps)
			var su := _fade(tu)
			var dsu := _fade_slope(tu)
			var ddsu := _fade_curvature(tu)
			for corners in patterns:
				var b: float = corners[1] - corners[0]
				var c: float = corners[2] - corners[0]
				var d: float = corners[3] - corners[2] - corners[1] + corners[0]
				var huu := (b + d * sv) * ddsu
				var hvv := (c + d * su) * ddsv
				var huv := d * dsu * dsv
				var radius := _spectral_radius(huu, huv, hvv)
				if radius > found:
					found = radius
					found_at = Vector2(tu, tv)
	print("cell_curvature_brute_force=%.9f at=(%.3f, %.3f) constant=%.9f" % [found, found_at.x, found_at.y, TerrainCatalog.CELL_CURVATURE])
	_check(found <= TerrainCatalog.CELL_CURVATURE + 1e-9, "no cell position exceeds the cell curvature constant")
	_check(absf(found - TerrainCatalog.CELL_CURVATURE) < 1e-9, "the cell curvature constant is attained, so it is the supremum and not merely a bound")
	_check(found > 20.0 / sqrt(3.0), "the 2D supremum exceeds the 1D worst case, so the constant is not the axis-only figure")
	return true


func _verify_seed_vectors() -> bool:
	var catalog := load(CATALOG_PATH) as TerrainCatalog
	_check(DomainSeed.derive(1, 0, "terrain") == 76776120966530086, "seed 0 terrain domain vector is stable")
	_check(DomainSeed.derive(1, 42, "terrain") == 99106847639991883, "seed 42 terrain domain vector is stable")
	_check(TerrainField.DOMAIN == "terrain", "the field draws from the terrain domain")
	var field := TerrainField.for_track(0, catalog)
	_check(field.terrain_seed == DomainSeed.derive(catalog.version, 0, "terrain"), "a field built for a track derives its seed through DomainSeed")
	_check(field.terrain_seed != DomainSeed.derive(catalog.version, 0, "height_channel"), "the terrain domain is separated from the height channel domain")
	_check(field.terrain_seed != DomainSeed.derive(catalog.version, 0, "offtrack_objects"), "the terrain domain is separated from the off-track domain")
	_check(field is HeightQuery, "the field answers the height query contract")
	_check(field.octave_count() == catalog.octaves, "the field builds one lattice per catalog octave")
	return true


func _verify_determinism() -> bool:
	var catalog := _catalog()
	var positions := _spread_positions(64)
	var first := TerrainField.for_track(7, catalog)
	var second := _repeat_field(7, catalog)
	var other_version := catalog.duplicate(true) as TerrainCatalog
	other_version.version += 1
	var third := TerrainField.for_track(7, other_version)
	var other_track := TerrainField.for_track(8, catalog)
	var identical := 0
	var version_differs := 0
	var track_differs := 0
	var nonzero := 0
	for position in positions:
		var a := first.sample_at(position)
		var b := second.sample_at(position)
		if a.ground_height == b.ground_height and a.gradient == b.gradient:
			identical += 1
		if a.ground_height != third.sample_at(position).ground_height:
			version_differs += 1
		if a.ground_height != other_track.sample_at(position).ground_height:
			track_differs += 1
		if a.ground_height != 0.0:
			nonzero += 1
	print("determinism identical=%d version_differs=%d track_differs=%d nonzero=%d of %d" % [identical, version_differs, track_differs, nonzero, positions.size()])
	_check(identical == positions.size(), "two fields from the same seed and version agree bit for bit at every position")
	_check(version_differs == positions.size(), "a bumped catalog version changes the height at every position")
	_check(track_differs == positions.size(), "a different track seed changes the height at every position")
	_check(nonzero == positions.size(), "the field is not flat, so agreement is not agreement about zero")
	_check(first.sample_at(positions[0]) != first.sample_at(positions[0]), "each query returns its own sample object rather than a shared one")
	var repeat_a := first.sample_at(positions[3])
	var repeat_b := first.sample_at(positions[3])
	_check(repeat_a.ground_height == repeat_b.ground_height and repeat_a.gradient == repeat_b.gradient, "repeating a query on one field returns the same numbers")
	var total := catalog.total_amplitude()
	var within := 0
	for position in positions:
		if absf(first.sample_at(position).ground_height) <= total:
			within += 1
	_check(within == positions.size(), "every height lies within the catalog's total amplitude")
	return true


func _verify_gradient_is_the_derivative() -> bool:
	var field := TerrainField.for_track(3, _catalog())
	var positions := _spread_positions(400)
	var worst := 0.0
	var worst_at := Vector2.ZERO
	var largest_gradient := 0.0
	var step := Vector2(GRADIENT_STEP, 0.0)
	for position in positions:
		var sample := field.sample_at(position)
		var difference := Vector2(
			(field.height_at(position + step) - field.height_at(position - step)) / (2.0 * GRADIENT_STEP),
			(field.height_at(position + Vector2(0.0, GRADIENT_STEP)) - field.height_at(position - Vector2(0.0, GRADIENT_STEP))) / (2.0 * GRADIENT_STEP)
		)
		var error := (sample.gradient - difference).length()
		largest_gradient = maxf(largest_gradient, sample.gradient.length())
		if error > worst:
			worst = error
			worst_at = position
	# Both entry points share _evaluate today; this guards against them diverging later, and is
	# kept to a handful of positions so it does not inflate the check count.
	for index in [0, 1, positions.size() / 2, positions.size() - 1]:
		var position: Vector2 = positions[index]
		_check(field.sample_at(position).ground_height == field.height_at(position), "height_at agrees with sample_at at (%.1f, %.1f)" % [position.x, position.y])
	print("gradient_max_error=%.10f at=(%.1f, %.1f) largest_gradient=%.5f tolerance=%.10f" % [worst, worst_at.x, worst_at.y, largest_gradient, GRADIENT_TOLERANCE])
	_check(worst < GRADIENT_TOLERANCE, "the analytic gradient matches a central finite difference within %.10f at %d positions (worst %.10f)" % [GRADIENT_TOLERANCE, positions.size(), worst])
	_check(largest_gradient > 100.0 * GRADIENT_TOLERANCE, "gradients are large against the tolerance, so a wrong gradient could not hide inside it")
	_check(largest_gradient <= sqrt(2.0) * _catalog().slope_bound(), "no sampled gradient exceeds the catalog's slope bound")
	return true


## The car leaves the ground when the ground ahead falls away faster than one tick of gravity:
## v . grad(h(p + v dt)) < v . grad(h(p)) - g dt. Dividing by dt, that is the directional second
## derivative along the velocity, v^2 h'' < -g. The bound is therefore on curvature and must hold
## at the top speed the tuning allows, g / max_safe_speed^2. Both sides come from data: the
## threshold from the tuning resource, the field's bound from the catalog's amplitude and
## wavelengths through the cell constant. Raise the car's top speed and this fails.
func _verify_curvature_is_bounded() -> bool:
	var tuning := load(TUNING_PATH) as VehicleTuning
	var catalog := _catalog()
	_check(tuning != null, "the default tuning loads")
	if tuning == null:
		return false
	var lift_off_curvature := tuning.gravity / (tuning.max_safe_speed * tuning.max_safe_speed)
	var analytic_bound := catalog.curvature_bound()
	var sampled_max := 0.0
	var sampled_max_at := Vector2.ZERO
	var sampled_max_seed := -1
	var evaluations := 0
	var started := Time.get_ticks_usec()
	for seed in CURVATURE_SEEDS:
		var field := TerrainField.for_track(seed, catalog)
		for row in range(SWEEP_STEPS + 1):
			for column in range(SWEEP_STEPS + 1):
				var position := SWEEP_AREA.position + Vector2(
					SWEEP_AREA.size.x * float(column) / float(SWEEP_STEPS),
					SWEEP_AREA.size.y * float(row) / float(SWEEP_STEPS)
				)
				var curvature := field.curvature_at(position)
				evaluations += 1
				if curvature > sampled_max:
					sampled_max = curvature
					sampled_max_at = position
					sampled_max_seed = seed
	var sweep_usec := Time.get_ticks_usec() - started
	print("lift_off_curvature=%.10f analytic_bound=%.10f sampled_max=%.10f at=(%.0f, %.0f) seed=%d evaluations=%d sweep_usec=%d" % [lift_off_curvature, analytic_bound, sampled_max, sampled_max_at.x, sampled_max_at.y, sampled_max_seed, evaluations, sweep_usec])
	print("curvature_margin analytic=%.3f sampled=%.3f launch_speed_at_bound=%.1f px/s (%.1f km/h)" % [lift_off_curvature / analytic_bound, lift_off_curvature / sampled_max, sqrt(tuning.gravity / analytic_bound), WorldScale.to_kph(sqrt(tuning.gravity / analytic_bound))])
	_check(analytic_bound < lift_off_curvature, "the catalog's curvature bound (%.10f) stays under the lift-off curvature at max_safe_speed (%.10f)" % [analytic_bound, lift_off_curvature])
	_check(sampled_max < lift_off_curvature, "the sampled maximum curvature (%.10f) stays under the lift-off curvature (%.10f)" % [sampled_max, lift_off_curvature])
	_check(sampled_max <= analytic_bound, "the sampled maximum never exceeds the analytic bound, so the bound is a bound")
	_check(sampled_max > 0.25 * analytic_bound, "the sampled maximum is a real fraction of the bound (%.2f), so the sweep is not measuring a flat field" % (sampled_max / analytic_bound))
	# The curvature the sweep reads is itself checked against the verified gradient: a finite
	# difference of the analytic gradient must reproduce the analytic Hessian's spectral radius.
	# The quintic fade makes the field C2 but not C3, so a stencil straddling a lattice edge of any
	# octave differences across a jump in the third derivative and is only first-order accurate
	# there (the error grows with the step instead of shrinking). Those stencils are skipped, and
	# the count of positions actually checked is asserted so the skip cannot hollow the check out.
	var field := TerrainField.for_track(CURVATURE_SEEDS[0], catalog)
	var worst := 0.0
	var checked := 0
	var skipped := 0
	for position in _spread_positions(200):
		if _straddles_lattice_edge(position, catalog, CURVATURE_STEP):
			skipped += 1
			continue
		checked += 1
		var right := field.sample_at(position + Vector2(CURVATURE_STEP, 0.0)).gradient
		var left := field.sample_at(position - Vector2(CURVATURE_STEP, 0.0)).gradient
		var up := field.sample_at(position + Vector2(0.0, CURVATURE_STEP)).gradient
		var down := field.sample_at(position - Vector2(0.0, CURVATURE_STEP)).gradient
		var hxx := (right.x - left.x) / (2.0 * CURVATURE_STEP)
		var hyy := (up.y - down.y) / (2.0 * CURVATURE_STEP)
		var hxy := 0.5 * ((right.y - left.y) + (up.x - down.x)) / (2.0 * CURVATURE_STEP)
		worst = maxf(worst, absf(_spectral_radius(hxx, hxy, hyy) - field.curvature_at(position)))
	print("curvature_max_error=%.10f tolerance=%.10f checked=%d skipped_on_lattice_edges=%d" % [worst, CURVATURE_TOLERANCE, checked, skipped])
	_check(worst < CURVATURE_TOLERANCE, "the analytic curvature matches a finite difference of the gradient within %.10f at %d positions (worst %.10f)" % [CURVATURE_TOLERANCE, checked, worst])
	_check(checked >= 150, "at least 150 positions sit clear of every lattice edge (%d did)" % checked)
	_check(skipped >= 4, "the scatter's deliberate on-edge positions were recognised as straddling an edge (%d skipped)" % skipped)
	return true


## True when a central-difference stencil of the given half-width around the position crosses a
## lattice edge of any octave on either axis.
func _straddles_lattice_edge(position: Vector2, catalog: TerrainCatalog, half_width: float) -> bool:
	for octave in range(catalog.octaves):
		var wavelength := catalog.octave_wavelength(octave)
		for coordinate in [position.x, position.y]:
			var into_cell := fposmod(coordinate, wavelength)
			if minf(into_cell, wavelength - into_cell) <= half_width:
				return true
	return false


func _verify_fingerprints() -> bool:
	var catalog := _catalog()
	var seen: Dictionary = {}
	var started := Time.get_ticks_usec()
	for seed in range(FINGERPRINT_SEED_COUNT):
		var first := TerrainField.for_track(seed, catalog).fingerprint(SWEEP_AREA)
		var second := _repeat_field(seed, catalog).fingerprint(SWEEP_AREA)
		_check(first == second, "seed %d terrain fingerprint repeats" % seed)
		_check(not seen.has(first), "seed %d terrain fingerprint is distinct from every earlier seed" % seed)
		seen[first] = seed
	var fingerprint_usec := Time.get_ticks_usec() - started
	var seed_0 := TerrainField.for_track(0, catalog).fingerprint(SWEEP_AREA)
	print("seed_0_fingerprint=%s fingerprint_usec_per_seed=%d" % [seed_0, fingerprint_usec / (2 * FINGERPRINT_SEED_COUNT)])
	if not _break_curvature:
		_check(seed_0 == SEED_0_FINGERPRINT, "seed 0 terrain fingerprint matches the pinned vector")
	var bumped := catalog.duplicate(true) as TerrainCatalog
	bumped.version += 1
	_check(TerrainField.for_track(0, bumped).fingerprint(SWEEP_AREA) != seed_0, "a catalog version bump moves the seed 0 fingerprint")
	# The area sits in the hash header, so two areas differing is no proof the grid honours it.
	# Rebuild the fingerprint independently from height_at over the grid the field documents.
	var field := TerrainField.for_track(0, catalog)
	var smaller := Rect2(SWEEP_AREA.position + Vector2(1000.0, -500.0), SWEEP_AREA.size * 0.5)
	_check(seed_0 == _independent_fingerprint(field, catalog, SWEEP_AREA), "the fingerprint is the hash of the documented grid over the sweep area")
	_check(field.fingerprint(smaller) == _independent_fingerprint(field, catalog, smaller), "the fingerprint samples the grid of the area it was asked for")
	return true


## The fingerprint's documented contract, built from the public height query rather than the
## field's own loop: header, then heights on a FINGERPRINT_SPACING grid, row-major, from the
## area's origin, "%.3f" each, joined by "|", SHA-256.
func _independent_fingerprint(field: TerrainField, catalog: TerrainCatalog, area: Rect2) -> String:
	var spacing: float = TerrainField.FINGERPRINT_SPACING
	var components := PackedStringArray(["version=%d|seed=%d|area=%.1f,%.1f,%.1f,%.1f|spacing=%.1f" % [
		catalog.version, field.terrain_seed, area.position.x, area.position.y, area.size.x, area.size.y, spacing,
	]])
	for row in range(int(floor(area.size.y / spacing)) + 1):
		for column in range(int(floor(area.size.x / spacing)) + 1):
			components.append("%.3f" % field.height_at(area.position + Vector2(float(column), float(row)) * spacing))
	return "|".join(components).sha256_text()


func _verify_definition_fields() -> bool:
	var definition := TrackDefinition.new()
	_check(definition.terrain_seed == 0, "a fresh definition has no terrain seed")
	_check(definition.terrain_fingerprint == "", "a fresh definition has no terrain fingerprint")
	_check(definition.terrain_generation_usec == 0, "a fresh definition has no terrain timing")
	_check(definition.terrain_diagnostics.is_empty(), "a fresh definition has no terrain diagnostics")
	return true


## Task 2 (#47) wired the field in: the generator attaches the terrain seed and fingerprint, and
## the height map answers the field away from every ramp. tests/terrain_height_map_test.gd owns
## the sum itself; this is the contract-level wiring check.
func _verify_generator_attaches_the_field() -> bool:
	var catalog := load(CATALOG_PATH) as TerrainCatalog
	var definition: TrackDefinition = TrackGenerator.new().generate(0)
	_check(definition.terrain_seed == DomainSeed.derive(catalog.version, 0, "terrain"), "the generator attaches the terrain domain seed")
	var field := TerrainField.new(definition.terrain_seed, catalog)
	_check(definition.terrain_fingerprint == field.fingerprint(definition.play_area), "the generator attaches the field's fingerprint over the play area")
	var height_map := TrackHeightMap.new(definition)
	var off_ramp := Vector2(1e6, 1e6)
	_check(height_map.sample_at(off_ramp).ground_height == field.height_at(off_ramp), "the height map answers the field away from ramps")
	_check(height_map.sample_at(off_ramp).ground_height != 0.0, "the height map is no longer flat away from ramps")
	return true


## Deterministic scatter over a wide area, including negative coordinates and points near and on
## lattice boundaries of every octave, so the derivative checks cross cell edges. Every position
## is a multiple of 0.5 px so that it, and the finite-difference steps around it, are exact in
## float32 (see the step constants).
func _spread_positions(count: int) -> Array[Vector2]:
	var positions: Array[Vector2] = []
	var golden := 0.7548776662466927
	var golden_2 := 0.5698402909980532
	for index in range(count):
		var x := fmod(0.5 + float(index) * golden, 1.0) * SWEEP_AREA.size.x + SWEEP_AREA.position.x
		var y := fmod(0.5 + float(index) * golden_2, 1.0) * SWEEP_AREA.size.y + SWEEP_AREA.position.y
		positions.append(Vector2(round(x * 2.0) * 0.5, round(y * 2.0) * 0.5))
	positions.append(Vector2.ZERO)
	positions.append(Vector2(3000.0, 0.0))
	positions.append(Vector2(750.0, -1500.0))
	positions.append(Vector2(-3000.0, 4500.0))
	return positions


func _fade(t: float) -> float:
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


func _fade_slope(t: float) -> float:
	return 30.0 * t * t * (t - 1.0) * (t - 1.0)


func _fade_curvature(t: float) -> float:
	return 60.0 * t * (2.0 * t - 1.0) * (t - 1.0)


func _spectral_radius(hxx: float, hxy: float, hyy: float) -> float:
	var mean := 0.5 * (hxx + hyy)
	var half_difference := 0.5 * (hxx - hyy)
	return absf(mean) + sqrt(half_difference * half_difference + hxy * hxy)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		print("PASS: %s" % message)
	else:
		_failures.append(message)
		print("FAIL: %s" % message)


func _finish() -> void:
	if _failures.is_empty():
		print("Terrain field contract checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Terrain field contract check failed: %s" % failure)
	quit(1)
