class_name PicoFrameReceiver
extends Node

## Owns the single PICO helper TCP listener used by both spatial calibration and
## realtime reconstruction. Consumers subscribe to [signal frame_received]
## instead of opening a second listener on port 8787.

signal listening_changed(is_listening: bool, port: int)
signal connection_changed(is_connected: bool)
signal frame_received(
	frame_id: int,
	timestamp_ns: int,
	width: int,
	height: int,
	metadata: Dictionary,
	jpeg_bytes: PackedByteArray,
)
signal status_changed(status: String)
signal stats_changed(snapshot: Dictionary)

const FrameProtocol := preload(
	"res://Assets/ARSpace/Scripts/SpatialCalibration/anchor_frame_protocol.gd"
)

const DEFAULT_PORT := 8787
const ALLOWED_HOST_SETTING := "godot_space/realtime_reconstruction/pico_helper_allowed_host"
const ALLOWED_HOST_ENV := "GODOTSPACE_PICO_HELPER_ALLOWED_HOST"
const MAX_FRAME_BYTES := 8 * 1024 * 1024
const MAX_METADATA_BYTES := 64 * 1024
const MAX_FRAME_PACKET_BYTES := (
	MAX_FRAME_BYTES + MAX_METADATA_BYTES + FrameProtocol.FRAME_HEADER_SIZE
)
const MAX_RECEIVE_BUFFER_BYTES := MAX_FRAME_PACKET_BYTES * 2

@export_range(1, 65535, 1) var listen_port := DEFAULT_PORT
@export var auto_start := true

var _server := TCPServer.new()
var _client: StreamPeerTCP
var _receive_buffer := PackedByteArray()
var _ack_buffer := PackedByteArray()
var _last_received_frame_id := -1
var _last_frame_id := -1
var _last_frame_size := Vector2i.ZERO
var _frames_this_second := 0
var _dropped_frames_this_second := 0
var _display_fps := 0.0
var _display_dropped_frames := 0
var _fps_tick_ms := 0
var _status := "Not started"
var _allowed_helper_host := ""


func _ready() -> void:
	add_to_group("pico_frame_receiver")
	_ack_buffer.resize(FrameProtocol.ACK_HEADER_SIZE)
	_allowed_helper_host = str(ProjectSettings.get_setting(
		ALLOWED_HOST_SETTING,
		"",
	)).strip_edges()
	var allowed_host_override := OS.get_environment(ALLOWED_HOST_ENV).strip_edges()
	if not allowed_host_override.is_empty():
		_allowed_helper_host = allowed_host_override
	if not multiplayer.is_server():
		set_process(false)
		_set_status("PICO frame receiver is available on the server only")
		return
	set_process(true)
	if auto_start:
		start_listening(listen_port)


func _exit_tree() -> void:
	stop_listening("")


func _process(_delta: float) -> void:
	if _server.is_connection_available():
		_accept_client()

	if _client != null:
		match _client.get_status():
			StreamPeerTCP.STATUS_CONNECTED:
				_pump_socket()
			StreamPeerTCP.STATUS_ERROR:
				_disconnect_client("PICO helper connection error")
			StreamPeerTCP.STATUS_NONE:
				_disconnect_client("PICO helper disconnected")
	_update_fps_stats()


func start_listening(port: int = DEFAULT_PORT) -> Error:
	if not multiplayer.is_server():
		_set_status("Only the server can listen for the PICO helper")
		return ERR_UNAUTHORIZED
	if port <= 0 or port > 65535:
		_set_status("Invalid PICO helper port: %d" % port)
		return ERR_INVALID_PARAMETER

	stop_listening("")
	var error := _server.listen(port)
	if error != OK:
		_set_status("Failed to listen on port %d: %s" % [port, error_string(error)])
		_emit_stats()
		return error

	listen_port = port
	_set_status("Listening for PICO helper on port %d" % port)
	listening_changed.emit(true, listen_port)
	_emit_stats()
	return OK


func stop_listening(reason: String = "PICO helper listener stopped") -> void:
	var was_listening := _server.is_listening()
	_disconnect_client("")
	if was_listening:
		_server.stop()
		listening_changed.emit(false, listen_port)
	if reason != "":
		_set_status(reason)
	_emit_stats()


func is_listening() -> bool:
	return _server.is_listening()


func is_helper_connected() -> bool:
	return _client != null and _client.get_status() == StreamPeerTCP.STATUS_CONNECTED


func get_status_snapshot() -> Dictionary:
	return {
		"listening": is_listening(),
		"connected": is_helper_connected(),
		"port": listen_port,
		"status": _status,
		"last_frame_id": _last_frame_id,
		"last_frame_width": _last_frame_size.x,
		"last_frame_height": _last_frame_size.y,
		"fps": _display_fps,
		"dropped_frames": _display_dropped_frames,
		"allowed_helper_host": _allowed_helper_host,
	}


func get_local_addresses() -> Array[String]:
	var addresses: Array[String] = []
	for address in IP.get_local_addresses():
		if "." in address and not address.begins_with("127.") and not address.begins_with("169.254."):
			addresses.append("%s:%d" % [address, listen_port])
	return addresses


func _accept_client() -> void:
	var candidate := _server.take_connection()
	if candidate == null:
		return
	if _client != null \
			and _client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		candidate.disconnect_from_host()
		_set_status("Rejected a second PICO helper while the active helper is connected")
		return
	var candidate_host := candidate.get_connected_host()
	if not _is_helper_host_allowed(candidate_host):
		candidate.disconnect_from_host()
		_set_status("Rejected PICO helper from non-allowlisted host")
		return
	_disconnect_client("")
	_client = candidate
	_receive_buffer = PackedByteArray()
	_client.set_no_delay(true)
	_set_status("PICO helper connected; waiting for frames")
	connection_changed.emit(true)
	_emit_stats()


