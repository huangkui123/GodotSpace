class_name LingbotStreamBridge
extends Node

## Bridges the shared PICO PSA2 stream to LingBot-Map and receives PCCH chunks.
## Both remote ports are expected to be exposed locally through an SSH tunnel:
##   ssh -N -L 18787:127.0.0.1:8787 -L 18790:127.0.0.1:8790 lab_4090

signal input_connection_changed(is_connected: bool)
signal output_connection_changed(is_connected: bool)
signal point_packet_received(packet: PackedByteArray)
signal status_changed(snapshot: Dictionary)

const FrameProtocol := preload(
	"res://Assets/ARSpace/Scripts/SpatialCalibration/anchor_frame_protocol.gd"
)
const ChunkCodec := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk_codec.gd"
)

const HOST_SETTING := "godot_space/realtime_reconstruction/lab_tunnel_host"
const INPUT_PORT_SETTING := "godot_space/realtime_reconstruction/lab_input_port"
const OUTPUT_PORT_SETTING := "godot_space/realtime_reconstruction/lab_output_port"
const HOST_ENV := "GODOTSPACE_LINGBOT_TUNNEL_HOST"
const INPUT_PORT_ENV := "GODOTSPACE_LINGBOT_INPUT_PORT"
const OUTPUT_PORT_ENV := "GODOTSPACE_LINGBOT_OUTPUT_PORT"
const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_INPUT_PORT := 18787
const DEFAULT_OUTPUT_PORT := 18790
const RETRY_INTERVAL_MSEC := 2000
const MAX_QUEUED_INPUT_FRAMES := 3
const MAX_OUTPUT_BUFFER_BYTES := ChunkCodec.MAX_ENCODED_BYTES * 2
const INPUT_WRITE_SLICE_BYTES := 256 * 1024

@export var auto_connect := false

var _host := DEFAULT_HOST
var _input_port := DEFAULT_INPUT_PORT
var _output_port := DEFAULT_OUTPUT_PORT
var _input_peer: StreamPeerTCP
var _output_peer: StreamPeerTCP
var _input_queue: Array[Dictionary] = []
var _input_ack_buffer := PackedByteArray()
var _output_buffer := PackedByteArray()
var _awaiting_ack_frame_id := -1
var _input_send_packet := PackedByteArray()
var _input_send_offset := 0
var _input_send_frame_id := -1
var _last_connect_attempt_msec := -RETRY_INTERVAL_MSEC
var _forwarding_enabled := false
var _input_connected := false
var _output_connected := false
var _dropped_input_frames := 0
var _received_point_packets := 0
var _last_error := ""


func _ready() -> void:
	add_to_group("lingbot_stream_bridge")
	if not multiplayer.is_server():
		set_process(false)
		return
	_load_configuration()
	set_process(true)
	if auto_connect:
		connect_tunnel()


func _exit_tree() -> void:
	_disconnect_all()


func _process(_delta: float) -> void:
	if not multiplayer.is_server():
		return
	_poll_connections()
	if auto_connect and (not _input_connected or not _output_connected):
		var now := Time.get_ticks_msec()
		if now - _last_connect_attempt_msec >= RETRY_INTERVAL_MSEC:
			connect_tunnel()
	if _input_connected:
		_pump_input_ack()
		_send_next_frame()
	if _output_connected:
		_pump_output_packets()


func connect_tunnel() -> void:
	if not multiplayer.is_server():
		return
	_last_connect_attempt_msec = Time.get_ticks_msec()
	if _input_peer == null or _input_peer.get_status() in [
		StreamPeerTCP.STATUS_NONE,
		StreamPeerTCP.STATUS_ERROR,
	]:
		_input_peer = StreamPeerTCP.new()
		var input_error := _input_peer.connect_to_host(_host, _input_port)
		if input_error != OK:
			_set_error("LingBot input tunnel connect failed: %s" % error_string(input_error))
	if _output_peer == null or _output_peer.get_status() in [
		StreamPeerTCP.STATUS_NONE,
		StreamPeerTCP.STATUS_ERROR,
	]:
		_output_peer = StreamPeerTCP.new()
		var output_error := _output_peer.connect_to_host(_host, _output_port)
		if output_error != OK:
			_set_error("LingBot output tunnel connect failed: %s" % error_string(output_error))
	_emit_status()


