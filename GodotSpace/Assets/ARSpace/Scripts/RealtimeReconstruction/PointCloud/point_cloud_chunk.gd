class_name ReconstructionPointCloudChunk
extends RefCounted

const MAX_ID_BYTES: int = 128
const MAX_SAFE_JSON_INTEGER: int = 9_007_199_254_740_991

var session_id: String = ""
var map_id: String = ""
var chunk_id: String = ""
var source_frame_id: int = -1
var timestamp_usec: int = 0
var positions: PackedVector3Array = PackedVector3Array()
var colors_rgb8: PackedByteArray = PackedByteArray()
var confidence_u8: PackedByteArray = PackedByteArray()
var has_camera_pose: bool = false
var camera_to_lingbot_world: Transform3D = Transform3D.IDENTITY
var metadata_extensions: Dictionary = {}


static func create(
	p_session_id: String,
	p_map_id: String,
	p_chunk_id: String,
	p_positions: PackedVector3Array,
	p_colors_rgb8: PackedByteArray,
	p_confidence_u8: PackedByteArray = PackedByteArray(),
	p_timestamp_usec: int = 0,
	p_source_frame_id: int = -1,
	p_has_camera_pose: bool = false,
	p_camera_to_lingbot_world: Transform3D = Transform3D.IDENTITY,
	p_metadata_extensions: Dictionary = {}
) -> ReconstructionPointCloudChunk:
	var chunk := ReconstructionPointCloudChunk.new()
	chunk.session_id = p_session_id
	chunk.map_id = p_map_id
	chunk.chunk_id = p_chunk_id
	chunk.positions = p_positions.duplicate()
	chunk.colors_rgb8 = p_colors_rgb8.duplicate()
	chunk.confidence_u8 = p_confidence_u8.duplicate()
	chunk.timestamp_usec = p_timestamp_usec
	chunk.source_frame_id = p_source_frame_id
	chunk.has_camera_pose = p_has_camera_pose
	chunk.camera_to_lingbot_world = p_camera_to_lingbot_world
	chunk.metadata_extensions = p_metadata_extensions.duplicate(true)
	return chunk


func point_count() -> int:
	return positions.size()


func has_confidence() -> bool:
	return not confidence_u8.is_empty()


func validate(max_point_count: int) -> String:
	var id_error := validate_ids()
	if not id_error.is_empty():
		return id_error
	if max_point_count <= 0:
		return "max_point_count must be positive"
	if positions.is_empty():
		return "point chunk must contain at least one point"
	if positions.size() > max_point_count:
		return "point count %d exceeds limit %d" % [positions.size(), max_point_count]
	if colors_rgb8.size() != positions.size() * 3:
		return "RGB byte count must equal point_count * 3"
	if not confidence_u8.is_empty() and confidence_u8.size() != positions.size():
		return "confidence count must be zero or equal point_count"
	if timestamp_usec < 0 or timestamp_usec > MAX_SAFE_JSON_INTEGER:
		return "timestamp_usec must be a non-negative JSON-safe integer"
	if source_frame_id < -1 or source_frame_id > MAX_SAFE_JSON_INTEGER:
		return "source_frame_id must be -1 or a non-negative JSON-safe integer"
	for reserved_field in [
		"session_id",
		"map_id",
		"chunk_id",
		"source_frame_id",
		"timestamp_usec",
		"coordinate_space",
		"position_unit",
		"camera_pose",
	]:
		if metadata_extensions.has(reserved_field):
			return "metadata_extensions must not override %s" % reserved_field
	var metadata_error := _validate_metadata_value(metadata_extensions, 0)
	if not metadata_error.is_empty():
		return metadata_error
	for point in positions:
		if not _is_finite_vector(point):
			return "positions contain a non-finite value"
	if has_camera_pose:
		if not _is_finite_vector(camera_to_lingbot_world.origin):
			return "camera pose translation contains a non-finite value"
		var quaternion := camera_to_lingbot_world.basis.get_rotation_quaternion()
		if not _is_finite_quaternion(quaternion):
			return "camera pose quaternion contains a non-finite value"
		if absf(quaternion.length_squared() - 1.0) > 0.001:
			return "camera pose quaternion must be normalized"
		var basis := camera_to_lingbot_world.basis
		if absf(basis.determinant() - 1.0) > 0.001:
			return "camera pose basis must be a proper unit rotation"
	return ""


