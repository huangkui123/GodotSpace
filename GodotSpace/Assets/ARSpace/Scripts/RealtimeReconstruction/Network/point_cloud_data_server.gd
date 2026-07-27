class_name ReconstructionPointCloudDataServer
extends Node

## PC Server authority for the independent point-cloud TCP channel.
##
## Public API:
## - start_server(port, bind_address)
## - stop_server(reason)
## - begin_map(session_id, map_id)
## - publish_packet(pcch_packet)
## - clear_map_cache()
## - get_status_snapshot()

signal listening_changed(is_listening: bool, port: int)
signal client_connected(client_id: int)
signal client_disconnected(client_id: int, reason: String)
signal packet_published(chunk_id: String, point_count: int, packet_bytes: int)
signal packet_rejected(reason: String)
signal status_changed(status: String)

const Codec := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/PointCloud/point_cloud_chunk_codec.gd"
)
const PacketQueue := preload(
	"res://Assets/ARSpace/Scripts/RealtimeReconstruction/Network/point_cloud_packet_queue.gd"
)

const DEFAULT_PORT: int = 8791
const DEFAULT_BIND_ADDRESS: String = "*"
const MAX_CLIENTS: int = 8
const MAX_CACHE_BYTES: int = 64 * 1024 * 1024
const MAX_CACHE_POINTS: int = 1_000_000
const MAX_CLIENT_PENDING_BYTES: int = MAX_CACHE_BYTES
const SOCKET_WRITE_SLICE_BYTES: int = 64 * 1024
const MAX_WRITE_BYTES_PER_CLIENT_PER_FRAME: int = 1024 * 1024
const SLOW_CLIENT_TIMEOUT_MSEC: int = 10_000
const AUTH_MAGIC: int = 0x50434448 # "PCDH"
const AUTH_VERSION: int = 1
const AUTH_HEADER_BYTES: int = 12
const MAX_AUTH_TOKEN_BYTES: int = 128
const AUTH_TIMEOUT_MSEC: int = 5000
const ROLE_GROUND_VR: String = "ground_vr"
const ROLE_SKY: String = "sky"


class ClientState extends RefCounted:
	var client_id := 0
	var peer: StreamPeerTCP
	var queue
	var last_write_progress_msec := 0
	var auth_buffer := PackedByteArray()
	var auth_deadline_msec := 0
	var authenticated := false
	var enet_peer_id := 0


var _server := TCPServer.new()
var _clients: Array[ClientState] = []
var _next_client_id := 1
var _listen_port := DEFAULT_PORT
var _cache: Array[PackedByteArray] = []
var _chunk_digests: Dictionary = {}
var _cache_bytes := 0
var _cache_points := 0
var _session_id := ""
var _map_id := ""
var _status := "Not started"
var _auth_token := ""
var _network_handler: Node


func _exit_tree() -> void:
	stop_server("")


func _process(_delta: float) -> void:
	while _server.is_connection_available():
		_accept_client()
	for index in range(_clients.size() - 1, -1, -1):
		var error_message := _service_client(_clients[index])
		if not error_message.is_empty():
			_disconnect_client(index, error_message)


func start_server(
	port: int = DEFAULT_PORT,
	bind_address: String = DEFAULT_BIND_ADDRESS
) -> Error:
	if port <= 0 or port > 65535:
		return ERR_INVALID_PARAMETER
	if not _is_valid_auth_token(_auth_token):
		_set_status("Point-cloud data listen rejected: auth token is not configured")
		return ERR_UNAUTHORIZED
	stop_server("")
	var error := _server.listen(port, bind_address)
	if error != OK:
		_set_status("Point-cloud data listen failed: %s" % error_string(error))
		return error
	_listen_port = port
	set_process(true)
	_set_status("Point-cloud data channel listening on %s:%d" % [bind_address, port])
	listening_changed.emit(true, port)
	return OK


func set_auth_token(auth_token: String) -> Error:
	if _server.is_listening():
		return ERR_ALREADY_IN_USE
	if not _is_valid_auth_token(auth_token):
		return ERR_INVALID_PARAMETER
	_auth_token = auth_token
	return OK


func set_network_handler(network_handler: Node) -> void:
	_network_handler = network_handler


func stop_server(reason: String = "Point-cloud data server stopped") -> void:
	var was_listening := _server.is_listening()
	for index in range(_clients.size() - 1, -1, -1):
		_disconnect_client(index, reason)
	if was_listening:
		_server.stop()
		listening_changed.emit(false, _listen_port)
	set_process(false)
	if not reason.is_empty():
		_set_status(reason)


func begin_map(session_id: String, map_id: String) -> Error:
	if not _is_valid_identifier(session_id) or not _is_valid_identifier(map_id):
		return ERR_INVALID_PARAMETER
	clear_map_cache()
	_session_id = session_id
	_map_id = map_id
	return OK


