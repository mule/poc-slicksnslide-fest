extends SceneTree

## Pins the height channel's shared types before any consumer exists: the flat base query, the
## shared seed routine (and the off-track vectors it must keep producing), ramp record validity,
## catalog derivations, definition and tuning fields, and the clearance/obstacle agreement.

const TUNING_PATH := "res://data/default_vehicle_tuning.tres"
const HEIGHT_CATALOG_PATH := "res://data/default_height_channel_catalog.tres"
const OBJECT_CATALOG_PATH := "res://data/default_offtrack_object_catalog.tres"

var _failures: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_check(_verify_base_query_is_flat(), "the base query verification ran to completion")
	_check(_verify_domain_seed_vectors(), "the domain seed verification ran to completion")
	_check(_verify_placement_validity(), "the placement validity verification ran to completion")
	_check(_verify_catalog_defaults(), "the catalog defaults verification ran to completion")
	_check(_verify_landing_clearance_covers_top_speed_flight(), "the ballistic landing-clearance verification ran to completion")
	_check(_verify_definition_fields(), "the definition fields verification ran to completion")
	_check(_verify_tuning_fields(), "the tuning fields verification ran to completion")
	_check(_verify_clearance_agrees_with_obstacle_height(), "the clearance agreement verification ran to completion")
	_finish()


func _verify_base_query_is_flat() -> bool:
	var query := HeightQuery.new()
	var sample := query.sample_at(Vector2(123.0, -456.0))
	_check(sample.ground_height == 0.0, "the base height query reports flat ground")
	_check(sample.gradient == Vector2.ZERO, "the base height query reports a zero gradient")
	return true


func _verify_domain_seed_vectors() -> bool:
	# The off-track vectors are the ones already pinned in offtrack_object_contract_test.gd. They
	# must survive the extraction into DomainSeed unchanged.
	_check(DomainSeed.derive(1, 0, "offtrack_objects") == 845162064041503952, "DomainSeed reproduces the off-track seed 0 vector")
	_check(DomainSeed.derive(1, 42, "offtrack_objects") == 365479572614719053, "DomainSeed reproduces the off-track seed 42 vector")
	_check(DomainSeed.child(845162064041503952, 3, -2) == 173704369122287513, "DomainSeed reproduces the off-track cell vector")
	_check(OfftrackSeed.domain_seed(0, 1) == 845162064041503952, "OfftrackSeed still produces its seed 0 vector")
	_check(DomainSeed.derive(1, 0, "height_channel") != DomainSeed.derive(1, 0, "offtrack_objects"), "the height domain is separated from the off-track domain")
	_check(DomainSeed.derive(1, 0, "height_channel") > 0, "domain seeds are positive 64-bit integers")
	return true


func _verify_placement_validity() -> bool:
	var ramp := JumpRampPlacement.new()
	ramp.stable_id = "h1:0:12"
	ramp.transform = Transform2D(0.3, Vector2(100.0, 200.0))
	ramp.half_length = 150.0
	ramp.crest_height = 18.0
	ramp.width = 240.0
	_check(ramp.is_valid(), "a finite, positive ramp record is valid")
	var bad_height := ramp.duplicate() as JumpRampPlacement
	bad_height.crest_height = 0.0
	_check(not bad_height.is_valid(), "a zero crest height is invalid")
	var bad_length := ramp.duplicate() as JumpRampPlacement
	bad_length.half_length = -1.0
	_check(not bad_length.is_valid(), "a negative half length is invalid")
	var bad_origin := ramp.duplicate() as JumpRampPlacement
	bad_origin.transform = Transform2D(0.0, Vector2(INF, 0.0))
	_check(not bad_origin.is_valid(), "a non-finite origin is invalid")
	var bad_width := ramp.duplicate() as JumpRampPlacement
	bad_width.width = 0.0
	_check(not bad_width.is_valid(), "a zero width is invalid")
	return true


func _verify_catalog_defaults() -> bool:
	var catalog := load(HEIGHT_CATALOG_PATH) as HeightChannelCatalog
	_check(catalog != null, "the default height catalog loads")
	if catalog == null:
		return false
	_check(catalog.version == 3, "catalog version is 3")
	_check(is_equal_approx(catalog.half_length, WorldScale.metres(12.0)), "half length is 12 m")
	_check(is_equal_approx(catalog.slope, 0.06), "slope is 0.06")
	_check(is_equal_approx(catalog.crest_height(), WorldScale.metres(0.72)), "crest height derives as slope times half length")
	_check(catalog.ramps_per_lap_min == 2 and catalog.ramps_per_lap_max == 4, "two to four ramps are requested per lap")
	_check(catalog.ramps_per_lap_min <= catalog.ramps_per_lap_max, "ramp count range is ordered")
	_check(is_equal_approx(catalog.approach_clearance, WorldScale.metres(28.0)), "approach clearance is 28 m")
	_check(is_equal_approx(catalog.landing_clearance, WorldScale.metres(32.0)), "landing clearance is 32 m")
	_check(is_equal_approx(catalog.spawn_exclusion, WorldScale.metres(80.0)), "spawn exclusion is 80 m")
	_check(is_equal_approx(catalog.checkpoint_exclusion, WorldScale.metres(40.0)), "checkpoint exclusion is 40 m")
	_check(is_equal_approx(catalog.minimum_spacing, WorldScale.metres(120.0)), "minimum crest spacing is 120 m")
	_check(catalog.minimum_run_length() > catalog.approach_clearance + catalog.landing_clearance, "minimum run length includes both faces")
	_check(is_equal_approx(catalog.minimum_run_length(), WorldScale.metres(84.0)), "minimum run length remains 1050 px")
	var script_defaults := HeightChannelCatalog.new()
	_check(
		script_defaults.version == catalog.version
		and is_equal_approx(script_defaults.slope, catalog.slope)
		and is_equal_approx(script_defaults.approach_clearance, catalog.approach_clearance)
		and is_equal_approx(script_defaults.landing_clearance, catalog.landing_clearance),
		"script defaults match the versioned resource tuning"
	)
	return true


