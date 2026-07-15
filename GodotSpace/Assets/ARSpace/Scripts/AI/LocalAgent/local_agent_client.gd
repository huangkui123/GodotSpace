extends Node

signal connection_state_changed(connected: bool)
signal assistant_final_received(request_id: String, answer: String)
signal run_error_received(request_id: String, code: String, message: String)

const PROTOCOL_VERSION := "1.0"
const DEFAULT_ENDPOINT := "ws://127.0.0.1:7861/ws/godot"
const HEARTBEAT_SECONDS := 10.0
const PONG_TIMEOUT_SECONDS := 25.0
const DEFAULT_MAX_MESSAGE_BYTES := 262_144
const MAX_RECONNECT_SECONDS := 30.0
const MAX_CACHED_TOOL_RESULTS := 128
const ToolRegistryScript := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_tool_registry.gd")
const OpenAlbumAdapterScript := preload("res://Assets/ARSpace/Scripts/AI/LocalAgent/open_album_tool_adapter.gd")

var _peer: WebSocketPeer
var _registry: RefCounted
var _session_id := ""
var _client_id := "godotspace-%x" % randi()
var _connected := false
var _hello_sent := false
var _next_connect_msec := 0
var _reconnect_seconds := 1.0
var _last_ping_msec := 0
var _last_pong_msec := 0
var _tool_result_cache: Dictionary = {}
var _last_error := ""
var _last_error_msec := 0


func _ready() -> void:
	_registry = ToolRegistryScript.new()
	_registry.register_tool("open_album", Callable(OpenAlbumAdapterScript.new(), "execute"))
	set_process(true)
	_try_connect()


func _exit_tree() -> void:
	set_process(false)
	if _peer != null:
		_peer.close(1000, "GodotSpace shutdown")
		_peer = null
	_set_connected(false)


func _process(_delta: float) -> void:
	if not _is_enabled():
		_disable_connection()
		return
	if _peer == null:
		if Time.get_ticks_msec() >= _next_connect_msec:
			_try_connect()
		return

	_peer.poll()
	var state := _peer.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _hello_sent:
			_send_hello()
		_drain_packets()
		if _pong_timed_out(Time.get_ticks_msec()):
			_close_with_error(1001, "Gateway heartbeat timed out.")
			return
		_send_heartbeat_if_due()
	elif state == WebSocketPeer.STATE_CLOSED:
		_handle_disconnect()


func is_connected_to_gateway() -> bool:
	return _connected


func get_debug_state() -> Dictionary:
	return {
		"connected": _connected,
		"endpoint": _endpoint_url(),
		"session_id": _session_id,
		"registered_tools": _registry.registered_tools() if _registry != null else PackedStringArray(),
		"cached_tool_result_count": _tool_result_cache.size(),
		"last_error": _last_error,
		"last_error_msec": _last_error_msec,
		"last_pong_msec": _last_pong_msec,
	}


func set_tool_registry_for_test(registry: RefCounted) -> void:
	_registry = registry


func execute_tool_call_for_test(
	tool_call_id: String,
	tool_name: String,
	arguments: Dictionary,
	request_id: String = "request-test"
) -> Dictionary:
	return _resolve_tool_call(request_id, tool_call_id, tool_name, arguments)


func _try_connect() -> void:
	if not _is_enabled():
		return
	_peer = WebSocketPeer.new()
	_peer.inbound_buffer_size = _max_message_bytes() * 2
	_hello_sent = false
	var endpoint := _endpoint_url()
	if endpoint.is_empty():
		_peer = null
		_record_error("Local Agent endpoint URL is empty.")
		_schedule_reconnect()
		return
	var error := _peer.connect_to_url(endpoint)
	if error != OK:
		_peer = null
		_record_error("Unable to connect to Local Agent Gateway: %s" % error_string(error))
		_schedule_reconnect()


func _send_hello() -> void:
	_hello_sent = _send_envelope("hello", {"client_id": _client_id})


func _drain_packets() -> void:
	while _peer != null and _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		if packet.size() > _max_message_bytes():
			_close_with_error(1009, "Gateway message exceeded the configured size limit.")
			return
		if not _peer.was_string_packet():
			_record_error("Gateway sent an unsupported binary message.")
			continue
		var text := packet.get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			_handle_envelope(parsed as Dictionary)
		else:
			_record_error("Gateway sent invalid JSON.")


func _handle_envelope(envelope: Dictionary) -> void:
	if str(envelope.get("protocol_version", "")) != PROTOCOL_VERSION:
		_close_with_error(1002, "Gateway protocol version does not match.")
		return
	var message_type := str(envelope.get("type", ""))
	if message_type == "hello_ack":
		if not _hello_sent or _connected:
			_close_with_error(1002, "Unexpected hello_ack from Gateway.")
			return
		var assigned_session := str(envelope.get("session_id", ""))
		if assigned_session.is_empty():
			_close_with_error(1002, "Gateway hello_ack did not assign a session_id.")
			return
		if not _session_id.is_empty() and assigned_session != _session_id:
			_close_with_error(1008, "Gateway changed the session_id during reconnect.")
			return
		_session_id = assigned_session
		_reconnect_seconds = 1.0
		_last_pong_msec = Time.get_ticks_msec()
		_set_connected(true)
		return

	if not _connected or _session_id.is_empty():
		_close_with_error(1008, "Gateway message arrived before handshake completion.")
		return
	if str(envelope.get("session_id", "")) != _session_id:
		_close_with_error(1008, "Gateway message session_id does not match this connection.")
		return

	if message_type == "tool_call":
		_handle_tool_call(envelope)
	elif message_type == "pong":
		_last_pong_msec = Time.get_ticks_msec()
	elif message_type == "assistant_final":
		var payload := _dictionary(envelope.get("payload", {}))
		assistant_final_received.emit(str(envelope.get("request_id", "")), str(payload.get("answer", "")))
	elif message_type == "run_error":
		var payload := _dictionary(envelope.get("payload", {}))
		run_error_received.emit(
			str(envelope.get("request_id", "")),
			str(payload.get("code", "run_error")),
			str(payload.get("message", "Local Agent run failed."))
		)


