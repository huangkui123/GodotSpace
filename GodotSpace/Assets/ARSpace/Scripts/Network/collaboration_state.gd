extends Node

const Schema = preload("res://Assets/ARSpace/Scripts/Network/collaboration_state_schema.gd")

signal state_changed(domain: String, operation: String, entity_id: String, session_revision: int, domain_revision: int)
signal snapshot_applied(session_revision: int, domain_revisions: Dictionary)
signal request_completed(result: Dictionary)
signal operation_rejected(error: String)
signal session_cleared()

const SERVER_PEER_ID: int = 1
const MAX_CACHED_REQUESTS_PER_PEER: int = 64
const SNAPSHOT_REQUEST_INTERVAL_MSEC: int = 250

@export_node_path("Node") var peer_authority_path := NodePath("/root/NetworkHandler")

var _state: Dictionary = Schema.make_default_state()
var _session_revision: int = 0
var _domain_revisions: Dictionary = Schema.make_default_domain_revisions()
var _next_request_sequence: int = 1
var _next_stroke_id: int = 1
var _next_model_id: int = 1
var _recent_client_requests: Dictionary = {}
var _peer_highest_sequences: Dictionary = {}
var _peer_request_cache: Dictionary = {}
var _peer_request_order: Dictionary = {}
var _peer_snapshot_request_msec: Dictionary = {}


func _ready() -> void:
	_connect_multiplayer_signals()
	_connect_authority_signals()
	if _is_connected_client():
		_clear_local_session()
		call_deferred("request_snapshot")


func _exit_tree() -> void:
	_disconnect_multiplayer_signals()
	_disconnect_authority_signals()


func get_state() -> Dictionary:
	return _state.duplicate(true)


func get_domain_state(domain: String) -> Variant:
	return _state.get(domain, null).duplicate(true) if _state.get(domain, null) is Dictionary else _state.get(domain, null)


func get_session_revision() -> int:
	return _session_revision


func get_domain_revisions() -> Dictionary:
	return _domain_revisions.duplicate(true)


func get_domain_revision(domain: String) -> int:
	return int(_domain_revisions.get(domain, 0))


func request_change(domain: String, operation: String, payload: Variant) -> int:
	var request_sequence := _next_request_sequence
	_next_request_sequence += 1
	var request := {
		"domain": domain,
		"operation": operation,
		"payload": payload.duplicate(true) if payload is Dictionary or payload is Array else payload,
	}
	_remember_client_request(request_sequence, request)
	if _is_server_authority():
		var result := _process_server_request(SERVER_PEER_ID, request_sequence, domain, operation, payload)
		_deliver_result_locally(result)
		return request_sequence
	if not _is_connected_client():
		_deliver_result_locally(_make_result(false, request_sequence, domain, operation, "", "not_connected"))
		return request_sequence
	rpc_id(SERVER_PEER_ID, "_server_request_change", request_sequence, domain, operation, payload)
	return request_sequence


func retry_request(request_sequence: int) -> bool:
	if not _recent_client_requests.has(request_sequence):
		return false
	var request := _recent_client_requests[request_sequence] as Dictionary
	if _is_server_authority():
		var result := _process_server_request(
			SERVER_PEER_ID,
			request_sequence,
			str(request["domain"]),
			str(request["operation"]),
			request["payload"]
		)
		_deliver_result_locally(result)
		return true
	if not _is_connected_client():
		return false
	rpc_id(
		SERVER_PEER_ID,
		"_server_request_change",
		request_sequence,
		str(request["domain"]),
		str(request["operation"]),
		request["payload"]
	)
	return true


func request_snapshot() -> void:
	if not _is_connected_client():
		return
	rpc_id(SERVER_PEER_ID, "_server_request_snapshot")


func reset_session() -> bool:
	if not _is_server_authority():
		return false
	_clear_all_state()
	if multiplayer.has_multiplayer_peer():
		rpc("_client_reset_session")
		call_deferred("_broadcast_snapshot")
	return true


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_change(
	request_sequence: int,
	domain: String,
	operation: String,
	payload: Variant
) -> void:
	if not _is_server_authority():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		return
	var result := _process_server_request(sender_id, request_sequence, domain, operation, payload)
	rpc_id(sender_id, "_client_receive_result", result)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_snapshot() -> void:
	if not _is_server_authority():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		return
	var now := Time.get_ticks_msec()
	var last_request := int(_peer_snapshot_request_msec.get(sender_id, -SNAPSHOT_REQUEST_INTERVAL_MSEC))
	if now - last_request < SNAPSHOT_REQUEST_INTERVAL_MSEC:
		return
	_peer_snapshot_request_msec[sender_id] = now
	_send_snapshot(sender_id)


