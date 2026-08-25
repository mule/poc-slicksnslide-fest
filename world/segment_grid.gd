class_name SegmentGrid
extends RefCounted

## Uniform spatial index over a polyline's segments.
##
## This is a broadphase: every query returns a superset of the true answer,
## and callers still run the exact geometry test on what comes back. It exists
## so that centerline proximity (queried every physics tick) and generator
## self-intersection validation stay affordable once a circuit spans
## thousands of samples instead of a hundred.

var _cell_size := 1.0
var _cells: Dictionary = {}


func _init(points: PackedVector2Array, cell_size: float) -> void:
	_cell_size = maxf(cell_size, 1.0)
	for index in range(maxi(points.size() - 1, 0)):
		for cell in _cells_for_bounds(points[index], points[index + 1]):
			if not _cells.has(cell):
				_cells[cell] = PackedInt32Array()
			_cells[cell].append(index)


func segments_near(point: Vector2, radius: float) -> PackedInt32Array:
	return _collect(_cells_for_bounds(point - Vector2(radius, radius), point + Vector2(radius, radius)))


func segments_overlapping(from: Vector2, to: Vector2) -> PackedInt32Array:
	return _collect(_cells_for_bounds(from, to))


func candidate_pairs() -> Array:
	var pairs := {}
	for bucket in _cells.values():
		for first_slot in range(bucket.size()):
			for second_slot in range(first_slot + 1, bucket.size()):
				var first: int = bucket[first_slot]
				var second: int = bucket[second_slot]
				pairs[Vector2i(mini(first, second), maxi(first, second))] = true
	return pairs.keys()


func _collect(cells: Array) -> PackedInt32Array:
	var found := PackedInt32Array()
	var seen := {}
	for cell in cells:
		for index in _cells.get(cell, PackedInt32Array()):
			if not seen.has(index):
				seen[index] = true
				found.append(index)
	return found


func _cells_for_bounds(first: Vector2, second: Vector2) -> Array:
	var min_cell := _cell_of(Vector2(minf(first.x, second.x), minf(first.y, second.y)))
	var max_cell := _cell_of(Vector2(maxf(first.x, second.x), maxf(first.y, second.y)))
	var cells := []
	for x in range(min_cell.x, max_cell.x + 1):
		for y in range(min_cell.y, max_cell.y + 1):
			cells.append(Vector2i(x, y))
	return cells


func _cell_of(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / _cell_size), floori(point.y / _cell_size))
