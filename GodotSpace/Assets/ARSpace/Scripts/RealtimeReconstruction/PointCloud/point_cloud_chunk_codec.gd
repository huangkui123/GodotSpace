class_name ReconstructionPointCloudChunkCodec
extends RefCounted

# PCCH v1 is shared with the Lab encoder. Every integer and float is big-endian.
# Header: >4sHHIIIIII32s, then UTF-8 metadata JSON, then 15/16-byte point rows.
# The digest covers the complete body (metadata followed by point rows).
const Chunk := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk.gd"
)

const MAGIC_TEXT: String = "PCCH"
const VERSION: int = 1
const HEADER_SIZE: int = 64
const FLAG_HAS_CONFIDENCE_U8: int = 1
const FLAG_HAS_CAMERA_POSE: int = 2
const KNOWN_FLAGS: int = FLAG_HAS_CONFIDENCE_U8 | FLAG_HAS_CAMERA_POSE
const POSITION_BYTES: int = 12
const COLOR_BYTES: int = 3
const CONFIDENCE_BYTES: int = 1
const MAX_POINT_COUNT: int = 1_000_000
const MAX_METADATA_BYTES: int = 16 * 1024
const MAX_POINT_DATA_BYTES: int = 16 * 1024 * 1024
const MAX_ENCODED_BYTES: int = 32 * 1024 * 1024
const DIGEST_OFFSET: int = 32
const DIGEST_SIZE: int = 32
const COORDINATE_SPACE: String = "lingbot_world"
const POSITION_UNIT: String = "lingbot_model_unit"
const CAMERA_POSE_CONVENTION: String = "camera_to_lingbot_world"


static func encode(chunk: ReconstructionPointCloudChunk) -> Dictionary:
	if chunk == null:
		return _failure("chunk is null")
	var validation_error := chunk.validate(MAX_POINT_COUNT)
	if not validation_error.is_empty():
		return _failure(validation_error)

	var flags := FLAG_HAS_CONFIDENCE_U8 if chunk.has_confidence() else 0
	if chunk.has_camera_pose:
		flags |= FLAG_HAS_CAMERA_POSE
	var metadata_result := _encode_metadata(chunk)
	if not bool(metadata_result.get("ok", false)):
		return metadata_result
	var metadata_bytes := metadata_result.get("data", PackedByteArray()) as PackedByteArray
	var point_data_result := _encode_point_data(chunk)
	if not bool(point_data_result.get("ok", false)):
		return point_data_result
	var point_data := point_data_result.get("data", PackedByteArray()) as PackedByteArray
	var total_size := HEADER_SIZE + metadata_bytes.size() + point_data.size()
	if total_size > MAX_ENCODED_BYTES:
		return _failure("encoded chunk exceeds the maximum byte size")

	var body := metadata_bytes.duplicate()
	body.append_array(point_data)
	var digest := _sha256(body)
	if digest.size() != DIGEST_SIZE:
		return _failure("could not calculate point chunk SHA-256")

	var encoded := PackedByteArray()
	encoded.resize(HEADER_SIZE)
	encoded[0] = 0x50
	encoded[1] = 0x43
	encoded[2] = 0x43
	encoded[3] = 0x48
	_write_u16_be(encoded, 4, VERSION)
	_write_u16_be(encoded, 6, HEADER_SIZE)
	_write_u32_be(encoded, 8, flags)
	_write_u32_be(encoded, 12, chunk.point_count())
	_write_u32_be(encoded, 16, metadata_bytes.size())
	_write_u32_be(encoded, 20, point_data.size())
	_write_u32_be(encoded, 24, total_size)
	_write_u32_be(encoded, 28, 0)
	for index in range(DIGEST_SIZE):
		encoded[DIGEST_OFFSET + index] = digest[index]
	encoded.append_array(body)
	return {
		"ok": true,
		"data": encoded,
		"sha256": _sha256(encoded).hex_encode(),
		"error": "",
	}


