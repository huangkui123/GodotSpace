extends Node

const Contract = preload("res://Assets/ARSpace/Scripts/SpatialCalibration/shared_space_contract.gd")

signal calibration_changed(state: Dictionary)
signal preview_changed(preview: Dictionary)
signal snapshot_applied(revision: int)
signal operation_rejected(reason: String)

const SERVER_PEER_ID: int = 1
const MAX_REVISION: int = 2147483647
const MAX_CONFIRMED_POINTS: int = 128
const MAX_METADATA_BYTES: int = 4096
const MAX_METRICS_BYTES: int = 8192
const MAX_SNAPSHOT_BYTES: int = 262144
const MAX_DICTIONARY_ENTRIES: int = 32
const MAX_ARRAY_ENTRIES: int = 64
const MAX_VALUE_DEPTH: int = 4
const MAX_KEY_BYTES: int = 64
const MAX_STRING_BYTES: int = 512
const MAX_LABEL_BYTES: int = 128
const MAX_METADATA_VECTOR_LENGTH: float = 1000.0
const SNAPSHOT_REQUEST_INTERVAL_MSEC: int = 250

const STATUS_UNCALIBRATED: String = "uncalibrated"
const STATUS_CALIBRATING: String = "calibrating"
const STATUS_CALIBRATED: String = "calibrated"
const VALID_STATUSES: Array[String] = [
	STATUS_UNCALIBRATED,
	STATUS_CALIBRATING,
	STATUS_CALIBRATED,
]

@export_node_path("Node") var peer_authority_path := NodePath("/root/NetworkHandler")
@export_node_path("Node3D") var shared_space_origin_path: NodePath

var _state: Dictionary = _make_default_state()
var _next_point_id: int = 1
var _peer_snapshot_request_msec: Dictionary = {}


func _ready() -> void:
	add_to_group("spatial_calibration_state")
	_connect_multiplayer_signals()
	_connect_authority_signals()
	if not get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.connect(_on_tree_node_added)
	call_deferred("_apply_origin_to_scene")
	if _is_connected_client():
		_clear_local_replica()
		call_deferred("request_snapshot")


func _exit_tree() -> void:
	_disconnect_multiplayer_signals()
	_disconnect_authority_signals()
	if get_tree() != null and get_tree().node_added.is_connected(_on_tree_node_added):
		get_tree().node_added.disconnect(_on_tree_node_added)


func get_state() -> Dictionary:
	return _state.duplicate(true)


func get_preview() -> Dictionary:
	return (_state.get("preview", {}) as Dictionary).duplicate(true)


func get_revision() -> int:
	return int(_state.get("revision", 0))


func get_origin_global_transform() -> Transform3D:
	return _state.get("origin_global", Transform3D.IDENTITY) as Transform3D


func set_preview(shared_position: Vector3, data: Dictionary = {}) -> bool:
	if not _require_server_authority("set_preview"):
		return false
	if not Contract.is_valid_shared_point(shared_position) or not _is_safe_payload(data, MAX_METADATA_BYTES):
		_reject("invalid_preview")
		return false
	var replacement := _state.duplicate(true)
	replacement["preview"] = {
		"visible": true,
		"shared_position": shared_position,
		"data": data.duplicate(true),
	}
	return _commit_server_state(replacement)


func clear_preview() -> bool:
	if not _require_server_authority("clear_preview"):
		return false
	if (_state.get("preview", {}) as Dictionary).is_empty():
		return true
	var replacement := _state.duplicate(true)
	replacement["preview"] = {}
	return _commit_server_state(replacement)


func confirm_point(shared_position: Vector3, data: Dictionary = {}) -> bool:
	if not _require_server_authority("confirm_point"):
		return false
	if not Contract.is_valid_shared_point(shared_position) or not _is_safe_payload(data, MAX_METADATA_BYTES):
		_reject("invalid_confirmed_point")
		return false
	var points := (_state.get("confirmed_points", []) as Array).duplicate(true)
	if points.size() >= MAX_CONFIRMED_POINTS:
		_reject("confirmed_point_limit_reached")
		return false
	points.append({
		"id": "calibration_point_%d" % _next_point_id,
		"shared_position": shared_position,
		"data": data.duplicate(true),
	})
	_next_point_id += 1
	var replacement := _state.duplicate(true)
	replacement["confirmed_points"] = points
	replacement["preview"] = {}
	return _commit_server_state(replacement)


