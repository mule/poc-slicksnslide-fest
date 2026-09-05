class_name DomainSeed
extends RefCounted

## Fixed integer-mixing routine shared by every deterministic placement domain. The text layout
## is a persistence contract: changing it changes every fingerprint on every platform.


static func derive(version: int, track_seed: int, domain: String) -> int:
	return from_text("%d|%d|%s" % [version, track_seed, domain])


static func child(parent_seed: int, first: int, second: int) -> int:
	return from_text("%d|%d|%d" % [parent_seed, first, second])


static func from_text(material: String) -> int:
	# Fifteen hexadecimal digits fit in a positive signed 64-bit integer.
	return material.sha256_text().substr(0, 15).hex_to_int()