static func decode(encoded: PackedByteArray) -> Dictionary:
	if encoded.size() < HEADER_SIZE:
		return _failure("encoded chunk is shorter than the fixed header")
	if encoded.size() > MAX_ENCODED_BYTES:
		return _failure("encoded chunk exceeds the maximum byte size")
	if not _has_magic(encoded):
		return _failure("invalid point chunk magic")

	var version := _read_u16_be(encoded, 4)
	if version != VERSION:
		return _failure("unsupported point chunk version %d" % version)
	if _read_u16_be(encoded, 6) != HEADER_SIZE:
		return _failure("unexpected point chunk header size")
	var flags := _read_u32_be(encoded, 8)
	if (flags & ~KNOWN_FLAGS) != 0:
		return _failure("point chunk contains unknown flags")
	var point_count := _read_u32_be(encoded, 12)
	if point_count <= 0 or point_count > MAX_POINT_COUNT:
		return _failure("point count is outside the supported range")
	var metadata_size := _read_u32_be(encoded, 16)
	if metadata_size <= 0 or metadata_size > MAX_METADATA_BYTES:
		return _failure("metadata size is outside the supported range")
	var point_data_size := _read_u32_be(encoded, 20)
	if point_data_size <= 0 or point_data_size > MAX_POINT_DATA_BYTES:
		return _failure("point data size is outside the supported range")
	var declared_total_size := _read_u32_be(encoded, 24)
	if declared_total_size != encoded.size():
		return _failure("declared point chunk size does not match received bytes")
	if _read_u32_be(encoded, 28) != 0:
		return _failure("reserved point chunk header field must be zero")

	var stride := POSITION_BYTES + COLOR_BYTES
	var has_confidence := (flags & FLAG_HAS_CONFIDENCE_U8) != 0
	if has_confidence:
		stride += CONFIDENCE_BYTES
	if point_data_size != point_count * stride:
		return _failure("point data size is inconsistent with count and flags")
	if HEADER_SIZE + metadata_size + point_data_size != encoded.size():
		return _failure("metadata and point data lengths do not match total size")

	var body := encoded.slice(HEADER_SIZE)
	var declared_digest := encoded.slice(DIGEST_OFFSET, DIGEST_OFFSET + DIGEST_SIZE)
	if _sha256(body) != declared_digest:
		return _failure("point chunk SHA-256 validation failed")
	var metadata_bytes := encoded.slice(HEADER_SIZE, HEADER_SIZE + metadata_size)
	var metadata_result := _decode_metadata(
		metadata_bytes,
		(flags & FLAG_HAS_CAMERA_POSE) != 0
	)
	if not bool(metadata_result.get("ok", false)):
		return metadata_result
	var metadata := metadata_result.get("metadata", {}) as Dictionary
	var point_data := encoded.slice(HEADER_SIZE + metadata_size)
	var points_result := _decode_point_data(point_data, point_count, has_confidence)
	if not bool(points_result.get("ok", false)):
		return points_result

	var transform := Transform3D.IDENTITY
	var has_camera_pose := (flags & FLAG_HAS_CAMERA_POSE) != 0
	if has_camera_pose:
		transform = _camera_pose_from_metadata(metadata.get("camera_pose", {}) as Dictionary)
	var metadata_extensions := metadata.duplicate(true)
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
		metadata_extensions.erase(reserved_field)
	var decoded := Chunk.create(
		str(metadata.get("session_id", "")),
		str(metadata.get("map_id", "")),
		str(metadata.get("chunk_id", "")),
		points_result.get("positions", PackedVector3Array()) as PackedVector3Array,
		points_result.get("colors_rgb8", PackedByteArray()) as PackedByteArray,
		points_result.get("confidence_u8", PackedByteArray()) as PackedByteArray,
		int(metadata.get("timestamp_usec", -1)),
		int(metadata.get("source_frame_id", -2)),
		has_camera_pose,
		transform,
		metadata_extensions
	)
	var validation_error := decoded.validate(MAX_POINT_COUNT)
	if not validation_error.is_empty():
		return _failure("decoded point chunk is invalid: %s" % validation_error)
	return {
		"ok": true,
		"chunk": decoded,
		"sha256": _sha256(encoded).hex_encode(),
		"error": "",
	}


static func sha256_hex(bytes: PackedByteArray) -> String:
	return _sha256(bytes).hex_encode()


