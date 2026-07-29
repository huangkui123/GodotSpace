class_name ReconstructionPointCloudPacketFramer
extends RefCounted

## Incrementally separates the TCP byte stream into strict PCCH v1 packets.
## A packet is not returned until the complete codec validation, including its
## body SHA-256, succeeds.

const Codec := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk_codec.gd"
)

const HEADER_SIZE: int = 64
const TOTAL_SIZE_OFFSET: int = 24
const SOCKET_READ_CHUNK_BYTES: int = 1024 * 1024
const MAX_BUFFER_BYTES: int = Codec.MAX_ENCODED_BYTES + SOCKET_READ_CHUNK_BYTES

var _buffer := PackedByteArray()
var _failed := false
var _last_error := ""


func feed(bytes: PackedByteArray) -> Dictionary:
	if _failed:
		return _failure(_last_error)
	if bytes.is_empty():
		return {"ok": true, "packets": [], "error": ""}
	if _buffer.size() + bytes.size() > MAX_BUFFER_BYTES:
		return _fail_and_clear("PCCH receive buffer exceeded its bounded capacity")

	_buffer.append_array(bytes)
	var packets: Array[PackedByteArray] = []
	while true:
		if _buffer.size() < HEADER_SIZE:
			break
		var header_result := inspect_header(_buffer)
		if not bool(header_result.get("ok", false)):
			return _fail_and_clear(str(header_result.get("error", "invalid PCCH header")))
		var total_size := int(header_result.get("total_size", 0))
		if _buffer.size() < total_size:
			break

		var packet := _buffer.slice(0, total_size)
		var decode_result := Codec.decode(packet)
		if not bool(decode_result.get("ok", false)):
			return _fail_and_clear(
				"PCCH packet validation failed: %s" % str(decode_result.get("error", ""))
			)
		packets.append(packet)
		_buffer = _buffer.slice(total_size, _buffer.size())

	return {"ok": true, "packets": packets, "error": ""}


func reset() -> void:
	_buffer = PackedByteArray()
	_failed = false
	_last_error = ""


func has_failed() -> bool:
	return _failed


func get_last_error() -> String:
	return _last_error


func get_buffered_byte_count() -> int:
	return _buffer.size()


static func inspect_header(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < HEADER_SIZE:
		return _failure("PCCH header is incomplete")
	if not _has_magic(bytes):
		return _failure("invalid PCCH magic")
	var version := _read_u16_be(bytes, 4)
	if version != Codec.VERSION:
		return _failure("unsupported PCCH version %d" % version)
	if _read_u16_be(bytes, 6) != HEADER_SIZE:
		return _failure("unexpected PCCH header size")

	var flags := _read_u32_be(bytes, 8)
	if (flags & ~Codec.KNOWN_FLAGS) != 0:
		return _failure("PCCH header contains unknown flags")
	var point_count := _read_u32_be(bytes, 12)
	if point_count <= 0 or point_count > Codec.MAX_POINT_COUNT:
		return _failure("PCCH point count is outside the supported range")
	var metadata_size := _read_u32_be(bytes, 16)
	if metadata_size <= 0 or metadata_size > Codec.MAX_METADATA_BYTES:
		return _failure("PCCH metadata size is outside the supported range")
	var point_data_size := _read_u32_be(bytes, 20)
	if point_data_size <= 0 or point_data_size > Codec.MAX_POINT_DATA_BYTES:
		return _failure("PCCH point payload is outside the supported range")
	var total_size := _read_u32_be(bytes, TOTAL_SIZE_OFFSET)
	if total_size <= HEADER_SIZE or total_size > Codec.MAX_ENCODED_BYTES:
		return _failure("PCCH total size is outside the supported range")
	if _read_u32_be(bytes, 28) != 0:
		return _failure("PCCH reserved header field must be zero")

	var stride := Codec.POSITION_BYTES + Codec.COLOR_BYTES
	if (flags & Codec.FLAG_HAS_CONFIDENCE_U8) != 0:
		stride += Codec.CONFIDENCE_BYTES
	if point_data_size != point_count * stride:
		return _failure("PCCH payload size does not match point count and flags")
	if total_size != HEADER_SIZE + metadata_size + point_data_size:
		return _failure("PCCH section sizes do not match total_size")
	return {
		"ok": true,
		"total_size": total_size,
		"point_count": point_count,
		"flags": flags,
		"error": "",
	}


func _fail_and_clear(message: String) -> Dictionary:
	_failed = true
	_last_error = message
	_buffer = PackedByteArray()
	return _failure(message)


static func _has_magic(bytes: PackedByteArray) -> bool:
	return bytes[0] == 0x50 \
		and bytes[1] == 0x43 \
		and bytes[2] == 0x43 \
		and bytes[3] == 0x48


static func _read_u16_be(bytes: PackedByteArray, offset: int) -> int:
	return (int(bytes[offset]) << 8) | int(bytes[offset + 1])


static func _read_u32_be(bytes: PackedByteArray, offset: int) -> int:
	return (
		(int(bytes[offset]) << 24)
		| (int(bytes[offset + 1]) << 16)
		| (int(bytes[offset + 2]) << 8)
		| int(bytes[offset + 3])
	)


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "packets": [], "error": message}
