class_name AnchorFrameProtocol
extends RefCounted

const FRAME_MAGIC_PSA2 := 0x50534132
const ACK_MAGIC_PAA1 := 0x50414131
const FRAME_HEADER_SIZE := 32
const ACK_HEADER_SIZE := 8


static func read_u32_be(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3]


static func read_u64_be(bytes: PackedByteArray, offset: int) -> int:
	var value: int = 0
	for index in range(8):
		value = (value << 8) | bytes[offset + index]
	return value


static func write_u32_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	bytes[offset] = (value >> 24) & 0xFF
	bytes[offset + 1] = (value >> 16) & 0xFF
	bytes[offset + 2] = (value >> 8) & 0xFF
	bytes[offset + 3] = value & 0xFF
