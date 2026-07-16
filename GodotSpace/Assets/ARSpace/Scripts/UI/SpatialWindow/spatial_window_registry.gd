extends Node

const State = preload("res://Assets/ARSpace/Scripts/UI/SpatialWindow/spatial_window_state.gd")

signal window_registered(window_id: String, state: Dictionary)
signal window_unregistered(window_id: String)
signal window_state_changed(window_id: String, state: Dictionary)
signal window_preview_changed(window_id: String, shared_transform: Transform3D, stream_sequence: int)
signal window_selected(window_id: String)
signal snapshot_applied(revision: int, window_count: int)
signal operation_completed(result: Dictionary)
signal operation_rejected(reason: String)
signal session_cleared()

const SERVER_PEER_ID: int = 1
const MAX_REQUEST_BYTES: int = 16 * 1024
const MAX_REQUEST_SEQUENCE: int = 2147483647
const SNAPSHOT_REQUEST_INTERVAL_MSEC: int = 250
const MIN_LEASE_MSEC: int = 500
const DEFAULT_LEASE_MSEC: int = 3000
const MAX_LEASE_MSEC: int = 10000

const OP_OPEN := "open"
const OP_TRANSFORM_PREVIEW := "transform_preview"
const OP_TRANSFORM_COMMIT := "transform_commit"
const OP_RESIZE_COMMIT := "resize_commit"
const OP_SET_MODE := "set_mode"
const OP_SET_VISIBLE := "set_visible"
const OP_FOCUS := "focus"
const OP_SNAP := "snap"
const OP_CLOSE := "close"
const OP_ACQUIRE_LEASE := "acquire_lease"
const OP_RELEASE_LEASE := "release_lease"
const OP_SELECT := "select"
const RELIABLE_OPERATIONS: Array[String] = [
	OP_OPEN,
	OP_TRANSFORM_COMMIT,
	OP_RESIZE_COMMIT,
	OP_SET_MODE,
	OP_SET_VISIBLE,
	OP_FOCUS,
	OP_SNAP,
	OP_CLOSE,
	OP_ACQUIRE_LEASE,
	OP_RELEASE_LEASE,
]

@export_node_path("Node") var peer_authority_path := NodePath("/root/NetworkHandler")

var _windows: Dictionary = {}
var _revision: int = 0
var _focus_counter: int = 0
var _next_request_sequence: int = 1
var _multi_sequence_by_key: Dictionary = {}
var _peer_highest_request_sequence: Dictionary = {}
var _peer_snapshot_request_msec: Dictionary = {}
var _peer_preview_sequence_by_window: Dictionary = {}
var _broadcast_preview_sequence_by_window: Dictionary = {}


func _ready() -> void:
	add_to_group("spatial_window_registry")
	_connect_multiplayer_signals()
	_connect_authority_signals()
	set_process(true)
	if _is_connected_client():
		_clear_local_replica()
		call_deferred("request_snapshot")


func _exit_tree() -> void:
	_disconnect_multiplayer_signals()
	_disconnect_authority_signals()


func _process(_delta: float) -> void:
	if not _is_server_authority():
		return
	_expire_leases(Time.get_ticks_msec())


func register_window(descriptor: Dictionary) -> bool:
	if not _is_server_authority():
		_reject("server_authority_required:register_window")
		return false
	var result := _process_open(SERVER_PEER_ID, descriptor)
	_deliver_result(result)
	return bool(result.get("accepted", false))


func unregister_window(window_id: String) -> bool:
	if not _is_server_authority():
		_reject("server_authority_required:unregister_window")
		return false
	if not State.is_safe_identifier(window_id) or not _windows.has(window_id):
		_reject("unknown_window")
		return false
	_windows.erase(window_id)
	_clear_preview_sequences_for_window(window_id)
	_revision += 1
	window_unregistered.emit(window_id)
	window_state_changed.emit(window_id, {})
	_broadcast_snapshot()
	return true