static func _encode_metadata(chunk: ReconstructionPointCloudChunk) -> Dictionary:
	var metadata := chunk.metadata_extensions.duplicate(true)
	metadata["session_id"] = chunk.session_id
	metadata["map_id"] = chunk.map_id
	metadata["chunk_id"] = chunk.chunk_id
	metadata["source_frame_id"] = chunk.source_frame_id
	metadata["timestamp_usec"] = chunk.timestamp_usec
	metadata["coordinate_space"] = COORDINATE_SPACE
	metadata["position_unit"] = POSITION_UNIT
	if chunk.has_camera_pose:
		var rotation := chunk.camera_to_lingbot_world.basis.get_rotation_quaternion()
		metadata["camera_pose"] = {
			"convention": CAMERA_POSE_CONVENTION,
			"translation_xyz": [
				chunk.camera_to_lingbot_world.origin.x,
				chunk.camera_to_lingbot_world.origin.y,
				chunk.camera_to_lingbot_world.origin.z,
			],
			"quaternion_wxyz": [rotation.w, rotation.x, rotation.y, rotation.z],
		}
	var bytes := JSON.stringify(metadata).to_utf8_buffer()
	if bytes.is_empty() or bytes.size() > MAX_METADATA_BYTES:
		return _failure("metadata JSON exceeds the supported byte size")
	return {"ok": true, "data": bytes, "error": ""}


static func _decode_metadata(bytes: PackedByteArray, expects_camera_pose: bool) -> Dictionary:
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes:
		return _failure("metadata is not valid UTF-8")
	var parsed = JSON.parse_string(text)
	if not parsed is Dictionary:
		return _failure("metadata JSON root must be an object")
	var metadata := parsed as Dictionary
	for field_name in [
		"session_id",
		"map_id",
		"chunk_id",
		"source_frame_id",
		"timestamp_usec",
		"coordinate_space",
		"position_unit",
	]:
		if not metadata.has(field_name):
			return _failure("metadata is missing required field %s" % field_name)
	if str(metadata.get("coordinate_space", "")) != COORDINATE_SPACE:
		return _failure("metadata coordinate_space is unsupported")
	if str(metadata.get("position_unit", "")) != POSITION_UNIT:
		return _failure("metadata position_unit is unsupported")
	if not _is_json_integer(metadata.get("source_frame_id")) \
		or int(metadata.get("source_frame_id")) < -1:
		return _failure("metadata source_frame_id must be -1 or a non-negative integer")
	if not _is_json_integer(metadata.get("timestamp_usec")) \
		or int(metadata.get("timestamp_usec")) < 0:
		return _failure("metadata timestamp_usec must be a non-negative integer")

	var id_probe := Chunk.new()
	id_probe.session_id = str(metadata.get("session_id", ""))
	id_probe.map_id = str(metadata.get("map_id", ""))
	id_probe.chunk_id = str(metadata.get("chunk_id", ""))
	var id_error := id_probe.validate_ids()
	if not id_error.is_empty():
		return _failure("metadata %s" % id_error)
	if expects_camera_pose:
		if not metadata.get("camera_pose") is Dictionary:
			return _failure("camera pose flag requires camera_pose metadata")
		var pose_error := _validate_camera_pose(metadata.get("camera_pose") as Dictionary)
		if not pose_error.is_empty():
			return _failure(pose_error)
	elif metadata.has("camera_pose"):
		return _failure("camera_pose metadata requires its header flag")
	return {"ok": true, "metadata": metadata, "error": ""}


static func _encode_point_data(chunk: ReconstructionPointCloudChunk) -> Dictionary:
	var stream := StreamPeerBuffer.new()
	stream.big_endian = true
	for point_index in range(chunk.point_count()):
		var point := chunk.positions[point_index]
		stream.put_float(point.x)
		stream.put_float(point.y)
		stream.put_float(point.z)
		var color_offset := point_index * 3
		stream.put_u8(chunk.colors_rgb8[color_offset])
		stream.put_u8(chunk.colors_rgb8[color_offset + 1])
		stream.put_u8(chunk.colors_rgb8[color_offset + 2])
		if chunk.has_confidence():
			stream.put_u8(chunk.confidence_u8[point_index])
	var bytes := stream.data_array
	if bytes.size() > MAX_POINT_DATA_BYTES:
		return _failure("point data exceeds the supported byte size")
	return {"ok": true, "data": bytes, "error": ""}


