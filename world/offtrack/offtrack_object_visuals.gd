class_name OfftrackObjectVisuals
extends Node2D

var _visual_count := 0
var _decorative_batch_count := 0
var _solid_visual_count := 0
var _decorative_instances: Dictionary = {}


func _init() -> void:
	y_sort_enabled = true


## With a height query, every object stands on the ground under it: its body is lifted up the
## screen by TerrainShading.lift_offset of the ground height at its foot, and each solid's shadow
## is cast from that lifted body -- anchored to the lift, then stretched and thrown further for the
## height -- so it stays under the body on a rise and cannot land on the lit side in a hollow
## (#52; until then it stayed at the foot). With a shading as well, every body is coloured
## by shade() from the same sample, so an object and the ground under it brighten and darken
## together and their contrast is the contrast of their base colours. Without a query every object
## sits at its placement with its factory shadow, as on the flat fixtures. The shadow direction is
## rewritten on both paths: every shadow falls along the world shadow direction, query or no query,
## so a flat fixture and a terrain track light their solids from the same side.
func build(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog, height_query: HeightQuery = null, shading: TerrainShading = null) -> void:
	_clear_children()
	var decorative := Node2D.new()
	decorative.name = "DecorativeBatches"
	add_child(decorative)
	var solids := Node2D.new()
	solids.name = "SolidObjects"
	solids.y_sort_enabled = true
	add_child(solids)
	_build_decorative(placements, catalog, decorative, height_query, shading)
	_build_solids(placements, catalog, solids, height_query, shading)


func visual_count() -> int:
	return _visual_count


func decorative_batch_count() -> int:
	return _decorative_batch_count


func solid_visual_count() -> int:
	return _solid_visual_count


## The batch, instance index and the batch's uploaded buffer a decorative placement was drawn
## with, by stable id; empty if none. Packed arrays are copy-on-write, so the buffer stored here
## is a copy equal to the one uploaded: it is recorded after the fill, and nothing writes to
## either afterwards, so a reader decoding it sees the values the renderer draws from.
func decorative_instance_of(stable_id: String) -> Dictionary:
	return _decorative_instances.get(stable_id, {})


## Floats per instance in a batch's buffer: a 2D transform as two rows of four, plus a colour.
static func instance_stride(with_colors: bool) -> int:
	return 12 if with_colors else 8


func _build_decorative(placements: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog, parent: Node2D, height_query: HeightQuery, shading: TerrainShading) -> void:
	var groups: Dictionary = {}
	for placement in placements:
		if placement == null or placement.solid:
			continue
		var chunk := Vector2i(
			floori(placement.transform.origin.x / catalog.chunk_size),
			floori(placement.transform.origin.y / catalog.chunk_size)
		)
		var key := "%d:%d:%s:%d" % [chunk.x, chunk.y, placement.archetype_id, placement.visual_variant]
		if not groups.has(key):
			groups[key] = []
		var group: Array = groups[key]
		group.append(placement)
		groups[key] = group
	for key in groups.keys():
		var typed_group: Array[OfftrackObjectPlacement] = []
		for placement in groups[key]:
			typed_group.append(placement)
		_add_batch(parent, key, typed_group, catalog, height_query, shading)


func _add_batch(parent: Node2D, key: String, group: Array[OfftrackObjectPlacement], catalog: OfftrackObjectCatalog, height_query: HeightQuery, shading: TerrainShading) -> void:
	var first := group[0]
	var mesh := OfftrackObjectMeshFactory.decorative_mesh(first.archetype_id, first.visual_variant)
	if mesh == null:
		push_error("Unknown decorative archetype %s" % first.archetype_id)
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	var with_colors := shading != null and height_query != null
	multimesh.use_colors = with_colors
	multimesh.mesh = mesh
	multimesh.instance_count = group.size()
	var instance := MultiMeshInstance2D.new()
	instance.name = key
	# The whole batch is uploaded as one buffer, in the renderer's own layout: per instance the
	# transform's two rows (x.x, y.x, 0, origin.x) and (x.y, y.y, 0, origin.y), then the colour.
	# Recorded once filled, so the seating and tint of every instance can be read back as
	# uploaded; the headless renderer discards instance data, so nothing else can read it there.
	var stride := instance_stride(with_colors)
	var buffer := PackedFloat32Array()
	buffer.resize(group.size() * stride)
	# Chunk bounds grow by however far the lift moves any instance up or down the screen.
	var lift_low := 0.0
	var lift_high := 0.0
	for index in range(group.size()):
		var placement := group[index]
		var instance_transform := placement.transform.scaled_local(Vector2.ONE * placement.scale_factor)
		var brightness := 1.0
		if height_query != null:
			var sample := height_query.sample_at(placement.transform.origin)
			var lift := TerrainShading.lift_offset(sample.ground_height)
			instance_transform.origin += lift
			lift_low = minf(lift_low, lift.y)
			lift_high = maxf(lift_high, lift.y)
			if shading != null:
				brightness = shading.brightness(sample)
		var offset := index * stride
		buffer[offset] = instance_transform.x.x
		buffer[offset + 1] = instance_transform.y.x
		buffer[offset + 3] = instance_transform.origin.x
		buffer[offset + 4] = instance_transform.x.y
		buffer[offset + 5] = instance_transform.y.y
		buffer[offset + 7] = instance_transform.origin.y
		if with_colors:
			buffer[offset + 8] = brightness
			buffer[offset + 9] = brightness
			buffer[offset + 10] = brightness
			buffer[offset + 11] = 1.0
	multimesh.buffer = buffer
	for index in range(group.size()):
		_decorative_instances[group[index].stable_id] = {"batch": instance, "index": index, "buffer": buffer}
	var chunk := Vector2i(floori(first.transform.origin.x / catalog.chunk_size), floori(first.transform.origin.y / catalog.chunk_size))
	var chunk_origin := Vector2(chunk) * catalog.chunk_size
	var mesh_extent := _maximum_scaled_mesh_extent(mesh, group)
	multimesh.custom_aabb = AABB(
		Vector3(chunk_origin.x - mesh_extent, chunk_origin.y - mesh_extent + lift_low, WorldScale.metres(-0.08)),
		Vector3(catalog.chunk_size + mesh_extent * 2.0, catalog.chunk_size + mesh_extent * 2.0 + lift_high - lift_low, WorldScale.metres(0.16))
	)
	instance.multimesh = multimesh
	instance.z_index = -1
	parent.add_child(instance)
	_decorative_batch_count += 1
	_visual_count += group.size()