func request_operation(window_id: String, operation: String, payload: Dictionary = {}) -> bool:
	var normalized_operation := operation.strip_edges().to_lower()
	if normalized_operation == OP_SELECT:
		return select_window(window_id)
	if normalized_operation not in RELIABLE_OPERATIONS and normalized_operation != OP_TRANSFORM_PREVIEW:
		_reject("unsupported_operation")
		return false
	if normalized_operation != OP_OPEN and not State.is_safe_identifier(window_id):
		_reject("invalid_window_id")
		return false
	if not _is_safe_request(window_id, normalized_operation, payload):
		_reject("invalid_or_oversized_request")
		return false
	if _is_server_authority():
		var result := _process_server_operation(SERVER_PEER_ID, window_id, normalized_operation, payload)
		_deliver_result(result)
		return bool(result.get("accepted", false))
	if not _is_connected_client():
		_reject("not_connected")
		return false
	if normalized_operation == OP_TRANSFORM_PREVIEW:
		rpc_id(SERVER_PEER_ID, "_server_receive_transform_preview", window_id, payload)
		return true
	if _next_request_sequence > MAX_REQUEST_SEQUENCE:
		_reject("request_sequence_limit_reached")
		return false
	var sequence := _next_request_sequence
	_next_request_sequence += 1
	rpc_id(SERVER_PEER_ID, "_server_request_operation", sequence, window_id, normalized_operation, payload)
	return true


func select_window(window_id: String) -> bool:
	if not State.is_safe_identifier(window_id) or not _windows.has(window_id):
		_reject("unknown_window")
		return false
	var record := _windows[window_id] as Dictionary
	if str(record.get("mode", State.MODE_CLOSED)) == State.MODE_CLOSED:
		_reject("window_closed")
		return false
	var local_role := _get_peer_role(multiplayer.get_unique_id())
	if local_role.is_empty() and _is_connected_client():
		# Client role assignment is authoritative on the Server. Selection is a
		# local presentation action, so a connected client may select without
		# mutating replicated business state.
		local_role = State.ROLE_ASTRONAUT
	if not State.is_selectable_role(local_role):
		_reject("role_not_selectable")
		return false
	window_selected.emit(window_id)
	return true


func get_window_state(window_id: String) -> Dictionary:
	return (_windows.get(window_id, {}) as Dictionary).duplicate(true)


func get_windows_snapshot() -> Dictionary:
	return _windows.duplicate(true)


func get_active_windows() -> Array[Dictionary]:
	var active: Array[Dictionary] = []
	for window_id in _windows:
		var record := _windows[window_id] as Dictionary
		if str(record.get("mode", State.MODE_CLOSED)) != State.MODE_CLOSED \
				and bool(record.get("visible", false)):
			active.append(record.duplicate(true))
	active.sort_custom(func(left: Dictionary, right: Dictionary) -> bool:
		return int(left.get("focus_order", 0)) < int(right.get("focus_order", 0))
	)
	return active


func get_revision() -> int:
	return _revision


func request_snapshot() -> void:
	if _is_connected_client():
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
func _server_request_operation(
	request_sequence: int,
	window_id: String,
	operation: String,
	payload: Dictionary
) -> void:
	if not _is_server_authority():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		return
	var result: Dictionary
	if request_sequence <= int(_peer_highest_request_sequence.get(sender_id, 0)) \
			or request_sequence > MAX_REQUEST_SEQUENCE:
		result = _make_result(false, window_id, operation, "stale_request_sequence")
	else:
		_peer_highest_request_sequence[sender_id] = request_sequence
		result = _process_server_operation(sender_id, window_id, operation, payload)
	result["request_sequence"] = request_sequence
	rpc_id(sender_id, "_client_receive_operation_result", result)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _server_receive_transform_preview(window_id: String, payload: Dictionary) -> void:
	if not _is_server_authority():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		return
	_process_transform_preview(sender_id, window_id, payload)