static func _decode_point_data(
	bytes: PackedByteArray,
	point_count: int,
	has_confidence: bool
) -> Dictionary:
	var stream := StreamPeerBuffer.new()
	stream.big_endian = true
	stream.data_array = bytes
	var positions := PackedVector3Array()
	var colors := PackedByteArray()
	var confidence := PackedByteArray()
	positions.resize(point_count)
	colors.resize(point_count * 3)
	if has_confidence:
		confidence.resize(point_count)
	for point_index in range(point_count):
		positions[point_index] = Vector3(
			stream.get_float(),
			stream.get_float(),
			stream.get_float()
		)
		var color_offset := point_index * 3
		colors[color_offset] = stream.get_u8()
		colors[color_offset + 1] = stream.get_u8()
		colors[color_offset + 2] = stream.get_u8()
		if has_confidence:
			confidence[point_index] = stream.get_u8()
	return {
		"ok": true,
		"positions": positions,
		"colors_rgb8": colors,
		"confidence_u8": confidence,
		"error": "",
	}


static func _validate_camera_pose(pose: Dictionary) -> String:
	if str(pose.get("convention", "")) != CAMERA_POSE_CONVENTION:
		return "camera pose convention must be %s" % CAMERA_POSE_CONVENTION
	if not pose.get("translation_xyz") is Array \
		or not pose.get("quaternion_wxyz") is Array:
		return "camera pose translation and quaternion must be arrays"
	var translation := pose.get("translation_xyz") as Array
	var quaternion := pose.get("quaternion_wxyz") as Array
	if translation.size() != 3 or quaternion.size() != 4:
		return "camera pose must contain xyz translation and wxyz quaternion"
	for value in translation + quaternion:
		if not _is_json_number(value) or not is_finite(float(value)):
			return "camera pose values must be finite numbers"
	var length_squared := 0.0
	for value in quaternion:
		length_squared += float(value) * float(value)
	if absf(length_squared - 1.0) > 0.001:
		return "camera pose quaternion must be normalized"
	return ""


static func _camera_pose_from_metadata(pose: Dictionary) -> Transform3D:
	var translation := pose.get("translation_xyz") as Array
	var values := pose.get("quaternion_wxyz") as Array
	var rotation := Quaternion(
		float(values[1]),
		float(values[2]),
		float(values[3]),
		float(values[0])
	).normalized()
	return Transform3D(Basis(rotation), Vector3(
		float(translation[0]),
		float(translation[1]),
		float(translation[2])
	))


static func _is_json_integer(value: Variant) -> bool:
	if not _is_json_number(value):
		return false
	var number := float(value)
	return is_finite(number) \
		and absf(number) <= float(Chunk.MAX_SAFE_JSON_INTEGER) \
		and number == floor(number)


static func _is_json_number(value: Variant) -> bool:
	return value is int or value is float


static func _write_u16_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	bytes[offset] = (value >> 8) & 0xff
	bytes[offset + 1] = value & 0xff


static func _has_magic(bytes: PackedByteArray) -> bool:
	return bytes.size() >= 4 \
		and bytes[0] == 0x50 \
		and bytes[1] == 0x43 \
		and bytes[2] == 0x43 \
		and bytes[3] == 0x48


static func _write_u32_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	bytes[offset] = (value >> 24) & 0xff
	bytes[offset + 1] = (value >> 16) & 0xff
	bytes[offset + 2] = (value >> 8) & 0xff
	bytes[offset + 3] = value & 0xff


static func _read_u16_be(bytes: PackedByteArray, offset: int) -> int:
	return (int(bytes[offset]) << 8) | int(bytes[offset + 1])


static func _read_u32_be(bytes: PackedByteArray, offset: int) -> int:
	return (
		(int(bytes[offset]) << 24)
		| (int(bytes[offset + 1]) << 16)
		| (int(bytes[offset + 2]) << 8)
		| int(bytes[offset + 3])
	)


static func _sha256(bytes: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	if context.start(HashingContext.HASH_SHA256) != OK:
		return PackedByteArray()
	if context.update(bytes) != OK:
		return PackedByteArray()
	return context.finish()


static func _failure(message: String) -> Dictionary:
	return {
		"ok": false,
		"error": message,
	}
