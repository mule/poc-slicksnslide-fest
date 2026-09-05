class_name JumpRampPlacement
extends Resource

## One generated jump ramp: a symmetric hump whose crest is the transform origin and whose faces
## run along the transform's x axis. Data only; never holds nodes or callbacks.

@export var stable_id: String = ""
@export var transform: Transform2D = Transform2D.IDENTITY
@export_range(1.0, 2000.0, 0.5) var half_length: float = 150.0
## These two defaults are inspector placeholders, not the shipped shape, and no production
## placement ever reads them: `JumpRampPlacer.place` overwrites `crest_height` from
## `HeightChannelCatalog.crest_height()` (9.0 at catalog v3, not the 18.0 below) and `width` from
## `TrackDefinition.track_width`, which is road geometry rather than a catalog value at all.
@export_range(0.0, 500.0, 0.1) var crest_height: float = 18.0
@export_range(1.0, 500.0, 0.5) var width: float = 240.0


func is_valid() -> bool:
	var origin := transform.origin
	if not is_finite(origin.x) or not is_finite(origin.y):
		return false
	if not is_finite(transform.get_rotation()):
		return false
	return half_length > 0.0 and crest_height > 0.0 and width > 0.0