@rpc("any_peer", "call_remote", "reliable", 0)
func _server_request_snapshot() -> void:
	if not _is_server_authority():
		return
	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id <= SERVER_PEER_ID or sender_id not in multiplayer.get_peers():
		return
	var now := Time.get_ticks_msec()
	var previous := int(_peer_snapshot_request_msec.get(sender_id, -SNAPSHOT_REQUEST_INTERVAL_MSEC))
	if now - previous < SNAPSHOT_REQUEST_INTERVAL_MSEC:
		return
	_peer_snapshot_request_msec[sender_id] = now
	_send_snapshot(sender_id)


@rpc("authority", "call_remote", "reliable", 0)
func _client_receive_operation_result(result: Dictionary) -> void:
	if multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	_deliver_result(result)


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _client_receive_transform_preview(
	window_id: String,
	shared_transform: Transform3D,
	stream_sequence: int
) -> void:
	if multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	if not _windows.has(window_id) or not State.is_valid_shared_transform(shared_transform):
		return
	var previous_sequence := int(_broadcast_preview_sequence_by_window.get(window_id, -1))
	if stream_sequence <= previous_sequence:
		return
	_broadcast_preview_sequence_by_window[window_id] = stream_sequence
	window_preview_changed.emit(window_id, shared_transform, stream_sequence)


@rpc("authority", "call_remote", "reliable", 0)
func _client_receive_snapshot(envelope: Dictionary) -> void:
	if multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	_apply_snapshot_envelope(envelope)


@rpc("authority", "call_remote", "reliable", 0)
func _client_reset_session() -> void:
	if multiplayer.get_remote_sender_id() == SERVER_PEER_ID:
		_clear_local_replica()


