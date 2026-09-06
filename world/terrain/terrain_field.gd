class_name TerrainField
extends HeightQuery

## Deterministic continuous terrain over the whole play area: seeded value noise summed over a few
## octaves. Every query is evaluated analytically, so the gradient is the field's exact derivative
## and the curvature the contract test bounds is the field's exact Hessian, not a finite difference
## of either.
##
## Seeding follows the project's one scheme. The field's seed is
## `DomainSeed.derive(catalog.version, track_seed, DOMAIN)`; each octave's lattice seed is a
## `DomainSeed.child` of that, and each lattice corner's value is a `DomainSeed.child` of the
## octave seed keyed by the corner's integer coordinates. No RandomNumberGenerator is involved, so
## the field cannot consume or disturb the road generator's stream, and the same seed and version
## reproduce the same field on every platform. Corner values are memoised per octave: a query
## touches four corners per octave, and neighbouring queries share them.
##
## Interpolation uses the quintic fade 6t^5 - 15t^4 + 10t^3, whose first and second derivatives
## vanish at the cell edges, so the gradient and the Hessian are continuous across every lattice
## boundary. A cubic fade would leave the Hessian stepping at each edge, which the car's lift-off
## rule would read as a crest.

const DOMAIN := "terrain"
## Grid pitch the fingerprint samples on, in px: the off-track placement cell.
const FINGERPRINT_SPACING := 250.0

var terrain_seed: int
var _version: int
var _octave_seeds := PackedInt64Array()
var _frequencies := PackedFloat64Array()
var _amplitudes := PackedFloat64Array()
var _lattices: Array[Dictionary] = []


static func for_track(track_seed: int, catalog: TerrainCatalog) -> TerrainField:
	return TerrainField.new(DomainSeed.derive(catalog.version, track_seed, DOMAIN), catalog)


func _init(initial_terrain_seed: int, catalog: TerrainCatalog) -> void:
	terrain_seed = initial_terrain_seed
	_version = catalog.version
	for octave in range(catalog.octaves):
		_octave_seeds.append(DomainSeed.child(terrain_seed, octave, 0))
		_frequencies.append(1.0 / catalog.octave_wavelength(octave))
		_amplitudes.append(catalog.octave_amplitude(octave))
		_lattices.append({})


func octave_count() -> int:
	return _octave_seeds.size()


func sample_at(world_position: Vector2) -> HeightSample:
	var terms := _evaluate(world_position, false)
	return HeightSample.new(terms[0], Vector2(terms[1], terms[2]))


func height_at(world_position: Vector2) -> float:
	return _evaluate(world_position, false)[0]


## Largest absolute directional second derivative at the position: the spectral radius of the
## Hessian. This is the quantity the lift-off rule compares against gravity over speed squared.
func curvature_at(world_position: Vector2) -> float:
	var terms := _evaluate(world_position, true)
	var hxx := terms[3]
	var hxy := terms[4]
	var hyy := terms[5]
	var mean := 0.5 * (hxx + hyy)
	var half_difference := 0.5 * (hxx - hyy)
	return absf(mean) + sqrt(half_difference * half_difference + hxy * hxy)


## SHA-256 over heights sampled on a FINGERPRINT_SPACING grid across the area, with the version,
## seed and area in the header. The field is never serialised; this is what stands in for it.
func fingerprint(area: Rect2) -> String:
	var components := PackedStringArray(["version=%d|seed=%d|area=%.1f,%.1f,%.1f,%.1f|spacing=%.1f" % [
		_version,
		terrain_seed,
		area.position.x,
		area.position.y,
		area.size.x,
		area.size.y,
		FINGERPRINT_SPACING,
	]])
	var columns := int(floor(area.size.x / FINGERPRINT_SPACING)) + 1
	var rows := int(floor(area.size.y / FINGERPRINT_SPACING)) + 1
	for row in range(rows):
		for column in range(columns):
			var position := area.position + Vector2(float(column), float(row)) * FINGERPRINT_SPACING
			components.append("%.3f" % height_at(position))
	return "|".join(components).sha256_text()


## Returns [height, dh/dx, dh/dy, d2h/dx2, d2h/dxdy, d2h/dy2]; the last three only when asked.
func _evaluate(world_position: Vector2, with_hessian: bool) -> PackedFloat64Array:
	var terms := PackedFloat64Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	for octave in range(_octave_seeds.size()):
		var frequency := _frequencies[octave]
		var amplitude := _amplitudes[octave]
		var u := world_position.x * frequency
		var v := world_position.y * frequency
		var column := floori(u)
		var row := floori(v)
		var tu := u - float(column)
		var tv := v - float(row)
		var v00 := _lattice_value(octave, column, row)
		var v10 := _lattice_value(octave, column + 1, row)
		var v01 := _lattice_value(octave, column, row + 1)
		var v11 := _lattice_value(octave, column + 1, row + 1)
		# Bilinear form in the faded coordinates: v00 + b su + c sv + d su sv.
		var b := v10 - v00
		var c := v01 - v00
		var d := v11 - v01 - v10 + v00
		var su := tu * tu * tu * (tu * (tu * 6.0 - 15.0) + 10.0)
		var sv := tv * tv * tv * (tv * (tv * 6.0 - 15.0) + 10.0)
		var dsu := 30.0 * tu * tu * (tu - 1.0) * (tu - 1.0)
		var dsv := 30.0 * tv * tv * (tv - 1.0) * (tv - 1.0)
		var along_u := b + d * sv
		var along_v := c + d * su
		terms[0] += amplitude * (v00 + b * su + c * sv + d * su * sv)
		var scale := amplitude * frequency
		terms[1] += scale * along_u * dsu
		terms[2] += scale * along_v * dsv
		if with_hessian:
			var ddsu := 60.0 * tu * (2.0 * tu - 1.0) * (tu - 1.0)
			var ddsv := 60.0 * tv * (2.0 * tv - 1.0) * (tv - 1.0)
			var scale_2 := scale * frequency
			terms[3] += scale_2 * along_u * ddsu
			terms[4] += scale_2 * d * dsu * dsv
			terms[5] += scale_2 * along_v * ddsv
	return terms


## Lattice corner value in [-1, 1], memoised per octave.
func _lattice_value(octave: int, column: int, row: int) -> float:
	var lattice := _lattices[octave]
	var key := (column << 32) ^ (row & 0xFFFFFFFF)
	if lattice.has(key):
		return lattice[key]
	var material := DomainSeed.child(_octave_seeds[octave], column, row)
	var value := float(material & 0xFFFFFFFF) / 4294967295.0 * 2.0 - 1.0
	lattice[key] = value
	return value
