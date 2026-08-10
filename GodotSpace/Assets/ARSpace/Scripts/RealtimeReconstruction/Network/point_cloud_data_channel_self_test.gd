extends SceneTree

const Chunk := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk.gd"
)
const Codec := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk_codec.gd"
)
const Framer := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Network/point_cloud_packet_framer.gd"
)
const PacketQueue := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Network/point_cloud_packet_queue.gd"
)
const DataServer := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Network/point_cloud_data_server.gd"
)
const DataClient := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Network/point_cloud_data_client.gd"
)

var _failures: Array[String] = []


func _init() -> void:
	var first_packet := _encode_packet("chunk-1", 0.0)
	var second_packet := _encode_packet("chunk-2", 2.0)
	if first_packet.is_empty() or second_packet.is_empty():
		_finish()
		return

	_test_framer(first_packet, second_packet)
	_test_queue(first_packet, second_packet)
	_test_server_cache(first_packet, second_packet)
	_test_authorization_handshake()
	_finish()


func _test_framer(first_packet: PackedByteArray, second_packet: PackedByteArray) -> void:
	var framer := Framer.new()
	var first_part := framer.feed(first_packet.slice(0, 17))
	_expect(bool(first_part.get("ok", false)), "fragmented PCCH header must be accepted")
	_expect(
		(first_part.get("packets", []) as Array).is_empty(),
		"fragmented PCCH header must not emit a packet"
	)
	var combined := first_packet.slice(17, first_packet.size())
	combined.append_array(second_packet)
	var completed := framer.feed(combined)
	_expect(bool(completed.get("ok", false)), "two complete PCCH packets must parse")
	var packets := completed.get("packets", []) as Array
	_expect(packets.size() == 2, "framer must emit both coalesced packets")
	if packets.size() == 2:
		_expect(
			(packets[0] as PackedByteArray) == first_packet,
			"framer must preserve first packet bytes"
		)
		_expect(
			(packets[1] as PackedByteArray) == second_packet,
			"framer must preserve second packet bytes"
		)

	var corrupt := first_packet.duplicate()
	corrupt[corrupt.size() - 1] ^= 0x01
	var corrupt_result := Framer.new().feed(corrupt)
	_expect(
		not bool(corrupt_result.get("ok", false)),
		"framer must reject a packet with a bad body SHA-256"
	)

	var oversized := first_packet.duplicate()
	_write_u32_be(oversized, Framer.TOTAL_SIZE_OFFSET, Codec.MAX_ENCODED_BYTES + 1)
	var oversized_result := Framer.new().feed(oversized.slice(0, Framer.HEADER_SIZE))
	_expect(
		not bool(oversized_result.get("ok", false)),
		"framer must reject an oversized declared total_size from the header alone"
	)


func _test_queue(first_packet: PackedByteArray, second_packet: PackedByteArray) -> void:
	var queue := PacketQueue.new()
	_expect(
		queue.configure(first_packet.size() + second_packet.size() - 1),
		"queue must accept a positive byte capacity"
	)
	_expect(queue.enqueue(first_packet), "queue must accept a packet within capacity")
	_expect(
		not queue.enqueue(second_packet),
		"queue must reject a packet that exceeds bounded pending bytes"
	)
	var prefix_size := mini(31, first_packet.size())
	var prefix := queue.peek_slice(prefix_size)
	_expect(prefix == first_packet.slice(0, prefix_size), "queue prefix must be exact")
	_expect(queue.consume(prefix.size()), "queue must consume the written prefix")
	_expect(
		queue.get_pending_byte_count() == first_packet.size() - prefix.size(),
		"queue pending byte accounting must follow partial writes"
	)
	_expect(queue.enqueue(second_packet), "freed queue capacity must be reusable")
	var remaining_first := queue.peek_slice(first_packet.size())
	_expect(
		remaining_first == first_packet.slice(prefix.size(), first_packet.size()),
		"queue must resume the partially written front packet"
	)
	_expect(queue.consume(remaining_first.size()), "front packet remainder must consume")
	_expect(
		queue.peek_slice(second_packet.size()) == second_packet,
		"queue must preserve FIFO packet ordering"
	)


func _test_server_cache(
	first_packet: PackedByteArray,
	second_packet: PackedByteArray
) -> void:
	var server := DataServer.new()
	_expect(
		server.begin_map("session-self-test", "map-self-test") == OK,
		"server cache must begin an explicit map"
	)
	_expect(server.publish_packet(first_packet) == OK, "server must cache a valid PCCH packet")
	_expect(
		server.publish_packet(first_packet) == OK,
		"server cache must treat identical chunk retransmit as idempotent"
	)
	_expect(server.publish_packet(second_packet) == OK, "server must append a second packet")
	var snapshot := server.get_status_snapshot()
	_expect(int(snapshot.get("cached_packets", 0)) == 2, "server must cache two packets")
	_expect(int(snapshot.get("cached_points", 0)) == 4, "server must cache point counts")
	var replay := server.get_cached_packets()
	_expect(
		replay.size() == 2 and replay[0] == first_packet and replay[1] == second_packet,
		"late-join replay snapshot must preserve append order and bytes"
	)
	server.free()


func _test_authorization_handshake() -> void:
	var token := "0123456789abcdef0123456789abcdef"
	var server := DataServer.new()
	_expect(
		server.start_server(8791, "127.0.0.1") == ERR_UNAUTHORIZED,
		"data server must refuse to listen without an authorization token",
	)
	_expect(
		server.set_auth_token(token) == OK,
		"data server must accept a bounded authorization token",
	)
	var handshake := DataClient.build_authentication_packet(token, 23)
	_expect(
		handshake.size() == DataClient.AUTH_HEADER_BYTES + token.length(),
		"data client must build a bounded PCDH handshake",
	)
	_expect(
		DataClient.build_authentication_packet("short", 23).is_empty(),
		"data client must reject a short authorization token",
	)
	_expect(
		DataClient.build_authentication_packet(token, 1).is_empty(),
		"data client must reject the Server ENet peer id",
	)
	server.free()


func _encode_packet(chunk_id: String, x_offset: float) -> PackedByteArray:
	var chunk := Chunk.create(
		"session-self-test",
		"map-self-test",
		chunk_id,
		PackedVector3Array([
			Vector3(x_offset, 0.0, 0.0),
			Vector3(x_offset + 0.25, 0.5, -0.25),
		]),
		PackedByteArray([255, 0, 0, 0, 255, 0]),
		PackedByteArray([255, 192]),
		123456789,
		42,
		true,
		Transform3D(Basis(Quaternion(Vector3.UP, 0.25)), Vector3(1.0, 2.0, 3.0))
	)
	var result := Codec.encode(chunk)
	_expect(bool(result.get("ok", false)), "self-test PCCH packet must encode")
	return result.get("data", PackedByteArray()) as PackedByteArray


func _write_u32_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	bytes[offset] = (value >> 24) & 0xff
	bytes[offset + 1] = (value >> 16) & 0xff
	bytes[offset + 2] = (value >> 8) & 0xff
	bytes[offset + 3] = value & 0xff


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)


func _finish() -> void:
	if _failures.is_empty():
		print("POINT_CLOUD_DATA_CHANNEL_SELF_TEST PASS")
		quit(0)
		return
	for message in _failures:
		push_error("POINT_CLOUD_DATA_CHANNEL_SELF_TEST FAIL: %s" % message)
	quit(1)