func _process_server_operation(
	peer_id: int,
	window_id: String,
	operation: String,
	payload: Dictionary
) -> Dictionary:
	if not _is_safe_request(window_id, operation, payload):
		return _make_result(false, window_id, operation, "invalid_or_oversized_request")
	var role := _get_peer_role(peer_id)
	if not State.is_ground_role(role):
		return _make_result(false, window_id, operation, "role_not_allowed")
	if operation == OP_OPEN:
		return _process_open(peer_id, payload)
	if not _windows.has(window_id):
		return _make_result(false, window_id, operation, "unknown_window")
	if operation == OP_TRANSFORM_PREVIEW:
		return _make_result(_process_transform_preview(peer_id, window_id, payload), window_id, operation, "")
	var record := (_windows[window_id] as Dictionary).duplicate(true)
	var now := Time.get_ticks_msec()
	_clear_expired_lease_in_record(record, now)
	if operation in [OP_SET_MODE, OP_SET_VISIBLE, OP_CLOSE] \
			and int(record.get("lease_peer_id", 0)) not in [0, peer_id]:
		return _make_result(false, window_id, operation, "window_lease_busy")
	match operation:
		OP_ACQUIRE_LEASE:
			var timeout_value = payload.get("timeout_msec", DEFAULT_LEASE_MSEC)
			if not (timeout_value is int):
				return _make_result(false, window_id, operation, "invalid_lease_timeout")
			var timeout_msec := int(timeout_value)
			if timeout_msec < MIN_LEASE_MSEC or timeout_msec > MAX_LEASE_MSEC:
				return _make_result(false, window_id, operation, "invalid_lease_timeout")
			var current_lease_peer := int(record.get("lease_peer_id", 0))
			if current_lease_peer != 0 and current_lease_peer != peer_id:
				return _make_result(false, window_id, operation, "window_lease_busy")
			record["lease_peer_id"] = peer_id
			record["lease_token"] = _make_lease_token(window_id, peer_id)
			record["lease_expires_msec"] = now + timeout_msec
		OP_RELEASE_LEASE:
			if not _has_valid_lease(record, peer_id, payload, now):
				return _make_result(false, window_id, operation, "lease_required")
			_clear_lease_in_record(record)
		OP_TRANSFORM_COMMIT:
			if not _has_valid_lease(record, peer_id, payload, now):
				return _make_result(false, window_id, operation, "lease_required")
			var transform_value = payload.get("shared_transform", null)
			if not State.is_valid_shared_transform(transform_value):
				return _make_result(false, window_id, operation, "invalid_shared_transform")
			var transform_size = payload.get("size_m", null)
			if transform_size != null and not State.is_valid_size(transform_size):
				return _make_result(false, window_id, operation, "invalid_window_size")
			record["shared_transform"] = transform_value
			if transform_size != null:
				record["size_m"] = transform_size
			record["mode"] = State.MODE_NORMAL
			record["snap_slot"] = ""
			if bool(payload.get("release_lease", true)):
				_clear_lease_in_record(record)
		OP_RESIZE_COMMIT:
			if not _has_valid_lease(record, peer_id, payload, now):
				return _make_result(false, window_id, operation, "lease_required")
			var size_value = payload.get("size_m", null)
			if not State.is_valid_size(size_value):
				return _make_result(false, window_id, operation, "invalid_window_size")
			record["size_m"] = size_value
			if bool(payload.get("release_lease", true)):
				_clear_lease_in_record(record)
		OP_SET_MODE:
			var mode := str(payload.get("mode", "")).strip_edges().to_lower()
			if mode not in [State.MODE_NORMAL, State.MODE_MAXIMIZED]:
				return _make_result(false, window_id, operation, "invalid_mode_transition")
			var mode_size = payload.get("size_m", record.get("size_m", Vector2.ZERO))
			if not State.is_valid_size(mode_size):
				return _make_result(false, window_id, operation, "invalid_window_size")
			record["mode"] = mode
			record["size_m"] = mode_size
			record["visible"] = true
			record["snap_slot"] = ""
		OP_SET_VISIBLE:
			if not (payload.get("visible", null) is bool) \
					or str(record.get("mode", "")) == State.MODE_CLOSED:
				return _make_result(false, window_id, operation, "invalid_visibility")
			record["visible"] = bool(payload["visible"])
		OP_FOCUS:
			_focus_counter += 1
			record["focus_order"] = _focus_counter
		OP_SNAP:
			if not _has_valid_lease(record, peer_id, payload, now):
				return _make_result(false, window_id, operation, "lease_required")
			var snap_slot := str(payload.get("snap_slot", "")).strip_edges()
			var snap_transform = payload.get("shared_transform", null)
			var snap_size = payload.get("size_m", record.get("size_m", Vector2.ZERO))
			if not State.is_safe_identifier(snap_slot) \
					or not State.is_valid_shared_transform(snap_transform) \
					or not State.is_valid_size(snap_size):
				return _make_result(false, window_id, operation, "invalid_snap")
			record["shared_transform"] = snap_transform
			record["size_m"] = snap_size
			record["mode"] = State.MODE_SNAPPED
			record["snap_slot"] = snap_slot
			record["visible"] = true
			_clear_lease_in_record(record)
		OP_CLOSE:
			record["mode"] = State.MODE_CLOSED
			record["visible"] = false
			record["snap_slot"] = ""
			_clear_lease_in_record(record)
		_:
			return _make_result(false, window_id, operation, "unsupported_operation")
	if record == _windows[window_id]:
		return _make_result(true, window_id, operation, "")
	if not _commit_record(record):
		return _make_result(false, window_id, operation, "invalid_resulting_state")
	return _make_result(true, window_id, operation, "")


