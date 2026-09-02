class_name OfftrackObjectPlacement
extends Resource

@export var stable_id: String = ""
@export var archetype_id: StringName = &""
@export var transform: Transform2D = Transform2D.IDENTITY
@export_range(0.01, 10.0, 0.01) var scale_factor: float = 1.0
@export_range(0, 31, 1) var visual_variant: int = 0
@export var solid: bool = false
@export var collision_profile: StringName = &"none"
