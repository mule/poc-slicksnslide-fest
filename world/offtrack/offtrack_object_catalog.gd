class_name OfftrackObjectCatalog
extends Resource

@export var version: int = 1
@export var cell_size: float = 250.0
@export var chunk_size: float = 1000.0
@export var near_max_distance: float = 150.0
@export var solid_clearance: float = 250.0
@export var hazard_max_distance: float = 1750.0
@export var containment_buffer: float = 250.0
@export var spawn_checkpoint_exclusion: float = 500.0
## Solid archetypes at or below this height go on collision layer 2, which the car drops from its
## mask while above VehicleTuning.low_obstacle_clearance.
@export var low_obstacle_height: float = 12.5
@export_range(0.0, 1.0, 0.01) var near_occupancy: float = 0.55
@export_range(0.0, 1.0, 0.01) var hazard_occupancy: float = 0.35
@export_range(0.0, 1.0, 0.01) var minimum_fill_ratio: float = 0.75
@export var archetypes: Array[OfftrackObjectArchetype] = []


func archetype_by_id(id: StringName) -> OfftrackObjectArchetype:
	for archetype in archetypes:
		if archetype != null and archetype.id == id:
			return archetype
	return null


func archetypes_for_zone(near_shoulder: bool) -> Array[OfftrackObjectArchetype]:
	var matching: Array[OfftrackObjectArchetype] = []
	for archetype in archetypes:
		if archetype == null:
			continue
		var weight := archetype.near_weight if near_shoulder else archetype.hazard_weight
		if weight > 0.0:
			matching.append(archetype)
	return matching