func _process_open(peer_id: int, descriptor_value: Variant) -> Dictionary:
	var descriptor_result := State.normalize_descriptor(descriptor_value)
	if not bool(descriptor_result.get("ok", false)):
		return _make_result(false, "", OP_OPEN, str(descriptor_result.get("error", "invalid_descriptor")))
	var descriptor := descriptor_result["value"] as Dictionary
	var explicit_id := str(descriptor.get("window_id", ""))
	var window_type := str(descriptor["window_type"])
	var policy := str(descriptor["instance_policy"])
	var content_key := str(descriptor["content_key"])
	var window_id := explicit_id
	if window_id.is_empty():
		if policy == State.POLICY_UNIQUE:
			window_id = State.make_stable_window_id(window_type, content_key, policy)
		else:
			var sequence_key := "%s\n%s" % [window_type, content_key]
			var sequence := int(_multi_sequence_by_key.get(sequence_key, 0)) + 1
			var allocation_attempts := 0
			while _windows.has(State.make_stable_window_id(window_type, content_key, policy, sequence)):
				sequence += 1
				allocation_attempts += 1
				if allocation_attempts > State.MAX_WINDOWS:
					return _make_result(false, "", OP_OPEN, "window_id_allocation_exhausted")
			_multi_sequence_by_key[sequence_key] = sequence
			window_id = State.make_stable_window_id(window_type, content_key, policy, sequence)
	if not State.is_safe_identifier(window_id):
		return _make_result(false, window_id, OP_OPEN, "invalid_generated_window_id")
	if peer_id != SERVER_PEER_ID and not _windows.has(window_id):
		return _make_result(false, window_id, OP_OPEN, "server_registration_required")
	if _windows.has(window_id):
		var existing := (_windows[window_id] as Dictionary).duplicate(true)
		_clear_expired_lease_in_record(existing, Time.get_ticks_msec())
		if int(existing.get("lease_peer_id", 0)) not in [0, peer_id]:
			return _make_result(false, window_id, OP_OPEN, "window_lease_busy")
		if policy != State.POLICY_UNIQUE \
				or str(existing.get("window_type", "")) != window_type \
				or str(existing.get("content_key", "")) != content_key:
			return _make_result(false, window_id, OP_OPEN, "window_id_conflict")
		existing["shared_transform"] = descriptor["shared_transform"]
		existing["size_m"] = descriptor["size_m"]
		existing["mode"] = State.MODE_NORMAL
		existing["visible"] = true
		existing["snap_slot"] = ""
		_clear_lease_in_record(existing)
		_focus_counter += 1
		existing["focus_order"] = _focus_counter
		if not _commit_record(existing):
			return _make_result(false, window_id, OP_OPEN, "invalid_resulting_state")
		return _make_result(true, window_id, OP_OPEN, "")
	if _windows.size() >= State.MAX_WINDOWS:
		return _make_result(false, window_id, OP_OPEN, "window_limit_reached")
	_focus_counter += 1
	var record := State.make_record(descriptor, window_id, peer_id, 1, _focus_counter)
	var normalized := State.normalize_record(record)
	if not bool(normalized.get("ok", false)):
		return _make_result(false, window_id, OP_OPEN, str(normalized.get("error", "invalid_window")))
	_windows[window_id] = normalized["value"]
	_revision += 1
	window_registered.emit(window_id, get_window_state(window_id))
	window_state_changed.emit(window_id, get_window_state(window_id))
	_broadcast_snapshot()
	return _make_result(true, window_id, OP_OPEN, "")


func _process_transform_preview(peer_id: int, window_id: String, payload: Dictionary) -> bool:
	if not State.is_ground_role(_get_peer_role(peer_id)) or not _windows.has(window_id):
		return false
	if not _is_safe_request(window_id, OP_TRANSFORM_PREVIEW, payload):
		return false
	var record := _windows[window_id] as Dictionary
	var now := Time.get_ticks_msec()
	if not _has_valid_lease(record, peer_id, payload, now):
		return false
	var transform_value = payload.get("shared_transform", null)
	var stream_sequence_value = payload.get("stream_sequence", null)
	if not State.is_valid_shared_transform(transform_value) \
			or not (stream_sequence_value is int) \
			or int(stream_sequence_value) < 0:
		return false
	var stream_sequence := int(stream_sequence_value)
	if stream_sequence > MAX_REQUEST_SEQUENCE:
		return false
	var sequence_key := "%d:%s" % [peer_id, window_id]
	if stream_sequence <= int(_peer_preview_sequence_by_window.get(sequence_key, -1)):
		return false
	_peer_preview_sequence_by_window[sequence_key] = stream_sequence
	var broadcast_sequence := int(_broadcast_preview_sequence_by_window.get(window_id, 0)) + 1
	_broadcast_preview_sequence_by_window[window_id] = broadcast_sequence
	window_preview_changed.emit(window_id, transform_value as Transform3D, broadcast_sequence)
	if _is_server_authority():
		rpc("_client_receive_transform_preview", window_id, transform_value, broadcast_sequence)
	return true