func _disconnect_client(reason: String) -> void:
	var was_connected := _client != null
	if _client != null:
		_client.disconnect_from_host()
		_client = null
	_receive_buffer = PackedByteArray()
	_last_received_frame_id = -1
	if was_connected:
		connection_changed.emit(false)
	if reason != "":
		_set_status(reason)
	_emit_stats()


func _pump_socket() -> void:
	var available := _client.get_available_bytes()
	if available <= 0:
		return
	if _receive_buffer.size() + available > MAX_RECEIVE_BUFFER_BYTES:
		_disconnect_client("PICO receive buffer exceeded its bounded limit")
		return

	var packet := _client.get_data(available)
	if int(packet[0]) != OK:
		_disconnect_client("PICO helper read failed: %s" % error_string(int(packet[0])))
		return

	_receive_buffer.append_array(packet[1])
	while _try_consume_frame():
		pass


func _try_consume_frame() -> bool:
	if _receive_buffer.size() < FrameProtocol.FRAME_HEADER_SIZE:
		return false

	if FrameProtocol.read_u32_be(_receive_buffer, 0) != FrameProtocol.FRAME_MAGIC_PSA2:
		_resync_buffer()
		return _receive_buffer.size() >= FrameProtocol.FRAME_HEADER_SIZE

	var metadata_size := FrameProtocol.read_u32_be(_receive_buffer, 24)
	var payload_size := FrameProtocol.read_u32_be(_receive_buffer, 28)
	if metadata_size > MAX_METADATA_BYTES:
		_disconnect_client("PICO frame declared oversized metadata")
		return false
	if payload_size <= 0 or payload_size > MAX_FRAME_BYTES:
		_disconnect_client("PICO frame declared an invalid JPEG payload")
		return false

	var total_size := FrameProtocol.FRAME_HEADER_SIZE + metadata_size + payload_size
	if total_size > MAX_FRAME_PACKET_BYTES:
		_disconnect_client("PICO frame exceeded its bounded packet limit")
		return false
	if _receive_buffer.size() < total_size:
		return false

	var frame_id := FrameProtocol.read_u32_be(_receive_buffer, 4)
	var timestamp_ns := FrameProtocol.read_u64_be(_receive_buffer, 8)
	var width := FrameProtocol.read_u32_be(_receive_buffer, 16)
	var height := FrameProtocol.read_u32_be(_receive_buffer, 20)
	if _last_received_frame_id >= 0 and frame_id > _last_received_frame_id + 1:
		_dropped_frames_this_second += frame_id - _last_received_frame_id - 1
	_last_received_frame_id = frame_id

	var metadata: Dictionary = {}
	if metadata_size > 0:
		var metadata_bytes := _receive_buffer.slice(
			FrameProtocol.FRAME_HEADER_SIZE,
			FrameProtocol.FRAME_HEADER_SIZE + metadata_size,
		)
		metadata = _parse_metadata(metadata_bytes)
	var jpeg_bytes := _receive_buffer.slice(
		FrameProtocol.FRAME_HEADER_SIZE + metadata_size,
		total_size,
	)
	_receive_buffer = _receive_buffer.slice(total_size, _receive_buffer.size())

	_send_ack(frame_id)
	_last_frame_id = frame_id
	_last_frame_size = Vector2i(width, height)
	_frames_this_second += 1
	frame_received.emit(frame_id, timestamp_ns, width, height, metadata, jpeg_bytes)
	_emit_stats()
	return true


func _send_ack(frame_id: int) -> void:
	if _client == null:
		return
	FrameProtocol.write_u32_be(_ack_buffer, 0, FrameProtocol.ACK_MAGIC_PAA1)
	FrameProtocol.write_u32_be(_ack_buffer, 4, frame_id)
	var error := _client.put_data(_ack_buffer)
	if error != OK:
		_disconnect_client("PICO helper ACK failed: %s" % error_string(error))


func _resync_buffer() -> void:
	for index in range(1, _receive_buffer.size() - 3):
		if FrameProtocol.read_u32_be(_receive_buffer, index) == FrameProtocol.FRAME_MAGIC_PSA2:
			_receive_buffer = _receive_buffer.slice(index, _receive_buffer.size())
			return
	_receive_buffer = PackedByteArray()


func _parse_metadata(metadata_bytes: PackedByteArray) -> Dictionary:
	var json := JSON.new()
	var error := json.parse(metadata_bytes.get_string_from_utf8())
	if error != OK:
		_set_status("PICO metadata JSON parse failed: %s" % error_string(error))
		return {}
	if typeof(json.data) != TYPE_DICTIONARY:
		_set_status("PICO metadata must be a JSON object")
		return {}
	return json.data


func _update_fps_stats() -> void:
	var now_ms := Time.get_ticks_msec()
	if _fps_tick_ms == 0:
		_fps_tick_ms = now_ms
		return
	if now_ms - _fps_tick_ms < 1000:
		return

	_display_fps = _frames_this_second * 1000.0 / float(now_ms - _fps_tick_ms)
	_display_dropped_frames = _dropped_frames_this_second
	_frames_this_second = 0
	_dropped_frames_this_second = 0
	_fps_tick_ms = now_ms
	_emit_stats()


func _set_status(value: String) -> void:
	if value == _status:
		return
	_status = value
	status_changed.emit(_status)


func _is_helper_host_allowed(candidate_host: String) -> bool:
	return _allowed_helper_host.is_empty() \
		or candidate_host.strip_edges() == _allowed_helper_host


func _emit_stats() -> void:
	stats_changed.emit(get_status_snapshot())
