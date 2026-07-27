class_name ReconstructionPointCloudMapStore
extends RefCounted

const Chunk := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk.gd"
)

enum AppendResult {
	APPENDED,
	DUPLICATE,
	INVALID_CHUNK,
	CAPACITY_EXCEEDED,
	SESSION_MISMATCH,
	MAP_MISMATCH,
	CHUNK_CONFLICT,
}

const DEFAULT_MAX_POINTS: int = 1_000_000

var max_points: int = DEFAULT_MAX_POINTS
var session_id: String = ""
var map_id: String = ""
var _point_count: int = 0
var _chunks_by_id: Dictionary = {}
var _chunk_order: PackedStringArray = PackedStringArray()
var _last_error: String = ""
var _bounds: AABB = AABB()
var _has_bounds: bool = false


func configure(p_max_points: int = DEFAULT_MAX_POINTS) -> bool:
	if p_max_points <= 0 or p_max_points > DEFAULT_MAX_POINTS:
		_last_error = "max_points must be within [1, %d]" % DEFAULT_MAX_POINTS
		return false
	if not _chunk_order.is_empty():
		_last_error = "cannot reconfigure a non-empty map store"
		return false
	max_points = p_max_points
	_last_error = ""
	return true


func append_chunk(chunk: ReconstructionPointCloudChunk) -> AppendResult:
	if chunk == null:
		_last_error = "chunk is null"
		return AppendResult.INVALID_CHUNK
	var validation_error := chunk.validate(max_points)
	if not validation_error.is_empty():
		_last_error = validation_error
		return AppendResult.INVALID_CHUNK
	if not session_id.is_empty() and chunk.session_id != session_id:
		_last_error = "chunk session_id does not match the active map"
		return AppendResult.SESSION_MISMATCH
	if not map_id.is_empty() and chunk.map_id != map_id:
		_last_error = "chunk map_id does not match the active map"
		return AppendResult.MAP_MISMATCH
	if _chunks_by_id.has(chunk.chunk_id):
		var existing := _chunks_by_id[chunk.chunk_id] as ReconstructionPointCloudChunk
		if existing != null and existing.payload_equals(chunk):
			_last_error = ""
			return AppendResult.DUPLICATE
		_last_error = "chunk_id already exists with different content"
		return AppendResult.CHUNK_CONFLICT
	if chunk.point_count() > max_points - _point_count:
		_last_error = "appending chunk would exceed the %d point limit" % max_points
		return AppendResult.CAPACITY_EXCEEDED

	var stored := chunk.duplicate_deep()
	if session_id.is_empty():
		session_id = stored.session_id
		map_id = stored.map_id
	_chunks_by_id[stored.chunk_id] = stored
	_chunk_order.append(stored.chunk_id)
	_point_count += stored.point_count()
	_extend_bounds(stored.calculate_aabb())
	_last_error = ""
	return AppendResult.APPENDED


func reset() -> void:
	session_id = ""
	map_id = ""
	_point_count = 0
	_chunks_by_id.clear()
	_chunk_order.clear()
	_last_error = ""
	_bounds = AABB()
	_has_bounds = false


func get_point_count() -> int:
	return _point_count


func get_chunk_count() -> int:
	return _chunk_order.size()


func is_empty() -> bool:
	return _chunk_order.is_empty()


func contains_chunk(chunk_id: String) -> bool:
	return _chunks_by_id.has(chunk_id)


func get_chunk(chunk_id: String) -> ReconstructionPointCloudChunk:
	if not _chunks_by_id.has(chunk_id):
		return null
	var chunk := _chunks_by_id[chunk_id] as ReconstructionPointCloudChunk
	return chunk.duplicate_deep() if chunk != null else null


func get_chunks() -> Array[ReconstructionPointCloudChunk]:
	var result: Array[ReconstructionPointCloudChunk] = []
	for chunk_id in _chunk_order:
		var chunk := _chunks_by_id[chunk_id] as ReconstructionPointCloudChunk
		if chunk != null:
			result.append(chunk.duplicate_deep())
	return result


func get_chunk_ids() -> PackedStringArray:
	return _chunk_order.duplicate()


func get_bounds() -> AABB:
	return _bounds if _has_bounds else AABB()


func has_bounds() -> bool:
	return _has_bounds


func get_last_error() -> String:
	return _last_error


func _extend_bounds(chunk_bounds: AABB) -> void:
	if not _has_bounds:
		_bounds = chunk_bounds
		_has_bounds = true
		return
	var old_end := _bounds.position + _bounds.size
	var chunk_end := chunk_bounds.position + chunk_bounds.size
	var minimum := Vector3(
		minf(_bounds.position.x, chunk_bounds.position.x),
		minf(_bounds.position.y, chunk_bounds.position.y),
		minf(_bounds.position.z, chunk_bounds.position.z)
	)
	var maximum := Vector3(
		maxf(old_end.x, chunk_end.x),
		maxf(old_end.y, chunk_end.y),
		maxf(old_end.z, chunk_end.z)
	)
	_bounds = AABB(minimum, maximum - minimum)