func _commit_record(record: Dictionary) -> bool:
	var window_id := str(record.get("window_id", ""))
	if not _windows.has(window_id):
		return false
	var replacement := record.duplicate(true)
	replacement["revision"] = int((_windows[window_id] as Dictionary).get("revision", 0)) + 1
	var normalized := State.normalize_record(replacement)
	if not bool(normalized.get("ok", false)):
		return false
	_windows[window_id] = normalized["value"]
	_revision += 1
	window_state_changed.emit(window_id, get_window_state(window_id))
	_broadcast_snapshot()
	return true


func _expire_leases(now_msec: int) -> void:
	var expired: Array[String] = []
	for window_id in _windows:
		var record := _windows[window_id] as Dictionary
		if int(record.get("lease_peer_id", 0)) != 0 \
				and int(record.get("lease_expires_msec", 0)) <= now_msec:
			expired.append(str(window_id))
	if expired.is_empty():
		return
	for window_id in expired:
		var replacement := (_windows[window_id] as Dictionary).duplicate(true)
		_clear_lease_in_record(replacement)
		replacement["revision"] = int(replacement.get("revision", 0)) + 1
		_windows[window_id] = replacement
	_revision += 1
	for window_id in expired:
		window_state_changed.emit(window_id, get_window_state(window_id))
	_broadcast_snapshot()


func _release_peer_leases(peer_id: int) -> void:
	var changed: Array[String] = []
	for window_id in _windows:
		var record := _windows[window_id] as Dictionary
		if int(record.get("lease_peer_id", 0)) == peer_id:
			var replacement := record.duplicate(true)
			_clear_lease_in_record(replacement)
			replacement["revision"] = int(replacement.get("revision", 0)) + 1
			_windows[window_id] = replacement
			changed.append(str(window_id))
	if changed.is_empty():
		return
	_revision += 1
	for window_id in changed:
		window_state_changed.emit(window_id, get_window_state(window_id))
	_broadcast_snapshot()


func _has_valid_lease(record: Dictionary, peer_id: int, payload: Dictionary, now_msec: int) -> bool:
	if int(record.get("lease_peer_id", 0)) != peer_id \
			or int(record.get("lease_expires_msec", 0)) <= now_msec:
		return false
	var token := str(payload.get("lease_token", ""))
	return not token.is_empty() and token == str(record.get("lease_token", ""))


func _clear_expired_lease_in_record(record: Dictionary, now_msec: int) -> void:
	if int(record.get("lease_peer_id", 0)) != 0 \
			and int(record.get("lease_expires_msec", 0)) <= now_msec:
		_clear_lease_in_record(record)


func _clear_lease_in_record(record: Dictionary) -> void:
	record["lease_peer_id"] = 0
	record["lease_token"] = ""
	record["lease_expires_msec"] = 0


func _clear_preview_sequences_for_window(window_id: String) -> void:
	_broadcast_preview_sequence_by_window.erase(window_id)
	var suffix := ":%s" % window_id
	for key in _peer_preview_sequence_by_window.keys():
		if str(key).ends_with(suffix):
			_peer_preview_sequence_by_window.erase(key)


func _clear_preview_sequences_for_peer(peer_id: int) -> void:
	var prefix := "%d:" % peer_id
	for key in _peer_preview_sequence_by_window.keys():
		if str(key).begins_with(prefix):
			_peer_preview_sequence_by_window.erase(key)


