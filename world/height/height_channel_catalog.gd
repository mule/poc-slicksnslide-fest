class_name HeightChannelCatalog
extends Resource

## Versioned ramp geometry and placement rules. Every length is a baked pixel value.
##
## `flank_width` is the lateral falloff outside the road edge: the wedge keeps its full height
## across the road and fades to nothing over this distance beyond each edge, along the quintic
## fade 6t^5 - 15t^4 + 10t^3, whose first and second derivatives vanish at both ends. It was
## added at version 3 without a bump: the flank is not part of the placement fingerprint (see
## JumpRampPlacer._fingerprint), so the pinned height fingerprints hold, and a bump would move
## every one of them through the domain seed.

@export var version: int = 3
@export_range(0, 16, 1) var ramps_per_lap_min: int = 2
@export_range(0, 16, 1) var ramps_per_lap_max: int = 4
@export_range(1.0, 2000.0, 0.5) var half_length: float = 150.0
@export_range(0.0, 1.0, 0.001) var slope: float = 0.06
@export_range(0.0, 10000.0, 1.0) var approach_clearance: float = 350.0
@export_range(0.0, 10000.0, 1.0) var landing_clearance: float = 400.0
@export_range(0.0, 10000.0, 1.0) var spawn_exclusion: float = 1000.0
@export_range(0.0, 10000.0, 1.0) var checkpoint_exclusion: float = 500.0
@export_range(0.0, 20000.0, 1.0) var minimum_spacing: float = 1500.0
@export_range(0.0, 2000.0, 1.0) var flank_width: float = 250.0


func crest_height() -> float:
	return slope * half_length


## Straight run needed to hold one ramp: approach, both faces, and the landing zone.
func minimum_run_length() -> float:
	return approach_clearance + 2.0 * half_length + landing_clearance


## Upper bound on the directional second derivative the flank adds, in 1/px. On a flank the wedge
## is crest * p(x) * w(y) with p the linear face profile and w the fade across the flank, so away
## from the wedge's own kinks the Hessian has entries crest * p * w'' and crest * p' * w', and its
## spectral radius is at most their sum: crest * (|w''|max + |w'|max / half_length). The terrain
## catalog's bound covers the field; this covers the ramp term; the two add.
func flank_curvature_bound() -> float:
	if flank_width <= 0.0:
		return INF
	return crest_height() * (
		TerrainCatalog.FADE_PEAK_CURVATURE / (flank_width * flank_width)
		+ TerrainCatalog.FADE_PEAK_SLOPE / (flank_width * half_length)
	)
