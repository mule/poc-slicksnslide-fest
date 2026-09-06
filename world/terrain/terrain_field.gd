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
##
## This is on the car's per-tick path through TrackHeightMap, so evaluation allocates nothing: the
## result lands in member scalars, and `sample_into` writes a caller's sample in place. Each octave
## also keeps the bilinear coefficients of the cell its previous query fell in; a moving car's
## consecutive queries land in the same cell almost always, so the four corner lookups per octave,
## each a call into a dictionary, are skipped on the steady path. The arithmetic is otherwise the
## expression of the first version, term for term, so the pinned fingerprints hold.

const DOMAIN := "terrain"
## Grid pitch the fingerprint samples on, in px: the off-track placement cell.
const FINGERPRINT_SPACING := 250.0
## A cell coordinate no query can produce, so the first query of every octave loads its cell.
const NO_CELL := -9223372036854775808

var terrain_seed: int
var _version: int
var _octave_count := 0
var _octave_seeds := PackedInt64Array()
var _frequencies := PackedFloat64Array()
var _amplitudes := PackedFloat64Array()
var _lattices: Array[Dictionary] = []
var _cell_columns := PackedInt64Array()
var _cell_rows := PackedInt64Array()
var _cell_v00 := PackedFloat64Array()
var _cell_b := PackedFloat64Array()
var _cell_c := PackedFloat64Array()
var _cell_d := PackedFloat64Array()
# Outputs of the last _evaluate: height, gradient, and the Hessian when it was asked for.
var _height := 0.0
var _slope_x := 0.0
var _slope_y := 0.0
var _hxx := 0.0
var _hxy := 0.0
var _hyy := 0.0


static func for_track(track_seed: int, catalog: TerrainCatalog) -> TerrainField:
	return TerrainField.new(DomainSeed.derive(catalog.version, track_seed, DOMAIN), catalog)


func _init(initial_terrain_seed: int, catalog: TerrainCatalog) -> void:
	terrain_seed = initial_terrain_seed
	_version = catalog.version
	_octave_count = catalog.octaves
	for octave in range(catalog.octaves):
		_octave_seeds.append(DomainSeed.child(terrain_seed, octave, 0))
		_frequencies.append(1.0 / catalog.octave_wavelength(octave))
		_amplitudes.append(catalog.octave_amplitude(octave))
		_lattices.append({})
		_cell_columns.append(NO_CELL)
		_cell_rows.append(NO_CELL)
		_cell_v00.append(0.0)
		_cell_b.append(0.0)
		_cell_c.append(0.0)
		_cell_d.append(0.0)


func octave_count() -> int:
	return _octave_count


func sample_at(world_position: Vector2) -> HeightSample:
	_evaluate(world_position.x, world_position.y, false)
	return HeightSample.new(_height, Vector2(_slope_x, _slope_y))


## Writes the height and gradient at the position into an existing sample, allocating nothing.
func sample_into(world_position: Vector2, sample: HeightSample) -> void:
	_evaluate(world_position.x, world_position.y, false)
	sample.ground_height = _height
	sample.gradient = Vector2(_slope_x, _slope_y)


func height_at(world_position: Vector2) -> float:
	_evaluate(world_position.x, world_position.y, false)
	return _height


## Largest absolute directional second derivative at the position: the spectral radius of the
## Hessian. This is the quantity the lift-off rule compares against gravity over speed squared.
func curvature_at(world_position: Vector2) -> float:
	_evaluate(world_position.x, world_position.y, true)
	var mean := 0.5 * (_hxx + _hyy)
	var half_difference := 0.5 * (_hxx - _hyy)
	return absf(mean) + sqrt(half_difference * half_difference + _hxy * _hxy)


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


## Leaves height, dh/dx, dh/dy in the members, and d2h/dx2, d2h/dxdy, d2h/dy2 only when asked.
func _evaluate(x: float, y: float, with_hessian: bool) -> void:
	var height := 0.0
	var slope_x := 0.0
	var slope_y := 0.0
	var hxx := 0.0
	var hxy := 0.0
	var hyy := 0.0
	for octave in _octave_count:
		var frequency := _frequencies[octave]
		var amplitude := _amplitudes[octave]
		var u := x * frequency
		var v := y * frequency
		var column := floori(u)
		var row := floori(v)
		var tu := u - float(column)
		var tv := v - float(row)
		if column != _cell_columns[octave] or row != _cell_rows[octave]:
			_load_cell(octave, column, row)
		# Bilinear form in the faded coordinates: v00 + b su + c sv + d su sv.
		var v00 := _cell_v00[octave]
		var b := _cell_b[octave]
		var c := _cell_c[octave]
		var d := _cell_d[octave]
		var su := tu * tu * tu * (tu * (tu * 6.0 - 15.0) + 10.0)
		var sv := tv * tv * tv * (tv * (tv * 6.0 - 15.0) + 10.0)
		var dsu := 30.0 * tu * tu * (tu - 1.0) * (tu - 1.0)
		var dsv := 30.0 * tv * tv * (tv - 1.0) * (tv - 1.0)
		var along_u := b + d * sv
		var along_v := c + d * su
		height += amplitude * (v00 + b * su + c * sv + d * su * sv)
		var scale := amplitude * frequency
		slope_x += scale * along_u * dsu
		slope_y += scale * along_v * dsv
		if with_hessian:
			var ddsu := 60.0 * tu * (2.0 * tu - 1.0) * (tu - 1.0)
			var ddsv := 60.0 * tv * (2.0 * tv - 1.0) * (tv - 1.0)
			var scale_2 := scale * frequency
			hxx += scale_2 * along_u * ddsu
			hxy += scale_2 * d * dsu * dsv
			hyy += scale_2 * along_v * ddsv
	_height = height
	_slope_x = slope_x
	_slope_y = slope_y
	_hxx = hxx
	_hxy = hxy
	_hyy = hyy


## Loads the bilinear coefficients of one octave's cell from its four memoised corners.
func _load_cell(octave: int, column: int, row: int) -> void:
	var v00 := _lattice_value(octave, column, row)
	var v10 := _lattice_value(octave, column + 1, row)
	var v01 := _lattice_value(octave, column, row + 1)
	var v11 := _lattice_value(octave, column + 1, row + 1)
	_cell_columns[octave] = column
	_cell_rows[octave] = row
	_cell_v00[octave] = v00
	_cell_b[octave] = v10 - v00
	_cell_c[octave] = v01 - v00
	_cell_d[octave] = v11 - v01 - v10 + v00


## Lattice corner value in [-1, 1], memoised per octave.
func _lattice_value(octave: int, column: int, row: int) -> float:
	var lattice := _lattices[octave]
	var key := (column << 32) ^ (row & 0xFFFFFFFF)
	var memoised = lattice.get(key)
	if memoised != null:
		return memoised
	var material := DomainSeed.child(_octave_seeds[octave], column, row)
	var value := float(material & 0xFFFFFFFF) / 4294967295.0 * 2.0 - 1.0
	lattice[key] = value
	return value
