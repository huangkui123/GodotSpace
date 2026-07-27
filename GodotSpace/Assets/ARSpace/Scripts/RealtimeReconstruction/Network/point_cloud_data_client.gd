class_name ReconstructionPointCloudDataClient
extends Node

## Reconnecting client for the PC Server's independent point-cloud TCP channel.
## Valid PCCH packets are emitted as original bytes so the renderer/map owner
## can decode or persist them without a second wire representation.

signal connection_changed(is_connected: bool)
signal packet_received(packet: PackedByteArray)
signal packet_rejected(reason: String)
signal status_changed(status: String)

const Framer := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Network/point_cloud_packet_framer.gd"
)

const DEFAULT_HOST: String = "127.0.0.1"
const DEFAULT_PORT: int = 8791
const DEFAULT_RECONNECT_DELAY_SECONDS: float = 1.5
const MAX_READ_BYTES_PER_FRAME: int = 4 * 1024 * 1024
const AUTH_MAGIC: int = 0x50434448 # "PCDH"
const AUTH_VERSION: int = 1
const AUTH_HEADER_BYTES: int = 12
const MAX_AUTH_TOKEN_BYTES: int = 128

@export_range(1, 65535, 1) var server_port := DEFAULT_PORT
@export_range(0.1, 30.0, 0.1) var reconnect_delay_seconds := DEFAULT_RECONNECT_DELAY_SECONDS

var _peer: StreamPeerTCP
var _framer := Framer.new()
var _server_host := DEFAULT_HOST
var _should_reconnect := false
var _was_connected := false
var _next_reconnect_msec := 0
var _status := "Not started"
var _auth_token := ""


func _exit_tree() -> void:
	stop_client("")


func _process(_delta: float) -> void:
	if _peer == null:
		if _should_reconnect and Time.get_ticks_msec() >= _next_reconnect_msec:
			_begin_connection()
		return

	_peer.poll()
	match _peer.get_status():
		StreamPeerTCP.STATUS_CONNECTING:
			return
		StreamPeerTCP.STATUS_CONNECTED:
			if not _was_connected:
				var auth_error := _send_authentication()
				if auth_error != OK:
					_disconnect_and_schedule(
						"Point-cloud authentication send failed: %s" % error_string(
							auth_error
						)
					)
					return
				_was_connected = true
				_set_status("Point-cloud data channel connected to %s:%d" % [
					_server_host,
					server_port,
				])
				connection_changed.emit(true)
			_pump_socket()
		StreamPeerTCP.STATUS_ERROR:
			_disconnect_and_schedule("Point-cloud TCP connection error")
		StreamPeerTCP.STATUS_NONE:
			_disconnect_and_schedule("Point-cloud TCP disconnected")


func start_client(
	host: String = "",
	port: int = DEFAULT_PORT,
	auth_token: String = "",
) -> Error:
	if port <= 0 or port > 65535:
		return ERR_INVALID_PARAMETER
	if not auth_token.is_empty():
		_auth_token = auth_token
	if not _is_valid_auth_token(_auth_token):
		return ERR_UNAUTHORIZED
	_server_host = _resolve_server_host(host)
	if _server_host.is_empty():
		return ERR_INVALID_PARAMETER
	server_port = port
	_should_reconnect = true
	_next_reconnect_msec = 0
	set_process(true)
	return _begin_connection()


func stop_client(reason: String = "Point-cloud data client stopped") -> void:
	_should_reconnect = false
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	_framer.reset()
	if _was_connected:
		_was_connected = false
		connection_changed.emit(false)
	set_process(false)
	if not reason.is_empty():
		_set_status(reason)


func is_connected_to_server() -> bool:
	return _peer != null \
		and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED \
		and _was_connected


func get_status_snapshot() -> Dictionary:
	return {
		"connected": is_connected_to_server(),
		"host": _server_host,
		"port": server_port,
		"reconnect_enabled": _should_reconnect,
		"authenticated": _was_connected,
		"buffered_bytes": _framer.get_buffered_byte_count(),
		"status": _status,
	}