func publish_packet(packet: PackedByteArray) -> Error:
	if packet.is_empty() or packet.size() > Codec.MAX_ENCODED_BYTES:
		return _reject_packet("PCCH publish packet size is invalid", ERR_INVALID_DATA)
	var decode_result := Codec.decode(packet)
	if not bool(decode_result.get("ok", false)):
		return _reject_packet(
			"PCCH publish validation failed: %s" % str(decode_result.get("error", "")),
			ERR_INVALID_DATA
		)
	var chunk = decode_result.get("chunk")
	if chunk == null:
		return _reject_packet("PCCH decoder did not return a chunk", ERR_INVALID_DATA)

	if _session_id.is_empty() and _map_id.is_empty():
		_session_id = chunk.session_id
		_map_id = chunk.map_id
	elif chunk.session_id != _session_id or chunk.map_id != _map_id:
		return _reject_packet(
			"PCCH packet does not belong to the current session/map",
			ERR_INVALID_DATA
		)

	var packet_digest := Codec.sha256_hex(packet)
	if _chunk_digests.has(chunk.chunk_id):
		if str(_chunk_digests[chunk.chunk_id]) == packet_digest:
			return OK
		return _reject_packet(
			"PCCH chunk_id conflicts with an existing packet",
			ERR_ALREADY_EXISTS
		)
	if _cache_bytes + packet.size() > MAX_CACHE_BYTES:
		return _reject_packet("Point-cloud packet cache reached 64 MiB", ERR_OUT_OF_MEMORY)
	if _cache_points + chunk.point_count() > MAX_CACHE_POINTS:
		return _reject_packet("Point-cloud packet cache reached 1,000,000 points", ERR_OUT_OF_MEMORY)

	var stored_packet := packet.duplicate()
	_cache.append(stored_packet)
	_chunk_digests[chunk.chunk_id] = packet_digest
	_cache_bytes += stored_packet.size()
	_cache_points += chunk.point_count()

	for index in range(_clients.size() - 1, -1, -1):
		var client := _clients[index]
		if not client.authenticated:
			continue
		var was_empty: bool = client.queue.is_empty()
		if not client.queue.enqueue(stored_packet):
			_disconnect_client(index, "Point-cloud client is too slow")
		elif was_empty:
			client.last_write_progress_msec = Time.get_ticks_msec()
	packet_published.emit(chunk.chunk_id, chunk.point_count(), stored_packet.size())
	return OK


func clear_map_cache() -> void:
	_cache.clear()
	_chunk_digests.clear()
	_cache_bytes = 0
	_cache_points = 0
	_session_id = ""
	_map_id = ""
	for index in range(_clients.size() - 1, -1, -1):
		_disconnect_client(index, "Point-cloud map changed; reconnect for a fresh snapshot")


func is_listening() -> bool:
	return _server.is_listening()


func get_cached_packets() -> Array[PackedByteArray]:
	var snapshot: Array[PackedByteArray] = []
	for packet in _cache:
		snapshot.append(packet.duplicate())
	return snapshot


func get_status_snapshot() -> Dictionary:
	return {
		"listening": is_listening(),
		"port": _listen_port,
		"client_count": _count_authenticated_clients(),
		"pending_client_count": _clients.size() - _count_authenticated_clients(),
		"authenticated_client_count": _count_authenticated_clients(),
		"session_id": _session_id,
		"map_id": _map_id,
		"cached_packets": _cache.size(),
		"cached_bytes": _cache_bytes,
		"cached_points": _cache_points,
		"max_cache_bytes": MAX_CACHE_BYTES,
		"max_cache_points": MAX_CACHE_POINTS,
		"status": _status,
	}


func _accept_client() -> void:
	var peer := _server.take_connection()
	if peer == null:
		return
	if _clients.size() >= MAX_CLIENTS:
		peer.disconnect_from_host()
		return
	peer.set_no_delay(true)
	var state := ClientState.new()
	state.client_id = _next_client_id
	_next_client_id += 1
	state.peer = peer
	state.queue = PacketQueue.new()
	state.queue.configure(MAX_CLIENT_PENDING_BYTES)
	state.last_write_progress_msec = Time.get_ticks_msec()
	state.auth_deadline_msec = Time.get_ticks_msec() + AUTH_TIMEOUT_MSEC
	_clients.append(state)