@rpc("authority", "call_remote", "reliable", 0)
func _client_receive_result(result: Dictionary) -> void:
	if multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	_deliver_result_locally(result)


@rpc("authority", "call_remote", "reliable", 0)
func _client_receive_snapshot(envelope: Dictionary) -> void:
	if multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	_apply_snapshot_envelope(envelope)


@rpc("authority", "call_remote", "reliable", 0)
func _client_reset_session() -> void:
	if multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	_clear_local_session()


func _process_server_request(
	peer_id: int,
	request_sequence: int,
	domain: String,
	operation: String,
	payload: Variant
) -> Dictionary:
	if request_sequence <= 0:
		return _make_result(false, request_sequence, domain, operation, "", "invalid_request_sequence")
	# Validate the complete envelope before serializing it for a fingerprint.
	# This prevents an oversized hostile payload from forcing a large temporary
	# hex string merely to produce an error response.
	var valid_envelope := Schema.is_valid_request_envelope(domain, operation, payload)
	var fingerprint := _request_fingerprint(domain, operation, payload) if valid_envelope else "invalid_envelope"
	var peer_cache: Dictionary = _peer_request_cache.get(peer_id, {})
	if peer_cache.has(request_sequence):
		var cached := peer_cache[request_sequence] as Dictionary
		if str(cached["fingerprint"]) == fingerprint:
			return (cached["result"] as Dictionary).duplicate(true)
		return _make_result(false, request_sequence, domain, operation, "", "request_sequence_conflict")
	if request_sequence <= int(_peer_highest_sequences.get(peer_id, 0)):
		return _make_result(false, request_sequence, domain, operation, "", "stale_request_sequence")
	_peer_highest_sequences[peer_id] = request_sequence
	var result: Dictionary
	if not valid_envelope:
		result = _make_result(false, request_sequence, domain, operation, "", "invalid_or_oversized_request")
	else:
		result = _validate_and_apply(peer_id, request_sequence, domain, operation, payload)
	_cache_server_result(peer_id, request_sequence, fingerprint, result)
	return result


func _validate_and_apply(
	peer_id: int,
	request_sequence: int,
	domain: String,
	operation: String,
	payload: Variant
) -> Dictionary:
	var role := _get_peer_role(peer_id)
	if not Schema.is_role_allowed(domain, role):
		return _make_result(false, request_sequence, domain, operation, "", "role_not_allowed")
	var normalized_result := Schema.normalize_change(domain, operation, payload)
	if not bool(normalized_result.get("ok", false)):
		return _make_result(false, request_sequence, domain, operation, "", str(normalized_result.get("error", "invalid_change")))
	var normalized_payload = normalized_result["value"]
	if operation == Schema.OP_UPSERT and domain in [Schema.DOMAIN_STROKES, Schema.DOMAIN_MODELS]:
		var record := normalized_payload as Dictionary
		if str(record.get("id", "")).is_empty():
			record = Schema.with_entity_id(record, _allocate_entity_id(domain))
			normalized_payload = record
	if Schema.is_collection_domain(domain) and operation == Schema.OP_UPSERT:
		var current_collection := _state[domain] as Dictionary
		var entity_id := str((normalized_payload as Dictionary)["id"])
		if not current_collection.has(entity_id) and current_collection.size() >= Schema.get_max_records(domain):
			return _make_result(false, request_sequence, domain, operation, entity_id, "collection_limit_reached")
	var replacement := Schema.apply_normalized_change(_state, domain, operation, normalized_payload)
	var snapshot_result := Schema.normalize_snapshot(replacement)
	if not bool(snapshot_result.get("ok", false)):
		return _make_result(false, request_sequence, domain, operation, "", str(snapshot_result.get("error", "invalid_state")))
	replacement = snapshot_result["value"]
	var entity_id := _get_entity_id(operation, normalized_payload)
	if replacement == _state:
		return _make_result(true, request_sequence, domain, operation, entity_id, "")
	var changed_domains: Array[String] = []
	for candidate in Schema.get_domains():
		if replacement[candidate] != _state[candidate]:
			changed_domains.append(candidate)
	_state = replacement
	_session_revision += 1
	for changed_domain in changed_domains:
		_domain_revisions[changed_domain] = int(_domain_revisions[changed_domain]) + 1
		state_changed.emit(
			changed_domain,
			operation,
			entity_id,
			_session_revision,
			int(_domain_revisions[changed_domain])
		)
	_broadcast_snapshot()
	return _make_result(true, request_sequence, domain, operation, entity_id, "")


