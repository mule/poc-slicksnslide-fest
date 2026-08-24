class_name WorldScale
extends RefCounted

## Single source of truth for the world's pixel-to-metre contract.
##
## The world unit is the pixel. Physics tuning, track dimensions, and any
## hardcoded speed threshold are expressed in pixels at this scale. Route
## scale-dependent literals through metres() so they stay greppable.

const PIXELS_PER_METRE := 12.5


static func metres(value_m: float) -> float:
	return value_m * PIXELS_PER_METRE


static func to_metres(value_px: float) -> float:
	return value_px / PIXELS_PER_METRE


static func to_kph(px_per_second: float) -> float:
	return px_per_second / PIXELS_PER_METRE * 3.6
