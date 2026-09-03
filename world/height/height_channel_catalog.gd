class_name HeightChannelCatalog
extends Resource

## Versioned ramp geometry and placement rules. Every length is a baked pixel value.

@export var version: int = 1
@export_range(0, 16, 1) var ramps_per_lap_min: int = 2
@export_range(0, 16, 1) var ramps_per_lap_max: int = 4
@export_range(1.0, 2000.0, 0.5) var half_length: float = 150.0
@export_range(0.0, 1.0, 0.001) var slope: float = 0.12
@export_range(0.0, 10000.0, 1.0) var approach_clearance: float = 500.0
@export_range(0.0, 10000.0, 1.0) var landing_clearance: float = 1000.0
@export_range(0.0, 10000.0, 1.0) var spawn_exclusion: float = 1000.0
@export_range(0.0, 10000.0, 1.0) var checkpoint_exclusion: float = 500.0
@export_range(0.0, 20000.0, 1.0) var minimum_spacing: float = 1500.0


func crest_height() -> float:
	return slope * half_length


## Straight run needed to hold one ramp: approach, both faces, and the landing zone.
func minimum_run_length() -> float:
	return approach_clearance + 2.0 * half_length + landing_clearance