func clear_calibration(reason: String = "manual") -> bool:
	if not _require_server_authority("clear_calibration"):
		return false
	var safe_reason := _normalize_label(reason, "manual")
	if safe_reason.is_empty():
		_reject("invalid_clear_reason")
		return false
	var replacement := _make_default_state()
	replacement["revision"] = get_revision()
	replacement["reason"] = safe_reason
	return _commit_server_state(replacement)


func begin_recalibration(reason: String = "manual") -> bool:
	if not _require_server_authority("begin_recalibration"):
		return false
	var safe_reason := _normalize_label(reason, "manual")
	if safe_reason.is_empty():
		_reject("invalid_recalibration_reason")
		return false
	var replacement := _state.duplicate(true)
	replacement["status"] = STATUS_CALIBRATING
	replacement["preview"] = {}
	replacement["confirmed_points"] = []
	replacement["metrics"] = {}
	replacement["source"] = ""
	replacement["reason"] = safe_reason
	return _commit_server_state(replacement)


func commit_calibration(
	absolute_origin_global: Transform3D,
	metrics: Dictionary = {},
	source: String = "manual"
) -> bool:
	if not _require_server_authority("commit_calibration"):
		return false
	var safe_source := _normalize_label(source, "manual")
	if not Contract.is_valid_origin_transform(absolute_origin_global) \
			or not _is_safe_payload(metrics, MAX_METRICS_BYTES) \
			or safe_source.is_empty():
		_reject("invalid_calibration_commit")
		return false
	var replacement := _state.duplicate(true)
	# This is an absolute replacement by contract. Never multiply it by the
	# previous origin or interpret it as a calibration delta.
	replacement["origin_global"] = absolute_origin_global
	replacement["status"] = STATUS_CALIBRATED
	replacement["preview"] = {}
	replacement["metrics"] = metrics.duplicate(true)
	replacement["source"] = safe_source
	replacement["reason"] = ""
	return _commit_server_state(replacement)


func request_snapshot() -> void:
	if _is_connected_client():
		rpc_id(SERVER_PEER_ID, "_server_request_snapshot")


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
func _client_receive_snapshot(envelope: Dictionary) -> void:
	if multiplayer.get_remote_sender_id() != SERVER_PEER_ID:
		return
	_apply_snapshot_envelope(envelope)


func _commit_server_state(replacement: Dictionary) -> bool:
	if get_revision() >= MAX_REVISION:
		_reject("revision_limit_reached")
		return false
	replacement["revision"] = get_revision() + 1
	var normalized := _normalize_state(replacement)
	if normalized.is_empty():
		_reject("invalid_or_oversized_state")
		return false
	_set_local_state(normalized)
	_broadcast_snapshot()
	return true


func _apply_snapshot_envelope(envelope: Variant) -> bool:
	if not (envelope is Dictionary) or not _is_encoded_size_within(envelope, MAX_SNAPSHOT_BYTES):
		_reject("invalid_or_oversized_snapshot")
		return false
	var source := envelope as Dictionary
	if source.size() != 2 or not source.has("revision") or not source.has("state"):
		_reject("invalid_snapshot_envelope")
		return false
	var incoming_revision_value = source.get("revision", -1)
	if not (incoming_revision_value is int):
		_reject("invalid_snapshot_revision")
		return false
	var incoming_revision := int(incoming_revision_value)
	if incoming_revision < get_revision():
		_reject("stale_snapshot")
		return false
	var normalized := _normalize_state(source.get("state", null))
	if normalized.is_empty() or int(normalized.get("revision", -1)) != incoming_revision:
		_reject("invalid_snapshot_state")
		return false
	_set_local_state(normalized)
	snapshot_applied.emit(incoming_revision)
	return true


func _make_snapshot_envelope() -> Dictionary:
	return {
		"revision": get_revision(),
		"state": get_state(),
	}


func _send_snapshot(peer_id: int) -> void:
	if not _is_server_authority() or peer_id not in multiplayer.get_peers():
		return
	var envelope := _make_snapshot_envelope()
	if not _is_encoded_size_within(envelope, MAX_SNAPSHOT_BYTES):
		push_error("SpatialCalibrationState snapshot exceeds its byte limit.")
		return
	rpc_id(peer_id, "_client_receive_snapshot", envelope)


func _broadcast_snapshot() -> void:
	if not _is_server_authority():
		return
	for peer_id_value in multiplayer.get_peers():
		_send_snapshot(int(peer_id_value))


func _set_local_state(replacement: Dictionary) -> void:
	var previous_preview := get_preview()
	_state = replacement.duplicate(true)
	_apply_origin_to_scene()
	calibration_changed.emit(get_state())
	var current_preview := get_preview()
	if current_preview != previous_preview:
		preview_changed.emit(current_preview)


