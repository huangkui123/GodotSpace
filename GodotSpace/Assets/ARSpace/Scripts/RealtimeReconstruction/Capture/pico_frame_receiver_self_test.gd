extends SceneTree

const ReceiverScript := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Capture/pico_frame_receiver.gd"
)
const FrameProtocol := preload(
	"res://Assets/ARSpace/Scripts/SpatialCalibration/anchor_frame_protocol.gd"
)

var _received_frames: Array[Dictionary] = []


func _init() -> void:
	var receiver: Node = ReceiverScript.new()
	receiver.frame_received.connect(_on_frame_received)
	var packet := _build_frame_packet()

	receiver._receive_buffer.append_array(packet.slice(0, 17))
	_expect(not receiver._try_consume_frame(), "fragmented header must wait")
	receiver._receive_buffer.append_array(packet.slice(17, packet.size()))
	_expect(receiver._try_consume_frame(), "complete frame must be consumed")
	_expect(_received_frames.size() == 1, "one frame must be emitted")
	_expect(int(_received_frames[0]["frame_id"]) == 42, "frame id must round-trip")
	_expect(
		str((_received_frames[0]["metadata"] as Dictionary).get("camera", "")) == "rgb",
		"metadata JSON must round-trip",
	)
	_expect(
		(_received_frames[0]["jpeg"] as PackedByteArray) == PackedByteArray([1, 2, 3, 4]),
		"payload must round-trip",
	)

	receiver._receive_buffer = PackedByteArray([0, 1, 2, 3, 4])
	receiver._receive_buffer.append_array(packet)
	_expect(receiver._try_consume_frame(), "parser must resynchronize to PSA2 magic")
	_expect(receiver._try_consume_frame(), "resynchronized frame must be consumed")
	_expect(_received_frames.size() == 2, "resynchronized frame must be emitted")
	_expect(
		receiver._is_helper_host_allowed("192.0.2.10"),
		"empty helper allowlist must preserve trusted-LAN compatibility",
	)
	receiver._allowed_helper_host = "192.0.2.10"
	_expect(
		receiver._is_helper_host_allowed("192.0.2.10"),
		"configured helper host must be accepted",
	)
	_expect(
		not receiver._is_helper_host_allowed("192.0.2.11"),
		"non-allowlisted helper host must be rejected",
	)

	receiver.free()
	print("PICO_FRAME_RECEIVER_SELF_TEST PASS")
	quit(0)


func _on_frame_received(
	frame_id: int,
	timestamp_ns: int,
	width: int,
	height: int,
	metadata: Dictionary,
	jpeg_bytes: PackedByteArray,
) -> void:
	_received_frames.append({
		"frame_id": frame_id,
		"timestamp_ns": timestamp_ns,
		"width": width,
		"height": height,
		"metadata": metadata,
		"jpeg": jpeg_bytes,
	})


func _build_frame_packet() -> PackedByteArray:
	var metadata := JSON.stringify({"camera": "rgb"}).to_utf8_buffer()
	var jpeg := PackedByteArray([1, 2, 3, 4])
	var packet := PackedByteArray()
	packet.resize(FrameProtocol.FRAME_HEADER_SIZE + metadata.size() + jpeg.size())
	FrameProtocol.write_u32_be(packet, 0, FrameProtocol.FRAME_MAGIC_PSA2)
	FrameProtocol.write_u32_be(packet, 4, 42)
	_write_u64_be(packet, 8, 123456789)
	FrameProtocol.write_u32_be(packet, 16, 640)
	FrameProtocol.write_u32_be(packet, 20, 480)
	FrameProtocol.write_u32_be(packet, 24, metadata.size())
	FrameProtocol.write_u32_be(packet, 28, jpeg.size())
	for index in range(metadata.size()):
		packet[FrameProtocol.FRAME_HEADER_SIZE + index] = metadata[index]
	for index in range(jpeg.size()):
		packet[FrameProtocol.FRAME_HEADER_SIZE + metadata.size() + index] = jpeg[index]
	return packet


func _write_u64_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	for index in range(8):
		bytes[offset + index] = (value >> (56 - index * 8)) & 0xFF


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("PICO_FRAME_RECEIVER_SELF_TEST FAIL: %s" % message)
	quit(1)