func _service_client(client: ClientState) -> String:
	client.peer.poll()
	match client.peer.get_status():
		StreamPeerTCP.STATUS_ERROR:
			return "Point-cloud TCP error"
		StreamPeerTCP.STATUS_NONE:
			return "Point-cloud TCP disconnected"
		StreamPeerTCP.STATUS_CONNECTING:
			return ""

	if not client.authenticated:
		return _service_authentication(client)
	if not _is_authorized_enet_peer(client.enet_peer_id):
		return "Point-cloud client authorization was revoked"
	if client.peer.get_available_bytes() > 0:
		return "Point-cloud data channel is server-to-client only"
	if not client.queue.is_empty() \
		and Time.get_ticks_msec() - client.last_write_progress_msec \
			>= SLOW_CLIENT_TIMEOUT_MSEC:
		return "Point-cloud client write stalled for 10 seconds"
	var write_budget := MAX_WRITE_BYTES_PER_CLIENT_PER_FRAME
	while write_budget > 0 and not client.queue.is_empty():
		var slice_size := mini(SOCKET_WRITE_SLICE_BYTES, write_budget)
		var bytes: PackedByteArray = client.queue.peek_slice(slice_size)
		if bytes.is_empty():
			return "Point-cloud send queue entered an invalid state"
		var result := client.peer.put_partial_data(bytes)
		var error := int(result[0])
		var written := int(result[1])
		if error != OK:
			return "Point-cloud TCP write failed: %s" % error_string(error)
		if written <= 0:
			break
		if not client.queue.consume(written):
			return "Point-cloud send queue accounting failed"
		client.last_write_progress_msec = Time.get_ticks_msec()
		write_budget -= written
	return ""


func _service_authentication(client: ClientState) -> String:
	if Time.get_ticks_msec() >= client.auth_deadline_msec:
		return "Point-cloud client authentication timed out"
	var available := client.peer.get_available_bytes()
	if available > 0:
		var max_remaining := AUTH_HEADER_BYTES + MAX_AUTH_TOKEN_BYTES \
			- client.auth_buffer.size()
		if max_remaining <= 0:
			return "Point-cloud authentication packet is too large"
		var result := client.peer.get_data(mini(available, max_remaining))
		if int(result[0]) != OK:
			return "Point-cloud authentication read failed: %s" % error_string(
				int(result[0])
			)
		client.auth_buffer.append_array(result[1] as PackedByteArray)
	if client.auth_buffer.size() < AUTH_HEADER_BYTES:
		return ""
	if _read_u32_be(client.auth_buffer, 0) != AUTH_MAGIC:
		return "Point-cloud authentication magic is invalid"
	if _read_u16_be(client.auth_buffer, 4) != AUTH_VERSION:
		return "Point-cloud authentication version is unsupported"
	var token_length := _read_u16_be(client.auth_buffer, 6)
	if token_length <= 0 or token_length > MAX_AUTH_TOKEN_BYTES:
		return "Point-cloud authentication token length is invalid"
	var packet_size := AUTH_HEADER_BYTES + token_length
	if client.auth_buffer.size() < packet_size:
		return ""
	var peer_id := _read_u32_be(client.auth_buffer, 8)
	var token := client.auth_buffer.slice(
		AUTH_HEADER_BYTES,
		packet_size
	).get_string_from_utf8()
	if token != _auth_token:
		return "Point-cloud authentication token is invalid"
	if not _is_authorized_enet_peer(peer_id):
		return "Point-cloud client is not an authorized VR peer"
	client.authenticated = true
	client.enet_peer_id = peer_id
	client.auth_buffer.clear()
	for packet in _cache:
		if not client.queue.enqueue(packet):
			return "Point-cloud replay exceeds the client queue capacity"
	client.last_write_progress_msec = Time.get_ticks_msec()
	client_connected.emit(client.client_id)
	return ""


func _disconnect_client(index: int, reason: String) -> void:
	var client := _clients[index]
	_clients.remove_at(index)
	if client.peer != null:
		client.peer.disconnect_from_host()
	client.queue.clear()
	client_disconnected.emit(client.client_id, reason)


func _reject_packet(reason: String, error: Error) -> Error:
	packet_rejected.emit(reason)
	push_warning(reason)
	return error


func _set_status(value: String) -> void:
	if value == _status:
		return
	_status = value
	status_changed.emit(_status)


func _is_valid_identifier(value: String) -> bool:
	var bytes := value.to_utf8_buffer()
	return not bytes.is_empty() and bytes.size() <= 128


func _is_valid_auth_token(value: String) -> bool:
	var bytes := value.to_utf8_buffer()
	return bytes.size() >= 32 and bytes.size() <= MAX_AUTH_TOKEN_BYTES


func _is_authorized_enet_peer(peer_id: int) -> bool:
	if peer_id <= 1:
		return false
	var handler := _network_handler
	if handler == null:
		handler = get_node_or_null("/root/NetworkHandler")
	if handler == null or not handler.has_method("get_peer_role"):
		return false
	return str(handler.call("get_peer_role", peer_id)) in [
		ROLE_GROUND_VR,
		ROLE_SKY,
	]


func _count_authenticated_clients() -> int:
	var count := 0
	for client in _clients:
		if client.authenticated:
			count += 1
	return count


func _read_u16_be(bytes: PackedByteArray, offset: int) -> int:
	return (int(bytes[offset]) << 8) | int(bytes[offset + 1])


func _read_u32_be(bytes: PackedByteArray, offset: int) -> int:
	return (
		(int(bytes[offset]) << 24)
		| (int(bytes[offset + 1]) << 16)
		| (int(bytes[offset + 2]) << 8)
		| int(bytes[offset + 3])
	)