func _clear_local_replica() -> void:
	_state = _make_default_state()
	_next_point_id = 1
	_peer_snapshot_request_msec.clear()
	_apply_origin_to_scene()
	calibration_changed.emit(get_state())
	preview_changed.emit({})


func _normalize_state(value: Variant) -> Dictionary:
	if not (value is Dictionary) or not _is_encoded_size_within(value, MAX_SNAPSHOT_BYTES):
		return {}
	var source := value as Dictionary
	var revision_value = source.get("revision", -1)
	var status_value = source.get("status", null)
	var origin_value = source.get("origin_global", null)
	var points_value = source.get("confirmed_points", null)
	var preview_value = source.get("preview", null)
	var metrics_value = source.get("metrics", null)
	if not (revision_value is int) or int(revision_value) < 0 or int(revision_value) > MAX_REVISION:
		return {}
	if not (status_value is String) or str(status_value) not in VALID_STATUSES:
		return {}
	if not (origin_value is Transform3D) or not Contract.is_valid_origin_transform(origin_value as Transform3D):
		return {}
	if not (points_value is Array) or (points_value as Array).size() > MAX_CONFIRMED_POINTS:
		return {}
	if not (preview_value is Dictionary) or not (metrics_value is Dictionary):
		return {}
	if not _is_safe_payload(metrics_value as Dictionary, MAX_METRICS_BYTES):
		return {}
	var points: Array[Dictionary] = []
	var seen_ids: Dictionary = {}
	for point_value in points_value as Array:
		var point := _normalize_point(point_value)
		if point.is_empty() or seen_ids.has(str(point["id"])):
			return {}
		seen_ids[str(point["id"])] = true
		points.append(point)
	var preview := _normalize_preview(preview_value)
	if not (preview_value as Dictionary).is_empty() and preview.is_empty():
		return {}
	var source_label := _normalize_label(str(source.get("source", "")), "")
	var reason_label := _normalize_label(str(source.get("reason", "")), "")
	if str(source.get("source", "")) != "" and source_label.is_empty():
		return {}
	if str(source.get("reason", "")) != "" and reason_label.is_empty():
		return {}
	return {
		"revision": int(revision_value),
		"status": str(status_value),
		"origin_global": origin_value,
		"preview": preview,
		"confirmed_points": points,
		"metrics": (metrics_value as Dictionary).duplicate(true),
		"source": source_label,
		"reason": reason_label,
	}