func _handle_tool_call(envelope: Dictionary) -> void:
	var request_id := str(envelope.get("request_id", ""))
	var tool_call_id := str(envelope.get("tool_call_id", ""))
	var payload := _dictionary(envelope.get("payload", {}))
	var tool_name := str(payload.get("name", ""))
	var arguments_value: Variant = payload.get("arguments", {})
	var result: Dictionary
	if request_id.is_empty() or tool_call_id.is_empty() or tool_name.is_empty() or typeof(arguments_value) != TYPE_DICTIONARY:
		result = ToolRegistryScript._error("invalid_tool_call", "Malformed tool_call envelope.")
	else:
		result = _resolve_tool_call(request_id, tool_call_id, tool_name, arguments_value as Dictionary)
	_send_envelope("tool_result", result, request_id, tool_call_id)


func _resolve_tool_call(
	request_id: String,
	tool_call_id: String,
	tool_name: String,
	arguments: Dictionary
) -> Dictionary:
	if _tool_result_cache.has(tool_call_id):
		var cached := _tool_result_cache[tool_call_id] as Dictionary
		if str(cached.get("request_id", "")) != request_id or str(cached.get("tool_name", "")) != tool_name:
			return ToolRegistryScript._error(
				"tool_call_conflict",
				"Duplicate tool_call_id does not match its original request_id and tool name."
			)
		return (cached.get("result", {}) as Dictionary).duplicate(true)
	var result: Dictionary = _registry.dispatch(tool_name, arguments) if _registry != null else ToolRegistryScript._error(
		"tool_registry_not_ready", "The Local Agent tool registry is not ready."
	)
	_tool_result_cache[tool_call_id] = {
		"request_id": request_id,
		"tool_name": tool_name,
		"result": result.duplicate(true),
	}
	while _tool_result_cache.size() > MAX_CACHED_TOOL_RESULTS:
		_tool_result_cache.erase(_tool_result_cache.keys()[0])
	return result


func _send_heartbeat_if_due() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_ping_msec >= int(HEARTBEAT_SECONDS * 1000.0):
		_last_ping_msec = now
		_send_envelope("ping", {"client_time_msec": now})


func _pong_timed_out(now_msec: int) -> bool:
	return _connected and now_msec - _last_pong_msec > int(PONG_TIMEOUT_SECONDS * 1000.0)


func _send_envelope(
	message_type: String,
	payload: Dictionary,
	request_id: String = "",
	tool_call_id: String = ""
) -> bool:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	var envelope := {
		"protocol_version": PROTOCOL_VERSION,
		"type": message_type,
		"session_id": _session_id,
		"request_id": request_id,
		"tool_call_id": tool_call_id,
		"timestamp_ms": int(Time.get_unix_time_from_system() * 1000.0),
		"payload": payload,
	}
	var error := _peer.send_text(JSON.stringify(envelope))
	if error != OK:
		_record_error("Unable to send %s to Gateway: %s" % [message_type, error_string(error)])
	return error == OK


func _handle_disconnect() -> void:
	_peer = null
	_hello_sent = false
	_set_connected(false)
	_schedule_reconnect()


func _disable_connection() -> void:
	if _peer != null:
		_peer.close(1000, "Local Agent disabled")
		_peer = null
	_hello_sent = false
	_session_id = ""
	_tool_result_cache.clear()
	_set_connected(false)


func _close_with_error(code: int, message: String) -> void:
	_record_error(message)
	if _peer != null and _peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_peer.close(code, message.left(120))
	_hello_sent = false
	_set_connected(false)


func _record_error(message: String) -> void:
	_last_error = message
	_last_error_msec = Time.get_ticks_msec()


func _schedule_reconnect() -> void:
	_next_connect_msec = Time.get_ticks_msec() + int(_reconnect_seconds * 1000.0)
	_reconnect_seconds = minf(_reconnect_seconds * 2.0, MAX_RECONNECT_SECONDS)


func _set_connected(value: bool) -> void:
	if _connected == value:
		return
	_connected = value
	connection_state_changed.emit(value)


func _is_enabled() -> bool:
	return bool(ProjectSettings.get_setting("arspace/local_agent/enabled", true))


func _endpoint_url() -> String:
	return str(ProjectSettings.get_setting("arspace/local_agent/endpoint_url", DEFAULT_ENDPOINT)).strip_edges()


func _max_message_bytes() -> int:
	return maxi(1024, int(ProjectSettings.get_setting(
		"arspace/local_agent/max_message_bytes", DEFAULT_MAX_MESSAGE_BYTES
	)))


static func _dictionary(value: Variant) -> Dictionary:
	return value as Dictionary if typeof(value) == TYPE_DICTIONARY else {}