func _maximum_scaled_mesh_extent(mesh: ArrayMesh, group: Array[OfftrackObjectPlacement]) -> float:
	var prototype_extent := 0.0
	for surface_index in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for vertex in vertices:
			prototype_extent = maxf(prototype_extent, Vector2(vertex.x, vertex.y).length())
	var maximum_scale := 0.0
	for placement in group:
		maximum_scale = maxf(maximum_scale, placement.scale_factor)
	return prototype_extent * maximum_scale


func _build_solids(placements: Array[OfftrackObjectPlacement], _catalog: OfftrackObjectCatalog, parent: Node2D, height_query: HeightQuery, shading: TerrainShading) -> void:
	for placement in placements:
		if placement == null or not placement.solid:
			continue
		var visual := OfftrackObjectMeshFactory.solid_visual(placement.archetype_id, placement.visual_variant)
		if visual == null:
			push_error("Unknown solid archetype %s" % placement.archetype_id)
			continue
		visual.name = placement.stable_id.replace(":", "_")
		visual.position = placement.transform.origin
		visual.rotation = placement.transform.get_rotation()
		visual.scale = Vector2.ONE * placement.scale_factor
		var body := visual.get_child(1) as Polygon2D
		var ground_height := 0.0
		var lift := Vector2.ZERO
		if height_query != null:
			var sample := height_query.sample_at(placement.transform.origin)
			ground_height = sample.ground_height
			# The lift is a screen distance; the body is a child of a rotated, scaled node, so the
			# offset is taken back through the inverse of that node's basis or a 1.25x tree would
			# lift 1.25x as far. The affine inverse, not basis_xform_inv: that one transposes, which
			# only inverts an unscaled basis. The shadow below is cast from this same anchor.
			lift = visual.transform.affine_inverse().basis_xform(TerrainShading.lift_offset(ground_height))
			body.position = lift
			if shading != null:
				body.color = shading.shade(body.color, sample)
		_cast_shadow(visual.get_child(0) as Polygon2D, lift, visual.rotation, TerrainShading.shadow_length_factor(ground_height))
		parent.add_child(visual)
		_solid_visual_count += 1
		_visual_count += 1


## Casts the shadow from the anchor -- the body's lift, in the object's local frame -- along the
## world's shadow direction, whatever the object's own rotation, at the factory's offset distance
## times the factor, and stretches the polygon along the same axis by the factor. The factory
## places every shadow in the object's local frame, so before this a rotated tree's shadow fell
## wherever the tree happened to turn; the ground shading lights every slope from one direction,
## and the shadows now fall away from that same light. Anchoring to the lift is what keeps the
## shadow under a raised body: with the anchor at the foot, #51's stills showed a tree on a +42 px
## rise hovering 20 px clear of its shadow, and a tree in a hollow with its shadow on the lit side.
func _cast_shadow(shadow: Polygon2D, anchor: Vector2, world_rotation: float, factor: float) -> void:
	var local_axis := TerrainShading.SHADOW_DIRECTION.rotated(-world_rotation)
	shadow.position = anchor + local_axis * shadow.position.length() * factor
	var stretched := PackedVector2Array()
	stretched.resize(shadow.polygon.size())
	for index in shadow.polygon.size():
		var point := shadow.polygon[index]
		stretched[index] = point + local_axis * (point.dot(local_axis) * (factor - 1.0))
	shadow.polygon = stretched


func _clear_children() -> void:
	for child in get_children():
		child.free()
	_visual_count = 0
	_decorative_batch_count = 0
	_solid_visual_count = 0
	_decorative_instances.clear()