func _begin_connection() -> Error:
	if not _should_reconnect:
		return ERR_UNAVAILABLE
	if _peer != null:
		_peer.disconnect_from_host()
	_peer = StreamPeerTCP.new()
	_framer.reset()
	_was_connected = false
	var error := _peer.connect_to_host(_server_host, server_port)
	if error != OK:
		_peer = null
		_schedule_reconnect()
		_set_status("Point-cloud TCP connect failed: %s" % error_string(error))
		return error
	_set_status("Connecting to point-cloud data channel %s:%d" % [
		_server_host,
		server_port,
	])
	return OK


func _pump_socket() -> void:
	var remaining_budget := MAX_READ_BYTES_PER_FRAME
	while remaining_budget > 0:
		var available := _peer.get_available_bytes()
		if available <= 0:
			return
		var read_size := mini(
			available,
			mini(Framer.SOCKET_READ_CHUNK_BYTES, remaining_budget)
		)
		var result := _peer.get_data(read_size)
		if int(result[0]) != OK:
			_disconnect_and_schedule(
				"Point-cloud TCP read failed: %s" % error_string(int(result[0]))
			)
			return
		remaining_budget -= read_size
		var frame_result := _framer.feed(result[1])
		if not bool(frame_result.get("ok", false)):
			var reason := str(frame_result.get("error", "Invalid PCCH packet"))
			packet_rejected.emit(reason)
			_disconnect_and_schedule(reason)
			return
		var packets: Array = frame_result.get("packets", [])
		for packet in packets:
			packet_received.emit(packet as PackedByteArray)


func _send_authentication() -> Error:
	if not _is_valid_auth_token(_auth_token):
		return ERR_UNAUTHORIZED
	var packet := build_authentication_packet(
		_auth_token,
		multiplayer.get_unique_id(),
	)
	if packet.is_empty():
		return ERR_INVALID_PARAMETER
	return _peer.put_data(packet)


static func build_authentication_packet(
	auth_token: String,
	enet_peer_id: int,
) -> PackedByteArray:
	var token_bytes := auth_token.to_utf8_buffer()
	if token_bytes.size() < 32 \
			or token_bytes.size() > MAX_AUTH_TOKEN_BYTES \
			or enet_peer_id <= 1:
		return PackedByteArray()
	var packet := PackedByteArray()
	packet.resize(AUTH_HEADER_BYTES + token_bytes.size())
	_write_u32_be(packet, 0, AUTH_MAGIC)
	_write_u16_be(packet, 4, AUTH_VERSION)
	_write_u16_be(packet, 6, token_bytes.size())
	_write_u32_be(packet, 8, enet_peer_id)
	for index in token_bytes.size():
		packet[AUTH_HEADER_BYTES + index] = token_bytes[index]
	return packet


func _disconnect_and_schedule(reason: String) -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null
	_framer.reset()
	if _was_connected:
		_was_connected = false
		connection_changed.emit(false)
	_set_status(reason)
	_schedule_reconnect()


func _schedule_reconnect() -> void:
	if not _should_reconnect:
		return
	_next_reconnect_msec = Time.get_ticks_msec() \
		+ int(reconnect_delay_seconds * 1000.0)


func _resolve_server_host(explicit_host: String) -> String:
	var stripped := explicit_host.strip_edges()
	if not stripped.is_empty():
		return stripped
	for argument in OS.get_cmdline_args():
		if argument.begins_with("--server-ip="):
			var value := argument.get_slice("=", 1).strip_edges()
			if not value.is_empty():
				return value
	return DEFAULT_HOST


func _set_status(value: String) -> void:
	if value == _status:
		return
	_status = value
	status_changed.emit(_status)


func _is_valid_auth_token(value: String) -> bool:
	var bytes := value.to_utf8_buffer()
	return bytes.size() >= 32 and bytes.size() <= MAX_AUTH_TOKEN_BYTES


static func _write_u16_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	bytes[offset] = (value >> 8) & 0xff
	bytes[offset + 1] = value & 0xff


static func _write_u32_be(bytes: PackedByteArray, offset: int, value: int) -> void:
	bytes[offset] = (value >> 24) & 0xff
	bytes[offset + 1] = (value >> 16) & 0xff
	bytes[offset + 2] = (value >> 8) & 0xff
	bytes[offset + 3] = value & 0xff
