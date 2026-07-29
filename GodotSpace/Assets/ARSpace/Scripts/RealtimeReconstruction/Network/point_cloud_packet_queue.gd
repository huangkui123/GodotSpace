class_name ReconstructionPointCloudPacketQueue
extends RefCounted

## Bounded FIFO used by each point-stream client. It owns immutable packet
## snapshots and exposes only a bounded slice for non-blocking socket writes.

const DEFAULT_MAX_PENDING_BYTES: int = 64 * 1024 * 1024

var _max_pending_bytes := DEFAULT_MAX_PENDING_BYTES
var _packets: Array[PackedByteArray] = []
var _front_offset := 0
var _pending_bytes := 0


func configure(max_pending_bytes: int) -> bool:
	if max_pending_bytes <= 0:
		return false
	_max_pending_bytes = max_pending_bytes
	clear()
	return true


func enqueue(packet: PackedByteArray) -> bool:
	if packet.is_empty() or packet.size() > _max_pending_bytes:
		return false
	if _pending_bytes + packet.size() > _max_pending_bytes:
		return false
	_packets.append(packet.duplicate())
	_pending_bytes += packet.size()
	return true


func peek_slice(max_bytes: int) -> PackedByteArray:
	if _packets.is_empty() or max_bytes <= 0:
		return PackedByteArray()
	var packet := _packets[0]
	var end_offset := mini(packet.size(), _front_offset + max_bytes)
	return packet.slice(_front_offset, end_offset)


func consume(byte_count: int) -> bool:
	if _packets.is_empty() or byte_count < 0:
		return false
	var packet := _packets[0]
	var remaining := packet.size() - _front_offset
	if byte_count > remaining:
		return false
	_front_offset += byte_count
	_pending_bytes -= byte_count
	if _front_offset == packet.size():
		_packets.pop_front()
		_front_offset = 0
	return true


func clear() -> void:
	_packets.clear()
	_front_offset = 0
	_pending_bytes = 0


func is_empty() -> bool:
	return _packets.is_empty()


func get_pending_byte_count() -> int:
	return _pending_bytes


func get_packet_count() -> int:
	return _packets.size()


func get_capacity_bytes() -> int:
	return _max_pending_bytes
