extends Node

signal connection_state_changed(connected: bool)
signal assistant_final_received(request_id: String, answer: String)
signal run_error_received(request_id: String, code: String, message: String)

const PROTOCOL_VERSION := "1.0"
const DEFAULT_ENDPOINT := "ws://127.0.0.1:7861/ws/godot"
const HEARTBEAT_SECONDS := 10.0
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
var _tool_result_cache: Dictionary = {}


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
	}


func set_tool_registry_for_test(registry: RefCounted) -> void:
	_registry = registry


func execute_tool_call_for_test(tool_call_id: String, tool_name: String, arguments: Dictionary) -> Dictionary:
	return _resolve_tool_call(tool_call_id, tool_name, arguments)


func _try_connect() -> void:
	if not _is_enabled():
		return
	_peer = WebSocketPeer.new()
	_hello_sent = false
	var error := _peer.connect_to_url(_endpoint_url())
	if error != OK:
		_peer = null
		_schedule_reconnect()


func _send_hello() -> void:
	_hello_sent = _send_envelope("hello", {"client_id": _client_id})


func _drain_packets() -> void:
	while _peer != null and _peer.get_available_packet_count() > 0:
		var packet := _peer.get_packet()
		if not _peer.was_string_packet():
			continue
		var text := packet.get_string_from_utf8()
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) == TYPE_DICTIONARY:
			_handle_envelope(parsed as Dictionary)


func _handle_envelope(envelope: Dictionary) -> void:
	if str(envelope.get("protocol_version", "")) != PROTOCOL_VERSION:
		return
	var message_type := str(envelope.get("type", ""))
	if message_type == "hello_ack":
		var assigned_session := str(envelope.get("session_id", ""))
		if assigned_session.is_empty():
			return
		_session_id = assigned_session
		_reconnect_seconds = 1.0
		_set_connected(true)
	elif message_type == "tool_call":
		_handle_tool_call(envelope)
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
		result = _resolve_tool_call(tool_call_id, tool_name, arguments_value as Dictionary)
	_send_envelope("tool_result", result, request_id, tool_call_id)


func _resolve_tool_call(tool_call_id: String, tool_name: String, arguments: Dictionary) -> Dictionary:
	if _tool_result_cache.has(tool_call_id):
		return (_tool_result_cache[tool_call_id] as Dictionary).duplicate(true)
	var result: Dictionary = _registry.dispatch(tool_name, arguments) if _registry != null else ToolRegistryScript._error(
		"tool_registry_not_ready", "The Local Agent tool registry is not ready."
	)
	_tool_result_cache[tool_call_id] = result.duplicate(true)
	while _tool_result_cache.size() > MAX_CACHED_TOOL_RESULTS:
		_tool_result_cache.erase(_tool_result_cache.keys()[0])
	return result


func _send_heartbeat_if_due() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_ping_msec >= int(HEARTBEAT_SECONDS * 1000.0):
		_last_ping_msec = now
		_send_envelope("ping", {"client_time_msec": now})


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
	return _peer.send_text(JSON.stringify(envelope)) == OK


func _handle_disconnect() -> void:
	_peer = null
	_hello_sent = false
	_set_connected(false)
	_schedule_reconnect()


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


static func _dictionary(value: Variant) -> Dictionary:
	return value as Dictionary if typeof(value) == TYPE_DICTIONARY else {}
