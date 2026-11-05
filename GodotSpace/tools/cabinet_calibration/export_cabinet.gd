extends SceneTree

## Exports authored geometry without instantiating the animated cabinet or
## executing its scripts. All OBJ coordinates are in the fixed frame mesh space.
const CABINET_SCENE := "res://Assets/ARSpace/Prefabs/UI/MaterialCanvas/dashiyangui.prefab.tscn"
const FRAME_NODE := "dashiyangui/MeshRenderer"
const PARTS := {
	"frame": FRAME_NODE,
	"chamber_a": "xiaoshiyangui/xiaoshiyangui_a/MeshRenderer",
	"chamber_b": "xiaoshiyangui/xiaoshiyangui_b/MeshRenderer",
	"chamber_c": "xiaoshiyangui/xiaoshiyangui_c/MeshRenderer",
	"spindle_tip": "zhouxinjigou/dingzi/MeshRenderer",
	"spindle": "zhouxinjigou/zhouxinjigou_a/MeshRenderer",
	"sample_box": "zhouxinjigou/zhouxinjigou_a/xiaoshiyangui_d/MeshRenderer",
}


func _initialize() -> void:
	var output_dir := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			output_dir = argument.trim_prefix("--output=").simplify_path()
	if output_dir.is_empty():
		push_error("Pass -- --output=<directory outside res:// or ignored artifacts/>")
		quit(1)
		return
	var error := DirAccess.make_dir_recursive_absolute(output_dir)
	if error != OK:
		push_error("Cannot create export directory: %s" % error_string(error))
		quit(1)
		return
	var scene := load(CABINET_SCENE) as PackedScene
	if scene == null:
		quit(1)
		return
	var state := scene.get_state()
	var transforms: Dictionary = {}
	var meshes: Dictionary = {}
	for index in range(state.get_node_count()):
		var node_path := str(state.get_node_path(index)).trim_prefix("./")
		var local_transform := Transform3D.IDENTITY
		var mesh: Mesh
		for property_index in range(state.get_node_property_count(index)):
			var property_name := state.get_node_property_name(index, property_index)
			if property_name == &"transform":
				local_transform = state.get_node_property_value(index, property_index)
			elif property_name == &"mesh":
				mesh = state.get_node_property_value(index, property_index) as Mesh
		var parent_path := node_path.get_base_dir()
		var parent_transform: Transform3D = transforms.get(parent_path, Transform3D.IDENTITY)
		transforms[node_path] = parent_transform * local_transform
		if mesh != null:
			meshes[node_path] = mesh
	if not transforms.has(FRAME_NODE):
		push_error("Cabinet fixed frame not found")
		quit(1)
		return
	var frame_transform: Transform3D = transforms[FRAME_NODE]
	var manifest := {
		"schema_version": 1,
		"source_scene": CABINET_SCENE,
		"coordinate_system": "godot_frame_mesh_local_right_handed_y_up",
		"units": "meters",
		"frame_node": FRAME_NODE,
		"frame_to_prefab": _matrix(frame_transform),
		"parts": [],
	}
	for part_name: String in PARTS:
		var path: String = PARTS[part_name]
		if not meshes.has(path):
			push_error("Cabinet mesh missing: %s" % path)
			quit(1)
			return
		var transform: Transform3D = frame_transform.affine_inverse() * transforms[path]
		var result := _write_obj(
			output_dir.path_join(part_name + ".obj"), meshes[path], transform
		)
		if result.is_empty():
			quit(1)
			return
		result["name"] = part_name
		result["node_path"] = path
		result["mesh_resource"] = (meshes[path] as Mesh).resource_path
		result["mesh_to_frame"] = _matrix(transform)
		manifest["parts"].append(result)
	var file := FileAccess.open(output_dir.path_join("virtual_cabinet.json"), FileAccess.WRITE)
	if file == null:
		push_error("Cannot write cabinet manifest")
		quit(1)
		return
	file.store_string(JSON.stringify(manifest, "\t"))
	file.close()
	print("Cabinet geometry exported: %s (%d parts)" % [output_dir, PARTS.size()])
	quit(0)


func _write_obj(path: String, mesh: Mesh, transform: Transform3D) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write: %s" % path)
		return {}
	file.store_line("# Godot cabinet; meters; fixed frame mesh local coordinates")
	var vertex_offset := 1
	var triangle_count := 0
	var bounds := AABB()
	var has_bounds := false
	for surface in range(mesh.get_surface_count()):
		if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for vertex in vertices:
			var point := transform * vertex
			if not has_bounds:
				bounds = AABB(point, Vector3.ZERO)
				has_bounds = true
			else:
				bounds = bounds.expand(point)
			file.store_line("v %.9f %.9f %.9f" % [point.x, point.y, point.z])
		var count := vertices.size() if indices.is_empty() else indices.size()
		for index in range(0, count - 2, 3):
			var a := index if indices.is_empty() else indices[index]
			var b := index + 1 if indices.is_empty() else indices[index + 1]
			var c := index + 2 if indices.is_empty() else indices[index + 2]
			# Godot uses clockwise fronts; OBJ/OpenCV renderers use counterclockwise.
			file.store_line("f %d %d %d" % [
				a + vertex_offset, c + vertex_offset, b + vertex_offset
			])
			triangle_count += 1
		vertex_offset += vertices.size()
	file.close()
	return {
		"file": path.get_file(),
		"vertices": vertex_offset - 1,
		"triangles": triangle_count,
		"bounds_min": [bounds.position.x, bounds.position.y, bounds.position.z],
		"bounds_max": [bounds.end.x, bounds.end.y, bounds.end.z],
	}


func _matrix(value: Transform3D) -> Array:
	return [
		[value.basis.x.x, value.basis.y.x, value.basis.z.x, value.origin.x],
		[value.basis.x.y, value.basis.y.y, value.basis.z.y, value.origin.y],
		[value.basis.x.z, value.basis.y.z, value.basis.z.z, value.origin.z],
		[0.0, 0.0, 0.0, 1.0],
	]
