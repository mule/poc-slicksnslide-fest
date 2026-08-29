class_name OfftrackObjectMeshFactory
extends RefCounted


static func decorative_mesh(archetype_id: StringName, variant: int) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var colors := PackedColorArray()
	match archetype_id:
		&"grass":
			vertices = PackedVector3Array([
				Vector3(-4, 5, 0), Vector3(0, -9 - variant, 0), Vector3(1, 5, 0),
				Vector3(-1, 5, 0), Vector3(5, -6 - variant, 0), Vector3(4, 6, 0),
			])
			colors.resize(vertices.size())
			colors.fill(Color("6f8f3d"))
		&"debris":
			vertices = PackedVector3Array([
				Vector3(-6, -3, 0), Vector3(5 + variant, -2, 0), Vector3(3, 4, 0),
				Vector3(-6, -3, 0), Vector3(3, 4, 0), Vector3(-4, 5, 0),
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
	shadow.position = Vector2(4, 6)
	shadow.color = Color(0.02, 0.03, 0.02, 0.35)
	var body := Polygon2D.new()
	if archetype_id == &"tree":
		shadow.polygon = PackedVector2Array([Vector2(-20, 0), Vector2(0, -22), Vector2(20, 0), Vector2(0, 22)])
		body.polygon = PackedVector2Array([Vector2(-18, 4), Vector2(-10, -15), Vector2(0, -25 - variant * 3), Vector2(12, -13), Vector2(20, 5), Vector2(0, 22)])
		body.color = Color("315b2f") if variant == 0 else Color("3e6b35")
	elif archetype_id == &"rock":
		shadow.polygon = PackedVector2Array([Vector2(-18, 8), Vector2(-12, -10), Vector2(8, -16), Vector2(19, 3), Vector2(8, 15)])
		body.polygon = shadow.polygon
		body.color = [Color("777269"), Color("696963"), Color("857b6e")][variant % 3]
	else:
		return null
	root_node.add_child(shadow)
	root_node.add_child(body)
	return root_node
