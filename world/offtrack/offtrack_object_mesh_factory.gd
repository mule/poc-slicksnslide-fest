class_name OfftrackObjectMeshFactory
extends RefCounted

## Every body colour here is a base that TerrainShading multiplies by the ground's brightness at
## the object's foot, so each must keep TerrainShading.BODY_CONTRAST_FLOOR of luminance ratio
## against TerrainShading.GROUND_COLOR on its own: the ratio survives the shading unchanged. The
## trees and the debris were lifted in #51 to restore the ratios they had before #50 lightened
## the ground (the old #315b2f tree sat at 1.2 against the new ground and vanished on a rise).
##
## A solid visual is a root with two named children, the shadow under the body, so consumers reach
## them by name rather than by the order they were added in.

const SHADOW_NODE := "Shadow"
const BODY_NODE := "Body"


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
			colors.fill(Color("825a3a"))
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
	shadow.name = SHADOW_NODE
	shadow.position = Vector2(WorldScale.metres(0.32), WorldScale.metres(0.48))
	shadow.color = Color(0.02, 0.03, 0.02, 0.35)
	var body := Polygon2D.new()
	body.name = BODY_NODE
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
		body.color = Color("40763d") if variant == 0 else Color("4e8642")
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
