class_name OfftrackObjectArchetype
extends Resource

@export var id: StringName = &""
@export var solid: bool = false
@export_range(0.0, 500.0, 0.1) var footprint_radius: float = 5.0
@export_range(0.0, 500.0, 0.1) var collision_radius: float = 0.0
## Height of the obstacle in pixels. Zero for decorative archetypes. At or below the catalog's
## low_obstacle_height the object is on the low collision level an airborne car can clear.
@export_range(0.0, 500.0, 0.1) var obstacle_height: float = 0.0
@export_range(0.01, 10.0, 0.01) var min_scale: float = 1.0
@export_range(0.01, 10.0, 0.01) var max_scale: float = 1.0
@export_range(1, 32, 1) var visual_variant_count: int = 1
@export_range(0.0, 1.0, 0.01) var near_weight: float = 0.0
@export_range(0.0, 1.0, 0.01) var hazard_weight: float = 0.0
@export var collision_profile: StringName = &"none"
