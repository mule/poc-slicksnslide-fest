class_name OfftrackSeed
extends RefCounted

const DOMAIN := "offtrack_objects"


static func domain_seed(track_seed: int, version: int) -> int:
	return _seed_from_text("%d|%d|%s" % [version, track_seed, DOMAIN])


static func cell_seed(initial_domain_seed: int, cell: Vector2i) -> int:
	return _seed_from_text("%d|%d|%d" % [initial_domain_seed, cell.x, cell.y])


static func _seed_from_text(material: String) -> int:
	# Fifteen hexadecimal digits fit in a positive signed 64-bit integer.
	return material.sha256_text().substr(0, 15).hex_to_int()
