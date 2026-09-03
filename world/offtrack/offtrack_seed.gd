class_name OfftrackSeed
extends RefCounted

const DOMAIN := "offtrack_objects"


static func domain_seed(track_seed: int, version: int) -> int:
	return DomainSeed.derive(version, track_seed, DOMAIN)


static func cell_seed(initial_domain_seed: int, cell: Vector2i) -> int:
	return DomainSeed.child(initial_domain_seed, cell.x, cell.y)