func _normalize_point(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {}
	var source := value as Dictionary
	var point_id = source.get("id", null)
	var position_value = source.get("shared_position", null)
	var data_value = source.get("data", null)
	if not (point_id is String) or not _is_valid_identifier(str(point_id)):
		return {}
	if not (position_value is Vector3) or not Contract.is_valid_shared_point(position_value as Vector3):
		return {}
	if not (data_value is Dictionary) or not _is_safe_payload(data_value as Dictionary, MAX_METADATA_BYTES):
		return {}
	return {
		"id": str(point_id),
		"shared_position": position_value,
		"data": (data_value as Dictionary).duplicate(true),
	}


func _normalize_preview(value: Variant) -> Dictionary:
	if not (value is Dictionary):
		return {}
	var source := value as Dictionary
	if source.is_empty():
		return {}
	if source.get("visible", null) != true:
		return {}
	var position_value = source.get("shared_position", null)
	var data_value = source.get("data", null)
	if not (position_value is Vector3) or not Contract.is_valid_shared_point(position_value as Vector3):
		return {}
	if not (data_value is Dictionary) or not _is_safe_payload(data_value as Dictionary, MAX_METADATA_BYTES):
		return {}
	return {
		"visible": true,
		"shared_position": position_value,
		"data": (data_value as Dictionary).duplicate(true),
	}


func _is_safe_payload(value: Dictionary, max_bytes: int) -> bool:
	return _is_safe_value(value, 0) and _is_encoded_size_within(value, max_bytes)


func _is_safe_value(value: Variant, depth: int) -> bool:
	if depth > MAX_VALUE_DEPTH:
		return false
	if value == null or value is bool or value is int:
		return true
	if value is float:
		return Contract.is_finite_number(float(value))
	if value is String:
		return (value as String).to_utf8_buffer().size() <= MAX_STRING_BYTES \
			and not _has_control_characters(value as String)
	if value is Vector2:
		return Contract.is_finite_vector2(value as Vector2) \
			and (value as Vector2).length() <= MAX_METADATA_VECTOR_LENGTH
	if value is Vector3:
		return Contract.is_finite_vector3(value as Vector3) \
			and (value as Vector3).length() <= MAX_METADATA_VECTOR_LENGTH
	if value is Color:
		var color := value as Color
		return Contract.is_finite_number(color.r) \
			and Contract.is_finite_number(color.g) \
			and Contract.is_finite_number(color.b) \
			and Contract.is_finite_number(color.a)
	if value is Array:
		var array := value as Array
		if array.size() > MAX_ARRAY_ENTRIES:
			return false
		for item in array:
			if not _is_safe_value(item, depth + 1):
				return false
		return true
	if value is Dictionary:
		var dictionary := value as Dictionary
		if dictionary.size() > MAX_DICTIONARY_ENTRIES:
			return false
		for key in dictionary:
			if not (key is String) or not _is_valid_key(str(key)):
				return false
			if not _is_safe_value(dictionary[key], depth + 1):
				return false
		return true
	return false


func _is_valid_key(value: String) -> bool:
	return not value.is_empty() \
		and value.to_utf8_buffer().size() <= MAX_KEY_BYTES \
		and not _has_control_characters(value)


func _is_valid_identifier(value: String) -> bool:
	if value.is_empty() or value.to_utf8_buffer().size() > MAX_LABEL_BYTES:
		return false
	for character in value:
		var code := character.unicode_at(0)
		if not ((code >= 48 and code <= 57) \
				or (code >= 65 and code <= 90) \
				or (code >= 97 and code <= 122) \
				or character in ["_", "-"]):
			return false
	return true


func _normalize_label(value: String, default_value: String) -> String:
	var normalized := value.strip_edges()
	if normalized.is_empty():
		return default_value
	if normalized.to_utf8_buffer().size() > MAX_LABEL_BYTES or _has_control_characters(normalized):
		return ""
	return normalized


func _has_control_characters(value: String) -> bool:
	for character in value:
		if character.unicode_at(0) < 32:
			return true
	return false


func _is_encoded_size_within(value: Variant, limit: int) -> bool:
	return var_to_bytes(value).size() <= limit


func _make_default_state() -> Dictionary:
	return {
		"revision": 0,
		"status": STATUS_UNCALIBRATED,
		"origin_global": Transform3D.IDENTITY,
		"preview": {},
		"confirmed_points": [],
		"metrics": {},
		"source": "",
		"reason": "",
	}


func _require_server_authority(operation: String) -> bool:
	if _is_server_authority():
		return true
	_reject("server_authority_required:%s" % operation)
	return false


func _reject(reason: String) -> void:
	operation_rejected.emit(reason)


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


func _resolve_shared_space_origin() -> Node3D:
	if not shared_space_origin_path.is_empty():
		return get_node_or_null(shared_space_origin_path) as Node3D
	var current_scene := get_tree().current_scene
	if current_scene == null:
		return null
	var grouped := current_scene.find_children("*", "Node3D", true, false).filter(
		func(candidate: Node) -> bool: return candidate.is_in_group("shared_space_origin")
	)
	if grouped.size() == 1:
		return grouped[0] as Node3D
	if grouped.size() > 1:
		push_warning("SpatialCalibrationState requires exactly one SharedSpaceOrigin in the active scene.")
		return null
	return current_scene.find_child("SharedSpaceOrigin", true, false) as Node3D


func _apply_origin_to_scene() -> void:
	if not is_inside_tree():
		return
	var origin := _resolve_shared_space_origin()
	if origin != null and not origin.is_queued_for_deletion():
		origin.global_transform = get_origin_global_transform()


func _on_tree_node_added(node: Node) -> void:
	if node.name == &"SharedSpaceOrigin" or node.is_in_group("shared_space_origin"):
		call_deferred("_apply_origin_to_scene")


func _on_connected_to_server() -> void:
	_clear_local_replica()
	call_deferred("request_snapshot")


func _on_server_disconnected() -> void:
	_clear_local_replica()


func _on_peer_connected(peer_id: int) -> void:
	if _is_server_authority():
		call_deferred("_send_snapshot", peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_peer_snapshot_request_msec.erase(peer_id)
	if peer_id == SERVER_PEER_ID and not _is_server_authority():
		_clear_local_replica()


func _on_network_role_selected(is_server_role: bool) -> void:
	if is_server_role and _is_server_authority():
		_clear_local_replica()
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
	if authority.has_signal("network_role_selected") \
			and authority.is_connected("network_role_selected", _on_network_role_selected):
		authority.disconnect("network_role_selected", _on_network_role_selected)
	if authority.has_signal("session_closed") \
			and authority.is_connected("session_closed", _on_session_closed):
		authority.disconnect("session_closed", _on_session_closed)
