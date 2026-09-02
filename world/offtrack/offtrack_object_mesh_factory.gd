class_name OfftrackObjectMeshFactory
extends RefCounted


static func decorative_mesh(archetype_id: StringName, variant: int) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	match archetype_id:
		&"grass":
			vertices = PackedVector3Array([
				Vector3(WorldScale.metres(-0.32), WorldScale.metres(0.4), WorldScale.metres(0.0)),
				Vector3(WorldScale.metres(0.0), WorldScale.metres(-0.72 - variant * 0.08), WorldScale.metres(0.0)),
				Vector3(WorldScale.metres(0.08), WorldScale.metres(0.4), WorldScale.metres(0.0)),
				Vector3(WorldScale.metres(-0.08), WorldScale.metres(0.4), WorldScale.metres(0.0)),
				Vector3(WorldScale.metres(0.4), WorldScale.metres(-0.48 - variant * 0.08), WorldScale.metres(0.0)),
				Vector3(WorldScale.metres(0.32), WorldScale.metres(0.48), WorldScale.metres(0.0)),
			])
			colors.resize(vertices.size())
			colors.fill(Color("6f8f3d"))
		&"debris":
			vertices = PackedVector3Array([
				Vector3(WorldScale.metres(-0.48), WorldScale.metres(-0.24), WorldScale.metres(0.0)),
				Vector3(WorldScale.metres(0.4 + variant * 0.08), WorldScale.metres(-0.16), WorldScale.metres(0.0)),
				Vector3(WorldScale.metres(0.24), WorldScale.metres(0.32), WorldScale.metres(0.0)),
				Vector3(WorldScale.metres(-0.48), WorldScale.metres(-0.24), WorldScale.metres(0.0)),
				Vector3(WorldScale.metres(0.24), WorldScale.metres(0.32), WorldScale.metres(0.0)),
				Vector3(WorldScale.metres(-0.32), WorldScale.metres(0.4), WorldScale.metres(0.0)),
			])
			colors.resize(vertices.size())
			colors.fill(Color("765235"))
		_:
			return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func solid_visual(archetype_id: StringName, variant: int) -> Node2D:
	var root_node := Node2D.new()
	var shadow := Polygon2D.new()
	shadow.position = Vector2(WorldScale.metres(0.32), WorldScale.metres(0.48))
	shadow.color = Color(0.02, 0.03, 0.02, 0.35)
	var body := Polygon2D.new()
	if archetype_id == &"tree":
		shadow.polygon = PackedVector2Array([
			Vector2(WorldScale.metres(-1.6), WorldScale.metres(0.0)),
			Vector2(WorldScale.metres(0.0), WorldScale.metres(-1.76)),
			Vector2(WorldScale.metres(1.6), WorldScale.metres(0.0)),
			Vector2(WorldScale.metres(0.0), WorldScale.metres(1.76)),
		])
		body.polygon = PackedVector2Array([
			Vector2(WorldScale.metres(-1.44), WorldScale.metres(0.32)),
			Vector2(WorldScale.metres(-0.8), WorldScale.metres(-1.2)),
			Vector2(WorldScale.metres(0.0), WorldScale.metres(-2.0 - variant * 0.24)),
			Vector2(WorldScale.metres(0.96), WorldScale.metres(-1.04)),
			Vector2(WorldScale.metres(1.6), WorldScale.metres(0.4)),
			Vector2(WorldScale.metres(0.0), WorldScale.metres(1.76)),
		])
		body.color = Color("315b2f") if variant == 0 else Color("3e6b35")
	elif archetype_id == &"rock":
		shadow.polygon = PackedVector2Array([
			Vector2(WorldScale.metres(-1.44), WorldScale.metres(0.64)),
			Vector2(WorldScale.metres(-0.96), WorldScale.metres(-0.8)),
			Vector2(WorldScale.metres(0.64), WorldScale.metres(-1.28)),
			Vector2(WorldScale.metres(1.52), WorldScale.metres(0.24)),
			Vector2(WorldScale.metres(0.64), WorldScale.metres(1.2)),
		])
		body.polygon = shadow.polygon
		body.color = [Color("777269"), Color("696963"), Color("857b6e")][variant % 3]
	else:
		return null
	root_node.add_child(shadow)
	root_node.add_child(body)
	return root_node
