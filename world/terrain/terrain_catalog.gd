class_name TerrainCatalog
extends Resource

## Versioned terrain field tuning. Every length is a baked pixel value.
##
## The field is value noise summed over `octaves` octaves. Octave i has amplitude
## `amplitude * persistence^i` and lattice cell width `base_wavelength / lacunarity^i`, so every
## derived quantity below is a sum over octaves. Curvature scales with amplitude over wavelength
## squared, which is why persistence sits at 1 / lacunarity^2 in the shipped tuning: each octave
## then carries the same curvature as the one below it rather than the finest octave owning the
## bound.
##
## The field is summed under the road as it is. No road damping is applied: #49 showed that any
## envelope taking the field to flat on the centreline adds curvature of its own, of order
## total_amplitude() / width^2 across the road, which breaks the lift-off bound at every practical
## width; and the car takes only the forward component of the gradient, so a laterally tilted road
## exerts no sideways force. The road's drivability rests on curvature_bound() alone.

## Supremum of a quintic-fade value-noise cell's directional second derivative, in lattice units
## per unit amplitude, with corner values in [-1, 1]. The fade s(t) = 6t^5 - 15t^4 + 10t^3 peaks
## in slope at s'(1/2) = 15/8, and the saddle at the cell centre with corners (-1, +1, +1, -1) has
## the mixed derivative 4 * s'(1/2)^2 as its only Hessian entry, so its eigenvalues are
## +-225/16. That exceeds the axis-aligned worst case of 2 * max|s''| = 20 / sqrt(3). The contract
## test rederives this constant by brute force.
const CELL_CURVATURE := 225.0 / 16.0
## Peak slope of the quintic fade, s'(1/2).
const FADE_PEAK_SLOPE := 15.0 / 8.0
## Peak absolute second derivative of the quintic fade, |s''| at t = 1/2 -+ 1 / (2 sqrt 3).
const FADE_PEAK_CURVATURE := 10.0 / sqrt(3.0)

@export var version: int = 1
## Height range of the base octave: octave 0 spans -amplitude..+amplitude.
@export_range(0.0, 2000.0, 0.5) var amplitude: float = 40.0
## Lattice cell width of the base octave. One cell runs from one lattice value to the next, so the
## visible hill-to-hill distance is about twice this.
@export_range(1.0, 100000.0, 1.0) var base_wavelength: float = 3000.0
@export_range(1, 8, 1) var octaves: int = 3
@export_range(0.0, 1.0, 0.001) var persistence: float = 0.25
@export_range(1.0, 8.0, 0.01) var lacunarity: float = 2.0


func octave_amplitude(octave: int) -> float:
	var value := amplitude
	for _step in range(octave):
		value *= persistence
	return value


func octave_wavelength(octave: int) -> float:
	var value := base_wavelength
	for _step in range(octave):
		value /= lacunarity
	return value


## Largest absolute height the summed field can reach.
func total_amplitude() -> float:
	var total := 0.0
	for octave in range(octaves):
		total += octave_amplitude(octave)
	return total


## Upper bound on the field's directional second derivative anywhere, in 1/px. The car's lift-off
## rule fires when speed^2 times this exceeds gravity, so this is the number the vehicle tuning is
## checked against.
func curvature_bound() -> float:
	var bound := 0.0
	for octave in range(octaves):
		var wavelength := octave_wavelength(octave)
		bound += CELL_CURVATURE * octave_amplitude(octave) / (wavelength * wavelength)
	return bound


## Upper bound on either component of the field's gradient anywhere. Across a cell the height can
## change by twice the octave amplitude, at the fade's peak slope.
func slope_bound() -> float:
	var bound := 0.0
	for octave in range(octaves):
		bound += 2.0 * FADE_PEAK_SLOPE * octave_amplitude(octave) / octave_wavelength(octave)
	return bound