func disconnect_tunnel() -> void:
	auto_connect = false
	_disconnect_all()
	_emit_status()


func set_forwarding_enabled(enabled: bool) -> void:
	_forwarding_enabled = enabled
	if not enabled:
		_input_queue.clear()
		_clear_pending_input_write()
		_awaiting_ack_frame_id = -1
		_input_ack_buffer = PackedByteArray()
	_emit_status()


func restart_input_session() -> void:
	# Closing PSA2 is the Lab-side session boundary: LingBot clears its streaming
	# runner/KV state when the input client disconnects.
	_input_queue.clear()
	_clear_pending_input_write()
	_awaiting_ack_frame_id = -1
	_input_ack_buffer = PackedByteArray()
	_drop_input_connection()
	auto_connect = true
	_last_connect_attempt_msec = -RETRY_INTERVAL_MSEC
	connect_tunnel()


func is_ready() -> bool:
	return _input_connected and _output_connected


func enqueue_frame(
	frame_id: int,
	timestamp_ns: int,
	width: int,
	height: int,
	metadata: Dictionary,
	jpeg_bytes: PackedByteArray,
) -> bool:
	if not multiplayer.is_server() or not _forwarding_enabled:
		return false
	if jpeg_bytes.is_empty() or jpeg_bytes.size() > 8 * 1024 * 1024:
		_set_error("Rejected invalid PICO JPEG for LingBot")
		return false
	var packet := _encode_psa2(
		frame_id,
		timestamp_ns,
		width,
		height,
		metadata,
		jpeg_bytes,
	)
	if packet.is_empty():
		return false
	while _input_queue.size() >= MAX_QUEUED_INPUT_FRAMES:
		_input_queue.pop_front()
		_dropped_input_frames += 1
	_input_queue.append({"frame_id": frame_id, "packet": packet})
	_emit_status()
	return true


func get_status_snapshot() -> Dictionary:
	return {
		"host": _host,
		"input_port": _input_port,
		"output_port": _output_port,
		"input_connected": _input_connected,
		"output_connected": _output_connected,
		"ready": is_ready(),
		"forwarding": _forwarding_enabled,
		"queued_input_frames": _input_queue.size(),
		"input_write_bytes_remaining": (
			_input_send_packet.size() - _input_send_offset
		),
		"awaiting_ack_frame_id": _awaiting_ack_frame_id,
		"dropped_input_frames": _dropped_input_frames,
		"received_point_packets": _received_point_packets,
		"last_error": _last_error,
	}


func _load_configuration() -> void:
	_host = str(ProjectSettings.get_setting(HOST_SETTING, DEFAULT_HOST)).strip_edges()
	_input_port = int(ProjectSettings.get_setting(INPUT_PORT_SETTING, DEFAULT_INPUT_PORT))
	_output_port = int(ProjectSettings.get_setting(OUTPUT_PORT_SETTING, DEFAULT_OUTPUT_PORT))
	var host_override := OS.get_environment(HOST_ENV).strip_edges()
	var input_override := OS.get_environment(INPUT_PORT_ENV).strip_edges()
	var output_override := OS.get_environment(OUTPUT_PORT_ENV).strip_edges()
	if host_override != "":
		_host = host_override
	if input_override.is_valid_int():
		_input_port = input_override.to_int()
	if output_override.is_valid_int():
		_output_port = output_override.to_int()
	if _host == "":
		_host = DEFAULT_HOST
	if _input_port <= 0 or _input_port > 65535:
		_input_port = DEFAULT_INPUT_PORT
	if _output_port <= 0 or _output_port > 65535:
		_output_port = DEFAULT_OUTPUT_PORT