func _make_lease_token(window_id: String, peer_id: int) -> String:
	return "lease_%d_%s_%d" % [peer_id, window_id.sha256_text().substr(0, 8), _revision + 1]


func _make_result(accepted: bool, window_id: String, operation: String, error: String) -> Dictionary:
	return {
		"accepted": accepted,
		"window_id": window_id,
		"operation": operation,
		"revision": _revision,
		"error": error if not accepted else "",
	}


func _deliver_result(result: Dictionary) -> void:
	operation_completed.emit(result.duplicate(true))
	if not bool(result.get("accepted", false)):
		_reject(str(result.get("error", "operation_rejected")))


func _reject(reason: String) -> void:
	operation_rejected.emit(reason)


func _is_safe_request(window_id: String, operation: String, payload: Dictionary) -> bool:
	if operation != OP_OPEN and not State.is_safe_identifier(window_id):
		return false
	if operation not in RELIABLE_OPERATIONS and operation != OP_TRANSFORM_PREVIEW:
		return false
	return _is_network_safe_value(payload, 0) \
		and var_to_bytes([window_id, operation, payload]).size() <= MAX_REQUEST_BYTES


func _is_network_safe_value(value: Variant, depth: int) -> bool:
	if depth > 6:
		return false
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return true
		TYPE_FLOAT:
			return is_finite(value as float)
		TYPE_STRING:
			return (value as String).length() <= 256
		TYPE_VECTOR2:
			var vector2_value := value as Vector2
			return is_finite(vector2_value.x) and is_finite(vector2_value.y)
		TYPE_VECTOR3:
			var vector3_value := value as Vector3
			return is_finite(vector3_value.x) and is_finite(vector3_value.y) and is_finite(vector3_value.z)
		TYPE_TRANSFORM3D:
			return State.is_valid_shared_transform(value)
		TYPE_ARRAY:
			if (value as Array).size() > 64:
				return false
			for item in value as Array:
				if not _is_network_safe_value(item, depth + 1):
					return false
			return true
		TYPE_DICTIONARY:
			if (value as Dictionary).size() > 32:
				return false
			for key in value as Dictionary:
				if not (key is String) or not _is_network_safe_value((value as Dictionary)[key], depth + 1):
					return false
			return true
		_:
			return false


func _make_snapshot_envelope() -> Dictionary:
	return {
		"contract_version": State.CONTRACT_VERSION,
		"revision": _revision,
		"windows": _windows.duplicate(true),
	}


func _send_snapshot(peer_id: int) -> void:
	if not _is_server_authority() or peer_id not in multiplayer.get_peers():
		return
	var envelope := _make_snapshot_envelope()
	if var_to_bytes(envelope).size() > State.MAX_SNAPSHOT_BYTES:
		push_error("SpatialWindowRegistry snapshot exceeds its byte limit.")
		return
	rpc_id(peer_id, "_client_receive_snapshot", envelope)


func _broadcast_snapshot() -> void:
	if not _is_server_authority():
		return
	for peer_id_value in multiplayer.get_peers():
		_send_snapshot(int(peer_id_value))


func _apply_snapshot_envelope(value: Variant) -> bool:
	if not (value is Dictionary) or var_to_bytes(value).size() > State.MAX_SNAPSHOT_BYTES:
		_reject("invalid_or_oversized_snapshot")
		return false
	var envelope := value as Dictionary
	if int(envelope.get("contract_version", -1)) != State.CONTRACT_VERSION:
		_reject("unsupported_contract_version")
		return false
	var incoming_revision_value = envelope.get("revision", null)
	if not (incoming_revision_value is int) or int(incoming_revision_value) < _revision:
		_reject("stale_snapshot")
		return false
	var result := State.normalize_snapshot(envelope.get("windows", null))
	if not bool(result.get("ok", false)):
		_reject(str(result.get("error", "invalid_snapshot")))
		return false
	var incoming_revision := int(incoming_revision_value)
	var replacement := result["value"] as Dictionary
	if incoming_revision == _revision and replacement != _windows:
		_reject("conflicting_equal_revision_snapshot")
		return false
	var previous := _windows
	_windows = replacement
	_revision = incoming_revision
	_focus_counter = 0
	for window_id in _windows:
		_focus_counter = maxi(_focus_counter, int((_windows[window_id] as Dictionary).get("focus_order", 0)))
	for window_id in previous:
		if not _windows.has(window_id):
			window_unregistered.emit(str(window_id))
			window_state_changed.emit(str(window_id), {})
	for window_id in _windows:
		if not previous.has(window_id):
			window_registered.emit(str(window_id), get_window_state(str(window_id)))
		if not previous.has(window_id) or previous[window_id] != _windows[window_id]:
			window_state_changed.emit(str(window_id), get_window_state(str(window_id)))
	snapshot_applied.emit(_revision, _windows.size())
	return true