func _make_result(
	accepted: bool,
	request_sequence: int,
	domain: String,
	operation: String,
	entity_id: String,
	error: String
) -> Dictionary:
	return {
		"accepted": accepted,
		"request_sequence": request_sequence,
		"domain": _safe_result_token(domain),
		"operation": _safe_result_token(operation),
		"revision": int(_domain_revisions.get(domain, 0)),
		"session_revision": _session_revision,
		"entity_id": entity_id,
		"error": error,
	}


func _safe_result_token(value: String) -> String:
	if value.to_utf8_buffer().size() > Schema.MAX_ID_BYTES:
		return ""
	for character in value:
		if character.unicode_at(0) < 32:
			return ""
	return value


func _apply_snapshot_envelope(envelope: Variant) -> bool:
	if not (envelope is Dictionary) or var_to_bytes(envelope).size() > Schema.MAX_SNAPSHOT_BYTES:
		operation_rejected.emit("invalid_or_oversized_snapshot_envelope")
		return false
	var source := envelope as Dictionary
	var incoming_revision := int(source.get("session_revision", -1))
	if incoming_revision < 0 or incoming_revision < _session_revision:
		operation_rejected.emit("stale_snapshot")
		return false
	var revisions_result := Schema.normalize_domain_revisions(source.get("domain_revisions", null))
	var state_result := Schema.normalize_snapshot(source.get("state", null))
	if not bool(revisions_result.get("ok", false)) or not bool(state_result.get("ok", false)):
		operation_rejected.emit("invalid_snapshot")
		return false
	var incoming_revisions := revisions_result["value"] as Dictionary
	for domain in Schema.get_domains():
		if int(incoming_revisions[domain]) > incoming_revision:
			operation_rejected.emit("invalid_snapshot_revision")
			return false
	_state = state_result["value"]
	_session_revision = incoming_revision
	_domain_revisions = incoming_revisions
	snapshot_applied.emit(_session_revision, _domain_revisions.duplicate(true))
	return true


func _make_snapshot_envelope() -> Dictionary:
	return {
		"session_revision": _session_revision,
		"domain_revisions": _domain_revisions.duplicate(true),
		"state": _state.duplicate(true),
	}


func _send_snapshot(peer_id: int) -> void:
	if not _is_server_authority() or peer_id not in multiplayer.get_peers():
		return
	var envelope := _make_snapshot_envelope()
	if var_to_bytes(envelope).size() > Schema.MAX_SNAPSHOT_BYTES:
		push_error("CollaborationState snapshot exceeds the configured byte limit.")
		return
	rpc_id(peer_id, "_client_receive_snapshot", envelope)


func _broadcast_snapshot() -> void:
	if not _is_server_authority():
		return
	for peer_id_value in multiplayer.get_peers():
		_send_snapshot(int(peer_id_value))


func _clear_local_session() -> void:
	_clear_all_state()


func _clear_all_state() -> void:
	_state = Schema.make_default_state()
	_session_revision = 0
	_domain_revisions = Schema.make_default_domain_revisions()
	_next_request_sequence = 1
	_next_stroke_id = 1
	_next_model_id = 1
	_recent_client_requests.clear()
	_peer_highest_sequences.clear()
	_peer_request_cache.clear()
	_peer_request_order.clear()
	_peer_snapshot_request_msec.clear()
	session_cleared.emit()


func _on_connected_to_server() -> void:
	_clear_local_session()
	call_deferred("request_snapshot")


func _on_server_disconnected() -> void:
	_clear_local_session()