func _poll_connections() -> void:
	if _input_peer != null:
		_input_peer.poll()
	if _output_peer != null:
		_output_peer.poll()
	var new_input_connected := (
		_input_peer != null
		and _input_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED
	)
	var new_output_connected := (
		_output_peer != null
		and _output_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED
	)
	if new_input_connected != _input_connected:
		_input_connected = new_input_connected
		if not _input_connected:
			_clear_pending_input_write()
			_awaiting_ack_frame_id = -1
			_input_ack_buffer = PackedByteArray()
			input_connection_changed.emit(false)
		else:
			_last_error = ""
			_input_peer.set_no_delay(true)
			input_connection_changed.emit(true)
		_emit_status()
	if new_output_connected != _output_connected:
		_output_connected = new_output_connected
		if not _output_connected:
			_output_buffer = PackedByteArray()
			output_connection_changed.emit(false)
		else:
			_last_error = ""
			_output_peer.set_no_delay(true)
			output_connection_changed.emit(true)
		_emit_status()


func _send_next_frame() -> void:
	if _awaiting_ack_frame_id >= 0:
		return
	if _input_send_packet.is_empty():
		if _input_queue.is_empty():
			return
		var queued: Dictionary = _input_queue.pop_front() as Dictionary
		_input_send_packet = (
			queued.get("packet", PackedByteArray()) as PackedByteArray
		)
		_input_send_frame_id = int(queued.get("frame_id", -1))
		_input_send_offset = 0
	var write_end := mini(
		_input_send_packet.size(),
		_input_send_offset + INPUT_WRITE_SLICE_BYTES,
	)
	var result := _input_peer.put_partial_data(
		_input_send_packet.slice(_input_send_offset, write_end)
	)
	var error := int(result[0])
	if error != OK:
		_set_error("LingBot input write failed: %s" % error_string(error))
		_drop_input_connection()
		return
	var written := int(result[1])
	if written <= 0:
		return
	_input_send_offset += written
	if _input_send_offset >= _input_send_packet.size():
		_awaiting_ack_frame_id = _input_send_frame_id
		_clear_pending_input_write()
		_emit_status()


func _pump_input_ack() -> void:
	var available := _input_peer.get_available_bytes()
	if available > 0:
		var packet := _input_peer.get_data(available)
		if int(packet[0]) != OK:
			_set_error("LingBot ACK read failed: %s" % error_string(int(packet[0])))
			_drop_input_connection()
			return
		_input_ack_buffer.append_array(packet[1])
	while _input_ack_buffer.size() >= FrameProtocol.ACK_HEADER_SIZE:
		var magic := FrameProtocol.read_u32_be(_input_ack_buffer, 0)
		var frame_id := FrameProtocol.read_u32_be(_input_ack_buffer, 4)
		_input_ack_buffer = _input_ack_buffer.slice(
			FrameProtocol.ACK_HEADER_SIZE,
			_input_ack_buffer.size(),
		)
		if magic != FrameProtocol.ACK_MAGIC_PAA1:
			_set_error("LingBot returned an invalid PAA1 ACK")
			_drop_input_connection()
			return
		if _awaiting_ack_frame_id >= 0 and frame_id != _awaiting_ack_frame_id:
			_set_error("LingBot ACK frame id does not match the pending frame")
			_drop_input_connection()
			return
		_awaiting_ack_frame_id = -1


func _pump_output_packets() -> void:
	var available := _output_peer.get_available_bytes()
	if available > 0:
		if _output_buffer.size() + available > MAX_OUTPUT_BUFFER_BYTES:
			_set_error("LingBot PCCH receive buffer exceeded its limit")
			_drop_output_connection()
			return
		var result := _output_peer.get_data(available)
		if int(result[0]) != OK:
			_set_error("LingBot PCCH read failed: %s" % error_string(int(result[0])))
			_drop_output_connection()
			return
		_output_buffer.append_array(result[1])
	while _try_consume_point_packet():
		pass