func _clear_local_replica() -> void:
	var previous_ids := _windows.keys()
	_windows.clear()
	_revision = 0
	_focus_counter = 0
	_next_request_sequence = 1
	_multi_sequence_by_key.clear()
	_peer_highest_request_sequence.clear()
	_peer_snapshot_request_msec.clear()
	_peer_preview_sequence_by_window.clear()
	_broadcast_preview_sequence_by_window.clear()
	for window_id in previous_ids:
		window_unregistered.emit(str(window_id))
		window_state_changed.emit(str(window_id), {})
	session_cleared.emit()


func _clear_all_state() -> void:
	_clear_local_replica()


func _get_peer_role(peer_id: int) -> String:
	if peer_id == SERVER_PEER_ID and _is_server_authority():
		return State.ROLE_PC_GROUND
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


func _on_connected_to_server() -> void:
	_clear_local_replica()
	call_deferred("request_snapshot")


func _on_server_disconnected() -> void:
	_clear_local_replica()


func _on_peer_connected(peer_id: int) -> void:
	if _is_server_authority():
		call_deferred("_send_snapshot", peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_peer_highest_request_sequence.erase(peer_id)
	_peer_snapshot_request_msec.erase(peer_id)
	_clear_preview_sequences_for_peer(peer_id)
	_release_peer_leases(peer_id)
	if peer_id == SERVER_PEER_ID and not _is_server_authority():
		_clear_local_replica()


func _on_peer_role_changed(peer_id: int, _role: String) -> void:
	if _is_server_authority() and not State.is_ground_role(_get_peer_role(peer_id)):
		_release_peer_leases(peer_id)


func _on_network_role_selected(is_server_role: bool) -> void:
	if is_server_role and _is_server_authority():
		reset_session()
	elif not is_server_role:
		_clear_local_replica()


func _on_session_closed() -> void:
	_clear_local_replica()


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
	if authority.has_signal("peer_role_changed") \
			and not authority.is_connected("peer_role_changed", _on_peer_role_changed):
		authority.connect("peer_role_changed", _on_peer_role_changed)
	if authority.has_signal("network_role_selected") \
			and not authority.is_connected("network_role_selected", _on_network_role_selected):
		authority.connect("network_role_selected", _on_network_role_selected)
	if authority.has_signal("session_closed") \
			and not authority.is_connected("session_closed", _on_session_closed):
		authority.connect("session_closed", _on_session_closed)


func _disconnect_authority_signals() -> void:
	var authority := get_node_or_null(peer_authority_path)
	if authority == null:
		return
	if authority.has_signal("peer_role_changed") \
			and authority.is_connected("peer_role_changed", _on_peer_role_changed):
		authority.disconnect("peer_role_changed", _on_peer_role_changed)
	if authority.has_signal("network_role_selected") \
			and authority.is_connected("network_role_selected", _on_network_role_selected):
		authority.disconnect("network_role_selected", _on_network_role_selected)
	if authority.has_signal("session_closed") \
			and authority.is_connected("session_closed", _on_session_closed):
		authority.disconnect("session_closed", _on_session_closed)
