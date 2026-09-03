class_name TrackDefinition
extends Resource

## Serializable output contract for a generated circuit.
## Track generation owns these values; session and vehicle code consume them.

@export var seed: int = 0
@export var centerline: PackedVector2Array = PackedVector2Array()
@export var left_boundary: PackedVector2Array = PackedVector2Array()
@export var right_boundary: PackedVector2Array = PackedVector2Array()
@export_range(1.0, 500.0, 0.5) var track_width: float = 150.0
@export var bounds: Rect2 = Rect2()
@export var play_area: Rect2 = Rect2()
@export var spawn_transform: Transform2D = Transform2D.IDENTITY
@export var forward_direction: Vector2 = Vector2.RIGHT
@export var checkpoints: Array[Transform2D] = []
@export var geometry_fingerprint: String = ""
@export var lap_length: float = 0.0
@export var max_curvature: float = 0.0
@export var start_straight_length: float = 0.0
@export var generation_attempts: int = 0
@export var generation_usec: int = 0
@export var used_fallback: bool = false
@export var diagnostic_reason: String = ""
@export var offtrack_objects: Array[OfftrackObjectPlacement] = []
@export var offtrack_object_fingerprint: String = ""
@export var offtrack_object_generation_usec: int = 0
@export var offtrack_object_diagnostics: Dictionary = {}
@export var jump_ramps: Array[JumpRampPlacement] = []
@export var height_fingerprint: String = ""
@export var height_generation_usec: int = 0
@export var height_diagnostics: Dictionary = {}