func validate_ids() -> String:
	var session_error := _validate_id("session_id", session_id)
	if not session_error.is_empty():
		return session_error
	var map_error := _validate_id("map_id", map_id)
	if not map_error.is_empty():
		return map_error
	return _validate_id("chunk_id", chunk_id)


func duplicate_deep() -> ReconstructionPointCloudChunk:
	return create(
		session_id,
		map_id,
		chunk_id,
		positions,
		colors_rgb8,
		confidence_u8,
		timestamp_usec,
		source_frame_id,
		has_camera_pose,
		camera_to_lingbot_world,
		metadata_extensions
	)


func payload_equals(other: ReconstructionPointCloudChunk) -> bool:
	if other == null:
		return false
	return session_id == other.session_id \
		and map_id == other.map_id \
		and chunk_id == other.chunk_id \
		and source_frame_id == other.source_frame_id \
		and timestamp_usec == other.timestamp_usec \
		and positions == other.positions \
		and colors_rgb8 == other.colors_rgb8 \
		and confidence_u8 == other.confidence_u8 \
		and metadata_extensions == other.metadata_extensions \
		and has_camera_pose == other.has_camera_pose \
		and (
			not has_camera_pose
			or (
				camera_to_lingbot_world.origin.is_equal_approx(
					other.camera_to_lingbot_world.origin
				)
				and camera_to_lingbot_world.basis.is_equal_approx(
					other.camera_to_lingbot_world.basis
				)
			)
		)


func calculate_aabb() -> AABB:
	if positions.is_empty():
		return AABB()
	var minimum := positions[0]
	var maximum := positions[0]
	for index in range(1, positions.size()):
		var point := positions[index]
		minimum = Vector3(
			minf(minimum.x, point.x),
			minf(minimum.y, point.y),
			minf(minimum.z, point.z)
		)
		maximum = Vector3(
			maxf(maximum.x, point.x),
			maxf(maximum.y, point.y),
			maxf(maximum.z, point.z)
		)
	return AABB(minimum, maximum - minimum)


func get_chunk_key() -> String:
	return "%s\u001f%s\u001f%s" % [session_id, map_id, chunk_id]


static func _validate_id(field_name: String, value: String) -> String:
	var bytes := value.to_utf8_buffer()
	if bytes.is_empty():
		return "%s must not be empty" % field_name
	if bytes.size() > MAX_ID_BYTES:
		return "%s exceeds %d UTF-8 bytes" % [field_name, MAX_ID_BYTES]
	for character_index in range(value.length()):
		var codepoint := value.unicode_at(character_index)
		if codepoint < 32 or codepoint == 127:
			return "%s contains a control character" % field_name
	return ""


static func _is_finite_vector(value: Vector3) -> bool:
	return is_finite(value.x) and is_finite(value.y) and is_finite(value.z)


static func _is_finite_quaternion(value: Quaternion) -> bool:
	return is_finite(value.x) \
		and is_finite(value.y) \
		and is_finite(value.z) \
		and is_finite(value.w)


static func _validate_metadata_value(value: Variant, depth: int) -> String:
	if depth > 8:
		return "metadata_extensions nesting exceeds 8 levels"
	if value == null or value is bool or value is String:
		return ""
	if value is int:
		if absi(int(value)) > MAX_SAFE_JSON_INTEGER:
			return "metadata_extensions contain an integer outside JSON safe range"
		return ""
	if value is float:
		return "" if is_finite(float(value)) else "metadata_extensions contain non-finite data"
	if value is Array:
		for item in value:
			var item_error := _validate_metadata_value(item, depth + 1)
			if not item_error.is_empty():
				return item_error
		return ""
	if value is Dictionary:
		for key in value:
			if not key is String:
				return "metadata_extensions object keys must be strings"
			var field_error := _validate_metadata_value(value[key], depth + 1)
			if not field_error.is_empty():
				return field_error
		return ""
	return "metadata_extensions contain a non-JSON value"