## The continuous quadratic-drag solution is conservative relative to the game's 60 Hz
## semi-implicit integration: the game applies both drag and gravity before each movement step, so
## its car travels slightly less far before landing than this oracle predicts.
func _verify_landing_clearance_covers_top_speed_flight() -> bool:
	var catalog := load(HEIGHT_CATALOG_PATH) as HeightChannelCatalog
	var tuning := load(TUNING_PATH) as VehicleTuning
	var launch_height := catalog.crest_height()
	var launch_vertical_speed := tuning.max_safe_speed * catalog.slope
	var flight_seconds := (
		launch_vertical_speed
		+ sqrt(launch_vertical_speed * launch_vertical_speed + 2.0 * tuning.gravity * launch_height)
	) / tuning.gravity
	var flight_distance := (
		log(1.0 + tuning.aerodynamic_drag * tuning.max_safe_speed * flight_seconds)
		/ tuning.aerodynamic_drag
	)
	var guaranteed_road_after_crest := catalog.half_length + catalog.landing_clearance
	print("top_speed_flight_distance=%.3f guaranteed_road_after_crest=%.3f" % [flight_distance, guaranteed_road_after_crest])
	_check(
		guaranteed_road_after_crest >= flight_distance,
		"ramp landing clearance covers the conservative top-speed flight (%.1f >= %.1f px)" % [guaranteed_road_after_crest, flight_distance]
	)
	return true


func _verify_definition_fields() -> bool:
	var definition := TrackDefinition.new()
	_check(definition.jump_ramps.is_empty(), "a fresh definition has no ramps")
	_check(definition.height_fingerprint == "", "a fresh definition has no height fingerprint")
	_check(definition.height_generation_usec == 0, "a fresh definition has no height timing")
	_check(definition.height_diagnostics.is_empty(), "a fresh definition has no height diagnostics")
	return true


func _verify_tuning_fields() -> bool:
	var tuning := load(TUNING_PATH) as VehicleTuning
	_check(tuning != null, "the default tuning loads")
	if tuning == null:
		return false
	_check(is_equal_approx(tuning.gravity, WorldScale.metres(9.81)), "gravity is 9.81 m/s^2 in pixels")
	_check(tuning.airborne_steering_authority == 0.0, "airborne steering authority defaults to none")
	_check(is_equal_approx(tuning.landing_speed_loss, 0.03), "landing speed loss is 3% per m/s")
	_check(is_equal_approx(tuning.landing_recovery_seconds, 0.35), "landing recovery lasts 0.35 s")
	_check(is_equal_approx(tuning.landing_recovery_grip_multiplier, 0.5), "landing recovery halves grip")
	_check(is_equal_approx(tuning.air_time_notice_seconds, 0.5), "air time notice needs half a second")
	_check(is_equal_approx(tuning.lift_pixels_per_pixel, 1.0), "body lift is one pixel per pixel of height")
	_check(is_equal_approx(tuning.scale_per_metre, 0.04), "body scale gains 4% per metre")
	return true


func _verify_clearance_agrees_with_obstacle_height() -> bool:
	var tuning := load(TUNING_PATH) as VehicleTuning
	var catalog := load(OBJECT_CATALOG_PATH) as OfftrackObjectCatalog
	_check(is_equal_approx(tuning.low_obstacle_clearance, catalog.low_obstacle_height), "vehicle clearance equals the catalog's low obstacle height")
	_check(is_equal_approx(catalog.low_obstacle_height, WorldScale.metres(1.0)), "low obstacles are at most 1 m")
	var rock := catalog.archetype_by_id(&"rock")
	var tree := catalog.archetype_by_id(&"tree")
	var grass := catalog.archetype_by_id(&"grass")
	_check(rock != null and rock.obstacle_height <= catalog.low_obstacle_height, "rocks are low obstacles")
	_check(tree != null and tree.obstacle_height > catalog.low_obstacle_height, "trees are tall obstacles")
	_check(grass != null and grass.obstacle_height == 0.0, "decorative archetypes have no obstacle height")
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
		print("Height channel contract checks passed: %d checks" % _checks)
		quit(0)
		return
	for failure in _failures:
		push_error("Height channel contract check failed: %s" % failure)
	quit(1)