func _on_peer_connected(peer_id: int) -> void:
	if _is_server_authority():
		call_deferred("_send_snapshot", peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_forget_peer_requests(peer_id)
	if peer_id == SERVER_PEER_ID and not _is_server_authority():
		_clear_local_session()


func _on_peer_role_changed(peer_id: int, _assigned_role: String) -> void:
	if _is_server_authority():
		_forget_peer_requests(peer_id)


func _on_network_role_selected(is_server_role: bool) -> void:
	if is_server_role and _is_server_authority():
		reset_session()
	elif not is_server_role:
		_clear_local_session()


func _on_session_closed() -> void:
	_clear_local_session()


func _get_peer_role(peer_id: int) -> String:
	var authority := get_node_or_null(peer_authority_path)
	if authority != null and authority.has_method("get_peer_role"):
		return str(authority.call("get_peer_role", peer_id))
	return ""


func _is_server_authority() -> bool:
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return false
	return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
		and multiplayer.is_server() \
		and multiplayer.get_unique_id() == SERVER_PEER_ID


func _is_connected_client() -> bool:
	if not multiplayer.has_multiplayer_peer() or multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		return false
	return multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED \
		and not multiplayer.is_server() \
		and multiplayer.get_unique_id() != SERVER_PEER_ID


func _allocate_entity_id(domain: String) -> String:
	if domain == Schema.DOMAIN_STROKES:
		var entity_id := "stroke_%d" % _next_stroke_id
		_next_stroke_id += 1
		return entity_id
	var entity_id := "model_%d" % _next_model_id
	_next_model_id += 1
	return entity_id


func _get_entity_id(operation: String, payload: Variant) -> String:
	if operation == Schema.OP_UPSERT and payload is Dictionary:
		return str((payload as Dictionary).get("id", ""))
	if operation == Schema.OP_REMOVE:
		return str(payload)
	return ""


func _request_fingerprint(domain: String, operation: String, payload: Variant) -> String:
	if not Schema.is_network_safe_request_content(domain, operation, payload):
		return "unsafe:%d" % hash([domain, operation, payload])
	return var_to_bytes([domain, operation, payload]).hex_encode().sha256_text()


func _cache_server_result(
	peer_id: int,
	request_sequence: int,
	fingerprint: String,
	result: Dictionary
) -> void:
	var cache: Dictionary = _peer_request_cache.get(peer_id, {})
	var order: Array = _peer_request_order.get(peer_id, [])
	cache[request_sequence] = {"fingerprint": fingerprint, "result": result.duplicate(true)}
	order.append(request_sequence)
	while order.size() > MAX_CACHED_REQUESTS_PER_PEER:
		cache.erase(int(order.pop_front()))
	_peer_request_cache[peer_id] = cache
	_peer_request_order[peer_id] = order


func _remember_client_request(request_sequence: int, request: Dictionary) -> void:
	_recent_client_requests[request_sequence] = request
	while _recent_client_requests.size() > MAX_CACHED_REQUESTS_PER_PEER:
		var oldest := request_sequence
		for sequence_value in _recent_client_requests:
			oldest = mini(oldest, int(sequence_value))
		_recent_client_requests.erase(oldest)


func _forget_peer_requests(peer_id: int) -> void:
	_peer_highest_sequences.erase(peer_id)
	_peer_request_cache.erase(peer_id)
	_peer_request_order.erase(peer_id)
	_peer_snapshot_request_msec.erase(peer_id)


func _deliver_result_locally(result: Dictionary) -> void:
	request_completed.emit(result.duplicate(true))
	if not bool(result.get("accepted", false)):
		operation_rejected.emit(str(result.get("error", "request_rejected")))


func _connect_multiplayer_signals() -> void:
	if not multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.connect(_on_connected_to_server)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _disconnect_multiplayer_signals() -> void:
	if multiplayer.connected_to_server.is_connected(_on_connected_to_server):
		multiplayer.connected_to_server.disconnect(_on_connected_to_server)
	if multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.disconnect(_on_server_disconnected)
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
	if multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)


func _connect_authority_signals() -> void:
	var authority := get_node_or_null(peer_authority_path)
	if authority == null:
		return
	if authority.has_signal("peer_role_changed") and not authority.is_connected("peer_role_changed", _on_peer_role_changed):
		authority.connect("peer_role_changed", _on_peer_role_changed)
	if authority.has_signal("network_role_selected") and not authority.is_connected("network_role_selected", _on_network_role_selected):
		authority.connect("network_role_selected", _on_network_role_selected)
	if authority.has_signal("session_closed") and not authority.is_connected("session_closed", _on_session_closed):
		authority.connect("session_closed", _on_session_closed)


func _disconnect_authority_signals() -> void:
	var authority := get_node_or_null(peer_authority_path)
	if authority == null:
		return
	if authority.has_signal("peer_role_changed") and authority.is_connected("peer_role_changed", _on_peer_role_changed):
		authority.disconnect("peer_role_changed", _on_peer_role_changed)
	if authority.has_signal("network_role_selected") and authority.is_connected("network_role_selected", _on_network_role_selected):
		authority.disconnect("network_role_selected", _on_network_role_selected)
	if authority.has_signal("session_closed") and authority.is_connected("session_closed", _on_session_closed):
		authority.disconnect("session_closed", _on_session_closed)