func _try_consume_point_packet() -> bool:
	if _output_buffer.size() < ChunkCodec.HEADER_SIZE:
		return false
	if not (
		_output_buffer[0] == 0x50
		and _output_buffer[1] == 0x43
		and _output_buffer[2] == 0x43
		and _output_buffer[3] == 0x48
	):
		_set_error("LingBot PCCH stream lost framing")
		_drop_output_connection()
		return false
	var total_size := _read_u32_be(_output_buffer, 24)
	if total_size < ChunkCodec.HEADER_SIZE or total_size > ChunkCodec.MAX_ENCODED_BYTES:
		_set_error("LingBot PCCH packet declared an invalid size")
		_drop_output_connection()
		return false
	if _output_buffer.size() < total_size:
		return false
	var point_packet := _output_buffer.slice(0, total_size)
	_output_buffer = _output_buffer.slice(total_size, _output_buffer.size())
	_received_point_packets += 1
	point_packet_received.emit(point_packet)
	_emit_status()
	return true


func _encode_psa2(
	frame_id: int,
	timestamp_ns: int,
	width: int,
	height: int,
	metadata: Dictionary,
	jpeg_bytes: PackedByteArray,
) -> PackedByteArray:
	var metadata_bytes := JSON.stringify(metadata).to_utf8_buffer()
	if metadata_bytes.size() > 64 * 1024:
		_set_error("PICO metadata exceeds the LingBot bridge limit")
		return PackedByteArray()
	var packet := PackedByteArray()
	packet.resize(FrameProtocol.FRAME_HEADER_SIZE)
	FrameProtocol.write_u32_be(packet, 0, FrameProtocol.FRAME_MAGIC_PSA2)
	FrameProtocol.write_u32_be(packet, 4, frame_id)
	_write_u64_be(packet, 8, timestamp_ns)
	FrameProtocol.write_u32_be(packet, 16, width)
	FrameProtocol.write_u32_be(packet, 20, height)
	FrameProtocol.write_u32_be(packet, 24, metadata_bytes.size())
	FrameProtocol.write_u32_be(packet, 28, jpeg_bytes.size())
	packet.append_array(metadata_bytes)
	packet.append_array(jpeg_bytes)
	return packet


func _disconnect_all() -> void:
	if _input_peer != null:
		_input_peer.disconnect_from_host()
	if _output_peer != null:
		_output_peer.disconnect_from_host()
	_input_peer = null
	_output_peer = null
	if _input_connected:
		_input_connected = false
		input_connection_changed.emit(false)
	if _output_connected:
		_output_connected = false
		output_connection_changed.emit(false)
	_input_queue.clear()
	_input_ack_buffer = PackedByteArray()
	_output_buffer = PackedByteArray()
	_clear_pending_input_write()
	_awaiting_ack_frame_id = -1


func _drop_input_connection() -> void:
	if _input_peer != null:
		_input_peer.disconnect_from_host()
	_input_peer = null
	if _input_connected:
		_input_connected = false
		input_connection_changed.emit(false)
	_clear_pending_input_write()
	_awaiting_ack_frame_id = -1
	_input_ack_buffer = PackedByteArray()
	_emit_status()


func _drop_output_connection() -> void:
	if _output_peer != null:
		_output_peer.disconnect_from_host()
	_output_peer = null
	if _output_connected:
		_output_connected = false
		output_connection_changed.emit(false)
	_output_buffer = PackedByteArray()
	_emit_status()


func _set_error(message: String) -> void:
	_last_error = message
	_emit_status()


func _clear_pending_input_write() -> void:
	_input_send_packet = PackedByteArray()
	_input_send_offset = 0
	_input_send_frame_id = -1


func _emit_status() -> void:
	status_changed.emit(get_status_snapshot())


func _read_u32_be(bytes: PackedByteArray, offset: int) -> int:
	return (
		(bytes[offset] << 24)
		| (bytes[offset + 1] << 16)
		| (bytes[offset + 2] << 8)
		| bytes[offset + 3]
	)


func _write_u64_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	for index in range(8):
		bytes[offset + index] = (value >> (56 - index * 8)) & 0xFF
