extends SceneTree

const BridgeScript := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Network/lingbot_stream_bridge.gd"
)
const Chunk := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk.gd"
)
const Codec := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk_codec.gd"
)
const FrameProtocol := preload(
	"res://Assets/ARSpace/Scripts/SpatialCalibration/anchor_frame_protocol.gd"
)

var _packets: Array[PackedByteArray] = []


func _init() -> void:
	var bridge: Node = BridgeScript.new()
	bridge.point_packet_received.connect(_on_point_packet_received)

	var jpeg := PackedByteArray([0xFF, 0xD8, 0xFF, 0xD9])
	var psa2: PackedByteArray = bridge._encode_psa2(
		9,
		1234,
		320,
		240,
		{"head_pose_available": true},
		jpeg,
	)
	_expect(
		FrameProtocol.read_u32_be(psa2, 0) == FrameProtocol.FRAME_MAGIC_PSA2,
		"PSA2 magic must be encoded",
	)
	_expect(FrameProtocol.read_u32_be(psa2, 4) == 9, "frame id must be encoded")
	_expect(
		FrameProtocol.read_u32_be(psa2, 28) == jpeg.size(),
		"JPEG size must be encoded",
	)

	var chunk = Chunk.create(
		"session-a",
		"map-a",
		"chunk-a",
		PackedVector3Array([Vector3(1.0, 2.0, 3.0)]),
		PackedByteArray([10, 20, 30]),
		PackedByteArray(),
		1000,
		9,
		false,
		Transform3D.IDENTITY,
	)
	var encoded_result := Codec.encode(chunk)
	_expect(bool(encoded_result.get("ok", false)), "fixture PCCH must encode")
	var encoded := encoded_result.get("data", PackedByteArray()) as PackedByteArray
	bridge._output_buffer.append_array(encoded.slice(0, 31))
	_expect(not bridge._try_consume_point_packet(), "partial PCCH header must wait")
	bridge._output_buffer.append_array(encoded.slice(31, encoded.size()))
	_expect(bridge._try_consume_point_packet(), "complete PCCH must parse")
	_expect(_packets.size() == 1 and _packets[0] == encoded, "PCCH bytes must be preserved")

	var invalid := encoded.duplicate()
	invalid[24] = 0x7F
	bridge._output_buffer = invalid
	_expect(not bridge._try_consume_point_packet(), "oversized PCCH must be rejected")
	bridge.free()
	print("LINGBOT_STREAM_BRIDGE_SELF_TEST PASS")
	quit(0)


func _on_point_packet_received(packet: PackedByteArray) -> void:
	_packets.append(packet)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	push_error("LINGBOT_STREAM_BRIDGE_SELF_TEST FAIL: %s" % message)
	quit(1)
