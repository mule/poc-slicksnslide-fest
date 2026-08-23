class_name TrackDefinition
extends Resource

## Serializable output contract for a generated circuit.
## Track generation owns these values; session and vehicle code consume them.

@export var seed: int = 0
@export var centerline: PackedVector2Array = PackedVector2Array()
@export_range(1.0, 100.0, 0.5) var track_width: float = 14.0
@export var bounds: Rect2 = Rect2()
@export var spawn_transform: Transform2D = Transform2D.IDENTITY
@export var checkpoints: Array[Transform2D] = []
@export var geometry_fingerprint: String = ""
