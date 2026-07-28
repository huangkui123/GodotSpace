class_name ReconstructionPointCloudRenderer
extends Node3D

const Chunk := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk.gd"
)
const MapStore := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_map_store.gd"
)

# Keep the only mutable mesh small. Incoming chunks can update the tail batch
# repeatedly, so a 100k tail caused avoidable full-array uploads on XR clients.
const DEFAULT_POINTS_PER_BATCH: int = 10_000
const POINT_SHADER_CODE: String = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, blend_mix;

uniform float point_size : hint_range(1.0, 16.0, 0.25) = 4.0;

void vertex() {
	POINT_SIZE = point_size;
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = 1.0;
}
"""

@export_range(1_000, 50_000, 1_000) var max_points_per_batch: int = (
	DEFAULT_POINTS_PER_BATCH
)
@export_range(1.0, 16.0, 0.25) var point_size: float = 4.0

var _batch_positions: Array[PackedVector3Array] = []
var _batch_colors: Array[PackedColorArray] = []
var _batch_meshes: Array[ArrayMesh] = []
var _batch_instances: Array[MeshInstance3D] = []
var _rendered_chunk_keys: Dictionary = {}
var _rendered_point_count: int = 0
var _generation: int = 0
var _last_error: String = ""


func append_chunk(chunk: ReconstructionPointCloudChunk) -> bool:
	if chunk == null:
		_last_error = "chunk is null"
		return false
	var validation_error := chunk.validate(MapStore.DEFAULT_MAX_POINTS)
	if not validation_error.is_empty():
		_last_error = validation_error
		return false
	if max_points_per_batch <= 0:
		_last_error = "max_points_per_batch must be positive"
		return false
	var key := chunk.get_chunk_key()
	if _rendered_chunk_keys.has(key):
		_last_error = ""
		return false

	var source_index := 0
	while source_index < chunk.point_count():
		var batch_index := _ensure_writable_batch()
		var batch_positions := _batch_positions[batch_index]
		var batch_colors := _batch_colors[batch_index]
		var available := max_points_per_batch - batch_positions.size()
		var copy_count := mini(available, chunk.point_count() - source_index)
		for offset in range(copy_count):
			var point_index := source_index + offset
			batch_positions.append(chunk.positions[point_index])
			var color_offset := point_index * 3
			batch_colors.append(Color8(
				chunk.colors_rgb8[color_offset],
				chunk.colors_rgb8[color_offset + 1],
				chunk.colors_rgb8[color_offset + 2],
				255
			))
		_batch_positions[batch_index] = batch_positions
		_batch_colors[batch_index] = batch_colors
		_rebuild_batch(batch_index)
		source_index += copy_count
	_rendered_chunk_keys[key] = true
	_rendered_point_count += chunk.point_count()
	_last_error = ""
	return true


func rebuild_from_store(store: ReconstructionPointCloudMapStore) -> bool:
	if store == null:
		_last_error = "map store is null"
		return false
	clear_rendered()
	for chunk in store.get_chunks():
		if not append_chunk(chunk):
			return false
	return true


func clear_rendered() -> void:
	for instance in _batch_instances:
		if instance != null and is_instance_valid(instance):
			if instance.get_parent() == self:
				remove_child(instance)
			instance.queue_free()
	_batch_positions.clear()
	_batch_colors.clear()
	_batch_meshes.clear()
	_batch_instances.clear()
	_rendered_chunk_keys.clear()
	_rendered_point_count = 0
	_generation += 1
	_last_error = ""


func get_rendered_point_count() -> int:
	return _rendered_point_count


func get_mesh_batch_count() -> int:
	return _batch_meshes.size()


func get_meshes_for_test() -> Array[ArrayMesh]:
	return _batch_meshes.duplicate()


func get_last_error() -> String:
	return _last_error


static func build_point_mesh(
	positions: PackedVector3Array,
	colors: PackedColorArray
) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if positions.is_empty() or positions.size() != colors.size():
		return mesh
	for point in positions:
		if not is_finite(point.x) or not is_finite(point.y) or not is_finite(point.z):
			return ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_COLOR] = colors
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	return mesh


static func make_point_material(requested_point_size: float) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = POINT_SHADER_CODE
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("point_size", maxf(requested_point_size, 1.0))
	return material


func _ensure_writable_batch() -> int:
	if _batch_positions.is_empty() \
		or _batch_positions[_batch_positions.size() - 1].size() >= max_points_per_batch:
		_batch_positions.append(PackedVector3Array())
		_batch_colors.append(PackedColorArray())
		_batch_meshes.append(ArrayMesh.new())
		if DisplayServer.get_name() != "headless":
			var instance := MeshInstance3D.new()
			instance.name = "PointBatch_%d_%d" % [
				_generation,
				_batch_instances.size(),
			]
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			instance.material_override = make_point_material(point_size)
			add_child(instance)
			_batch_instances.append(instance)
	return _batch_positions.size() - 1


func _rebuild_batch(batch_index: int) -> void:
	var mesh := build_point_mesh(
		_batch_positions[batch_index],
		_batch_colors[batch_index]
	)
	_batch_meshes[batch_index] = mesh
	if DisplayServer.get_name() == "headless":
		return
	var instance := _batch_instances[batch_index]
	instance.mesh = mesh
	instance.custom_aabb = mesh.get_aabb().grow(0.02)
